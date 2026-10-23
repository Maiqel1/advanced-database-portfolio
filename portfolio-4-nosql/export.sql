\set ON_ERROR_STOP on
\set QUIET on
SET search_path = tomiwa, public;
SET client_min_messages = warning;

\echo 'Exporting September 2026 from PostgreSQL to /exchange as JSON documents...'

CREATE FUNCTION pg_temp.utc(ts timestamp) RETURNS json LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN ts IS NOT NULL THEN json_build_object('$date',
        to_char(ts AT TIME ZONE 'Africa/Lagos' AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')) END;
$$;

CREATE FUNCTION pg_temp.day(d date) RETURNS json LANGUAGE sql STABLE AS $$
    SELECT json_build_object('$date', to_char(d, 'YYYY-MM-DD') || 'T00:00:00.000Z');
$$;

CREATE FUNCTION pg_temp.person(id integer) RETURNS json LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN id IS NOT NULL THEN
        (SELECT json_build_object('id', s.staff_id, 'name', s.first_name || ' ' || s.last_name)
         FROM staff s WHERE s.staff_id = id) END;
$$;

CREATE TEMP TABLE sept AS
SELECT visit_id, patient_id FROM visit
WHERE checked_in_at >= '2026-09-01' AND checked_in_at < '2026-10-01';
ALTER TABLE sept ADD PRIMARY KEY (visit_id);
ANALYZE sept;

CREATE TEMP TABLE x_vitals AS
SELECT vs.visit_id,
       json_agg(json_build_object(
           'recordedAt', pg_temp.utc(vs.recorded_at),
           'recordedBy', pg_temp.person(vs.recorded_by),
           'temperatureC', vs.temperature_c,
           'bloodPressure', json_build_object('systolic', vs.systolic_bp, 'diastolic', vs.diastolic_bp),
           'pulseBpm', vs.pulse_bpm,
           'weightKg', vs.weight_kg) ORDER BY vs.recorded_at) AS doc
FROM vital_signs vs
JOIN sept s ON s.visit_id = vs.visit_id
GROUP BY vs.visit_id;

CREATE TEMP TABLE x_notes AS
SELECT cn.visit_id,
       json_agg(json_build_object(
           'writtenAt', pg_temp.utc(cn.written_at),
           'writtenBy', pg_temp.person(cn.written_by),
           'symptoms', cn.symptoms,
           'notes', cn.notes) ORDER BY cn.written_at) AS doc
FROM clinical_note cn
JOIN sept s ON s.visit_id = cn.visit_id
GROUP BY cn.visit_id;

CREATE TEMP TABLE x_diagnoses AS
SELECT d.visit_id,
       json_agg(json_build_object(
           'kind', d.kind,
           'code', d.icd10_code,
           'description', dc.description,
           'madeAt', pg_temp.utc(d.made_at),
           'madeBy', pg_temp.person(d.made_by)) ORDER BY d.made_at, d.kind DESC) AS doc
FROM diagnosis d
JOIN sept s ON s.visit_id = d.visit_id
JOIN diagnosis_code dc ON dc.icd10_code = d.icd10_code
GROUP BY d.visit_id;

CREATE TEMP TABLE x_results AS
SELECT r.lab_order_id, r.test_id,
       json_agg(json_build_object(
           'name', tp.name,
           'value', coalesce(to_json(r.value_numeric), to_json(r.value_text)),
           'unit', tp.unit,
           'normalLow', tp.normal_low,
           'normalHigh', tp.normal_high) ORDER BY tp.parameter_id) AS doc
FROM lab_result r
JOIN lab_order o ON o.lab_order_id = r.lab_order_id
JOIN sept s ON s.visit_id = o.visit_id
JOIN lab_test_parameter tp ON tp.parameter_id = r.parameter_id
GROUP BY r.lab_order_id, r.test_id;

CREATE TEMP TABLE x_tests AS
SELECT i.lab_order_id,
       json_agg(json_build_object(
           'testId', t.test_id,
           'name', t.name,
           'sampleType', t.sample_type,
           'completedAt', pg_temp.utc(i.completed_at),
           'performedBy', pg_temp.person(i.performed_by),
           'results', coalesce(xr.doc, '[]'::json)) ORDER BY t.test_id) AS doc
FROM lab_order_item i
JOIN lab_order o ON o.lab_order_id = i.lab_order_id
JOIN sept s ON s.visit_id = o.visit_id
JOIN lab_test t ON t.test_id = i.test_id
LEFT JOIN x_results xr ON xr.lab_order_id = i.lab_order_id AND xr.test_id = i.test_id
GROUP BY i.lab_order_id;

CREATE TEMP TABLE x_lab AS
SELECT o.visit_id,
       json_agg(json_build_object(
           'orderId', o.lab_order_id,
           'orderedAt', pg_temp.utc(o.ordered_at),
           'orderedBy', pg_temp.person(o.ordered_by),
           'tests', xt.doc) ORDER BY o.ordered_at) AS doc
FROM lab_order o
JOIN sept s ON s.visit_id = o.visit_id
JOIN x_tests xt ON xt.lab_order_id = o.lab_order_id
GROUP BY o.visit_id;

CREATE TEMP TABLE x_items AS
SELECT pi.prescription_id,
       json_agg(json_build_object(
           'drugId', d.drug_id,
           'drug', d.name || ' ' || d.strength || ' ' || d.form,
           'dose', pi.dose,
           'frequency', pi.frequency,
           'durationDays', pi.duration_days,
           'quantity', pi.quantity,
           'instructions', pi.instructions,
           'dispensedAt', pg_temp.utc(pi.dispensed_at),
           'dispensedBy', pg_temp.person(pi.dispensed_by)) ORDER BY d.drug_id) AS doc
FROM prescription_item pi
JOIN prescription p ON p.prescription_id = pi.prescription_id
JOIN sept s ON s.visit_id = p.visit_id
JOIN drug d ON d.drug_id = pi.drug_id
GROUP BY pi.prescription_id;

CREATE TEMP TABLE x_rx AS
SELECT p.visit_id,
       json_agg(json_build_object(
           'prescriptionId', p.prescription_id,
           'prescribedAt', pg_temp.utc(p.prescribed_at),
           'prescribedBy', pg_temp.person(p.prescribed_by),
           'items', xi.doc) ORDER BY p.prescribed_at) AS doc
FROM prescription p
JOIN sept s ON s.visit_id = p.visit_id
JOIN x_items xi ON xi.prescription_id = p.prescription_id
GROUP BY p.visit_id;

CREATE TEMP TABLE x_charges AS
SELECT c.visit_id,
       json_agg(json_build_object(
           'type', c.charge_type,
           'item', CASE c.charge_type WHEN 'consultation' THEN 'Consultation'
                                      WHEN 'lab_test' THEN t.name
                                      ELSE d.name || ' ' || d.strength || ' ' || d.form END,
           'quantity', c.quantity,
           'unitPrice', c.unit_price,
           'payment', CASE WHEN p.payment_id IS NOT NULL THEN json_build_object(
               'id', p.payment_id,
               'method', p.method,
               'receivedAt', pg_temp.utc(p.received_at),
               'receivedBy', pg_temp.person(p.received_by)) END) ORDER BY c.charge_id) AS doc
FROM charge c
JOIN sept s ON s.visit_id = c.visit_id
LEFT JOIN payment p ON p.payment_id = c.payment_id
LEFT JOIN lab_test t ON t.test_id = c.test_id
LEFT JOIN drug d ON d.drug_id = c.drug_id
GROUP BY c.visit_id;

\echo '  visits'
COPY (
    SELECT translate(json_strip_nulls(json_build_object(
        '_id', v.visit_id,
        'patient', json_build_object('id', p.patient_id, 'hospitalNumber', p.hospital_number,
                                     'name', p.first_name || ' ' || p.last_name),
        'branch', json_build_object('id', b.branch_id, 'name', b.name, 'state', b.state),
        'doctor', pg_temp.person(v.doctor_id),
        'checkedInAt', pg_temp.utc(v.checked_in_at),
        'checkedInBy', pg_temp.person(v.checked_in_by),
        'status', v.status,
        'appointment', CASE WHEN a.appointment_id IS NOT NULL THEN json_build_object(
            'id', a.appointment_id, 'scheduledFor', pg_temp.utc(a.scheduled_for), 'bookedVia', a.booked_via) END,
        'payer', CASE WHEN v.policy_id IS NULL THEN json_build_object('type', 'cash')
                      ELSE json_build_object('type', 'insurance', 'insurer', ins.name,
                                             'policyNumber', ip.policy_number) END,
        'vitals', coalesce(xv.doc, '[]'::json),
        'notes', coalesce(xn.doc, '[]'::json),
        'diagnoses', coalesce(xd.doc, '[]'::json),
        'labOrders', coalesce(xl.doc, '[]'::json),
        'prescriptions', coalesce(xp.doc, '[]'::json),
        'charges', coalesce(xc.doc, '[]'::json)
    ))::text, E'\n', '')
    FROM visit v
    JOIN sept s ON s.visit_id = v.visit_id
    JOIN patient p ON p.patient_id = v.patient_id
    JOIN branch b ON b.branch_id = v.branch_id
    LEFT JOIN appointment a ON a.appointment_id = v.appointment_id
    LEFT JOIN insurance_policy ip ON ip.policy_id = v.policy_id
    LEFT JOIN insurer ins ON ins.insurer_id = ip.insurer_id
    LEFT JOIN x_vitals xv ON xv.visit_id = v.visit_id
    LEFT JOIN x_notes xn ON xn.visit_id = v.visit_id
    LEFT JOIN x_diagnoses xd ON xd.visit_id = v.visit_id
    LEFT JOIN x_lab xl ON xl.visit_id = v.visit_id
    LEFT JOIN x_rx xp ON xp.visit_id = v.visit_id
    LEFT JOIN x_charges xc ON xc.visit_id = v.visit_id
    ORDER BY v.visit_id
) TO '/exchange/visits.json' WITH (FORMAT csv, QUOTE E'\x01', DELIMITER E'\x02');

\echo '  patients'
COPY (
    WITH policies AS (
        SELECT ip.patient_id,
               json_agg(json_build_object(
                   'insurer', ins.name,
                   'policyNumber', ip.policy_number,
                   'validFrom', pg_temp.day(ip.valid_from),
                   'validTo', pg_temp.day(ip.valid_to)) ORDER BY ip.valid_from) AS doc
        FROM insurance_policy ip
        JOIN insurer ins ON ins.insurer_id = ip.insurer_id
        WHERE ip.patient_id IN (SELECT patient_id FROM sept)
        GROUP BY ip.patient_id
    )
    SELECT translate(json_strip_nulls(json_build_object(
        '_id', p.patient_id,
        'hospitalNumber', p.hospital_number,
        'firstName', p.first_name,
        'lastName', p.last_name,
        'dateOfBirth', pg_temp.day(p.date_of_birth),
        'sex', p.sex,
        'phone', p.phone,
        'address', p.address,
        'registeredBranch', json_build_object('id', b.branch_id, 'name', b.name),
        'registeredAt', pg_temp.utc(p.registered_at),
        'insurance', coalesce(pol.doc, '[]'::json),
        'portal', CASE WHEN pa.patient_id IS NOT NULL THEN json_build_object(
            'username', pa.username, 'createdAt', pg_temp.utc(pa.created_at)) END
    ))::text, E'\n', '')
    FROM patient p
    JOIN branch b ON b.branch_id = p.registered_branch_id
    LEFT JOIN policies pol ON pol.patient_id = p.patient_id
    LEFT JOIN portal_account pa ON pa.patient_id = p.patient_id
    WHERE p.patient_id IN (SELECT patient_id FROM sept)
    ORDER BY p.patient_id
) TO '/exchange/patients.json' WITH (FORMAT csv, QUOTE E'\x01', DELIMITER E'\x02');

\echo '  reference data'
COPY (
    SELECT json_build_object('_id', branch_id, 'name', name, 'state', state, 'address', address,
                             'consultationFee', consultation_fee, 'openedOn', pg_temp.day(opened_on))::text
    FROM branch ORDER BY branch_id
) TO '/exchange/branches.json' WITH (FORMAT csv, QUOTE E'\x01', DELIMITER E'\x02');

COPY (
    SELECT json_build_object('_id', drug_id, 'name', name, 'form', form, 'strength', strength,
                             'unitPrice', unit_price)::text
    FROM drug ORDER BY drug_id
) TO '/exchange/drugs.json' WITH (FORMAT csv, QUOTE E'\x01', DELIMITER E'\x02');

COPY (
    SELECT translate(json_strip_nulls(json_build_object(
        '_id', t.test_id, 'name', t.name, 'sampleType', t.sample_type, 'price', t.price,
        'measures', (SELECT json_agg(json_build_object('name', tp.name, 'unit', tp.unit,
                                                       'normalLow', tp.normal_low, 'normalHigh', tp.normal_high)
                                     ORDER BY tp.parameter_id)
                     FROM lab_test_parameter tp WHERE tp.test_id = t.test_id)))::text, E'\n', '')
    FROM lab_test t ORDER BY t.test_id
) TO '/exchange/labTests.json' WITH (FORMAT csv, QUOTE E'\x01', DELIMITER E'\x02');

COPY (
    SELECT json_build_object('branchId', s.branch_id, 'drugId', s.drug_id,
                             'drug', d.name || ' ' || d.strength || ' ' || d.form,
                             'quantityInStock', s.quantity_in_stock, 'reorderLevel', s.reorder_level)::text
    FROM branch_stock s JOIN drug d ON d.drug_id = s.drug_id
    ORDER BY s.branch_id, s.drug_id
) TO '/exchange/branchStock.json' WITH (FORMAT csv, QUOTE E'\x01', DELIMITER E'\x02');

SELECT (SELECT count(*) FROM sept) AS visits_exported,
       (SELECT count(DISTINCT patient_id) FROM sept) AS patients_exported;
