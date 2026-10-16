# Normalisation: from a visit record sheet to the Tomiwa Hospitals schema

This shows why the schema is shaped the way it is. It starts from the kind of spreadsheet a busy hospital might keep, shows the problems that spreadsheet causes, and normalises it one step at a time.

It covers the slice of the design that holds patients, branches, doctors, visits and drugs. The laboratory and billing tables were designed with the same method: lab tests and drugs are both catalogues that a visit uses many of, so they follow the same pattern.

**Evidence:** every step runs in PostgreSQL. [normalisation-demo.sql](normalisation-demo.sql) builds the tables in a separate `normalisation_demo` schema and demonstrates each problem, and [normalisation-demo-output.txt](normalisation-demo-output.txt) is the output from running it. To run it yourself from the repository folder:

```powershell
Get-Content portfolio-1-database-design/normalisation-demo.sql | docker exec -i hospital-postgres psql -U hospital_admin -d hospital
```

or, in Git Bash:

```bash
docker exec -i hospital-postgres psql -U hospital_admin -d hospital < portfolio-1-database-design/normalisation-demo.sql
```

## Step 0: the visit record sheet (unnormalised)

One row per visit, with columns for up to two drugs:

| visit_no | visit_date | hospital_no | patient_name | patient_phone | branch | state | doctor | drug_1 | price_1 | qty_1 | drug_2 | price_2 | qty_2 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 5001 | 2026-10-01 | TH-000101 | Adaeze Okafor | 0800 000 0101 | Ilorin | Kwara | Dr Kemi Adebayo | Artemether/Lumefantrine 20/120 mg | 150 | 24 | Paracetamol 500 mg | 50 | 18 |
| 5002 | 2026-10-01 | TH-000102 | Musa Bello | 0800 000 0102 | Ilorin | Kwara | Dr Kemi Adebayo | Paracetamol 500 mg | 50 | 10 | | | |
| 5003 | 2026-10-03 | TH-000101 | Adaeze Okafor | 0800 000 0101 | Lagos Ikeja | Lagos | Dr Ibrahim Yusuf | Amoxicillin 500 mg | 120 | 15 | | | |
| 5004 | 2026-10-04 | TH-000103 | Funmi Adeyemi | 0800 000 0103 | Lagos Ikeja | Lagos | Dr Ibrahim Yusuf | Artemether/Lumefantrine 20/120 mg | 150 | 24 | Amoxicillin 500 mg | 120 | 15 |

The drug columns are a **repeating group**: the same three facts (drug, price, quantity) repeated across the row.

- A prescription with a third drug needs a new set of columns, which means changing the structure of the sheet.
- Visits with one drug leave the second set empty.
- Finding every visit that prescribed amoxicillin means searching two columns, and more as the sheet grows.

## Step 1: first normal form (1NF)

**Rule:** every cell holds a single value, and there are no repeating groups.

The repeating group is removed by giving each drug on a visit its own row. A row is now identified by **(visit_no, drug_name)** together:

| visit_no | hospital_no | patient_name | patient_phone | branch | doctor | drug_name | unit_price | quantity |
|---|---|---|---|---|---|---|---|---|
| 5001 | TH-000101 | Adaeze Okafor | 0800 000 0101 | Ilorin | Dr Kemi Adebayo | Artemether/Lumefantrine 20/120 mg | 150 | 24 |
| 5001 | TH-000101 | Adaeze Okafor | 0800 000 0101 | Ilorin | Dr Kemi Adebayo | Paracetamol 500 mg | 50 | 18 |
| 5002 | TH-000102 | Musa Bello | 0800 000 0102 | Ilorin | Dr Kemi Adebayo | Paracetamol 500 mg | 50 | 10 |
| 5003 | TH-000101 | Adaeze Okafor | 0800 000 0101 | Lagos Ikeja | Dr Ibrahim Yusuf | Amoxicillin 500 mg | 120 | 15 |
| 5004 | TH-000103 | Funmi Adeyemi | 0800 000 0103 | Lagos Ikeja | Dr Ibrahim Yusuf | Amoxicillin 500 mg | 120 | 15 |
| 5004 | TH-000103 | Funmi Adeyemi | 0800 000 0103 | Lagos Ikeja | Dr Ibrahim Yusuf | Artemether/Lumefantrine 20/120 mg | 150 | 24 |

(visit_date and branch_state are also in the table but left out here for width.)

Any number of drugs now fits, but the table still repeats facts. Adaeze's name and phone appear three times, and "Ilorin is in Kwara" appears three times. That repetition causes three problems, all shown in the demo:

| Problem | What happens | Result in the demo |
|---|---|---|
| **Update anomaly** | Adaeze changes her phone number, and the receptionist edits only one of her three rows | The table now holds **two different phone numbers** for the same patient |
| **Insertion anomaly** | A new patient, Chidi Eze, registers before ever having a visit | **Refused:** `null value in column "visit_no" … violates not-null constraint`. A patient can't exist without a visit and a drug |
| **Deletion anomaly** | Musa's only visit is deleted | **0 rows** still mention Musa. Deleting the visit erased the patient |

## Functional dependencies

A functional dependency **A → B** means: if you know A, there is only one possible value of B. These are the dependencies in the 1NF table:

| Dependency | Meaning |
|---|---|
| visit_no → visit_date, hospital_no, branch_name, doctor_name | A visit happens on one date, for one patient, at one branch, with one doctor |
| hospital_no → patient_name, patient_phone | A hospital number belongs to one patient |
| branch_name → branch_state | A branch is in one state |
| drug_name → unit_price | A drug has one price |
| (visit_no, drug_name) → quantity | How much of a drug was given depends on both the visit and the drug |

The next two steps use these to decide where each column belongs.

## Step 2: second normal form (2NF)

**Rule:** the table is in 1NF, and every non-key column depends on the **whole** key, not just part of it.

The key is (visit_no, drug_name), but most columns depend on only half of it. These are **partial dependencies**:

- The visit columns (date, patient, branch, doctor) depend on **visit_no alone**.
- unit_price depends on **drug_name alone**.
- Only **quantity** depends on both.

Each group moves to a table keyed by the part it depends on:

| Table | Key | Columns |
|---|---|---|
| visit_2nf | visit_no | visit_date, hospital_no, patient_name, patient_phone, branch_name, branch_state, doctor_name |
| drug | drug_name | unit_price |
| visit_drug | (visit_no, drug_name) | quantity |

Creating a primary key on each new table also tests the dependencies. If any visit_no had two different dates, or any drug two prices, PostgreSQL would refuse to create the key. It accepted all three.

## Step 3: third normal form (3NF)

**Rule:** the table is in 2NF, and no non-key column depends on another non-key column. That kind of chain is a **transitive dependency**.

visit_2nf still has two chains:

- visit_no → hospital_no → patient_name, patient_phone. The patient's details depend on the hospital number, not on the visit.
- visit_no → branch_name → branch_state. The state depends on the branch, not on the visit.

Each chain moves to its own table, leaving a foreign key behind:

| Table | Key | Columns | Foreign keys |
|---|---|---|---|
| patient | hospital_no | patient_name, patient_phone | |
| branch | branch_name | branch_state | |
| visit | visit_no | visit_date, hospital_no, branch_name, doctor_name | hospital_no → patient, branch_name → branch |
| drug | drug_name | unit_price | |
| visit_drug | (visit_no, drug_name) | quantity | visit_no → visit, drug_name → drug |

`doctor_name` stays in visit at this stage. With no other doctor details in the sheet, it doesn't create a chain. In the final design doctors get their own table anyway, because staff have details of their own (role, branch, phone) and two doctors can share a name.

## Step 4: the problems are gone

The demo repeats the same three operations on the 3NF tables:

| Operation | Result in the demo |
|---|---|
| Change Adaeze's phone | One row is updated in patient, and **both** of her visits show the new number |
| Register Chidi Eze before any visit | **Accepted.** He exists in patient with no visit |
| Delete Musa's visit | Musa's patient record **is still there** |

## Step 5: nothing was lost

Splitting a table is only safe if joining the parts back together gives exactly the original rows. This is called a **lossless decomposition**. The demo joins the five 3NF tables and compares the result with the 1NF table in both directions:

| Check | Result |
|---|---|
| Rows in the 1NF table | 6 |
| Rows rebuilt from the 3NF tables | 6 |
| Rows in 1NF that the rebuild is missing | **0** |
| Rows the rebuild invented | **0** |

The repetition is gone too:

| Fact | Copies in 1NF | Copies in 3NF |
|---|---|---|
| Adaeze's name and phone | 3 | 1 |
| Paracetamol's price | 2 | 1 |
| Ilorin is in Kwara | 3 | 1 |

## Boyce–Codd normal form (BCNF)

BCNF is a stricter version of 3NF: **every determinant must be a candidate key.** A determinant is anything on the left of an arrow. In each 3NF table above, the only determinant is the table's own key, so all five tables are also in BCNF.

The final design adds one case worth checking. The patient table has two candidate keys, `patient_id` and `hospital_number`, and each determines every other column. Both are candidate keys, so the table is still in BCNF.

## From the 3NF result to the final design

| 3NF table | Final table(s) | What changed, and why |
|---|---|---|
| patient | patient | A generated `patient_id` becomes the primary key. `hospital_number` is kept unique as a candidate key, because card numbers can be reissued in a new format but the ID never changes |
| branch | branch | A generated `branch_id`, with the name kept unique |
| doctor_name in visit | staff | Staff have their own details, and names aren't unique. `visit.doctor_id` points at staff |
| visit | visit | Holds patient, branch and doctor as foreign keys |
| drug | drug | `unit_price` is the **current** price |
| visit_drug | prescription and prescription_item | A visit can have more than one prescription (before and after lab results), and each line gains dose, frequency and duration |

## The price trap: why charge stores a price as well

In the sheet, `drug_name → unit_price` looked true only because no price changed during those four visits. If paracetamol rises to ₦60 next month, last month's visits must still show the ₦50 that was actually charged. So there are two different facts:

- **drug.unit_price** is the price today. It depends on the drug.
- **charge.unit_price** is the price paid on that visit. It depends on the charge.

Storing the second is not redundancy, and it doesn't break 3NF: it depends on the charge's own key, not on the drug.

`visit.branch_id` follows the same reasoning. It might look derivable from the doctor's branch, but doctors can move between branches, so `doctor_id → branch_id` doesn't hold over time. Where the visit happened is a fact about the visit.

## Values deliberately not stored

Some values can always be calculated from data already held, so storing them would create new update anomalies:

| Value | Calculated from |
|---|---|
| A patient's age | date_of_birth |
| A lab result's high/low flag | The value and the parameter's normal range |
| A charge's total | quantity × unit_price |
| A payment's amount | The charges it settles |
| Whether a visit is cash or insured | Whether the visit has a policy_id |

## The cost of normalising

Normalising removes repetition, but answering a question now takes joins. Rebuilding one row of the original sheet joins five tables. The course material notes that over-normalising makes queries more complex. Portfolio 2 measures what those joins cost and uses indexes to keep them fast. Portfolio 4 deliberately goes the other way, storing related data together in MongoDB documents where reads matter more than avoiding repetition.
