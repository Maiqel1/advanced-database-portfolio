\set ON_ERROR_STOP off
\set QUIET on
\pset pager off
\pset null '(none)'
SET client_min_messages = warning;
SET search_path = tomiwa, public;
SET application_name = 'session_a';

\echo '################################################################'
\echo 'PORTFOLIO 3: TRANSACTIONS AND CONCURRENCY'
\echo 'All demonstrations run at Tomiwa Hospitals Ilorin (branch 1).'
\echo 'Session A is this script. Session B is a second connection opened with dblink.'
\echo '################################################################'

\echo
\echo '=== Setup'
CREATE EXTENSION IF NOT EXISTS dblink SCHEMA public;
SELECT to_regclass('p3_demo.saved_stock') IS NOT NULL AS leftover \gset
\if :leftover
UPDATE branch_stock s
SET quantity_in_stock = ss.quantity_in_stock
FROM p3_demo.saved_stock ss
WHERE s.branch_id = ss.branch_id AND s.drug_id = ss.drug_id;
\endif
DELETE FROM restock_request WHERE branch_id = 1 AND requested_at >= '2026-10-19';
DELETE FROM prescription_item WHERE prescription_id IN (
    SELECT pr.prescription_id FROM prescription pr
    JOIN visit v ON v.visit_id = pr.visit_id
    JOIN patient p ON p.patient_id = v.patient_id
    WHERE p.hospital_number LIKE 'TH-DEMO%');
DELETE FROM prescription WHERE visit_id IN (
    SELECT v.visit_id FROM visit v
    JOIN patient p ON p.patient_id = v.patient_id
    WHERE p.hospital_number LIKE 'TH-DEMO%');
DELETE FROM visit WHERE patient_id IN (SELECT patient_id FROM patient WHERE hospital_number LIKE 'TH-DEMO%');
DELETE FROM appointment WHERE patient_id IN (SELECT patient_id FROM patient WHERE hospital_number LIKE 'TH-DEMO%');
DELETE FROM patient WHERE hospital_number LIKE 'TH-DEMO%';
DROP SCHEMA IF EXISTS p3_demo CASCADE;
CREATE SCHEMA p3_demo;

CREATE TABLE p3_demo.saved_stock AS
SELECT branch_id, drug_id, quantity_in_stock
FROM branch_stock
WHERE branch_id = 1 AND drug_id IN (1, 4);

CREATE FUNCTION p3_demo.b(cmd text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    r text;
BEGIN
    r := dblink_exec('b', cmd, false);
    IF r = 'ERROR' THEN
        RETURN dblink_error_message('b');
    END IF;
    RETURN r;
END;
$$;

CREATE FUNCTION p3_demo.b_value(query text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v text;
BEGIN
    SELECT t.v INTO v FROM dblink('b', query, false) AS t(v text);
    IF NOT FOUND THEN
        RETURN dblink_error_message('b');
    END IF;
    RETURN v;
END;
$$;

CREATE FUNCTION p3_demo.b_send(cmd text) RETURNS text LANGUAGE sql AS $$
    SELECT CASE dblink_send_query('b', cmd)
               WHEN 1 THEN 'sent: running in the background'
               ELSE dblink_error_message('b') END;
$$;

CREATE FUNCTION p3_demo.b_wait() RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v text;
    got boolean;
BEGIN
    SELECT t.v INTO v FROM dblink_get_result('b', false) AS t(v text);
    got := FOUND;
    PERFORM * FROM dblink_get_result('b', false) AS t(v text);
    IF NOT got THEN
        RETURN dblink_error_message('b');
    END IF;
    RETURN v;
END;
$$;

CREATE FUNCTION p3_demo.who_waits()
RETURNS TABLE (session text, state text, waiting_on text, blocked_by text)
LANGUAGE sql AS $$
    SELECT a.application_name, a.state, a.wait_event_type || ': ' || a.wait_event,
           (SELECT string_agg(o.application_name, ', ')
            FROM pg_stat_activity o
            WHERE o.pid = ANY (pg_blocking_pids(a.pid)))
    FROM pg_stat_activity a
    WHERE a.application_name = 'session_b';
$$;

CREATE FUNCTION p3_demo.stock()
RETURNS TABLE (drug text, in_stock integer)
LANGUAGE sql AS $$
    SELECT d.name || ' ' || d.strength, s.quantity_in_stock
    FROM branch_stock s
    JOIN drug d ON d.drug_id = s.drug_id
    WHERE s.branch_id = 1 AND s.drug_id IN (1, 4)
    ORDER BY s.drug_id;
$$;

INSERT INTO patient (hospital_number, first_name, last_name, date_of_birth, sex, phone, address,
                     registered_branch_id, registered_at)
VALUES ('TH-DEMO0001', 'Demo', 'Patient A', '1990-01-01', 'F', '0800 000 0001', '1 Demo Street, Ilorin', 1, '2026-10-19 08:00'),
       ('TH-DEMO0002', 'Demo', 'Patient B', '1985-05-05', 'M', '0800 000 0002', '2 Demo Street, Ilorin', 1, '2026-10-19 08:05');
SELECT patient_id AS pat_a FROM patient WHERE hospital_number = 'TH-DEMO0001' \gset
SELECT patient_id AS pat_b FROM patient WHERE hospital_number = 'TH-DEMO0002' \gset

INSERT INTO visit (patient_id, branch_id, doctor_id, checked_in_by, checked_in_at, status)
VALUES (:pat_a, 1, 3, 19, '2026-10-19 09:00', 'at_pharmacy') RETURNING visit_id AS visit_a \gset
INSERT INTO visit (patient_id, branch_id, doctor_id, checked_in_by, checked_in_at, status)
VALUES (:pat_b, 1, 3, 19, '2026-10-19 09:10', 'at_pharmacy') RETURNING visit_id AS visit_b \gset

INSERT INTO prescription (visit_id, prescribed_by, prescribed_at)
VALUES (:visit_a, 3, '2026-10-19 09:40') RETURNING prescription_id AS rx_a \gset
INSERT INTO prescription (visit_id, prescribed_by, prescribed_at)
VALUES (:visit_b, 3, '2026-10-19 09:50') RETURNING prescription_id AS rx_b \gset

INSERT INTO prescription_item (prescription_id, drug_id, dose, frequency, duration_days, quantity, instructions) VALUES
    (:rx_a, 1, '2 tablets', 'three times daily', 3, 18, 'For fever'),
    (:rx_a, 4, '1 capsule', 'three times daily', 5, 15, 'Complete the course'),
    (:rx_b, 1, '2 tablets', 'three times daily', 3, 18, 'For fever'),
    (:rx_b, 4, '2 capsules', 'three times daily', 8, 48, 'Complete the course');

UPDATE branch_stock SET quantity_in_stock = 100 WHERE branch_id = 1 AND drug_id = 1;
UPDATE branch_stock SET quantity_in_stock = 40 WHERE branch_id = 1 AND drug_id = 4;

SELECT dblink_connect('b', 'dbname=hospital user=hospital_admin application_name=session_b') AS session_b_connected;

SELECT :'rx_a' AS prescription_a, :'rx_b' AS prescription_b, 'pharmacists: staff 27 and 28' AS staff;
\echo 'Prescription A: paracetamol 18 + amoxicillin 15. Prescription B: paracetamol 18 + amoxicillin 48.'
SELECT * FROM p3_demo.stock();

\set QUIET off
\set ECHO queries

\echo
\echo '################################################################'
\echo 'PART 1: ATOMICITY - all or nothing'
\echo '################################################################'

\echo
\echo '=== 1.1 COMMIT: pharmacist 27 dispenses prescription A as one transaction'
BEGIN;
UPDATE branch_stock SET quantity_in_stock = quantity_in_stock - 18 WHERE branch_id = 1 AND drug_id = 1;
UPDATE prescription_item SET dispensed_by = 27, dispensed_at = '2026-10-19 10:00' WHERE prescription_id = :rx_a AND drug_id = 1;
UPDATE branch_stock SET quantity_in_stock = quantity_in_stock - 15 WHERE branch_id = 1 AND drug_id = 4;
UPDATE prescription_item SET dispensed_by = 27, dispensed_at = '2026-10-19 10:00' WHERE prescription_id = :rx_a AND drug_id = 4;
COMMIT;
SELECT * FROM p3_demo.stock();

\echo
\echo '=== 1.2 ROLLBACK: prescription B needs 48 amoxicillin but only 25 are in stock'
BEGIN;
UPDATE branch_stock SET quantity_in_stock = quantity_in_stock - 18 WHERE branch_id = 1 AND drug_id = 1;
UPDATE prescription_item SET dispensed_by = 27, dispensed_at = '2026-10-19 10:10' WHERE prescription_id = :rx_b AND drug_id = 1;
UPDATE branch_stock SET quantity_in_stock = quantity_in_stock - 48 WHERE branch_id = 1 AND drug_id = 4;
UPDATE prescription_item SET dispensed_by = 27, dispensed_at = '2026-10-19 10:10' WHERE prescription_id = :rx_b AND drug_id = 4;
COMMIT;
\echo 'The paracetamol already taken off inside the transaction was put back too:'
SELECT * FROM p3_demo.stock();
SELECT drug_id, quantity, dispensed_by FROM prescription_item WHERE prescription_id = :rx_b ORDER BY drug_id;

\echo
\echo '=== 1.3 SAVEPOINT: dispense what is available, request a restock for the rest'
BEGIN;
UPDATE branch_stock SET quantity_in_stock = quantity_in_stock - 18 WHERE branch_id = 1 AND drug_id = 1;
UPDATE prescription_item SET dispensed_by = 27, dispensed_at = '2026-10-19 10:15' WHERE prescription_id = :rx_b AND drug_id = 1;
SAVEPOINT before_amoxicillin;
UPDATE branch_stock SET quantity_in_stock = quantity_in_stock - 48 WHERE branch_id = 1 AND drug_id = 4;
ROLLBACK TO SAVEPOINT before_amoxicillin;
INSERT INTO restock_request (branch_id, drug_id, quantity_requested, requested_by, requested_at, status)
VALUES (1, 4, 200, 2, '2026-10-19 10:16', 'pending');
COMMIT;
SELECT * FROM p3_demo.stock();
SELECT drug_id, quantity, dispensed_by FROM prescription_item WHERE prescription_id = :rx_b ORDER BY drug_id;
SELECT request_id, drug_id, quantity_requested, status FROM restock_request WHERE branch_id = 1 AND requested_at >= '2026-10-19';

\echo
\echo '=== 1.4 A rule inside the transaction fails: a nurse (staff 11) is recorded as dispensing'
BEGIN;
UPDATE prescription_item SET dispensed_by = 11, dispensed_at = '2026-10-19 10:20' WHERE prescription_id = :rx_b AND drug_id = 4;
ROLLBACK;

\echo
\echo '################################################################'
\echo 'PART 2: ISOLATION - what one session can see of another'
\echo '################################################################'

\echo
\echo '=== 2.1 No dirty reads: B cannot see A''s uncommitted change'
BEGIN;
UPDATE branch_stock SET quantity_in_stock = 0 WHERE branch_id = 1 AND drug_id = 4;
SELECT p3_demo.b_value('SELECT quantity_in_stock FROM branch_stock WHERE branch_id = 1 AND drug_id = 4') AS "session B reads amoxicillin";
ROLLBACK;

\echo
\echo '=== 2.2 READ COMMITTED: a non-repeatable read'
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT quantity_in_stock AS "A reads amoxicillin" FROM branch_stock WHERE branch_id = 1 AND drug_id = 4;
SELECT p3_demo.b('UPDATE branch_stock SET quantity_in_stock = quantity_in_stock + 200 WHERE branch_id = 1 AND drug_id = 4') AS "session B: a delivery of 200 is recorded";
SELECT quantity_in_stock AS "A reads amoxicillin again" FROM branch_stock WHERE branch_id = 1 AND drug_id = 4;
COMMIT;

\echo
\echo '=== 2.3 REPEATABLE READ: the same read gives the same answer'
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT quantity_in_stock AS "A reads amoxicillin" FROM branch_stock WHERE branch_id = 1 AND drug_id = 4;
SELECT p3_demo.b('UPDATE branch_stock SET quantity_in_stock = quantity_in_stock - 15 WHERE branch_id = 1 AND drug_id = 4') AS "session B: dispenses 15";
SELECT quantity_in_stock AS "A reads amoxicillin again" FROM branch_stock WHERE branch_id = 1 AND drug_id = 4;
COMMIT;
SELECT quantity_in_stock AS "A after its transaction ends" FROM branch_stock WHERE branch_id = 1 AND drug_id = 4;

\echo
\echo '=== 2.4 LOST UPDATE at READ COMMITTED: two pharmacists read the stock, subtract, and write the result'
\echo 'A dispenses 10 and B dispenses 5, so 15 should come off.'
BEGIN;
SELECT quantity_in_stock AS a_qty FROM branch_stock WHERE branch_id = 1 AND drug_id = 4 \gset
SELECT p3_demo.b('BEGIN') AS "session B";
SELECT p3_demo.b_value('SELECT quantity_in_stock FROM branch_stock WHERE branch_id = 1 AND drug_id = 4') AS b_qty \gset
\echo 'A read' :a_qty 'and B read' :b_qty
UPDATE branch_stock SET quantity_in_stock = :a_qty - 10 WHERE branch_id = 1 AND drug_id = 4;
COMMIT;
SELECT p3_demo.b(format('UPDATE branch_stock SET quantity_in_stock = %s WHERE branch_id = 1 AND drug_id = 4', :b_qty - 5)) AS "session B";
SELECT p3_demo.b('COMMIT') AS "session B";
SELECT quantity_in_stock AS "amoxicillin now", :a_qty - 15 AS "should be" FROM branch_stock WHERE branch_id = 1 AND drug_id = 4;

\echo
\echo '=== 2.5 FIX 1: subtract inside the UPDATE, so the row lock makes B wait'
BEGIN;
UPDATE branch_stock SET quantity_in_stock = quantity_in_stock - 10 WHERE branch_id = 1 AND drug_id = 4;
SELECT p3_demo.b_send('UPDATE branch_stock SET quantity_in_stock = quantity_in_stock - 5 WHERE branch_id = 1 AND drug_id = 4') AS "session B";
SELECT pg_sleep(0.5);
SELECT * FROM p3_demo.who_waits();
COMMIT;
SELECT p3_demo.b_wait() AS "session B finishes";
SELECT * FROM p3_demo.stock();

\echo
\echo '=== 2.6 FIX 2: SELECT ... FOR UPDATE when the program must read before it writes'
BEGIN;
SELECT quantity_in_stock AS a_qty FROM branch_stock WHERE branch_id = 1 AND drug_id = 4 FOR UPDATE \gset
\echo 'A read' :a_qty 'and now holds the row lock'
SELECT p3_demo.b('BEGIN') AS "session B";
SELECT p3_demo.b_send('SELECT quantity_in_stock FROM branch_stock WHERE branch_id = 1 AND drug_id = 4 FOR UPDATE') AS "session B";
SELECT pg_sleep(0.5);
SELECT * FROM p3_demo.who_waits();
UPDATE branch_stock SET quantity_in_stock = :a_qty - 10 WHERE branch_id = 1 AND drug_id = 4;
COMMIT;
SELECT p3_demo.b_wait() AS b_qty \gset
\echo 'B read' :b_qty 'only after A committed'
SELECT p3_demo.b(format('UPDATE branch_stock SET quantity_in_stock = %s WHERE branch_id = 1 AND drug_id = 4', :b_qty - 5)) AS "session B";
SELECT p3_demo.b('COMMIT') AS "session B";
SELECT * FROM p3_demo.stock();

\echo
\echo '=== 2.7 FIX 3: REPEATABLE READ refuses the second write, and B retries'
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT quantity_in_stock AS a_qty FROM branch_stock WHERE branch_id = 1 AND drug_id = 4 \gset
SELECT p3_demo.b('BEGIN ISOLATION LEVEL REPEATABLE READ') AS "session B";
SELECT p3_demo.b_value('SELECT quantity_in_stock FROM branch_stock WHERE branch_id = 1 AND drug_id = 4') AS b_qty \gset
\echo 'A read' :a_qty 'and B read' :b_qty
UPDATE branch_stock SET quantity_in_stock = :a_qty - 10 WHERE branch_id = 1 AND drug_id = 4;
COMMIT;
SELECT p3_demo.b(format('UPDATE branch_stock SET quantity_in_stock = %s WHERE branch_id = 1 AND drug_id = 4', :b_qty - 5)) AS "session B";
SELECT p3_demo.b('ROLLBACK') AS "session B";
\echo 'B retries from the start:'
SELECT p3_demo.b('BEGIN ISOLATION LEVEL REPEATABLE READ') AS "session B";
SELECT p3_demo.b_value('SELECT quantity_in_stock FROM branch_stock WHERE branch_id = 1 AND drug_id = 4') AS b_qty \gset
\echo 'B now reads' :b_qty
SELECT p3_demo.b(format('UPDATE branch_stock SET quantity_in_stock = %s WHERE branch_id = 1 AND drug_id = 4', :b_qty - 5)) AS "session B";
SELECT p3_demo.b('COMMIT') AS "session B";
SELECT * FROM p3_demo.stock();

\echo
\echo '################################################################'
\echo 'PART 3: DOUBLE-BOOKING AND WRITE SKEW'
\echo '################################################################'
\echo 'Two receptionists book doctor 3 at 10:00 on 20 October for different patients.'
\echo 'Each first checks the slot is free, then books it.'

CREATE TABLE p3_demo.slot_booking (doctor_id integer, scheduled_for timestamp, patient_id integer, status text);

\echo
\echo '=== 3.1 With no rule in the database, at READ COMMITTED'
BEGIN;
SELECT count(*) AS "bookings A sees" FROM p3_demo.slot_booking WHERE doctor_id = 3 AND scheduled_for = '2026-10-20 10:00' AND status <> 'cancelled';
SELECT p3_demo.b('BEGIN') AS "session B";
SELECT p3_demo.b_value('SELECT count(*) FROM p3_demo.slot_booking WHERE doctor_id = 3 AND scheduled_for = ''2026-10-20 10:00'' AND status <> ''cancelled''') AS "bookings B sees";
INSERT INTO p3_demo.slot_booking VALUES (3, '2026-10-20 10:00', :pat_a, 'booked');
SELECT p3_demo.b(format('INSERT INTO p3_demo.slot_booking VALUES (3, %L, %s, %L)', '2026-10-20 10:00', :pat_b, 'booked')) AS "session B";
COMMIT;
SELECT p3_demo.b('COMMIT') AS "session B";
SELECT * FROM p3_demo.slot_booking ORDER BY patient_id;

\echo
\echo '=== 3.2 The same, at SERIALIZABLE'
TRUNCATE p3_demo.slot_booking;
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) AS "bookings A sees" FROM p3_demo.slot_booking WHERE doctor_id = 3 AND scheduled_for = '2026-10-20 10:00' AND status <> 'cancelled';
SELECT p3_demo.b('BEGIN ISOLATION LEVEL SERIALIZABLE') AS "session B";
SELECT p3_demo.b_value('SELECT count(*) FROM p3_demo.slot_booking WHERE doctor_id = 3 AND scheduled_for = ''2026-10-20 10:00'' AND status <> ''cancelled''') AS "bookings B sees";
INSERT INTO p3_demo.slot_booking VALUES (3, '2026-10-20 10:00', :pat_a, 'booked');
SELECT p3_demo.b(format('INSERT INTO p3_demo.slot_booking VALUES (3, %L, %s, %L)', '2026-10-20 10:00', :pat_b, 'booked')) AS "session B";
COMMIT;
SELECT p3_demo.b('COMMIT') AS "session B";
SELECT * FROM p3_demo.slot_booking ORDER BY patient_id;

\echo
\echo '=== 3.3 The real appointment table, protected by the Portfolio 1 index appointment_no_double_booking'
BEGIN;
INSERT INTO appointment (patient_id, doctor_id, branch_id, scheduled_for, booked_via, booked_by, status)
VALUES (:pat_a, 3, 1, '2026-10-20 10:00', 'reception', 19, 'booked');
SELECT p3_demo.b_send(format('INSERT INTO appointment (patient_id, doctor_id, branch_id, scheduled_for, booked_via, booked_by, status) VALUES (%s, 3, 1, %L, %L, 20, %L)', :pat_b, '2026-10-20 10:00', 'reception', 'booked')) AS "session B";
SELECT pg_sleep(0.5);
SELECT * FROM p3_demo.who_waits();
COMMIT;
SELECT p3_demo.b_wait() AS "session B finishes";
SELECT a.patient_id, p.hospital_number, a.scheduled_for, a.status
FROM appointment a JOIN patient p ON p.patient_id = a.patient_id
WHERE a.doctor_id = 3 AND a.scheduled_for = '2026-10-20 10:00';

\echo
\echo '=== 3.4 WRITE SKEW: doctors on call'
\echo 'Rule: Ilorin must always have at least one doctor on call tonight.'
\echo 'Doctors 3 and 4 are both on call, and each asks to go off call at the same time.'
CREATE TABLE p3_demo.on_call (branch_id integer, doctor_id integer, on_call boolean NOT NULL, PRIMARY KEY (branch_id, doctor_id));
INSERT INTO p3_demo.on_call VALUES (1, 3, true), (1, 4, true);

\echo
\echo '--- At REPEATABLE READ'
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) AS "on call, seen by A" FROM p3_demo.on_call WHERE branch_id = 1 AND on_call;
SELECT p3_demo.b('BEGIN ISOLATION LEVEL REPEATABLE READ') AS "session B";
SELECT p3_demo.b_value('SELECT count(*) FROM p3_demo.on_call WHERE branch_id = 1 AND on_call') AS "on call, seen by B";
UPDATE p3_demo.on_call SET on_call = false WHERE branch_id = 1 AND doctor_id = 3;
SELECT p3_demo.b('UPDATE p3_demo.on_call SET on_call = false WHERE branch_id = 1 AND doctor_id = 4') AS "session B";
COMMIT;
SELECT p3_demo.b('COMMIT') AS "session B";
SELECT count(*) AS "doctors on call now" FROM p3_demo.on_call WHERE branch_id = 1 AND on_call;

UPDATE p3_demo.on_call SET on_call = true;

\echo
\echo '--- At SERIALIZABLE'
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) AS "on call, seen by A" FROM p3_demo.on_call WHERE branch_id = 1 AND on_call;
SELECT p3_demo.b('BEGIN ISOLATION LEVEL SERIALIZABLE') AS "session B";
SELECT p3_demo.b_value('SELECT count(*) FROM p3_demo.on_call WHERE branch_id = 1 AND on_call') AS "on call, seen by B";
UPDATE p3_demo.on_call SET on_call = false WHERE branch_id = 1 AND doctor_id = 3;
SELECT p3_demo.b('UPDATE p3_demo.on_call SET on_call = false WHERE branch_id = 1 AND doctor_id = 4') AS "session B";
COMMIT;
SELECT p3_demo.b('COMMIT') AS "session B";
\echo 'B retries from the start:'
SELECT p3_demo.b('BEGIN ISOLATION LEVEL SERIALIZABLE') AS "session B";
SELECT p3_demo.b_value('SELECT count(*) FROM p3_demo.on_call WHERE branch_id = 1 AND on_call') AS "on call, seen by B on retry";
\echo 'Only one doctor is on call, so B''s request is refused and B rolls back.'
SELECT p3_demo.b('ROLLBACK') AS "session B";
SELECT doctor_id, on_call FROM p3_demo.on_call ORDER BY doctor_id;

\echo
\echo '################################################################'
\echo 'PART 4: DEADLOCK'
\echo '################################################################'
\echo 'A: the head of pharmacy records a delivery of both drugs, paracetamol first.'
\echo 'B: a pharmacist dispenses both drugs, amoxicillin first.'

\echo
\echo '=== 4.1 Opposite order'
BEGIN;
UPDATE branch_stock SET quantity_in_stock = quantity_in_stock + 100 WHERE branch_id = 1 AND drug_id = 1;
SELECT p3_demo.b('BEGIN') AS "session B";
SELECT p3_demo.b('UPDATE branch_stock SET quantity_in_stock = quantity_in_stock - 10 WHERE branch_id = 1 AND drug_id = 4') AS "session B";
SELECT p3_demo.b_send('UPDATE branch_stock SET quantity_in_stock = quantity_in_stock - 18 WHERE branch_id = 1 AND drug_id = 1') AS "session B";
SELECT pg_sleep(0.3);
SELECT * FROM p3_demo.who_waits();
UPDATE branch_stock SET quantity_in_stock = quantity_in_stock + 100 WHERE branch_id = 1 AND drug_id = 4;
SELECT p3_demo.b_wait() AS "session B finishes";
SELECT p3_demo.b('ROLLBACK') AS "session B";
COMMIT;
SELECT * FROM p3_demo.stock();

\echo
\echo '=== 4.2 Fix: every transaction updates stock rows in the same order (lowest drug_id first)'
BEGIN;
UPDATE branch_stock SET quantity_in_stock = quantity_in_stock + 100 WHERE branch_id = 1 AND drug_id = 1;
SELECT p3_demo.b('BEGIN') AS "session B";
SELECT p3_demo.b_send('UPDATE branch_stock SET quantity_in_stock = quantity_in_stock - 18 WHERE branch_id = 1 AND drug_id = 1') AS "session B";
SELECT pg_sleep(0.3);
SELECT * FROM p3_demo.who_waits();
UPDATE branch_stock SET quantity_in_stock = quantity_in_stock + 100 WHERE branch_id = 1 AND drug_id = 4;
COMMIT;
SELECT p3_demo.b_wait() AS "session B finishes";
SELECT p3_demo.b('UPDATE branch_stock SET quantity_in_stock = quantity_in_stock - 10 WHERE branch_id = 1 AND drug_id = 4') AS "session B";
SELECT p3_demo.b('COMMIT') AS "session B";
SELECT * FROM p3_demo.stock();

\set ECHO none
\set QUIET on

\echo
\echo '################################################################'
\echo 'CLEANUP: restoring the stock levels and removing the demo rows'
\echo '################################################################'
SELECT dblink_disconnect('b') AS session_b_disconnected;
UPDATE branch_stock s
SET quantity_in_stock = ss.quantity_in_stock
FROM p3_demo.saved_stock ss
WHERE s.branch_id = ss.branch_id AND s.drug_id = ss.drug_id;
DELETE FROM restock_request WHERE branch_id = 1 AND requested_at >= '2026-10-19';
DELETE FROM prescription_item WHERE prescription_id IN (:rx_a, :rx_b);
DELETE FROM prescription WHERE prescription_id IN (:rx_a, :rx_b);
DELETE FROM visit WHERE visit_id IN (:visit_a, :visit_b);
DELETE FROM appointment WHERE patient_id IN (:pat_a, :pat_b);
DELETE FROM patient WHERE patient_id IN (:pat_a, :pat_b);
DROP SCHEMA p3_demo CASCADE;
SELECT (SELECT count(*) FROM patient) AS patients, (SELECT count(*) FROM visit) AS visits,
       (SELECT count(*) FROM appointment) AS appointments, (SELECT count(*) FROM restock_request) AS restock_requests;
\echo 'Done.'
