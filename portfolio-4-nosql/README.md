# Portfolio 4: NoSQL and Advanced Data Models

Case study: **Tomiwa Hospitals** (see the [main README](../README.md)).

This portfolio models the same hospital as a **document database** in MongoDB 8.0. It does not use invented sample data: the September 2026 records in the Portfolio 1 PostgreSQL database are reshaped into documents and loaded into MongoDB. The two models therefore hold exactly the same facts, and the results can be checked against each other.

| File | What it is |
|---|---|
| [export.sql](export.sql) | Builds one JSON document per visit and per patient from the PostgreSQL tables |
| [setup.js](setup.js) | Starts the replica set and creates the collections with their validation rules |
| [load.ps1](load.ps1) | Runs the whole pipeline: export, setup and import |
| [load-output.txt](load-output.txt) | Output of the load |
| [queries.js](queries.js) | Queries, indexes, validation and transactions |
| [queries-output.txt](queries-output.txt) | Output of the queries |

To reproduce it:

```powershell
powershell -ExecutionPolicy Bypass -File portfolio-4-nosql/load.ps1
docker exec hospital-mongo mongosh --quiet --file /portfolio/portfolio-4-nosql/queries.js
```

## Why a document model fits part of this hospital

Almost everything a doctor, nurse or lab scientist does happens **within one visit**. They take vitals, write notes, record diagnoses, order and report tests, and prescribe. In the relational design, that one visit is spread across a dozen tables, so showing it on screen means joining them all back together. A document database can store the whole visit as one document. Lab results also vary a great deal between tests: a full blood count has six numeric measures, a malaria test has one text result, and urinalysis has a mixture. That variety fits a flexible structure well.

## The document model

| Collection | Documents | Average size | Holds |
|---|---:|---:|---|
| `visits` | 95,845 | 2,772 bytes | Everything that happened during one visit |
| `patients` | 81,832 | 340 bytes | The patient's details, insurance policies and portal login |
| `branchStock` | 288 | 125 bytes | One document per branch and drug |
| `branches`, `drugs`, `labTests` | 16, 18, 8 | | Reference lists |

An abridged visit document:

```json
{
  "_id": 1072156,
  "patient": { "id": 24837, "hospitalNumber": "TH-0024837", "name": "Ibrahim Dike" },
  "branch": { "id": 15, "name": "Tomiwa Hospitals Enugu", "state": "Enugu" },
  "doctor": { "id": 411, "name": "Precious Salami" },
  "checkedInAt": { "$date": "2026-09-01T06:40:14.604Z" },
  "status": "completed",
  "payer": { "type": "cash" },
  "vitals": [ { "recordedAt": "...", "temperatureC": 38.0,
                "bloodPressure": { "systolic": 104, "diastolic": 62 }, "pulseBpm": 94 } ],
  "notes": [ { "symptoms": "Fever, headache and joint pains for 3 days",
               "notes": "Suspected malaria. Malaria parasite test requested." } ],
  "diagnoses": [ { "kind": "provisional", "code": "B54" },
                 { "kind": "final", "code": "B50.9" } ],
  "labOrders": [ { "orderId": 1072156, "tests": [ { "name": "Malaria parasite (MP)",
                   "results": [ { "name": "Malaria parasites", "value": "Seen (+)" } ] } ] } ],
  "prescriptions": [ { "items": [ { "drug": "Artemether/Lumefantrine 20/120 mg tablet",
                                    "dose": "2 tablets", "quantity": 12 } ] } ],
  "charges": [ { "type": "consultation", "unitPrice": 6500,
                 "payment": { "method": "card", "receivedAt": "..." } } ]
}
```

Times are stored in UTC, as MongoDB expects. Nigeria is one hour ahead, so a check-in at 07:40 in Enugu is stored as `06:40Z`.

### What is embedded and what is referenced

The central design decision in a document database is whether related data goes **inside** a document or into a **separate** one.

| Data | Decision | Reason |
|---|---|---|
| Vitals, notes, diagnoses, lab orders, prescriptions, charges | **Embedded** in the visit | They belong to exactly one visit, are read together, and are few. The largest visit is 5,147 bytes, far below MongoDB's 16 MB limit |
| Lab tests and their results | **Embedded** inside each lab order | A result means nothing without its test and order. Results use a list of `{name, value, unit, normalLow, normalHigh}`, so each test can measure different things |
| Patient | **Referenced** by `patient.id`, plus a copy of the hospital number and name | Embedding visits inside the patient would make one document grow without limit, visit after visit for decades. The copy of the name lets lists of visits display without looking up the patient |
| Insurance policies | **Embedded** in the patient | A patient has few policies (at most 2 here), and they are read with the patient |
| Branch and doctor | A **copy** of the id and name in each visit | These record who and where *at the time*, the same reasoning as `visit.branch_id` in Portfolio 1 |
| Stock | **Separate** documents, one per branch and drug | Stock changes every time a drug is dispensed. One document holding all of a branch's stock would have every pharmacist at the branch updating the same document at once |
| Drug and test catalogues | **Separate** collections | Visits copy the name and price charged, so later price changes don't rewrite history |

Two things are deliberately left out. The high/low flag on a result is worked out when a report is read, as in Portfolio 1. The portal password hash is not copied at all: the document database serves the clinical record and has no reason to hold login secrets.

**The trade-off of copying.** If a patient changes their name, the copies in their old visits keep the old name. For a medical record that is usually correct, because it shows how the patient was recorded at the time. If the copies did need updating, one `updateMany({"patient.id": …})` would do it. That is extra work the relational design never needs.

## How the data was moved

[export.sql](export.sql) builds each document inside PostgreSQL with `json_build_object` and `json_agg`. Each visit's vitals, notes, diagnoses, lab results, prescriptions and charges are grouped and nested under the visit, and timestamps are converted from Nigerian time to UTC. PostgreSQL writes the documents to a Docker volume shared with the MongoDB container, and `mongoimport` loads them. The export took 69 seconds and the full load 101 seconds.

**Every one of the 95,845 visits and 81,832 patients passed MongoDB's validation rules on import**, and 0 were rejected ([load-output.txt](load-output.txt)).

Three queries were checked against the same questions asked of PostgreSQL:

| Check | MongoDB | PostgreSQL |
|---|---|---|
| Ikeja's takings on 15 September (M3) | Card ₦999,010 (154 payments), cash ₦1,573,985 (299), transfer ₦1,836,700 (296) | Identical (Portfolio 2, Q4) |
| States with at least 1,500 confirmed malaria cases in September (M4) | Edo 1,538, Enugu 1,508, Kano 1,808, Kwara 2,039, Lagos 2,454, Oyo 1,844, Rivers 1,853 | Identical |
| September visits with haemoglobin below 8 g/dL (M6) | 1,204 | 1,204 |

## Validation

A document database does not have to accept anything. [setup.js](setup.js) gives each collection a `$jsonSchema` validator that requires the key fields, fixes their types, limits values such as a diagnosis's `kind` to an allowed list, and sets ranges such as a temperature between 30 and 45 °C. Four test documents were tried:

| Test | Result |
|---|---|
| V1: a visit with no patient | **Rejected**: `document: missing patient` |
| V2: a diagnosis whose kind is "maybe" | **Rejected**: `diagnoses[0].kind: value was not found in enum` |
| V3: a lab result whose value is `true` | **Rejected**: `labOrders[0].tests[0].results[0].value: type did not match` |
| V4: a visit with a new **SARS-CoV-2 rapid antigen** test on a nasal swab, and a **referral** to another hospital | **Accepted** with no schema change |

V4 shows the flexibility. In the Portfolio 1 schema, a nasal swab would break the CHECK rule on `lab_test.sample_type`, and a referral would need a new table and a migration. Here, a new test or a new kind of information can start being recorded at once. The cost is that the database only enforces the rules someone writes down: nothing stops a misspelt field name from being stored as a new field.

## Queries and indexes

Each query ran first with only the automatic indexes (on `_id` and `hospitalNumber`), then again after five indexes were added. Times are the median of five runs and include the round trip from the MongoDB shell. *Documents examined* is the steadier measure.

| Query | Before (ms) | After (ms) | Documents examined, before → after | Plan after indexing |
|---|---:|---:|---:|---|
| M1 Patient history | 69.02 | 3.11 | 95,845 → 5 | IXSCAN `patient_history` |
| M2 Lab report for one visit | 3.95 | 5.05 | 1 → 1 | `_id` lookup, unchanged |
| M3 Daily takings at Ikeja | 74.96 | 7.34 | 95,845 → 321 | IXSCAN `branch_day` |
| M4 Confirmed malaria per state | 97.59 | 81.82 | 95,845 → 24,091 | IXSCAN `diagnosis_code` |
| M5 Find a patient by name | 50.22 | 2.41 | 81,832 → 11 | IXSCAN `name_case_insensitive` |
| M6 Haemoglobin below 8 g/dL | 170.81 | 26.50 | 95,845 → 1,204 | IXSCAN `lab_result_value` |

**M1, patient history.** Before indexing, MongoDB read every visit and then sorted the patient's five in memory (`SORT < COLLSCAN`). The index on `(patient.id, checkedInAt descending)` finds the five visits and returns them already in date order, so the plan has no sort step at all.

**M2, lab report.** The whole report comes from **one document** found by its `_id`: MongoDB examined 1 document. The same report in PostgreSQL joined five tables. No new index helps a lookup that is already a single read, so the small time difference is noise.

**M3, daily takings.** This is the query that needed an experiment in Portfolio 2: it was slow there because the payment table does not record a branch, so every branch's payments had to be looked up before Ikeja's could be picked out. In the document model, the charges and payments sit inside the visit, and the visit already records its branch. The `branch_day` index went straight to Ikeja's 321 visits that day, and the answer matched PostgreSQL to the naira.

**M4, malaria per state.** The index cut documents examined only from 95,845 to 24,091, because confirmed malaria is about a quarter of all September visits, so most of the collection still had to be read. MongoDB used the index anyway. Its planner chooses between candidate index plans by trying them briefly, and normally only scans the whole collection when no index applies. PostgreSQL's cost-based planner, faced with the same kind of query in Portfolio 2, chose to read the tables in full instead. The better answer for a monthly report is the same in both systems: compute it once and store the result, as Portfolio 2's materialised view did.

**M5, find a patient by name.** The index uses a **collation** with strength 2, which compares text without regard to capital letters, so a search for "folake mamman" finds "Folake Mamman". The query has to ask for the same collation to use the index. This is the document-database counterpart of Portfolio 2's index on `lower(name)`.

**M6, severe anaemia.** Lab results sit three arrays deep (orders → tests → results). A **multikey index** stores one entry for every result in every document, so MongoDB can search inside the nested arrays. The query uses `$elemMatch` so that both conditions, `name = "Haemoglobin"` and `value < 8`, must hold for the **same** result. Without it, a visit could match if one result was named Haemoglobin and a different result happened to be below 8.

The five indexes took 3 seconds to build and use 7.0 MB, against 77.5 MB for the visits themselves.

## Atomicity and transactions

**A1: one document, one atomic update.** A nurse retaking vitals adds a reading and moves the patient on to the doctor. In MongoDB that is a single `updateOne` with `$push` and `$set` on the visit document. Changes to a single document are always all-or-nothing, so no transaction is needed. An update that also tried to set the status to "on_lunch" was rejected by the validator, and its vitals reading was not added either. Because the visit is one document, most clinical work (vitals, notes, diagnoses, lab orders) touches one document and is atomic automatically.

**T1: two documents need a transaction.** Dispensing changes the visit (the prescription line is marked as dispensed) and a separate `branchStock` document. That needs a **multi-document transaction**, which MongoDB only allows on a replica set. That is why this MongoDB runs as a one-member replica set, `rs0`. The stock update includes the check `quantityInStock >= quantity` in its filter, the same idea as subtracting inside the `UPDATE` in Portfolio 3.

| Attempt | Result | Ilorin paracetamol stock | Prescription line |
|---|---|---:|---|
| Start | | 31,174 | Not dispensed |
| Dispense 18 | **Committed** | 31,156 | Dispensed |
| Dispense 32,156, more than the branch holds | **Aborted**: the stock filter matched nothing, so nothing was changed | 31,156 | Not dispensed |

The demonstration then puts the stock back and removes its test documents.

## Storage

The 287 MB of exported JSON takes 253 MB as BSON (MongoDB's binary format), but only **77.5 MB on disk**, because MongoDB's storage engine compresses data. Repeated field names in every document are a known cost of the document model, and compression recovers most of it.

## Where each model fits

| Need at Tomiwa Hospitals | Better fit | Why |
|---|---|---|
| Opening a patient's visit, or the patient portal's history page | **Document** | The whole visit is one read, with no joins |
| Recording new kinds of tests or information | **Document** | No migration needed |
| Spreading data across branches (Portfolio 5) | **Document** | A visit is self-contained, so visits can be stored by branch without splitting related rows |
| Billing, payments and stock | **Relational** | Money and stock need strict rules across many rows: foreign keys, CHECK constraints, and transactions as the normal case |
| Rules across documents, such as no double-booking | **Relational** | MongoDB can enforce a unique index, but rules like "at least one doctor on call" or "this payment's charges belong to one visit" are far easier to enforce with SQL constraints and transactions |
| Reports that slice data in new ways | **Relational** | SQL joins any table to any other. A document model is shaped around the questions it was designed for: M3 was fast because charges sit inside visits, but a report by drug across all visits must open every visit |

**Recommendation:** use both. PostgreSQL stays the **system of record** for appointments, billing, payments and stock, where its constraints and transactions protect the hospital's money and schedules. MongoDB serves the **clinical record and the patient portal**, where reading a whole visit at once and recording new kinds of results matter most. Changes would flow from PostgreSQL into MongoDB, as the export in this portfolio does in bulk.

## Other NoSQL models

MongoDB is a document store. The other main NoSQL models would each suit a different part of the hospital:

| Model | Example system | Where it could fit at Tomiwa Hospitals |
|---|---|---|
| Key-value | Redis | Today's patient queue at each branch, or portal login sessions: fast lookups by a single key |
| Wide-column | Cassandra | Vital signs streamed every few seconds from bedside monitors: huge volumes written in time order |
| Graph | Neo4j | Referral networks between doctors and hospitals, or tracing contacts during an outbreak, where the links between records are the point |
