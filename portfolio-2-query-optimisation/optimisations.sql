SET search_path = tomiwa, public;

CREATE INDEX IF NOT EXISTS visit_patient_checked_in_idx ON visit (patient_id, checked_in_at);
CREATE INDEX IF NOT EXISTS diagnosis_visit_idx ON diagnosis (visit_id);
CREATE INDEX IF NOT EXISTS lab_order_visit_idx ON lab_order (visit_id);
CREATE INDEX IF NOT EXISTS payment_received_at_idx ON payment (received_at);
CREATE INDEX IF NOT EXISTS charge_payment_idx ON charge (payment_id);
CREATE INDEX IF NOT EXISTS visit_branch_checked_in_idx ON visit (branch_id, checked_in_at);
CREATE INDEX IF NOT EXISTS patient_lower_name_idx ON patient (lower(last_name), lower(first_name));

CREATE MATERIALIZED VIEW IF NOT EXISTS monthly_diagnosis_by_state AS
SELECT b.state,
       date_trunc('month', d.made_at)::date AS month,
       d.icd10_code,
       count(*) AS cases
FROM diagnosis d
JOIN visit v ON v.visit_id = d.visit_id
JOIN branch b ON b.branch_id = v.branch_id
WHERE d.kind = 'final'
GROUP BY b.state, date_trunc('month', d.made_at)::date, d.icd10_code;

CREATE UNIQUE INDEX IF NOT EXISTS monthly_diagnosis_by_state_key
    ON monthly_diagnosis_by_state (state, month, icd10_code);

VACUUM (ANALYZE) visit, diagnosis, lab_order, payment, charge, patient, monthly_diagnosis_by_state;
