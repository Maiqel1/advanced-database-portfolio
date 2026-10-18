# Portfolio 2: Query Processing and Optimisation

Case study: **Tomiwa Hospitals** (see the [main README](../README.md)).

This portfolio takes eight queries that Tomiwa Hospitals runs every day, measures how PostgreSQL executes them on the Portfolio 1 database (1,168,000 visits, about 21.9 million rows), improves them, and measures again. Every number below comes from [benchmark-output.txt](benchmark-output.txt), produced by running [benchmark.sql](benchmark.sql).

| File | What it is |
|---|---|
| [benchmark.sql](benchmark.sql) | Resets the database to the Portfolio 1 baseline, runs every query before and after optimisation, and measures rewrites and costs |
| [optimisations.sql](optimisations.sql) | The seven indexes and one materialised view this portfolio adds |
| [benchmark-output.txt](benchmark-output.txt) | The full output: query results, every execution plan, and the measurements |

To reproduce it (it takes a few minutes):

```powershell
docker exec hospital-postgres psql -U hospital_admin -d hospital -f /portfolio/portfolio-2-query-optimisation/benchmark.sql
```

## Method

- **Execution plans:** each query runs under `EXPLAIN (ANALYZE, BUFFERS)`, which executes it and reports the plan PostgreSQL chose, the time each step took, and how many 8 kB pages it touched.
- **Timing:** one warm-up run, then the **median of five runs**, so the figures describe a warm cache. Times exclude planning and sending rows to a client.
- **Pages:** the total of pages found in PostgreSQL's buffer cache (*shared hit*, logical I/O) and pages fetched from the operating system or disk (*read*, physical I/O).
- **Baseline:** only the indexes Portfolio 1 created for primary keys and unique rules.
- **Inputs from real data:** patient TH-0000001, who has the most visits in the year (24); doctor 32 at Ikeja on 15 September 2026; and the patient's most recent visit with a full blood count.
- **Environment:** PostgreSQL 16.15 in Docker Desktop on Windows, 4 CPUs and 8 GB of memory, default settings (`shared_buffers` 128 MB, `work_mem` 4 MB).

Timings vary between runs. Q1's baseline took 651 ms in one run and 379 ms in the next, but it touched exactly 28,051 pages both times. Page counts are therefore the steadier measure of how much work a plan does, and both are reported.

## Results

| Query | Used by | Before (ms) | After (ms) | Faster | Pages before | Pages after | What changed |
|---|---|---:|---:|---:|---:|---:|---|
| Q1 Patient history | Doctor, reception | 378.78 | 0.30 | 1,263× | 28,051 | 311 | Composite index on visit, index on diagnosis |
| Q2 Doctor's day list | Doctor | 65.53 | 0.12 | 546× | 7,743 | 124 | Query rewrite only: no new index |
| Q3 Lab report for a visit | Doctor | 56.17 | 0.11 | 511× | 4,943 | 52 | Index on lab_order (visit_id) |
| Q4 Daily takings | Branch manager | 645.35 | 42.98 | 15× | 94,523 | 69,767 | Indexes on payment and charge; see [the Q4 investigation](#investigating-q4) |
| Q5 Attendance by hour | Branch manager | 91.87 | 0.20 | 459× | 12,116 | 6 | Composite index, used as a covering index |
| Q6 Find a patient by name | Reception | 105.50 | 0.06 | 1,758× | 4,427 | 8 | Expression index on lower(name) |
| Q7 Malaria by state and month | Public health | 767.37 | 0.26 | 2,951× | 27,894 | 18 | Materialised view |
| Q8 Drugs below reorder level | Head of Pharmacy | 0.23 | 0.24 | none | 4 | 4 | Nothing: no index is the right answer |

## Query by query

### Q1: Patient history

A doctor opening a patient's record sees every visit with its branch, doctor and final diagnosis.

**Before:** PostgreSQL scanned **all 1,168,000 visits** to find this patient's 24, and **all 1.9 million diagnoses** to match them, using two worker processes in parallel (*Parallel Seq Scan*) and a hash join.

```
Parallel Hash Right Join
  -> Parallel Seq Scan on diagnosis d   (rows=389333 loops=3)
  -> Parallel Hash
       -> Hash Join
            -> Parallel Seq Scan on visit v   (rows=389333 loops=3)
            -> Index Scan using patient_hospital_number_key on patient p
Execution Time: 601.915 ms
```

This printed plan comes from one extra run, which took 602 ms. The median of five runs was 379 ms.

**Change:** `visit (patient_id, checked_in_at)` and `diagnosis (visit_id)`. Neither foreign key had an index, because PostgreSQL indexes primary keys automatically but not foreign keys.

**After:** the plan became a chain of nested loops, each looking up only the rows it needs:

```
Nested Loop Left Join
  -> Nested Loop
       -> Index Scan using patient_hospital_number_key on patient p   (rows=1)
       -> Bitmap Heap Scan on visit v                                  (rows=24)
            -> Bitmap Index Scan on visit_patient_checked_in_idx
  -> Index Scan using diagnosis_visit_idx on diagnosis d              (loops=24)
Execution Time: 0.276 ms
```

The plan also shows the optimiser's estimate against reality: it expected **5** visits for this patient, the database-wide average, and found **24**. The estimate was off, but it still chose the right plan, because looking up 24 rows by index is cheap either way.

### Q2: Doctor's day list

The doctor portal lists one doctor's appointments for a day.

**Before:** a parallel scan of all 759,584 appointments.

**Change: a rewrite, not an index.** Portfolio 1 already created a partial unique index, `appointment_no_double_booking`, on `(doctor_id, scheduled_for) WHERE status <> 'cancelled'`. A partial index only covers some rows, so PostgreSQL can only use it when the query is guaranteed to want only those rows. Adding `AND a.status <> 'cancelled'` states what the day list should show anyway, and that made the existing index usable: **546 times faster with no new index.** The rewrite does change the meaning, since cancelled slots disappear from the list, which is what a doctor's day list should do.

### Q3: Lab report for one visit

The doctor's review screen shows every result for a visit, with its normal range and a high or low flag:

| Test | Measurement | Result | Normal range | Flag |
|---|---|---|---|---|
| Full blood count (FBC) | Haemoglobin | 12.5 g/dL | 12 to 16 | |
| Full blood count (FBC) | Neutrophils | 36.7 % | 40 to 75 | LOW |
| Urinalysis | Specific gravity | 1.021 | 1.005 to 1.030 | |

The flag is worked out in the query from the value and the range, as decided in Portfolio 1. It is never stored.

**Before:** 759,401 lab orders scanned to find the visit's one order. Everything after that already used the composite primary keys on `lab_order_item` and `lab_result`.

**Change:** `lab_order (visit_id)`, another unindexed foreign key.

### Q4: Daily takings

The branch manager's end-of-day report: payments received at Ikeja on 15 September 2026, by payment method.

| Method | Payments | Amount (₦) |
|---|---:|---:|
| Card | 154 | 999,010 |
| Cash | 299 | 1,573,985 |
| Transfer | 296 | 1,836,700 |

**Change:** `payment (received_at)` and `charge (payment_id)`. This gave a 15× improvement, much less than the others. The [investigation below](#investigating-q4) explains why.

### Q5: Attendance by hour

How many patients checked in at Ikeja during each hour of one day.

**Change:** `visit (branch_id, checked_in_at)`. The **order of the columns** matters. The equality condition (`branch_id = 2`) comes first and the range (`checked_in_at` within one day) second, so the day's visits for one branch sit next to each other in the index. Because the query needs no other columns, PostgreSQL answered it from the index alone (*Index Only Scan*) and touched **6 pages**, so the index works as a covering index.

### Q6: Find a patient by name

Reception searches without worrying about capital letters, so the query compares `lower(last_name)` and `lower(first_name)`.

**Change:** an **expression index** on `(lower(last_name), lower(first_name))`. A plain index on the name columns would not help, because the query searches for the result of `lower()`, not the stored value, and the index has to match the expression exactly. The search returned the 36 patients named Ladi Onuoha in 0.06 ms instead of scanning all 300,000.

### Q7: Confirmed malaria per state per month

A public-health report: months where a state recorded at least 1,500 confirmed malaria cases, using `GROUP BY` and `HAVING`.

**Before:** parallel scans of both tables, then a hash join of about 236,000 confirmed malaria diagnoses with all 1,168,000 visits, followed by grouping. An index would do little here: the report needs a large share of both tables, and reading them in full is the cheapest way to get it.

**Change:** a **materialised view**, `monthly_diagnosis_by_state`. It stores the result of the expensive grouping, 2,496 rows covering every state, month and diagnosis, so the report reads a 144 kB table instead. The cost is freshness: the view only changes when refreshed. A refresh takes about 3 seconds and would run nightly, which suits a monthly report. The view has a unique index, so `REFRESH MATERIALIZED VIEW CONCURRENTLY` can update it without blocking readers.

### Q8: Drugs below reorder level

The Head of Pharmacy's restock list.

**No change, deliberately.** `branch_stock` has 288 rows on 4 pages, so a full scan is already the cheapest possible plan. The condition `quantity_in_stock < reorder_level` also compares two columns of the same row, which an ordinary B-tree index cannot search. The difference in timings (0.23 ms against 0.24 ms) is measurement noise.

## Query rewrites

| Test | Version | Time (ms) | Pages |
|---|---|---:|---:|
| R1 | Q5 with `checked_in_at::date = '2026-09-15'` | 13.39 | 453 |
| R1 | Q5 with a date range | 0.17 | 6 |
| R2 | `IN (subquery)` | 71.08 | 5,446 |
| R2 | `EXISTS (correlated subquery)` | 68.36 | 5,446 |
| R2 | `JOIN` with `DISTINCT` | 43.59 | 29,994 |
| R3 | `NOT EXISTS` | 366.15 | 16,517 |
| R3 | `NOT IN` | over 30,000 | stopped |

**R1: write conditions the index can search.** Casting the column (`checked_in_at::date = ...`) makes the condition *non-sargable*: the index stores timestamps, not dates, so PostgreSQL can only use the `branch_id` part of the index and must check every one of Ikeja's visits in the year. Writing the same day as a range on the raw column lets it jump straight to that day: **79 times faster with the same index.**

**R2: the optimiser already rewrites IN.** A common tuning tip is to rewrite an `IN` subquery as a join. PostgreSQL does this itself: the `IN` and `EXISTS` versions produced **identical plans** (a *Parallel Hash Semi Join*). This is known as subquery flattening, and the optimiser does it automatically. The manual `JOIN` version needs `DISTINCT` to give the same answer: all three return 8,609 patients, but the join without `DISTINCT` returns 9,648, because it counts a patient once per visit. Here the join happened to run faster, because the optimiser chose a different plan for it.

**R3: avoid NOT IN with a subquery.** "Patients with no visit this year" took 0.37 s with `NOT EXISTS`, which PostgreSQL runs as an *anti join*: one pass over each table. The `NOT IN` version was **still running after 30 seconds** and was stopped. Its plan shows why: `NOT IN` has awkward rules when NULLs are involved, so PostgreSQL cannot turn it into an anti join. Instead it runs a *SubPlan* that checks each of the 300,000 patients against a list of 1.17 million visits. The answer is 6,857 patients.

## Investigating Q4

Q4 improved far less than the other queries, so its plan was examined more closely.

**First idea, and why it was wrong.** The first version of the payment index was `(received_at) INCLUDE (method)`, meant to let PostgreSQL answer from the index alone. The plan still visited the payment table, because the query also needs `payment_id` to join to charges. A version including `payment_id` as well was tested: **it made no difference.** That part of the plan was never the problem. One day's payments sit together on about 20 table pages, because they were inserted in time order, so visiting the table costs almost nothing. The `INCLUDE` was dropped, which shrank the index from 84 MB to 54 MB.

**The real cause.** The `loops` counts in the plan show where the work goes. On 15 September, **7,520 payments across all 16 branches** each looked up their charges (about 30,000 pages). Then **9,888 visits** were looked up to find which branch each charge belonged to (about 39,500 pages). Only after that were Ikeja's 749 payments separated from the rest, so most of the work was thrown away. This happens because the payment table does not record a branch. Portfolio 1 left it out because it can be worked out through charge and visit, which is normalisation trading read speed for less repetition.

**The experiment (R4).** The benchmark builds a copy of the payment table that also stores the branch that received the money, indexes it on `(branch_id, received_at)`, and runs the same report:

| Version | Time (ms) | Pages |
|---|---:|---:|
| As designed: branch found through charge and visit | 40.47 | 69,767 |
| Branch stored on payment | 2.85 | 3,064 |

Both versions return exactly the same takings. Storing the branch makes the report **14 times faster** and does 23 times less work.

**Recommendation.** Add `branch_id` to `payment` in a future version of the schema. This is a defensible design change rather than mere duplication. The branch where money was received is a real fact about the payment, like `visit.branch_id`, and it does not change if the receptionist later moves branch. It does need a rule to keep it consistent: a payment's branch should match the branch of the visits it pays for, which a trigger could check. It is not applied here, because changing the schema would mean rebuilding the Portfolio 1 database.

## The cost of the optimisations

Indexes are not free. They use space, and every insert has to update them.

| Index | Index size | Table size |
|---|---:|---:|
| charge_payment_idx | 71 MB | 296 MB |
| payment_received_at_idx | 54 MB | 132 MB |
| diagnosis_visit_idx | 38 MB | 123 MB |
| visit_branch_checked_in_idx | 35 MB | 94 MB |
| visit_patient_checked_in_idx | 35 MB | 94 MB |
| lab_order_visit_idx | 16 MB | 38 MB |
| patient_lower_name_idx | 2.3 MB | 34 MB |

That is about 250 MB of extra storage. To measure the write cost, the benchmark inserted all 1,168,000 visits into a copy of the visit table three times:

| Indexes on the table | Insert time |
|---|---:|
| None | 1.8 s |
| Primary key only | 3.6 s |
| Primary key and the two Portfolio 2 visit indexes | 11.1 s |

The two visit indexes make bulk inserts about **three times slower**. For Tomiwa Hospitals that is a good trade: visits arrive one at a time, about 3,200 a day, and an extra fraction of a millisecond per insert is nothing next to patient records opening in 0.3 ms instead of 0.4 seconds. It would matter more for a bulk import, where indexes are usually dropped and rebuilt afterwards.

## What this showed about the optimiser

- **It is cost-based.** It used indexes when few rows were needed (Q1 to Q6) and full scans when most rows were needed: Q7, and R3, where it ignored the new visit index because checking every patient needs every visit anyway.
- **Join methods follow the row counts.** Large inputs used hash joins, and small lookups used nested loops with index scans.
- **It uses parallelism.** Baseline plans for large tables split the scan across two worker processes.
- **It rewrites queries.** `IN` and `EXISTS` subqueries were turned into the same semi join.
- **Its estimates come from statistics,** so they can be wrong for unusual rows. It expected 5 visits for Q1's patient and found 24. The statistics stay accurate because `ANALYZE` runs after every bulk change.
- **Indexes only help queries that can use them.** Q2 needed a matching condition, R1 needed a condition on the raw column, and Q6 needed an index on the same expression.
