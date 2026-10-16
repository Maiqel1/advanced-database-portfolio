\set QUIET on
\pset pager off
\pset null '(empty)'
SET client_min_messages = warning;
DROP SCHEMA IF EXISTS normalisation_demo CASCADE;
CREATE SCHEMA normalisation_demo;
SET search_path = normalisation_demo;

\echo
\echo '================================================================'
\echo 'STEP 0: the visit record sheet (unnormalised)'
\echo '================================================================'

CREATE TABLE visit_sheet (
    visit_no integer PRIMARY KEY,
    visit_date date NOT NULL,
    hospital_no text NOT NULL,
    patient_name text NOT NULL,
    patient_phone text NOT NULL,
    branch_name text NOT NULL,
    branch_state text NOT NULL,
    doctor_name text NOT NULL,
    drug_1 text,
    price_1 numeric(10,2),
    qty_1 integer,
    drug_2 text,
    price_2 numeric(10,2),
    qty_2 integer
);

INSERT INTO visit_sheet VALUES
    (5001, '2026-10-01', 'TH-000101', 'Adaeze Okafor', '0800 000 0101', 'Ilorin', 'Kwara', 'Dr Kemi Adebayo',
        'Artemether/Lumefantrine 20/120 mg', 150, 24, 'Paracetamol 500 mg', 50, 18),
    (5002, '2026-10-01', 'TH-000102', 'Musa Bello', '0800 000 0102', 'Ilorin', 'Kwara', 'Dr Kemi Adebayo',
        'Paracetamol 500 mg', 50, 10, NULL, NULL, NULL),
    (5003, '2026-10-03', 'TH-000101', 'Adaeze Okafor', '0800 000 0101', 'Lagos Ikeja', 'Lagos', 'Dr Ibrahim Yusuf',
        'Amoxicillin 500 mg', 120, 15, NULL, NULL, NULL),
    (5004, '2026-10-04', 'TH-000103', 'Funmi Adeyemi', '0800 000 0103', 'Lagos Ikeja', 'Lagos', 'Dr Ibrahim Yusuf',
        'Artemether/Lumefantrine 20/120 mg', 150, 24, 'Amoxicillin 500 mg', 120, 15);

SELECT * FROM visit_sheet ORDER BY visit_no;

\echo
\echo '================================================================'
\echo 'STEP 1: first normal form (one row per drug on each visit)'
\echo '================================================================'

CREATE TABLE visit_drug_1nf AS
SELECT visit_no, visit_date, hospital_no, patient_name, patient_phone,
       branch_name, branch_state, doctor_name,
       drug_1 AS drug_name, price_1 AS unit_price, qty_1 AS quantity
FROM visit_sheet
WHERE drug_1 IS NOT NULL
UNION ALL
SELECT visit_no, visit_date, hospital_no, patient_name, patient_phone,
       branch_name, branch_state, doctor_name,
       drug_2, price_2, qty_2
FROM visit_sheet
WHERE drug_2 IS NOT NULL;

ALTER TABLE visit_drug_1nf ADD PRIMARY KEY (visit_no, drug_name);

SELECT * FROM visit_drug_1nf ORDER BY visit_no, drug_name;

\echo
\echo '--- 1NF problem 1, update anomaly: Adaeze changes her phone number,'
\echo '--- but the receptionist only edits one of her three rows'
BEGIN;
UPDATE visit_drug_1nf
SET patient_phone = '0800 000 0999'
WHERE visit_no = 5001 AND drug_name = 'Paracetamol 500 mg';
SELECT DISTINCT hospital_no, patient_name, patient_phone
FROM visit_drug_1nf
WHERE hospital_no = 'TH-000101'
ORDER BY patient_phone;
ROLLBACK;

\echo
\echo '--- 1NF problem 2, insertion anomaly: a new patient, Chidi Eze,'
\echo '--- registers today but has no visit or prescription yet'
INSERT INTO visit_drug_1nf (hospital_no, patient_name, patient_phone)
VALUES ('TH-000104', 'Chidi Eze', '0800 000 0104');

\echo
\echo '--- 1NF problem 3, deletion anomaly: deleting Musa''s only visit'
\echo '--- also deletes everything the hospital knows about Musa'
BEGIN;
DELETE FROM visit_drug_1nf WHERE visit_no = 5002;
SELECT count(*) AS rows_still_holding_musa
FROM visit_drug_1nf
WHERE hospital_no = 'TH-000102';
ROLLBACK;

\echo
\echo '================================================================'
\echo 'STEP 2: second normal form (remove partial dependencies)'
\echo '================================================================'

CREATE TABLE visit_2nf AS
SELECT DISTINCT visit_no, visit_date, hospital_no, patient_name, patient_phone,
       branch_name, branch_state, doctor_name
FROM visit_drug_1nf;
ALTER TABLE visit_2nf ADD PRIMARY KEY (visit_no);

CREATE TABLE drug AS
SELECT DISTINCT drug_name, unit_price
FROM visit_drug_1nf;
ALTER TABLE drug ADD PRIMARY KEY (drug_name);

CREATE TABLE visit_drug AS
SELECT visit_no, drug_name, quantity
FROM visit_drug_1nf;
ALTER TABLE visit_drug ADD PRIMARY KEY (visit_no, drug_name);

\echo 'visit_2nf'
SELECT * FROM visit_2nf ORDER BY visit_no;
\echo 'drug'
SELECT * FROM drug ORDER BY drug_name;
\echo 'visit_drug'
SELECT * FROM visit_drug ORDER BY visit_no, drug_name;

\echo
\echo '================================================================'
\echo 'STEP 3: third normal form (remove transitive dependencies)'
\echo '================================================================'

CREATE TABLE patient AS
SELECT DISTINCT hospital_no, patient_name, patient_phone
FROM visit_2nf;
ALTER TABLE patient ADD PRIMARY KEY (hospital_no);

CREATE TABLE branch AS
SELECT DISTINCT branch_name, branch_state
FROM visit_2nf;
ALTER TABLE branch ADD PRIMARY KEY (branch_name);

CREATE TABLE visit AS
SELECT visit_no, visit_date, hospital_no, branch_name, doctor_name
FROM visit_2nf;
ALTER TABLE visit
    ADD PRIMARY KEY (visit_no),
    ADD FOREIGN KEY (hospital_no) REFERENCES patient (hospital_no),
    ADD FOREIGN KEY (branch_name) REFERENCES branch (branch_name);

ALTER TABLE visit_drug
    ADD FOREIGN KEY (visit_no) REFERENCES visit (visit_no),
    ADD FOREIGN KEY (drug_name) REFERENCES drug (drug_name);

\echo 'patient'
SELECT * FROM patient ORDER BY hospital_no;
\echo 'branch'
SELECT * FROM branch ORDER BY branch_name;
\echo 'visit'
SELECT * FROM visit ORDER BY visit_no;

\echo
\echo '================================================================'
\echo 'STEP 4: the same three operations on the 3NF tables'
\echo '================================================================'

\echo
\echo '--- Update: Adaeze''s phone is changed in exactly one place'
BEGIN;
UPDATE patient SET patient_phone = '0800 000 0999' WHERE hospital_no = 'TH-000101';
SELECT v.visit_no, p.patient_name, p.patient_phone
FROM visit v
JOIN patient p ON p.hospital_no = v.hospital_no
WHERE p.hospital_no = 'TH-000101'
ORDER BY v.visit_no;
ROLLBACK;

\echo
\echo '--- Insertion: Chidi Eze can be registered before any visit'
BEGIN;
INSERT INTO patient VALUES ('TH-000104', 'Chidi Eze', '0800 000 0104');
SELECT * FROM patient WHERE hospital_no = 'TH-000104';
ROLLBACK;

\echo
\echo '--- Deletion: removing Musa''s visit leaves Musa''s patient record'
BEGIN;
DELETE FROM visit_drug WHERE visit_no = 5002;
DELETE FROM visit WHERE visit_no = 5002;
SELECT * FROM patient WHERE hospital_no = 'TH-000102';
ROLLBACK;

\echo
\echo '================================================================'
\echo 'STEP 5: nothing was lost (join the 3NF tables back together)'
\echo '================================================================'

CREATE VIEW rebuilt AS
SELECT v.visit_no, v.visit_date, v.hospital_no, p.patient_name, p.patient_phone,
       v.branch_name, b.branch_state, v.doctor_name,
       vd.drug_name, d.unit_price, vd.quantity
FROM visit_drug vd
JOIN visit v ON v.visit_no = vd.visit_no
JOIN patient p ON p.hospital_no = v.hospital_no
JOIN branch b ON b.branch_name = v.branch_name
JOIN drug d ON d.drug_name = vd.drug_name;

SELECT 'rows in the 1NF table' AS measure, count(*) AS result FROM visit_drug_1nf
UNION ALL
SELECT 'rows rebuilt from the 3NF tables', count(*) FROM rebuilt
UNION ALL
SELECT 'rows in 1NF that the rebuild is missing', count(*)
FROM (SELECT * FROM visit_drug_1nf EXCEPT SELECT * FROM rebuilt) AS missing
UNION ALL
SELECT 'rows the rebuild invented', count(*)
FROM (SELECT * FROM rebuilt EXCEPT SELECT * FROM visit_drug_1nf) AS invented;

\echo
\echo '--- How many times each fact is stored, before and after'
SELECT 'Adaeze''s name and phone' AS fact,
       (SELECT count(*) FROM visit_drug_1nf WHERE hospital_no = 'TH-000101') AS copies_in_1nf,
       (SELECT count(*) FROM patient WHERE hospital_no = 'TH-000101') AS copies_in_3nf
UNION ALL
SELECT 'Paracetamol''s price',
       (SELECT count(*) FROM visit_drug_1nf WHERE drug_name = 'Paracetamol 500 mg'),
       (SELECT count(*) FROM drug WHERE drug_name = 'Paracetamol 500 mg')
UNION ALL
SELECT 'Ilorin is in Kwara',
       (SELECT count(*) FROM visit_drug_1nf WHERE branch_name = 'Ilorin'),
       (SELECT count(*) FROM branch WHERE branch_name = 'Ilorin');

RESET search_path;
