# Logical ER diagrams by area: Mermaid source

Source for the five `er-logical-*.png` images in the Portfolio 1 README. Render with `npx @mermaid-js/mermaid-cli -i er-logical-areas.md -o out.md`.

## 1. People and places

```mermaid
erDiagram
    branch ||--o{ staff : employs
    branch ||--o{ patient : registers
    patient ||--o| portal_account : "logs in with"
    patient ||--o{ insurance_policy : holds
    insurer ||--o{ insurance_policy : issues

    branch {
        int branch_id PK
        varchar name UK
        varchar state
        varchar address
        numeric consultation_fee
        date opened_on
    }
    staff {
        int staff_id PK
        int branch_id FK
        varchar first_name
        varchar last_name
        varchar role
        varchar phone
        date hired_on
    }
    patient {
        int patient_id PK
        varchar hospital_number UK
        varchar first_name
        varchar last_name
        date date_of_birth
        char sex
        varchar phone
        varchar address
        int registered_branch_id FK
        timestamp registered_at
    }
    portal_account {
        int patient_id PK, FK
        varchar username UK
        varchar password_hash
        timestamp created_at
    }
    insurer {
        int insurer_id PK
        varchar name UK
        varchar phone
    }
    insurance_policy {
        int policy_id PK
        int patient_id FK
        int insurer_id FK
        varchar policy_number
        date valid_from
        date valid_to
    }
```

## 2. Visits and clinical care

```mermaid
erDiagram
    patient ||--o{ appointment : books
    staff ||--o{ appointment : "is doctor for"
    branch ||--o{ appointment : hosts
    appointment |o--o| visit : "leads to"
    patient ||--o{ visit : makes
    staff ||--o{ visit : "is doctor for"
    branch ||--o{ visit : hosts
    insurance_policy |o--o{ visit : "pays for"
    visit ||--o{ vital_signs : has
    visit ||--o{ clinical_note : has
    visit ||--o{ diagnosis : has
    diagnosis_code ||--o{ diagnosis : classifies

    appointment {
        int appointment_id PK
        int patient_id FK
        int doctor_id FK
        int branch_id FK
        timestamp scheduled_for
        varchar booked_via "reception or portal"
        int booked_by FK "empty when booked on the portal"
        varchar status
    }
    visit {
        int visit_id PK
        int patient_id FK
        int branch_id FK
        int doctor_id FK
        int appointment_id FK, UK "empty for walk-ins"
        int policy_id FK "empty for cash patients"
        int checked_in_by FK
        timestamp checked_in_at
        varchar status
    }
    vital_signs {
        int vitals_id PK
        int visit_id FK
        int recorded_by FK
        timestamp recorded_at
        numeric temperature_c
        int systolic_bp
        int diastolic_bp
        int pulse_bpm
        numeric weight_kg
    }
    clinical_note {
        int note_id PK
        int visit_id FK
        int written_by FK
        timestamp written_at
        text symptoms
        text notes
    }
    diagnosis_code {
        varchar icd10_code PK
        varchar description
    }
    diagnosis {
        int diagnosis_id PK
        int visit_id FK
        varchar icd10_code FK
        int made_by FK
        varchar kind "provisional or final"
        timestamp made_at
    }
```

## 3. Laboratory

```mermaid
erDiagram
    visit ||--o{ lab_order : has
    lab_order ||--|{ lab_order_item : contains
    lab_test ||--o{ lab_order_item : "is ordered as"
    lab_test ||--|{ lab_test_parameter : has
    lab_order_item ||--o{ lab_result : produces
    lab_test_parameter ||--o{ lab_result : "is reported in"

    lab_test {
        int test_id PK
        varchar name UK
        varchar sample_type
        numeric price
    }
    lab_test_parameter {
        int parameter_id PK
        int test_id FK
        varchar name
        varchar unit
        numeric normal_low
        numeric normal_high
    }
    lab_order {
        int lab_order_id PK
        int visit_id FK
        int ordered_by FK
        timestamp ordered_at
    }
    lab_order_item {
        int lab_order_id PK, FK
        int test_id PK, FK
        int performed_by FK
        timestamp completed_at "empty until the test is run"
    }
    lab_result {
        int lab_order_id PK, FK
        int test_id PK, FK
        int parameter_id PK, FK
        numeric value_numeric
        varchar value_text "for non-numeric results"
    }
```

## 4. Pharmacy and stock

```mermaid
erDiagram
    visit ||--o{ prescription : has
    prescription ||--|{ prescription_item : lists
    drug ||--o{ prescription_item : "is prescribed as"
    branch ||--o{ branch_stock : holds
    drug ||--o{ branch_stock : "is stocked as"
    branch_stock ||--o{ restock_request : "is restocked by"

    drug {
        int drug_id PK
        varchar name
        varchar form "tablet, syrup, injection"
        varchar strength
        numeric unit_price "per tablet, bottle or vial"
    }
    prescription {
        int prescription_id PK
        int visit_id FK
        int prescribed_by FK
        timestamp prescribed_at
    }
    prescription_item {
        int prescription_id PK, FK
        int drug_id PK, FK
        varchar dose
        varchar frequency
        int duration_days
        int quantity "in the smallest unit"
        varchar instructions
        int dispensed_by FK
        timestamp dispensed_at "empty until dispensed"
    }
    branch_stock {
        int branch_id PK, FK
        int drug_id PK, FK
        int quantity_in_stock "in the smallest unit"
        int reorder_level
    }
    restock_request {
        int request_id PK
        int branch_id FK
        int drug_id FK
        int quantity_requested
        int requested_by FK
        timestamp requested_at
        varchar status
        int reviewed_by FK
        timestamp reviewed_at
    }
```

## 5. Billing

```mermaid
erDiagram
    visit ||--o{ charge : incurs
    lab_order_item |o--o| charge : "is billed as"
    prescription_item |o--o| charge : "is billed as"
    payment |o--|{ charge : settles

    charge {
        int charge_id PK
        int visit_id FK
        varchar charge_type "consultation, lab_test or drug"
        int lab_order_id FK
        int test_id FK
        int prescription_id FK
        int drug_id FK
        int quantity
        numeric unit_price "price at the time"
        int payment_id FK "empty until paid"
    }
    payment {
        int payment_id PK
        int received_by FK
        timestamp received_at
        varchar method "cash, transfer or card"
    }
```
