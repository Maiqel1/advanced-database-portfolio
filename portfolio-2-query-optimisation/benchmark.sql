\set ON_ERROR_STOP on
\set QUIET on
\pset pager off
\pset null '(none)'
SET search_path = tomiwa, public;
SET client_min_messages = warning;

\echo '################################################################'
\echo 'PORTFOLIO 2 BENCHMARK: Tomiwa Hospitals query optimisation'
\echo '################################################################'
SELECT version();
SELECT count(*) AS visits FROM visit;

\echo
\echo '=== Resetting to the Portfolio 1 baseline (no Portfolio 2 indexes or views)'
DROP MATERIALIZED VIEW IF EXISTS monthly_diagnosis_by_state;
DROP INDEX IF EXISTS visit_patient_checked_in_idx, diagnosis_visit_idx, lab_order_visit_idx,
    payment_received_at_idx, charge_payment_idx, visit_branch_checked_in_idx, patient_lower_name_idx;
VACUUM (ANALYZE) visit, diagnosis, lab_order, payment, charge, patient, appointment;

\echo
\echo '=== Inputs chosen from the data'
SELECT v.patient_id AS pid, p.hospital_number AS patient_hn,
       lower(p.first_name) AS first_name, lower(p.last_name) AS last_name,
       count(*) AS patient_visits
FROM visit v
JOIN patient p ON p.patient_id = v.patient_id
GROUP BY v.patient_id, p.hospital_number, p.first_name, p.last_name
ORDER BY count(*) DESC, v.patient_id
LIMIT 1 \gset
SELECT coalesce(max(o.visit_id) FILTER (WHERE i.test_id = 2), max(o.visit_id)) AS lab_visit
FROM lab_order o
JOIN lab_order_item i ON i.lab_order_id = o.lab_order_id
JOIN visit v ON v.visit_id = o.visit_id
WHERE v.patient_id = :pid \gset
SELECT :'patient_hn' AS patient, :patient_visits AS visits_in_year,
       :'first_name' || ' ' || :'last_name' AS name_searched, :lab_visit AS lab_report_visit,
       'doctor 32, Ikeja, 15 Sep 2026' AS day_list, 'Ikeja, 15 Sep 2026' AS branch_day;

CREATE FUNCTION pg_temp.measure(q text, runs integer DEFAULT 5)
RETURNS TABLE (median_ms numeric, pages_hit bigint, pages_read bigint, scans text)
LANGUAGE plpgsql AS $$
DECLARE
    raw json;
    plan jsonb;
    times numeric[] := '{}';
BEGIN
    FOR i IN 1 .. runs LOOP
        EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || q INTO raw;
        plan := raw::jsonb;
        times := times || (plan -> 0 ->> 'Execution Time')::numeric;
    END LOOP;
    SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY t)::numeric, 2)
    INTO median_ms
    FROM unnest(times) AS t;
    pages_hit := (plan -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint;
    pages_read := (plan -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint;
    SELECT string_agg(DISTINCT label, '; ' ORDER BY label)
    INTO scans
    FROM (
        SELECT CASE WHEN (n ->> 'Parallel Aware')::boolean THEN 'Parallel ' ELSE '' END
               || (n ->> 'Node Type')
               || CASE WHEN n ? 'Index Name' THEN ' using ' || (n ->> 'Index Name')
                       WHEN n ? 'Relation Name' THEN ' on ' || (n ->> 'Relation Name')
                       ELSE '' END AS label
        FROM jsonb_path_query(plan, 'strict $.**') AS n
        WHERE jsonb_typeof(n) = 'object' AND (n ->> 'Node Type') LIKE '%Scan%'
    ) AS s;
    RETURN NEXT;
END;
$$;

CREATE TEMP TABLE bench (
    id text PRIMARY KEY,
    title text NOT NULL,
    before_sql text NOT NULL,
    after_sql text
);

INSERT INTO bench VALUES
('Q1', 'Patient history (doctor and reception)', format($q$
SELECT v.checked_in_at, b.name AS branch, s.first_name || ' ' || s.last_name AS doctor,
       d.icd10_code, dc.description
FROM patient p
JOIN visit v ON v.patient_id = p.patient_id
JOIN branch b ON b.branch_id = v.branch_id
JOIN staff s ON s.staff_id = v.doctor_id
LEFT JOIN diagnosis d ON d.visit_id = v.visit_id AND d.kind = 'final'
LEFT JOIN diagnosis_code dc ON dc.icd10_code = d.icd10_code
WHERE p.hospital_number = %L
ORDER BY v.checked_in_at DESC$q$, :'patient_hn'), NULL),

('Q2', 'Doctor''s day list (doctor portal)', $q$
SELECT a.scheduled_for, p.hospital_number, p.first_name || ' ' || p.last_name AS patient, a.status
FROM appointment a
JOIN patient p ON p.patient_id = a.patient_id
WHERE a.doctor_id = 32
  AND a.scheduled_for >= '2026-09-15' AND a.scheduled_for < '2026-09-16'
ORDER BY a.scheduled_for$q$, $q$
SELECT a.scheduled_for, p.hospital_number, p.first_name || ' ' || p.last_name AS patient, a.status
FROM appointment a
JOIN patient p ON p.patient_id = a.patient_id
WHERE a.doctor_id = 32
  AND a.scheduled_for >= '2026-09-15' AND a.scheduled_for < '2026-09-16'
  AND a.status <> 'cancelled'
ORDER BY a.scheduled_for$q$),

('Q3', 'Lab report for one visit (doctor review)', format($q$
SELECT t.name AS test, tp.name AS measurement,
       coalesce(r.value_numeric::text, r.value_text) AS result, tp.unit,
       CASE WHEN tp.normal_low IS NOT NULL THEN tp.normal_low || ' to ' || tp.normal_high END AS normal_range,
       CASE WHEN r.value_numeric < tp.normal_low THEN 'LOW'
            WHEN r.value_numeric > tp.normal_high THEN 'HIGH' END AS flag
FROM lab_order o
JOIN lab_order_item i ON i.lab_order_id = o.lab_order_id
JOIN lab_test t ON t.test_id = i.test_id
JOIN lab_result r ON r.lab_order_id = i.lab_order_id AND r.test_id = i.test_id
JOIN lab_test_parameter tp ON tp.parameter_id = r.parameter_id
WHERE o.visit_id = %s
ORDER BY o.lab_order_id, t.name, tp.parameter_id$q$, :lab_visit), NULL),

('Q4', 'Daily takings by payment method (branch manager)', $q$
SELECT p.method, count(DISTINCT p.payment_id) AS payments, sum(c.quantity * c.unit_price) AS amount
FROM payment p
JOIN charge c ON c.payment_id = p.payment_id
JOIN visit v ON v.visit_id = c.visit_id
WHERE p.received_at >= '2026-09-15' AND p.received_at < '2026-09-16'
  AND v.branch_id = 2
GROUP BY p.method
ORDER BY p.method$q$, NULL),

('Q5', 'Attendance by hour at one branch (branch manager)', $q$
SELECT extract(hour FROM v.checked_in_at) AS hour, count(*) AS visits
FROM visit v
WHERE v.branch_id = 2
  AND v.checked_in_at >= '2026-09-15' AND v.checked_in_at < '2026-09-16'
GROUP BY 1
ORDER BY 1$q$, NULL),

('Q6', 'Find a patient by name (reception)', format($q$
SELECT patient_id, hospital_number, first_name, last_name, date_of_birth, phone
FROM patient
WHERE lower(last_name) = %L AND lower(first_name) = %L
ORDER BY hospital_number$q$, :'last_name', :'first_name'), NULL),

('Q7', 'Confirmed malaria per state per month (public health)', $q$
SELECT b.state, date_trunc('month', d.made_at)::date AS month, count(*) AS cases
FROM diagnosis d
JOIN visit v ON v.visit_id = d.visit_id
JOIN branch b ON b.branch_id = v.branch_id
WHERE d.kind = 'final' AND d.icd10_code = 'B50.9'
GROUP BY b.state, date_trunc('month', d.made_at)::date
HAVING count(*) >= 1500
ORDER BY b.state, month$q$, $q$
SELECT state, month, cases
FROM monthly_diagnosis_by_state
WHERE icd10_code = 'B50.9' AND cases >= 1500
ORDER BY state, month$q$),

('Q8', 'Drugs below reorder level (head of pharmacy)', $q$
SELECT b.name AS branch, d.name AS drug, d.strength, s.quantity_in_stock, s.reorder_level
FROM branch_stock s
JOIN branch b ON b.branch_id = s.branch_id
JOIN drug d ON d.drug_id = s.drug_id
WHERE s.quantity_in_stock < s.reorder_level
ORDER BY b.name, d.name$q$, NULL);

UPDATE bench SET after_sql = before_sql WHERE after_sql IS NULL;

\echo
\echo '################################################################'
\echo 'PART 1: THE QUERIES AND THEIR RESULTS'
\echo '################################################################'
SELECT format('SELECT %L AS "Query"', id || ': ' || title), before_sql FROM bench ORDER BY id \gexec

\echo
\echo '################################################################'
\echo 'PART 2: BEFORE OPTIMISATION (Portfolio 1 baseline)'
\echo '################################################################'
\echo 'Warming the cache with one run of each query...'
SELECT count(*) AS warmed FROM bench, LATERAL pg_temp.measure(before_sql, 1);

CREATE TEMP TABLE result AS
SELECT b.id, 'before'::text AS phase, m.*
FROM bench b, LATERAL pg_temp.measure(b.before_sql) AS m;

SELECT format('SELECT %L AS "Plan before"', id || ': ' || title),
       'EXPLAIN (ANALYZE, BUFFERS) ' || before_sql
FROM bench ORDER BY id \gexec

\echo
\echo '################################################################'
\echo 'PART 3: APPLYING optimisations.sql'
\echo '################################################################'
\timing on
\i /portfolio/portfolio-2-query-optimisation/optimisations.sql
\timing off

\echo
\echo '################################################################'
\echo 'PART 4: AFTER OPTIMISATION'
\echo '################################################################'
SELECT count(*) AS warmed FROM bench, LATERAL pg_temp.measure(after_sql, 1);

INSERT INTO result
SELECT b.id, 'after', m.*
FROM bench b, LATERAL pg_temp.measure(b.after_sql) AS m;

SELECT format('SELECT %L AS "Plan after"', id || ': ' || title),
       'EXPLAIN (ANALYZE, BUFFERS) ' || after_sql
FROM bench ORDER BY id \gexec

\echo
\echo '################################################################'
\echo 'PART 5: SUMMARY (median of 5 runs, warm cache)'
\echo '################################################################'
SELECT b.id, b.title,
       bf.median_ms AS before_ms,
       af.median_ms AS after_ms,
       round(bf.median_ms / nullif(af.median_ms, 0), 1) AS times_faster,
       bf.pages_hit + bf.pages_read AS pages_before,
       af.pages_hit + af.pages_read AS pages_after
FROM bench b
JOIN result bf ON bf.id = b.id AND bf.phase = 'before'
JOIN result af ON af.id = b.id AND af.phase = 'after'
ORDER BY b.id;

\echo
\echo 'Scan methods used'
SELECT id, phase, scans FROM result ORDER BY id, phase DESC;

\echo
\echo '################################################################'
\echo 'PART 6: QUERY REWRITES'
\echo '################################################################'

CREATE TEMP TABLE rewrite (id text, variant text, sql text);
INSERT INTO rewrite VALUES
('R1', 'Q5 written with checked_in_at::date = ... (not sargable)', $q$
SELECT extract(hour FROM v.checked_in_at) AS hour, count(*) AS visits
FROM visit v
WHERE v.branch_id = 2 AND v.checked_in_at::date = '2026-09-15'
GROUP BY 1 ORDER BY 1$q$),
('R1', 'Q5 written as a date range (sargable)', (SELECT after_sql FROM bench WHERE id = 'Q5')),
('R2', 'IN (subquery)', $q$
SELECT count(*) FROM patient p
WHERE p.patient_id IN (SELECT v.patient_id FROM visit v
                       WHERE v.branch_id = 2
                         AND v.checked_in_at >= '2026-09-01' AND v.checked_in_at < '2026-10-01')$q$),
('R2', 'EXISTS (correlated subquery)', $q$
SELECT count(*) FROM patient p
WHERE EXISTS (SELECT 1 FROM visit v
              WHERE v.patient_id = p.patient_id AND v.branch_id = 2
                AND v.checked_in_at >= '2026-09-01' AND v.checked_in_at < '2026-10-01')$q$),
('R2', 'JOIN with DISTINCT', $q$
SELECT count(DISTINCT p.patient_id) FROM patient p
JOIN visit v ON v.patient_id = p.patient_id
WHERE v.branch_id = 2
  AND v.checked_in_at >= '2026-09-01' AND v.checked_in_at < '2026-10-01'$q$),
('R3', 'NOT EXISTS', $q$
SELECT count(*) FROM patient p
WHERE NOT EXISTS (SELECT 1 FROM visit v WHERE v.patient_id = p.patient_id)$q$),
('R4', 'Q4 as designed: branch found through charge and visit', (SELECT after_sql FROM bench WHERE id = 'Q4')),
('R4', 'Experiment: branch stored on payment', $q$
SELECT p.method, count(DISTINCT p.payment_id) AS payments, sum(c.quantity * c.unit_price) AS amount
FROM experiment.payment_with_branch p
JOIN charge c ON c.payment_id = p.payment_id
WHERE p.branch_id = 2
  AND p.received_at >= '2026-09-15' AND p.received_at < '2026-09-16'
GROUP BY p.method
ORDER BY p.method$q$);

\echo 'R4 setup: a copy of payment that also records the branch that received the money'
DROP SCHEMA IF EXISTS experiment CASCADE;
CREATE SCHEMA experiment;
CREATE TABLE experiment.payment_with_branch AS
SELECT p.payment_id, p.received_by, p.received_at, p.method, v.branch_id
FROM payment p
JOIN (SELECT payment_id, min(visit_id) AS visit_id
      FROM charge
      WHERE payment_id IS NOT NULL
      GROUP BY payment_id) AS cv ON cv.payment_id = p.payment_id
JOIN visit v ON v.visit_id = cv.visit_id;
ALTER TABLE experiment.payment_with_branch ADD PRIMARY KEY (payment_id);
CREATE INDEX ON experiment.payment_with_branch (branch_id, received_at);
VACUUM (ANALYZE) experiment.payment_with_branch;

\echo 'R4 check: both versions of Q4 give the same answer'
SELECT (SELECT after_sql FROM bench WHERE id = 'Q4') \gexec
SELECT (SELECT sql FROM rewrite WHERE variant = 'Experiment: branch stored on payment') \gexec

SELECT r.id, r.variant, m.median_ms, m.pages_hit + m.pages_read AS pages, m.scans
FROM rewrite r, LATERAL pg_temp.measure(r.sql) AS m
ORDER BY r.id;

\echo 'R4 plan with the branch stored on payment'
SELECT 'EXPLAIN (ANALYZE, BUFFERS) ' || sql FROM rewrite WHERE variant = 'Experiment: branch stored on payment' \gexec
DROP SCHEMA experiment CASCADE;

\echo
\echo 'R2 plans: IN and EXISTS'
EXPLAIN (COSTS OFF) SELECT count(*) FROM patient p
WHERE p.patient_id IN (SELECT v.patient_id FROM visit v
                       WHERE v.branch_id = 2
                         AND v.checked_in_at >= '2026-09-01' AND v.checked_in_at < '2026-10-01');
EXPLAIN (COSTS OFF) SELECT count(*) FROM patient p
WHERE EXISTS (SELECT 1 FROM visit v
              WHERE v.patient_id = p.patient_id AND v.branch_id = 2
                AND v.checked_in_at >= '2026-09-01' AND v.checked_in_at < '2026-10-01');

\echo
\echo 'R3: NOT EXISTS against NOT IN, "patients with no visit this year"'
SELECT (SELECT sql FROM rewrite WHERE id = 'R3') \gexec
EXPLAIN (COSTS OFF) SELECT count(*) FROM patient p
WHERE NOT EXISTS (SELECT 1 FROM visit v WHERE v.patient_id = p.patient_id);
EXPLAIN (COSTS OFF) SELECT count(*) FROM patient p
WHERE p.patient_id NOT IN (SELECT v.patient_id FROM visit v);
\echo 'Running the NOT IN version with a 30 second limit...'
\set ON_ERROR_STOP off
SET statement_timeout = '30s';
SELECT count(*) FROM patient p WHERE p.patient_id NOT IN (SELECT v.patient_id FROM visit v);
RESET statement_timeout;
\set ON_ERROR_STOP on

\echo
\echo '################################################################'
\echo 'PART 7: WHAT THE OPTIMISATIONS COST'
\echo '################################################################'

\echo 'Index sizes compared with their tables'
SELECT ic.relname AS index_name, tc.relname AS table_name,
       pg_size_pretty(pg_relation_size(ic.oid)) AS index_size,
       pg_size_pretty(pg_relation_size(tc.oid)) AS table_size
FROM pg_index i
JOIN pg_class ic ON ic.oid = i.indexrelid
JOIN pg_class tc ON tc.oid = i.indrelid
WHERE ic.relname IN ('visit_patient_checked_in_idx', 'diagnosis_visit_idx', 'lab_order_visit_idx',
                     'payment_received_at_idx', 'charge_payment_idx', 'visit_branch_checked_in_idx',
                     'patient_lower_name_idx', 'monthly_diagnosis_by_state_key')
ORDER BY pg_relation_size(ic.oid) DESC;

SELECT pg_size_pretty(pg_relation_size('monthly_diagnosis_by_state')) AS materialised_view_size,
       (SELECT count(*) FROM monthly_diagnosis_by_state) AS materialised_view_rows;

\echo
\echo 'Refreshing the materialised view (would run nightly)'
\timing on
REFRESH MATERIALIZED VIEW CONCURRENTLY monthly_diagnosis_by_state;
\timing off

\echo
\echo 'Inserting all 1,168,000 visits into a copy of the visit table'
DROP SCHEMA IF EXISTS benchmark CASCADE;
CREATE SCHEMA benchmark;
CREATE TABLE benchmark.visit_load (LIKE tomiwa.visit);

SELECT clock_timestamp() AS t0 \gset
INSERT INTO benchmark.visit_load SELECT * FROM tomiwa.visit;
SELECT round(1000 * extract(epoch FROM clock_timestamp() - :'t0'::timestamptz)) AS no_index_ms \gset

TRUNCATE benchmark.visit_load;
ALTER TABLE benchmark.visit_load ADD PRIMARY KEY (visit_id);
SELECT clock_timestamp() AS t0 \gset
INSERT INTO benchmark.visit_load SELECT * FROM tomiwa.visit;
SELECT round(1000 * extract(epoch FROM clock_timestamp() - :'t0'::timestamptz)) AS pk_ms \gset

TRUNCATE benchmark.visit_load;
CREATE INDEX ON benchmark.visit_load (patient_id, checked_in_at);
CREATE INDEX ON benchmark.visit_load (branch_id, checked_in_at);
SELECT clock_timestamp() AS t0 \gset
INSERT INTO benchmark.visit_load SELECT * FROM tomiwa.visit;
SELECT round(1000 * extract(epoch FROM clock_timestamp() - :'t0'::timestamptz)) AS all_ms \gset

SELECT 'no indexes' AS indexes_on_table, :no_index_ms AS insert_ms
UNION ALL SELECT 'primary key only', :pk_ms
UNION ALL SELECT 'primary key + 2 Portfolio 2 indexes', :all_ms;

DROP SCHEMA benchmark CASCADE;

\echo
\echo 'Benchmark complete.'
