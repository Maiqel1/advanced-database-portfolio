\set ON_ERROR_STOP on
\set QUIET on
\pset pager off
\if :{?days}
\else
\set days 365
\endif
\if :{?patients}
\else
\set patients 300000
\endif

SET search_path = tomiwa, public;
SET client_min_messages = warning;
SELECT clock_timestamp() AS seed_started \gset
SELECT setseed(0.2026) \gset

\echo 'Seeding' :days 'days of activity for' :patients 'patients...'

TRUNCATE branch, staff, patient, portal_account, insurer, insurance_policy, appointment, visit,
    vital_signs, clinical_note, diagnosis_code, diagnosis, lab_test, lab_test_parameter,
    lab_order, lab_order_item, lab_result, drug, prescription, prescription_item,
    branch_stock, restock_request, payment, charge
    RESTART IDENTITY CASCADE;

\echo '  reference data'

INSERT INTO branch (branch_id, name, state, address, consultation_fee, opened_on) VALUES
    (1, 'Tomiwa Hospitals Ilorin', 'Kwara', '14 Unity Road, Ilorin', 6000, '2012-03-05'),
    (2, 'Tomiwa Hospitals Ikeja', 'Lagos', '22 Hospital Road, Ikeja', 10000, '2015-09-14'),
    (3, 'Tomiwa Hospitals Ibadan', 'Oyo', '8 Ring Road, Ibadan', 7000, '2016-02-01'),
    (4, 'Tomiwa Hospitals Abeokuta', 'Ogun', '31 Station Road, Abeokuta', 6000, '2017-05-22'),
    (5, 'Tomiwa Hospitals Osogbo', 'Osun', '5 Market Street, Osogbo', 5500, '2018-01-15'),
    (6, 'Tomiwa Hospitals Akure', 'Ondo', '17 Garden Avenue, Akure', 5500, '2018-08-06'),
    (7, 'Tomiwa Hospitals Lokoja', 'Kogi', '9 Hospital Road, Lokoja', 5000, '2019-03-11'),
    (8, 'Tomiwa Hospitals Minna', 'Niger', '42 Unity Road, Minna', 5000, '2019-10-07'),
    (9, 'Tomiwa Hospitals Kaduna', 'Kaduna', '3 Ring Road, Kaduna', 6500, '2020-02-17'),
    (10, 'Tomiwa Hospitals Kano', 'Kano', '26 Station Road, Kano', 7000, '2020-11-02'),
    (11, 'Tomiwa Hospitals Jos', 'Plateau', '11 Market Street, Jos', 5500, '2021-04-12'),
    (12, 'Tomiwa Hospitals Benin City', 'Edo', '19 Garden Avenue, Benin City', 6500, '2021-09-20'),
    (13, 'Tomiwa Hospitals Asaba', 'Delta', '7 School Road, Asaba', 6000, '2022-06-06'),
    (14, 'Tomiwa Hospitals Port Harcourt', 'Rivers', '35 Hospital Road, Port Harcourt', 8500, '2023-01-16'),
    (15, 'Tomiwa Hospitals Enugu', 'Enugu', '12 Unity Road, Enugu', 6500, '2023-08-14'),
    (16, 'Tomiwa Hospitals Awka', 'Anambra', '4 Ring Road, Awka', 6000, '2024-03-04');

CREATE TEMP TABLE branch_pick AS
SELECT branch_id, city,
       (sum(weight) OVER w - weight) / sum(weight) OVER () AS lo,
       sum(weight) OVER w / sum(weight) OVER () AS hi
FROM (VALUES
    (1, 'Ilorin', 1.3), (2, 'Ikeja', 1.6), (3, 'Ibadan', 1.2), (4, 'Abeokuta', 0.9),
    (5, 'Osogbo', 0.8), (6, 'Akure', 0.8), (7, 'Lokoja', 0.7), (8, 'Minna', 0.7),
    (9, 'Kaduna', 1.0), (10, 'Kano', 1.2), (11, 'Jos', 0.8), (12, 'Benin City', 1.0),
    (13, 'Asaba', 0.8), (14, 'Port Harcourt', 1.2), (15, 'Enugu', 1.0), (16, 'Awka', 0.8)
) AS v (branch_id, city, weight)
WINDOW w AS (ORDER BY branch_id);

CREATE TEMP TABLE first_name (sex char(1), idx integer, name text);
INSERT INTO first_name
SELECT 'F', ord, name FROM unnest(ARRAY[
    'Adaeze', 'Aisha', 'Amaka', 'Bisola', 'Blessing', 'Chiamaka', 'Chioma', 'Damilola', 'Ebun', 'Esther',
    'Fatima', 'Folake', 'Funmilayo', 'Grace', 'Hadiza', 'Halima', 'Ifeoma', 'Joy', 'Kemi', 'Mercy',
    'Ngozi', 'Nkechi', 'Precious', 'Ruth', 'Simisola', 'Temitope', 'Titilayo', 'Yetunde', 'Zainab', 'Hauwa'
]) WITH ORDINALITY AS t (name, ord)
UNION ALL
SELECT 'M', ord, name FROM unnest(ARRAY[
    'Abdullahi', 'Adebayo', 'Ahmed', 'Babajide', 'Babatunde', 'Chidi', 'Daniel', 'David', 'Emeka', 'Femi',
    'Godwin', 'Ibrahim', 'Ikenna', 'Joseph', 'Kayode', 'Kelechi', 'Musa', 'Nnamdi', 'Obinna', 'Olumide',
    'Samuel', 'Sani', 'Segun', 'Suleiman', 'Tobi', 'Tunde', 'Uche', 'Usman', 'Yusuf', 'Ahmadu'
]) WITH ORDINALITY AS t (name, ord);

CREATE TEMP TABLE last_name AS
SELECT ord AS idx, name FROM unnest(ARRAY[
    'Abubakar', 'Adebayo', 'Adeleke', 'Adeyemi', 'Afolabi', 'Akinola', 'Aliyu', 'Balogun', 'Bello', 'Chukwu',
    'Danjuma', 'Ekwueme', 'Eze', 'Ibrahim', 'Igwe', 'Lawal', 'Mohammed', 'Musa', 'Nnadi', 'Nwachukwu',
    'Nwosu', 'Obi', 'Odunsi', 'Ogunleye', 'Okafor', 'Okeke', 'Okonkwo', 'Oladipo', 'Olaniyan', 'Onyeka',
    'Oyelaran', 'Popoola', 'Salami', 'Sanni', 'Suleiman', 'Tijani', 'Umar', 'Usman', 'Uzor', 'Yusuf'
]) WITH ORDINALITY AS t (name, ord);

CREATE TEMP TABLE staff_slot AS
SELECT k,
       CASE WHEN k = 1 THEN 'branch_manager'
            WHEN k = 2 THEN 'head_of_pharmacy'
            WHEN k <= 10 THEN 'doctor'
            WHEN k <= 18 THEN 'nurse'
            WHEN k <= 22 THEN 'receptionist'
            WHEN k <= 26 THEN 'lab_scientist'
            ELSE 'pharmacist' END AS role
FROM generate_series(1, 29) AS k;

WITH x AS MATERIALIZED (
    SELECT b.branch_id, b.opened_on, s.k, s.role,
           random() AS r_sex, random() AS r_fn, random() AS r_ln, random() AS r_ph, random() AS r_hire
    FROM branch b CROSS JOIN staff_slot s
)
INSERT INTO staff (staff_id, branch_id, first_name, last_name, role, phone, hired_on)
SELECT (x.branch_id - 1) * 29 + x.k, x.branch_id, fn.name, ln.name, x.role,
       '0800 200 ' || lpad(((x.branch_id - 1) * 29 + x.k)::text, 4, '0'),
       x.opened_on + floor(x.r_hire * (date '2025-09-01' - x.opened_on))::int
FROM x
JOIN first_name fn ON fn.sex = CASE WHEN x.r_sex < 0.5 THEN 'F' ELSE 'M' END
                  AND fn.idx = 1 + floor(x.r_fn * 30)::int
JOIN last_name ln ON ln.idx = 1 + floor(x.r_ln * 40)::int;

INSERT INTO insurer (insurer_id, name, phone) VALUES
    (1, 'Harmattan Health HMO', '0800 100 0001'),
    (2, 'Sahel Care HMO', '0800 100 0002'),
    (3, 'Atlantic Shield HMO', '0800 100 0003'),
    (4, 'GreenLeaf Health HMO', '0800 100 0004'),
    (5, 'Unity Cover HMO', '0800 100 0005'),
    (6, 'Savannah Wellness HMO', '0800 100 0006');

INSERT INTO diagnosis_code (icd10_code, description) VALUES
    ('B54', 'Unspecified malaria'),
    ('B50.9', 'Plasmodium falciparum malaria, unspecified'),
    ('A01.0', 'Typhoid fever'),
    ('A09', 'Other gastroenteritis and colitis of infectious and unspecified origin'),
    ('J06.9', 'Acute upper respiratory infection, unspecified'),
    ('J18.9', 'Pneumonia, unspecified'),
    ('I10', 'Essential (primary) hypertension'),
    ('E11.9', 'Type 2 diabetes mellitus without complications'),
    ('N39.0', 'Urinary tract infection, site not specified'),
    ('R30.0', 'Dysuria'),
    ('K29.7', 'Gastritis, unspecified'),
    ('D64.9', 'Anaemia, unspecified'),
    ('M54.5', 'Low back pain'),
    ('Z00.0', 'General medical examination');

INSERT INTO lab_test (test_id, name, sample_type, price) VALUES
    (1, 'Malaria parasite (MP)', 'blood', 2000),
    (2, 'Full blood count (FBC)', 'blood', 8000),
    (3, 'Widal test', 'blood', 3000),
    (4, 'Urinalysis', 'urine', 2500),
    (5, 'Urine microscopy', 'urine', 3000),
    (6, 'Fasting blood sugar', 'blood', 2000),
    (7, 'Stool microscopy', 'stool', 3000),
    (8, 'Electrolytes, urea and creatinine', 'blood', 9000);

INSERT INTO lab_test_parameter (parameter_id, test_id, name, unit, normal_low, normal_high) VALUES
    (1, 1, 'Malaria parasites', NULL, NULL, NULL),
    (2, 2, 'Haemoglobin', 'g/dL', 12, 16),
    (3, 2, 'White blood cells', 'x10^9/L', 4, 11),
    (4, 2, 'Platelets', 'x10^9/L', 150, 400),
    (5, 2, 'Packed cell volume', '%', 36, 48),
    (6, 2, 'Neutrophils', '%', 40, 75),
    (7, 2, 'Lymphocytes', '%', 20, 45),
    (8, 3, 'S. Typhi O titre', NULL, NULL, NULL),
    (9, 3, 'S. Typhi H titre', NULL, NULL, NULL),
    (10, 4, 'Urine protein', NULL, NULL, NULL),
    (11, 4, 'Urine glucose', NULL, NULL, NULL),
    (12, 4, 'Urine leucocytes', NULL, NULL, NULL),
    (13, 4, 'Urine nitrites', NULL, NULL, NULL),
    (14, 4, 'Urine pH', NULL, 4.5, 8.0),
    (15, 4, 'Specific gravity', NULL, 1.005, 1.030),
    (16, 5, 'Urine pus cells', '/HPF', 0, 5),
    (17, 5, 'Urine red blood cells', '/HPF', 0, 3),
    (18, 5, 'Urine organisms', NULL, NULL, NULL),
    (19, 6, 'Glucose (fasting)', 'mmol/L', 3.9, 5.6),
    (20, 7, 'Ova or cysts', NULL, NULL, NULL),
    (21, 7, 'Stool pus cells', NULL, NULL, NULL),
    (22, 8, 'Sodium', 'mmol/L', 135, 145),
    (23, 8, 'Potassium', 'mmol/L', 3.5, 5.1),
    (24, 8, 'Urea', 'mmol/L', 2.5, 7.8),
    (25, 8, 'Creatinine', 'umol/L', 60, 110);

INSERT INTO drug (drug_id, name, form, strength, unit_price) VALUES
    (1, 'Paracetamol', 'tablet', '500 mg', 20),
    (2, 'Paracetamol', 'syrup', '120 mg/5 mL', 800),
    (3, 'Artemether/Lumefantrine', 'tablet', '20/120 mg', 150),
    (4, 'Amoxicillin', 'capsule', '500 mg', 60),
    (5, 'Amoxicillin/Clavulanic acid', 'tablet', '625 mg', 250),
    (6, 'Ciprofloxacin', 'tablet', '500 mg', 80),
    (7, 'Nitrofurantoin', 'capsule', '100 mg', 70),
    (8, 'Metronidazole', 'tablet', '400 mg', 25),
    (9, 'Oral rehydration salts', 'sachet', '20.5 g', 150),
    (10, 'Zinc sulphate', 'tablet', '20 mg', 30),
    (11, 'Omeprazole', 'capsule', '20 mg', 50),
    (12, 'Amlodipine', 'tablet', '5 mg', 40),
    (13, 'Metformin', 'tablet', '500 mg', 30),
    (14, 'Ferrous sulphate', 'tablet', '200 mg', 15),
    (15, 'Folic acid', 'tablet', '5 mg', 10),
    (16, 'Ibuprofen', 'tablet', '400 mg', 30),
    (17, 'Vitamin C', 'tablet', '100 mg', 10),
    (18, 'Loratadine', 'tablet', '10 mg', 40);

CREATE TEMP TABLE cond (
    code text PRIMARY KEY,
    confirmed_code text,
    unconfirmed_code text,
    fever_chance numeric,
    symptoms text,
    consult_note text,
    review_confirmed text,
    review_unconfirmed text
);
INSERT INTO cond VALUES
    ('B54', 'B50.9', 'J06.9', 0.9, 'Fever, headache and joint pains for 3 days',
        'Suspected malaria. Malaria parasite test requested.',
        'Malaria parasites seen. Falciparum malaria confirmed and treated.',
        'No malaria parasites seen. Managed as a viral upper respiratory infection.'),
    ('A01.0', 'A01.0', 'A09', 0.8, 'Fever, abdominal pain and weakness for a week',
        'Suspected typhoid fever. Widal test requested.',
        'Widal titres significant. Treated for typhoid fever.',
        'Widal titres not significant. Managed as gastroenteritis.'),
    ('N39.0', 'N39.0', 'R30.0', 0.2, 'Painful and frequent urination',
        'Suspected urinary tract infection. Urine tests requested.',
        'Urine tests confirm infection. Antibiotic prescribed.',
        'Urine tests clear. Symptomatic treatment given.'),
    ('A09', 'A09', 'A09', 0.3, 'Diarrhoea and vomiting since yesterday',
        'Gastroenteritis. Rehydration advised.',
        'Stool results reviewed. Treatment continued.',
        'Stool results reviewed. Treatment continued.'),
    ('J06.9', 'J06.9', 'J06.9', 0.5, 'Sore throat, cough and catarrh',
        'Upper respiratory infection. Symptomatic treatment.', NULL, NULL),
    ('I10', 'I10', 'I10', 0.0, 'Routine blood pressure review',
        'Hypertension follow-up. Medication continued.',
        'Kidney function reviewed. Medication continued.',
        'Kidney function reviewed. Medication continued.'),
    ('E11.9', 'E11.9', 'E11.9', 0.0, 'Routine diabetes review',
        'Diabetes follow-up. Fasting blood sugar requested.',
        'Blood sugar reviewed. Metformin continued.',
        'Blood sugar reviewed. Metformin continued.'),
    ('K29.7', 'K29.7', 'K29.7', 0.0, 'Upper abdominal pain and heartburn',
        'Gastritis. Acid suppression started.', NULL, NULL),
    ('D64.9', 'D64.9', 'D64.9', 0.0, 'Tiredness and dizziness',
        'Suspected anaemia. Full blood count requested.',
        'Low haemoglobin confirmed. Iron and folic acid prescribed.',
        'Low haemoglobin confirmed. Iron and folic acid prescribed.'),
    ('M54.5', 'M54.5', 'M54.5', 0.0, 'Lower back pain for two weeks',
        'Mechanical low back pain. Pain relief given.', NULL, NULL),
    ('J18.9', 'J18.9', 'J18.9', 0.9, 'Cough, fever and difficulty breathing',
        'Suspected pneumonia. Full blood count requested.',
        'Results support a chest infection. Antibiotics prescribed.',
        'Results support a chest infection. Antibiotics prescribed.'),
    ('Z00.0', 'Z00.0', 'Z00.0', 0.0, 'No complaints. Routine check-up',
        'General check-up. Baseline tests requested.',
        'Check-up results reviewed.',
        'Check-up results reviewed.');

CREATE TEMP TABLE cond_pick AS
SELECT code,
       (sum(weight) OVER w - weight) / sum(weight) OVER () AS lo,
       sum(weight) OVER w / sum(weight) OVER () AS hi
FROM (VALUES
    ('J06.9', 14.0), ('I10', 10.0), ('A01.0', 6.0), ('N39.0', 7.0), ('A09', 7.0), ('K29.7', 6.0),
    ('E11.9', 6.0), ('D64.9', 4.0), ('M54.5', 5.0), ('J18.9', 2.0), ('Z00.0', 5.0)
) AS v (code, weight)
WINDOW w AS (ORDER BY code);

CREATE TEMP TABLE cond_test (code text, test_id integer, chance numeric);
INSERT INTO cond_test VALUES
    ('B54', 1, 1.0), ('B54', 2, 0.3),
    ('A01.0', 3, 1.0), ('A01.0', 2, 0.6),
    ('N39.0', 4, 1.0), ('N39.0', 5, 0.7),
    ('A09', 7, 0.5),
    ('E11.9', 6, 1.0),
    ('D64.9', 2, 1.0),
    ('I10', 8, 0.4),
    ('J18.9', 2, 0.9),
    ('Z00.0', 2, 1.0), ('Z00.0', 4, 1.0), ('Z00.0', 6, 0.5);

CREATE TEMP TABLE cond_drug (
    code text, drug_id integer, for_child boolean, dose text, frequency text,
    duration_days integer, quantity integer, instructions text, chance numeric
);
INSERT INTO cond_drug VALUES
    ('B50.9', 3, false, '4 tablets', 'twice daily', 3, 24, 'Take after food', 1),
    ('B50.9', 3, true, '2 tablets', 'twice daily', 3, 12, 'Take after food', 1),
    ('B50.9', 1, false, '2 tablets', 'three times daily', 3, 18, 'For fever', 1),
    ('B50.9', 2, true, '5 mL', 'three times daily', 3, 1, 'For fever', 1),
    ('J06.9', 1, false, '2 tablets', 'three times daily', 3, 18, 'For fever or pain', 1),
    ('J06.9', 2, true, '5 mL', 'three times daily', 3, 1, 'For fever or pain', 1),
    ('J06.9', 17, NULL, '1 tablet', 'twice daily', 5, 10, NULL, 0.6),
    ('J06.9', 18, false, '1 tablet', 'once daily', 5, 5, 'May cause drowsiness', 0.5),
    ('A01.0', 6, NULL, '1 tablet', 'twice daily', 7, 14, 'Complete the course', 1),
    ('A01.0', 1, false, '2 tablets', 'three times daily', 3, 18, 'For fever', 1),
    ('A01.0', 2, true, '5 mL', 'three times daily', 3, 1, 'For fever', 1),
    ('A09', 9, NULL, '1 sachet', 'after each loose stool', 3, 6, 'Dissolve in 1 litre of clean water', 1),
    ('A09', 8, false, '1 tablet', 'three times daily', 5, 15, 'Avoid alcohol', 0.7),
    ('A09', 10, true, '1 tablet', 'once daily', 10, 10, 'Dissolve in water', 1),
    ('N39.0', 7, NULL, '1 capsule', 'four times daily', 5, 20, 'Take with food', 1),
    ('R30.0', 1, false, '2 tablets', 'three times daily', 3, 18, 'For pain', 1),
    ('R30.0', 2, true, '5 mL', 'three times daily', 3, 1, 'For pain', 1),
    ('I10', 12, false, '1 tablet', 'once daily', 30, 30, 'Take every morning', 1),
    ('E11.9', 13, false, '1 tablet', 'twice daily', 30, 60, 'Take with meals', 1),
    ('K29.7', 11, NULL, '1 capsule', 'once daily', 14, 14, 'Take before breakfast', 1),
    ('D64.9', 14, NULL, '1 tablet', 'twice daily', 30, 60, 'Take after food', 1),
    ('D64.9', 15, NULL, '1 tablet', 'once daily', 30, 30, NULL, 1),
    ('M54.5', 16, false, '1 tablet', 'three times daily', 5, 15, 'Take after food', 1),
    ('J18.9', 5, false, '1 tablet', 'twice daily', 7, 14, 'Complete the course', 1),
    ('J18.9', 4, true, '1 capsule', 'three times daily', 5, 15, 'Complete the course', 1),
    ('J18.9', 1, false, '2 tablets', 'three times daily', 3, 18, 'For fever', 1),
    ('J18.9', 2, true, '5 mL', 'three times daily', 3, 1, 'For fever', 1),
    ('Z00.0', 17, NULL, '1 tablet', 'once daily', 30, 30, NULL, 0.1);

\echo '  patients, portal accounts and insurance'

WITH x AS MATERIALIZED (
    SELECT g AS patient_id,
           random() AS r_branch, random() AS r_sex, random() AS r_fn, random() AS r_ln,
           random() AS r_child, random() AS r_age, random() AS r_reg,
           random() AS r_ph1, random() AS r_ph2, random() AS r_house, random() AS r_street
    FROM generate_series(1, :patients) AS g
)
INSERT INTO patient (patient_id, hospital_number, first_name, last_name, date_of_birth, sex,
                     phone, address, registered_branch_id, registered_at)
SELECT x.patient_id,
       'TH-' || lpad(x.patient_id::text, 7, '0'),
       fn.name, ln.name, dob.d, sx.s,
       '0800 ' || lpad(floor(x.r_ph1 * 1000)::int::text, 3, '0') || ' ' || lpad(floor(x.r_ph2 * 10000)::int::text, 4, '0'),
       (1 + floor(x.r_house * 80)::int) || ' '
           || (ARRAY['Unity Road', 'Hospital Road', 'Market Street', 'Station Road',
                     'Church Street', 'Ring Road', 'Garden Avenue', 'School Road'])[1 + floor(x.r_street * 8)::int]
           || ', ' || bp.city,
       bp.branch_id,
       reg.start_at + x.r_reg * (timestamp '2025-09-30 17:00' - reg.start_at)
FROM x
JOIN branch_pick bp ON x.r_branch >= bp.lo AND x.r_branch < bp.hi
JOIN branch b ON b.branch_id = bp.branch_id
CROSS JOIN LATERAL (SELECT CASE WHEN x.r_sex < 0.53 THEN 'F' ELSE 'M' END AS s) AS sx
CROSS JOIN LATERAL (
    SELECT date '2025-10-01' - (CASE WHEN x.r_child < 0.2 THEN 0.2 + x.r_age * 11.7
                                     ELSE 12 + x.r_age * 73 END * 365.25)::int AS d
) AS dob
CROSS JOIN LATERAL (SELECT greatest(b.opened_on, dob.d)::timestamp + interval '8 hours' AS start_at) AS reg
JOIN first_name fn ON fn.sex = sx.s AND fn.idx = 1 + floor(x.r_fn * 30)::int
JOIN last_name ln ON ln.idx = 1 + floor(x.r_ln * 40)::int;

INSERT INTO portal_account (patient_id, username, password_hash, created_at)
SELECT patient_id,
       lower(first_name || '.' || last_name) || patient_id,
       'synthetic-' || md5(patient_id::text),
       least(registered_at + random() * interval '400 days', timestamp '2025-09-30 20:00')
FROM patient
WHERE date_of_birth <= date '2007-10-01' AND random() < 0.3;

CREATE TEMP TABLE policy_start AS
SELECT patient_id,
       1 + floor(random() * 6)::int AS insurer_id,
       date '2024-01-01' + floor(random() * 640)::int AS valid_from,
       CASE WHEN random() < 0.6 THEN 365 ELSE 730 END AS length_days,
       random() < 0.25 AS renews,
       1 + floor(random() * 6)::int AS next_insurer_id,
       floor(random() * 60)::int AS gap_days
FROM patient
WHERE random() < 0.3;

INSERT INTO insurance_policy (patient_id, insurer_id, policy_number, valid_from, valid_to)
SELECT patient_id, insurer_id, 'POL-' || lpad(patient_id::text, 7, '0') || '-1',
       valid_from, valid_from + length_days - 1
FROM policy_start
UNION ALL
SELECT patient_id, next_insurer_id, 'POL-' || lpad(patient_id::text, 7, '0') || '-2',
       valid_from + length_days + gap_days, valid_from + length_days + gap_days + 364
FROM policy_start
WHERE renews;

\echo '  planning visits and appointments'

CREATE TEMP TABLE plan_raw AS
SELECT g AS row_id,
       g > :days * 3200 AS is_ghost,
       1 + floor(:patients * power(random(), 1.6))::int AS patient_id,
       random() AS r_day, random() AS r_keep, random() AS r_branch, random() AS r_time,
       random() AS r_appt, random() AS r_doctor, random() AS r_chronic, random() AS r_malaria,
       random() AS r_cond, random() AS r_confirm, random() AS r_ghost, random() AS r_via,
       random() AS r_order, random() AS r_t1, random() AS r_t2, random() AS r_t3,
       random() AS r_t4, random() AS r_t5, random() AS r_follow
FROM generate_series(1, :days * 3200 + :days * 320) AS g;

CREATE TEMP TABLE plan_branch AS
SELECT r.*,
       CASE WHEN r.is_ghost THEN floor(r.r_day * (:days + 14))::int
            ELSE floor(r.r_day * :days)::int END AS day_no,
       CASE WHEN r.r_keep < 0.85 THEN p.registered_branch_id ELSE bp.branch_id END AS branch_id,
       p.date_of_birth,
       pa.patient_id IS NOT NULL AS has_portal
FROM plan_raw r
JOIN patient p ON p.patient_id = r.patient_id
JOIN branch_pick bp ON r.r_branch >= bp.lo AND r.r_branch < bp.hi
LEFT JOIN portal_account pa ON pa.patient_id = r.patient_id;

CREATE TEMP TABLE plan_slot AS
SELECT b.*,
       date '2025-10-01' + b.day_no AS visit_date,
       (b.is_ghost OR b.r_appt < 0.55) AS wants_appt,
       row_number() OVER (PARTITION BY b.branch_id, b.day_no, (b.is_ghost OR b.r_appt < 0.55)
                          ORDER BY b.r_order) AS slot_rn
FROM plan_branch b;

CREATE TEMP TABLE visit_plan AS
WITH s AS (
    SELECT p.*,
           p.wants_appt AND p.slot_rn <= 320 AS has_appt,
           (p.branch_id - 1) * 29 AS staff_base,
           (date '2025-10-01' + p.day_no) - p.date_of_birth < 12 * 365 AS is_child
    FROM plan_slot p
    WHERE NOT (p.is_ghost AND p.slot_rn > 320)
), t AS (
    SELECT s.*,
           CASE WHEN s.has_appt THEN s.visit_date + interval '8 hours' + ((s.slot_rn - 1) / 8) * interval '15 minutes' END AS scheduled_for,
           s.staff_base + CASE WHEN s.has_appt THEN 3 + (s.slot_rn - 1) % 8
                               ELSE 3 + floor(s.r_doctor * 8)::int END AS doctor_id,
           s.staff_base + 19 + (s.row_id % 4)::int AS receptionist_id,
           s.staff_base + 11 + (s.row_id % 8)::int AS nurse_id,
           s.staff_base + 23 + ((s.row_id / 3) % 4)::int AS lab_scientist_id,
           s.staff_base + 27 + ((s.row_id / 5) % 3)::int AS pharmacist_id
    FROM s
)
SELECT t.*,
       CASE WHEN t.has_appt THEN t.scheduled_for - t.r_time * interval '20 minutes'
            ELSE t.visit_date + interval '8 hours' + t.r_time * interval '570 minutes' END AS checked_in_at,
       CASE WHEN NOT t.is_ghost THEN 'attended'
            WHEN t.day_no >= :days THEN 'booked'
            WHEN t.r_ghost < 0.6 THEN 'no_show'
            ELSE 'cancelled' END AS appt_status,
       CASE WHEN t.has_appt THEN row_number() OVER (PARTITION BY t.has_appt ORDER BY t.scheduled_for, t.row_id) END AS appointment_id,
       ip.policy_id,
       CASE
           WHEN NOT t.is_child AND t.patient_id % 12 = 0 AND t.r_chronic < 0.6 THEN 'I10'
           WHEN NOT t.is_child AND t.patient_id % 12 = 6 AND t.r_chronic < 0.6 THEN 'E11.9'
           WHEN t.r_malaria < CASE WHEN extract(month FROM t.visit_date) BETWEEN 4 AND 10 THEN 0.34 ELSE 0.18 END THEN 'B54'
           WHEN t.is_child AND cp.code IN ('I10', 'E11.9', 'M54.5') THEN 'J06.9'
           ELSE cp.code
       END AS base_code,
       t.r_confirm < 0.8 AS confirmed
FROM t
JOIN cond_pick cp ON t.r_cond >= cp.lo AND t.r_cond < cp.hi
LEFT JOIN insurance_policy ip ON ip.patient_id = t.patient_id
                             AND t.visit_date BETWEEN ip.valid_from AND ip.valid_to;

CREATE TEMP TABLE visit_numbered AS
SELECT v.*, row_number() OVER (ORDER BY v.checked_in_at, v.row_id) AS visit_id
FROM visit_plan v
WHERE NOT v.is_ghost;

CREATE TEMP TABLE lab_item_plan AS
WITH j AS MATERIALIZED (
    SELECT v.visit_id, ct.test_id, ct.chance, random() AS r
    FROM visit_numbered v
    JOIN cond_test ct ON ct.code = v.base_code
)
SELECT visit_id, test_id FROM j WHERE r < chance;

CREATE TEMP TABLE visit_final AS
SELECT v.*,
       l.visit_id IS NOT NULL AS has_lab,
       CASE WHEN l.visit_id IS NOT NULL AND NOT v.confirmed THEN c.unconfirmed_code
            ELSE c.confirmed_code END AS final_code,
       l.visit_id IS NOT NULL AND v.base_code = 'B54' AND NOT v.confirmed AND v.r_follow < 0.3 AS has_followup,
       v.checked_in_at + (10 + v.r_t1 * 15) * interval '1 minute' AS t_vitals,
       v.checked_in_at + (25 + v.r_t1 * 15 + v.r_t2 * 45) * interval '1 minute' AS t_consult
FROM visit_numbered v
JOIN cond c ON c.code = v.base_code
LEFT JOIN (SELECT DISTINCT visit_id FROM lab_item_plan) AS l ON l.visit_id = v.visit_id;

ALTER TABLE visit_final
    ADD COLUMN t_lab_order timestamp,
    ADD COLUMN t_lab_done timestamp,
    ADD COLUMN t_review timestamp,
    ADD COLUMN t_rx timestamp,
    ADD COLUMN t_dispense timestamp;

UPDATE visit_final SET
    t_lab_order = t_consult + interval '5 minutes',
    t_lab_done = t_consult + (50 + r_t3 * 75) * interval '1 minute',
    t_review = t_consult + (130 + r_t3 * 75 + r_t4 * 25) * interval '1 minute',
    t_rx = CASE WHEN has_lab THEN t_consult + (135 + r_t3 * 75 + r_t4 * 25) * interval '1 minute'
                ELSE t_consult + interval '5 minutes' END;

UPDATE visit_final SET t_dispense = t_rx + (15 + r_t5 * 25) * interval '1 minute';

ANALYZE visit_final;
ANALYZE visit_plan;

\echo '  appointments and visits'

INSERT INTO appointment (appointment_id, patient_id, doctor_id, branch_id, scheduled_for, booked_via, booked_by, status)
SELECT appointment_id, patient_id, doctor_id, branch_id, scheduled_for,
       CASE WHEN has_portal AND r_via < 0.5 THEN 'portal' ELSE 'reception' END,
       CASE WHEN has_portal AND r_via < 0.5 THEN NULL ELSE receptionist_id END,
       appt_status
FROM visit_plan
WHERE has_appt
ORDER BY appointment_id;

INSERT INTO visit (visit_id, patient_id, branch_id, doctor_id, appointment_id, policy_id,
                   checked_in_by, checked_in_at, status)
SELECT visit_id, patient_id, branch_id, doctor_id, appointment_id, policy_id,
       receptionist_id, checked_in_at, 'completed'
FROM visit_final
ORDER BY visit_id;

\echo '  vital signs, notes and diagnoses'

WITH v AS MATERIALIZED (
    SELECT f.visit_id, f.nurse_id, f.t_vitals, f.is_child, f.base_code, c.fever_chance,
           random() AS r_fever, random() AS r1, random() AS r2, random() AS r3, random() AS r4,
           random() AS r_retake
    FROM visit_final f
    JOIN cond c ON c.code = f.base_code
)
INSERT INTO vital_signs (visit_id, recorded_by, recorded_at, temperature_c, systolic_bp, diastolic_bp, pulse_bpm, weight_kg)
SELECT visit_id, nurse_id, t_vitals,
       round((CASE WHEN r_fever < fever_chance THEN 37.8 + r1 * 2.0 ELSE 36.2 + r1 * 1.1 END)::numeric, 1),
       CASE WHEN base_code = 'I10' THEN 140 + floor(r2 * 45)::int
            WHEN is_child THEN 90 + floor(r2 * 20)::int
            ELSE 105 + floor(r2 * 33)::int END,
       CASE WHEN base_code = 'I10' THEN 90 + floor(r3 * 25)::int
            WHEN is_child THEN 55 + floor(r3 * 15)::int
            ELSE 65 + floor(r3 * 23)::int END,
       CASE WHEN r_fever < fever_chance THEN 90 + floor(r4 * 25)::int ELSE 62 + floor(r4 * 30)::int END,
       round((CASE WHEN is_child THEN 8 + r4 * 27 ELSE 50 + r2 * 50 END)::numeric, 1)
FROM v
UNION ALL
SELECT visit_id, nurse_id, t_vitals + interval '20 minutes',
       round((CASE WHEN r_fever < fever_chance THEN 37.6 + r1 * 1.8 ELSE 36.2 + r4 * 1.1 END)::numeric, 1),
       CASE WHEN base_code = 'I10' THEN 135 + floor(r3 * 45)::int
            WHEN is_child THEN 90 + floor(r3 * 20)::int
            ELSE 105 + floor(r3 * 33)::int END,
       CASE WHEN base_code = 'I10' THEN 88 + floor(r2 * 25)::int
            WHEN is_child THEN 55 + floor(r2 * 15)::int
            ELSE 65 + floor(r2 * 23)::int END,
       CASE WHEN r_fever < fever_chance THEN 88 + floor(r1 * 25)::int ELSE 62 + floor(r1 * 30)::int END,
       round((CASE WHEN is_child THEN 8 + r4 * 27 ELSE 50 + r2 * 50 END)::numeric, 1)
FROM v
WHERE r_retake < 0.08;

INSERT INTO clinical_note (visit_id, written_by, written_at, symptoms, notes)
SELECT f.visit_id, f.doctor_id, f.t_consult, c.symptoms, c.consult_note
FROM visit_final f
JOIN cond c ON c.code = f.base_code
UNION ALL
SELECT f.visit_id, f.doctor_id, f.t_review, NULL,
       CASE WHEN f.final_code = c.confirmed_code THEN c.review_confirmed ELSE c.review_unconfirmed END
FROM visit_final f
JOIN cond c ON c.code = f.base_code
WHERE f.has_lab;

INSERT INTO diagnosis (visit_id, icd10_code, made_by, kind, made_at)
SELECT visit_id, base_code, doctor_id, 'provisional', t_consult
FROM visit_final
WHERE has_lab
UNION ALL
SELECT visit_id, final_code, doctor_id, 'final', CASE WHEN has_lab THEN t_review ELSE t_consult END
FROM visit_final;

\echo '  laboratory orders and results'

INSERT INTO lab_order (lab_order_id, visit_id, ordered_by, ordered_at)
SELECT visit_id, visit_id, doctor_id, t_lab_order
FROM visit_final
WHERE has_lab
ORDER BY visit_id;

SELECT coalesce(max(lab_order_id), 0) AS max_first_order FROM lab_order \gset
SELECT setval(pg_get_serial_sequence('tomiwa.lab_order', 'lab_order_id'), :max_first_order + 1, false) \gset

INSERT INTO lab_order (visit_id, ordered_by, ordered_at)
SELECT visit_id, doctor_id, t_lab_done + interval '10 minutes'
FROM visit_final
WHERE has_followup
ORDER BY visit_id;

INSERT INTO lab_order_item (lab_order_id, test_id, performed_by, completed_at)
SELECT p.visit_id, p.test_id, f.lab_scientist_id, f.t_lab_done
FROM lab_item_plan p
JOIN visit_final f ON f.visit_id = p.visit_id
UNION ALL
SELECT o.lab_order_id, 3, f.lab_scientist_id, f.t_lab_done + interval '70 minutes'
FROM lab_order o
JOIN visit_final f ON f.visit_id = o.visit_id
WHERE o.lab_order_id > :max_first_order;

WITH x AS MATERIALIZED (
    SELECT i.lab_order_id, i.test_id, tp.parameter_id, tp.name AS param, tp.normal_low, tp.normal_high,
           f.base_code, f.confirmed, i.lab_order_id > :max_first_order AS is_followup,
           random() AS r1, random() AS r2, random() AS r3
    FROM lab_order_item i
    JOIN lab_order o ON o.lab_order_id = i.lab_order_id
    JOIN visit_final f ON f.visit_id = o.visit_id
    JOIN lab_test_parameter tp ON tp.test_id = i.test_id
)
INSERT INTO lab_result (lab_order_id, test_id, parameter_id, value_numeric, value_text)
SELECT lab_order_id, test_id, parameter_id,
       CASE
           WHEN normal_low IS NULL THEN NULL
           WHEN param = 'Haemoglobin' AND base_code = 'D64.9' THEN round((6.5 + r1 * 4)::numeric, 1)
           WHEN param = 'Glucose (fasting)' AND base_code = 'E11.9' THEN round((7 + r1 * 7)::numeric, 1)
           WHEN param = 'Urine pus cells' AND base_code = 'N39.0' AND confirmed THEN round((10 + r1 * 30)::numeric, 0)
           WHEN param = 'Specific gravity' THEN round((normal_low + r1 * (normal_high - normal_low))::numeric, 3)
           WHEN r2 < 0.85 THEN round((normal_low + r1 * (normal_high - normal_low))::numeric, 1)
           WHEN r3 < 0.5 THEN round(greatest(0, normal_low - r1 * (normal_high - normal_low) * 0.3)::numeric, 1)
           ELSE round((normal_high + r1 * (normal_high - normal_low) * 0.5)::numeric, 1)
       END,
       CASE param
           WHEN 'Malaria parasites' THEN
               CASE WHEN base_code = 'B54' AND confirmed
                    THEN (ARRAY['Seen (+)', 'Seen (++)', 'Seen (+++)'])[1 + floor(r1 * 3)::int]
                    ELSE 'Not seen' END
           WHEN 'S. Typhi O titre' THEN
               CASE WHEN (base_code = 'A01.0' AND confirmed AND NOT is_followup) OR (is_followup AND r2 < 0.25)
                    THEN (ARRAY['1:160', '1:320'])[1 + floor(r1 * 2)::int]
                    ELSE (ARRAY['1:40', '1:80'])[1 + floor(r1 * 2)::int] END
           WHEN 'S. Typhi H titre' THEN
               CASE WHEN (base_code = 'A01.0' AND confirmed AND NOT is_followup) OR (is_followup AND r2 < 0.25)
                    THEN (ARRAY['1:160', '1:320'])[1 + floor(r3 * 2)::int]
                    ELSE (ARRAY['1:40', '1:80'])[1 + floor(r3 * 2)::int] END
           WHEN 'Urine protein' THEN
               CASE WHEN r1 < 0.85 THEN 'Negative' WHEN r1 < 0.95 THEN 'Trace' ELSE '+' END
           WHEN 'Urine glucose' THEN
               CASE WHEN r2 < 0.95 THEN 'Negative' ELSE 'Trace' END
           WHEN 'Urine leucocytes' THEN
               CASE WHEN base_code = 'N39.0' AND confirmed
                    THEN (ARRAY['+', '++', '+++'])[1 + floor(r1 * 3)::int]
                    ELSE 'Negative' END
           WHEN 'Urine nitrites' THEN
               CASE WHEN base_code = 'N39.0' AND confirmed AND r2 < 0.7 THEN 'Positive' ELSE 'Negative' END
           WHEN 'Urine organisms' THEN
               CASE WHEN base_code = 'N39.0' AND confirmed THEN 'Bacteria seen' ELSE 'None seen' END
           WHEN 'Ova or cysts' THEN
               CASE WHEN r1 < 0.15 THEN 'Cysts of Entamoeba histolytica seen' ELSE 'None seen' END
           WHEN 'Stool pus cells' THEN
               CASE WHEN r2 < 0.3 THEN 'Few' ELSE 'None seen' END
       END
FROM x;

\echo '  prescriptions'

CREATE TEMP TABLE rx_item_plan AS
WITH j AS MATERIALIZED (
    SELECT f.visit_id, cd.drug_id, cd.dose, cd.frequency, cd.duration_days, cd.quantity,
           cd.instructions, cd.chance, random() AS r
    FROM visit_final f
    JOIN cond_drug cd ON cd.code = f.final_code
                     AND (cd.for_child IS NULL OR cd.for_child = f.is_child)
)
SELECT * FROM j WHERE r < chance;

INSERT INTO prescription (prescription_id, visit_id, prescribed_by, prescribed_at)
SELECT f.visit_id, f.visit_id, f.doctor_id, f.t_rx
FROM visit_final f
WHERE EXISTS (SELECT 1 FROM rx_item_plan p WHERE p.visit_id = f.visit_id)
ORDER BY f.visit_id;

INSERT INTO prescription_item (prescription_id, drug_id, dose, frequency, duration_days, quantity,
                               instructions, dispensed_by, dispensed_at)
SELECT p.visit_id, p.drug_id, p.dose, p.frequency, p.duration_days, p.quantity,
       p.instructions, f.pharmacist_id, f.t_dispense
FROM rx_item_plan p
JOIN visit_final f ON f.visit_id = p.visit_id
ORDER BY p.visit_id, p.drug_id;

\echo '  payments and charges'

INSERT INTO payment (payment_id, received_by, received_at, method)
SELECT pay.payment_id, pay.received_by, pay.received_at,
       (ARRAY['cash', 'transfer', 'transfer', 'card', 'cash'])[1 + floor(random() * 5)::int]
FROM (
    SELECT 4 * (f.visit_id - 1) + 1 AS payment_id, f.receptionist_id AS received_by, f.checked_in_at AS received_at
    FROM visit_final f
    WHERE f.policy_id IS NULL
    UNION ALL
    SELECT 4 * (f.visit_id - 1) + 2, f.receptionist_id, f.t_lab_order + interval '8 minutes'
    FROM visit_final f
    WHERE f.policy_id IS NULL AND f.has_lab
    UNION ALL
    SELECT 4 * (f.visit_id - 1) + 3, f.receptionist_id, f.t_rx + interval '8 minutes'
    FROM visit_final f
    WHERE f.policy_id IS NULL
      AND EXISTS (SELECT 1 FROM prescription p WHERE p.prescription_id = f.visit_id)
    UNION ALL
    SELECT 4 * (f.visit_id - 1) + 4, f.receptionist_id, f.t_lab_done + interval '15 minutes'
    FROM visit_final f
    WHERE f.policy_id IS NULL AND f.has_followup
) AS pay
ORDER BY pay.payment_id;

INSERT INTO charge (visit_id, charge_type, lab_order_id, test_id, prescription_id, drug_id,
                    quantity, unit_price, payment_id)
SELECT ch.* FROM (
    SELECT f.visit_id, 'consultation' AS charge_type,
           NULL::integer AS lab_order_id, NULL::integer AS test_id,
           NULL::integer AS prescription_id, NULL::integer AS drug_id,
           1 AS quantity,
           CASE WHEN f.visit_date < date '2026-04-01' THEN round(b.consultation_fee / 1.1 / 100) * 100
                ELSE b.consultation_fee END AS unit_price,
           CASE WHEN f.policy_id IS NULL THEN 4 * (f.visit_id - 1) + 1 END AS payment_id
    FROM visit_final f
    JOIN branch b ON b.branch_id = f.branch_id
    UNION ALL
    SELECT f.visit_id, 'lab_test', i.lab_order_id, i.test_id, NULL, NULL, 1,
           CASE WHEN f.visit_date < date '2026-04-01' THEN round(t.price / 1.1 / 100) * 100
                ELSE t.price END,
           CASE WHEN f.policy_id IS NULL
                THEN 4 * (f.visit_id - 1) + CASE WHEN i.lab_order_id > :max_first_order THEN 4 ELSE 2 END END
    FROM lab_order_item i
    JOIN lab_order o ON o.lab_order_id = i.lab_order_id
    JOIN visit_final f ON f.visit_id = o.visit_id
    JOIN lab_test t ON t.test_id = i.test_id
    UNION ALL
    SELECT f.visit_id, 'drug', NULL, NULL, pi.prescription_id, pi.drug_id, pi.quantity,
           CASE WHEN f.visit_date < date '2026-04-01' THEN round(d.unit_price / 1.1)
                ELSE d.unit_price END,
           CASE WHEN f.policy_id IS NULL THEN 4 * (f.visit_id - 1) + 3 END
    FROM prescription_item pi
    JOIN visit_final f ON f.visit_id = pi.prescription_id
    JOIN drug d ON d.drug_id = pi.drug_id
) AS ch
ORDER BY ch.visit_id, ch.charge_type, ch.lab_order_id, ch.test_id, ch.drug_id;

\echo '  pharmacy stock and restock requests'

WITH usage AS (
    SELECT f.branch_id, pi.drug_id, sum(pi.quantity) AS qty
    FROM prescription_item pi
    JOIN visit_final f ON f.visit_id = pi.prescription_id
    GROUP BY f.branch_id, pi.drug_id
), s AS MATERIALIZED (
    SELECT b.branch_id, d.drug_id,
           greatest(ceil(coalesce(u.qty, 0) / (:days / 30.0) / 2), 10)::int AS reorder_level,
           random() AS r
    FROM branch b
    CROSS JOIN drug d
    LEFT JOIN usage u ON u.branch_id = b.branch_id AND u.drug_id = d.drug_id
)
INSERT INTO branch_stock (branch_id, drug_id, quantity_in_stock, reorder_level)
SELECT branch_id, drug_id, floor(reorder_level * (0.2 + r * 2.8))::int, reorder_level
FROM s;

WITH r AS MATERIALIZED (
    SELECT s.branch_id, s.drug_id, s.reorder_level,
           date '2025-10-01' + floor(random() * greatest(:days - 3, 1))::int
               + interval '9 hours' + random() * interval '8 hours' AS requested_at,
           random() AS r_status, random() AS r_hours
    FROM branch_stock s
    CROSS JOIN generate_series(1, 6) AS n
)
INSERT INTO restock_request (branch_id, drug_id, quantity_requested, requested_by, requested_at,
                             status, reviewed_by, reviewed_at)
SELECT branch_id, drug_id, reorder_level * 4, (branch_id - 1) * 29 + 2, requested_at,
       CASE WHEN r_status < 0.85 THEN 'received' WHEN r_status < 0.95 THEN 'rejected' ELSE 'approved' END,
       (branch_id - 1) * 29 + 1,
       requested_at + (1 + r_hours * 47) * interval '1 hour'
FROM r
ORDER BY requested_at;

INSERT INTO restock_request (branch_id, drug_id, quantity_requested, requested_by, requested_at, status)
SELECT branch_id, drug_id, reorder_level * 4, (branch_id - 1) * 29 + 2,
       date '2025-10-01' + (:days - 1) - floor(random() * 3)::int + interval '10 hours',
       'pending'
FROM branch_stock
WHERE quantity_in_stock < reorder_level AND random() < 0.5;

\echo '  finishing'

DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT table_name, column_name
        FROM information_schema.columns
        WHERE table_schema = 'tomiwa' AND is_identity = 'YES'
    LOOP
        EXECUTE format(
            'SELECT setval(pg_get_serial_sequence(%L, %L), coalesce((SELECT max(%I) FROM tomiwa.%I), 0) + 1, false)',
            'tomiwa.' || r.table_name, r.column_name, r.column_name, r.table_name);
    END LOOP;
END
$$;

VACUUM (ANALYZE) branch, staff, patient, portal_account, insurer, insurance_policy, appointment, visit,
    vital_signs, clinical_note, diagnosis_code, diagnosis, lab_test, lab_test_parameter,
    lab_order, lab_order_item, lab_result, drug, prescription, prescription_item,
    branch_stock, restock_request, payment, charge;

\echo
\echo 'Rows loaded'
SELECT table_name, rows FROM (
    SELECT 1 AS n, 'branch' AS table_name, count(*) AS rows FROM branch
    UNION ALL SELECT 2, 'staff', count(*) FROM staff
    UNION ALL SELECT 3, 'patient', count(*) FROM patient
    UNION ALL SELECT 4, 'portal_account', count(*) FROM portal_account
    UNION ALL SELECT 5, 'insurer', count(*) FROM insurer
    UNION ALL SELECT 6, 'insurance_policy', count(*) FROM insurance_policy
    UNION ALL SELECT 7, 'appointment', count(*) FROM appointment
    UNION ALL SELECT 8, 'visit', count(*) FROM visit
    UNION ALL SELECT 9, 'vital_signs', count(*) FROM vital_signs
    UNION ALL SELECT 10, 'clinical_note', count(*) FROM clinical_note
    UNION ALL SELECT 11, 'diagnosis_code', count(*) FROM diagnosis_code
    UNION ALL SELECT 12, 'diagnosis', count(*) FROM diagnosis
    UNION ALL SELECT 13, 'lab_test', count(*) FROM lab_test
    UNION ALL SELECT 14, 'lab_test_parameter', count(*) FROM lab_test_parameter
    UNION ALL SELECT 15, 'lab_order', count(*) FROM lab_order
    UNION ALL SELECT 16, 'lab_order_item', count(*) FROM lab_order_item
    UNION ALL SELECT 17, 'lab_result', count(*) FROM lab_result
    UNION ALL SELECT 18, 'drug', count(*) FROM drug
    UNION ALL SELECT 19, 'prescription', count(*) FROM prescription
    UNION ALL SELECT 20, 'prescription_item', count(*) FROM prescription_item
    UNION ALL SELECT 21, 'branch_stock', count(*) FROM branch_stock
    UNION ALL SELECT 22, 'restock_request', count(*) FROM restock_request
    UNION ALL SELECT 23, 'payment', count(*) FROM payment
    UNION ALL SELECT 24, 'charge', count(*) FROM charge
) AS counts
ORDER BY n;

SELECT round(extract(epoch FROM clock_timestamp() - :'seed_started'::timestamptz)) AS seconds_taken;
