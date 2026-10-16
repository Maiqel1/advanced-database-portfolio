# Portfolio 1: Database Design and Modelling

Case study: **Tomiwa Hospitals** (see the [main README](../README.md)).

The design moves through the stages described in the course material: a **conceptual** model of the things the hospital cares about, then a **logical** model of tables, columns and keys.

| File | Stage | What it is |
|---|---|---|
| [er-conceptual.puml](er-conceptual.puml) and the four `er-conceptual-*.png` images | Conceptual | Chen-notation ER diagrams, written in PlantUML |
| [schema.dbml](schema.dbml) and [er-logical.png](er-logical.png) | Logical | All tables, columns and keys, drawn in [dbdiagram.io](https://dbdiagram.io) |
| [er-logical-areas.md](er-logical-areas.md) and the five `er-logical-*.png` images | Logical | The same tables area by area, with each relationship labelled, written in Mermaid |
| [normalisation.md](normalisation.md), [normalisation-demo.sql](normalisation-demo.sql) and [its output](normalisation-demo-output.txt) | Logical | How a flat visit record sheet is normalised to 3NF and BCNF, with each anomaly demonstrated in PostgreSQL |

## Conceptual ER diagram (Chen notation)

The conceptual model shows the hospital's entities and how they relate, before any decisions about tables. It is split into four parts so each one stays readable. Visit and Branch appear in more than one part, but their attributes are shown only once.

| Symbol | Meaning |
|---|---|
| Rectangle | Entity |
| Diamond | Relationship |
| Ellipse | Attribute. An underlined name is the key |
| Ellipse joined to smaller ellipses | Composite attribute, such as name (first and last) or blood pressure (systolic and diastolic) |
| Dashed ellipse | Derived attribute, worked out from other data, such as age from date of birth |
| Double rectangle | Weak entity, with no key of its own (a lab result is identified by the order and measurement it belongs to) |
| Double diamond | Identifying relationship, which links a weak entity to its owner |
| Thick line | Total participation: every lab result must belong to a lab order |
| 1, N, M on a line | Cardinality, written beside the entity it counts |

At this stage the many-to-many relationships **includes**, **lists** and **stocks** are diamonds with their own attributes, such as dose and reorder level. In the logical model they become the junction tables `lab_order_item`, `prescription_item` and `branch_stock`.

![Conceptual ER diagram, part 1: patients, staff, branches and visits](er-conceptual-1-core.png)

![Conceptual ER diagram, part 2: clinical care](er-conceptual-2-clinical.png)

![Conceptual ER diagram, part 3: laboratory](er-conceptual-3-laboratory.png)

![Conceptual ER diagram, part 4: pharmacy, stock and billing](er-conceptual-4-pharmacy-billing.png)

## Logical ER diagram: overview

Every table with its columns, keys and relationships, exported from [dbdiagram.io](https://dbdiagram.io) using [schema.dbml](schema.dbml). The columns ending in `_by`, which record the staff member who did something, are not drawn as lines to keep the diagram readable. They are listed under [Links to staff](#links-to-staff).

![Logical ER diagram of all 24 tables](er-logical.png)

## Relational schema by area

The same tables, one area at a time, with each relationship labelled.

**Notation (crow's foot).** Each end of a line shows how many of the table on that side can be involved:

| Symbol | Meaning |
|---|---|
| `\|\|` | exactly one |
| `\|o` | zero or one |
| `\|{` | one or more |
| `o{` | zero or more |

So `patient ||--o{ visit` reads: each visit belongs to exactly one patient, and each patient has zero or more visits.

### 1. People and places

![Logical ER diagram, people and places](er-logical-1-people.png)

### 2. Visits and clinical care

![Logical ER diagram, visits and clinical care](er-logical-2-visits.png)

### 3. Laboratory

![Logical ER diagram, laboratory](er-logical-3-laboratory.png)

### 4. Pharmacy and stock

![Logical ER diagram, pharmacy and stock](er-logical-4-pharmacy.png)

### 5. Billing

![Logical ER diagram, billing](er-logical-5-billing.png)

## Links to staff

Every one of these columns is a foreign key to `staff.staff_id`. It records who did something, which is what makes the clinical record auditable. A trigger also checks that the staff member holds the role shown when the record is written.

| Table | Column | Staff role |
|---|---|---|
| appointment | doctor_id | Doctor |
| appointment | booked_by | Receptionist (empty when booked on the portal) |
| visit | doctor_id | Doctor |
| visit | checked_in_by | Receptionist |
| vital_signs | recorded_by | Nurse |
| clinical_note | written_by | Doctor |
| diagnosis | made_by | Doctor |
| lab_order | ordered_by | Doctor |
| lab_order_item | performed_by | Lab scientist |
| prescription | prescribed_by | Doctor |
| prescription_item | dispensed_by | Pharmacist |
| restock_request | requested_by | Head of Pharmacy |
| restock_request | reviewed_by | Branch Manager |
| payment | received_by | Receptionist |

## Rules the diagram cannot show

- **Composite unique keys:** `(insurer_id, policy_number)` on insurance_policy, `(name, form, strength)` on drug, and `(test_id, parameter_id)` on lab_test_parameter.
- **A result's measurement must belong to the ordered test.** lab_result's `(test_id, parameter_id)` refers to lab_test_parameter, so haemoglobin can never be recorded against a urinalysis.
- **A restock request must be for a drug the branch stocks.** restock_request's `(branch_id, drug_id)` refers to branch_stock.
- **Each charge points at exactly the right thing.** A consultation charge has no item links, a lab_test charge links only to a lab_order_item, and a drug charge links only to a prescription_item. Each item is charged at most once, and each visit has at most one consultation charge.
- **No double-booking:** a doctor cannot have two active appointments at the same time.
- **Value checks:** stock and quantities cannot be negative, a policy's `valid_to` is after its `valid_from`, and `role`, `status`, `kind` and similar columns only accept their listed values.
- **Minimums of "one or more"** (an order has at least one test, a prescription at least one drug, a payment at least one charge) are met by creating the parent and its items together in one transaction.
- **Staff roles on links:** a foreign key only proves the staff member exists. A trigger checks that they hold the role listed under [Links to staff](#links-to-staff) when the record is written. A CHECK constraint can't do this, because it cannot read the staff table. Copying the role into each table would also work, but staff could then never change role, and the trigger only checks the role *at the time*, so a nurse later promoted to doctor keeps their old records.

## Key design decisions

- **The visit is the centre of the design.** It resolves the many-to-many relationship between doctors and patients, and links the branch, the payer and every clinical record from one trip.
- **Three many-to-many relationships become junction tables:** `prescription_item` (prescription and drug), `lab_order_item` (lab order and lab test) and `branch_stock` (branch and drug). Data about the pair, such as dose, who ran the test, and stock level, lives on the junction.
- **Surrogate keys** (generated integer IDs) identify most rows. `hospital_number` is a candidate key kept unique, and `diagnosis_code` uses the ICD-10 code itself as a natural key.
- **Clinical records are only ever added to.** Retaken vitals, follow-up lab orders, and a final diagnosis alongside the provisional one are all new rows.
- **Facts that change over time are stored as they were.** A visit keeps the branch where it happened and the insurance policy that covered it, and a charge keeps the price at the time.
- **Values that can be calculated are not stored.** The high/low flag on a result, the total of a charge or payment, and whether a visit is cash or insured (no policy means cash) are all worked out when read.
- **Insured visits are never paid at the counter.** Their charges are recorded but have no payment, because they are billed to the HMO.
- **Stock and dispensing use the smallest unit** (tablet, bottle, vial), so the numbers always add up.
