# Portfolio 3: Transactions and Concurrency

Case study: **Tomiwa Hospitals** (see the [main README](../README.md)).

This portfolio shows how the Tomiwa Hospitals database keeps data correct when things go wrong, and when many staff work at once. Every demonstration runs on the real Portfolio 1 schema, with its real constraints and triggers, at the Ilorin branch.

| File | What it is |
|---|---|
| [transactions.sql](transactions.sql) | Parts 1 to 4: atomicity, isolation, double-booking, write skew and deadlock |
| [transactions-output.txt](transactions-output.txt) | The full transcript of running it |
| [durability-test.ps1](durability-test.ps1) | Part 5: crashes the database mid-transaction and checks what survives |
| [durability-output.txt](durability-output.txt) | The output of the crash test |

To reproduce them:

```powershell
docker exec hospital-postgres psql -U hospital_admin -d hospital -f /portfolio/portfolio-3-transactions-concurrency/transactions.sql
powershell -ExecutionPolicy Bypass -File portfolio-3-transactions-concurrency/durability-test.ps1
```

The first script saves the stock levels it changes and puts them back at the end, and removes every row it adds. The database is left exactly as Portfolio 1 built it.

## How the two-session demonstrations work

Concurrency problems only appear when two transactions interleave, so most demonstrations need two connections working at precise moments. **Session A** is the script itself. **Session B** is a second, fully independent connection opened through PostgreSQL's `dblink` extension, with its own server process and its own transactions. The script runs B's statements at exact points while A holds a transaction open, and can send a statement to B in the background when B is expected to wait for a lock.

To show *why* B is waiting, the script asks PostgreSQL directly, through `pg_stat_activity` and `pg_blocking_pids()`:

```
  session  | state  |     waiting_on      | blocked_by
-----------+--------+---------------------+------------
 session_b | active | Lock: transactionid | session_a
```

## ACID at a glance

The four ACID properties, and where each is demonstrated:

| Property | Meaning | Demonstrated in |
|---|---|---|
| **Atomicity** | A transaction happens completely or not at all | Part 1: dispensing, rollback, savepoints |
| **Consistency** | Every transaction leaves the data obeying its rules | 1.2 (stock can't go negative), 1.4 (role trigger), 3.3 (no double-booking) |
| **Isolation** | Concurrent transactions don't see each other's unfinished work | Parts 2 and 3 |
| **Durability** | Once committed, data survives a crash | Part 5 |

## Part 1: Atomicity

Dispensing a prescription changes two things that must stay in step: the branch's stock goes down, and each prescription line is marked as dispensed. Two demo prescriptions are used. **A** is paracetamol 18 and amoxicillin 15. **B** is paracetamol 18 and amoxicillin 48. The starting stock is 100 paracetamol and 40 amoxicillin.

| Step | What happened | Paracetamol | Amoxicillin |
|---|---|---:|---:|
| Start | | 100 | 40 |
| 1.1 COMMIT | Prescription A dispensed in one transaction | 82 | 25 |
| 1.2 ROLLBACK | Prescription B: paracetamol taken off, then amoxicillin fails the `quantity_in_stock >= 0` check | 82 | 25 |
| 1.3 SAVEPOINT | Paracetamol dispensed; amoxicillin rolled back to the savepoint; restock request raised | 64 | 25 |

**1.2** is the key result. Inside the transaction the paracetamol was already taken off, but when the amoxicillin line failed, PostgreSQL refused every following statement (*"current transaction is aborted"*). When the script then sent `COMMIT`, PostgreSQL answered **`ROLLBACK`**. The paracetamol went back to 82 and neither line was marked as dispensed. There is no half-dispensed prescription.

**1.3** shows what a pharmacy actually wants: hand over what is available and chase the rest. A `SAVEPOINT` marks a point inside the transaction. When the amoxicillin failed, `ROLLBACK TO SAVEPOINT` undid only that part, and the transaction carried on to raise a restock request (200 amoxicillin, status `pending`) and commit. The paracetamol line was dispensed; the amoxicillin line was not.

**1.4:** recording a nurse (staff 11) as the person who dispensed was stopped by the Portfolio 1 role trigger: *"prescription_item.dispensed_by must be a pharmacist, but staff member 11 is a nurse"*. A trigger error aborts the transaction like any other error.

## Part 2: Isolation

PostgreSQL uses **MVCC** (multi-version concurrency control). An update writes a new version of the row instead of overwriting it, and each transaction reads from a *snapshot*: the versions committed at a particular moment. Readers therefore never wait for writers, and writers never wait for readers. The isolation level decides when the snapshot is taken:

| Level | Snapshot taken | Prevents |
|---|---|---|
| READ COMMITTED (the default) | At the start of each statement | Dirty reads |
| REPEATABLE READ | At the transaction's first statement | Also non-repeatable reads, phantoms and lost updates |
| SERIALIZABLE | As REPEATABLE READ, plus checks for dangerous patterns between transactions | Also write skew |

PostgreSQL accepts READ UNCOMMITTED but treats it as READ COMMITTED, so dirty reads are never possible.

### 2.1: No dirty reads

A set amoxicillin to 0 without committing. B read **25**, the last committed value. A then rolled back, so if B had seen the 0 it would have acted on a value that never existed.

### 2.2 and 2.3: Non-repeatable reads

| Isolation level | A reads | B commits | A reads again |
|---|---:|---|---:|
| READ COMMITTED | 25 | A delivery of 200 | **225**: the value changed inside A's transaction |
| REPEATABLE READ | 225 | Dispenses 15 | **225**: A keeps its snapshot; the 210 appears once A's transaction ends |

### 2.4: The lost update

Two pharmacists dispense amoxicillin at the same time. Each program reads the stock, subtracts its quantity, and writes the new figure back. A dispenses 10 and B dispenses 5:

```
A read 210 and B read 210
A: UPDATE ... SET quantity_in_stock = 210 - 10      COMMIT
B: UPDATE ... SET quantity_in_stock = 210 - 5       COMMIT

 amoxicillin now | should be
-----------------+-----------
             205 |       195
```

B's write was based on a stale read and overwrote A's, so **10 tablets disappeared from the record**. Nothing failed and no error was raised, which is what makes this anomaly dangerous: the stock count simply drifts away from what is on the shelf.

### 2.5 to 2.7: Three fixes

| Fix | How it works | Result |
|---|---|---|
| **2.5 Subtract inside the UPDATE** (`SET quantity_in_stock = quantity_in_stock - 10`) | The database reads and writes the row in one step under a row lock. B's update **waited** for A, as `who_waits()` showed (*Lock: transactionid, blocked by session_a*), then applied its subtraction to A's committed result | 205 → 190, correct |
| **2.6 `SELECT ... FOR UPDATE`** | For programs that must read before writing, such as to check enough stock exists. The read takes the row lock, so B's read waited and then saw **180**, A's committed value, not a stale one | 190 → 175, correct |
| **2.7 REPEATABLE READ** | B tried to write a row A had changed since B's snapshot, so PostgreSQL refused with *"could not serialize access due to concurrent update"*. B rolled back, retried, read 165, and wrote 160 | 175 → 160, correct |

Fix 1 is the right choice for Tomiwa Hospitals' dispensing, because it is simple and never needs a retry. Fix 3 is safe too, but the program must be written to retry when it gets that error (SQLSTATE `40001`).

## Part 3: Double-booking and write skew

Two receptionists book doctor 3 at 10:00 on 20 October for different patients. Each first checks the slot is free, then books it.

| Test | What happened | Bookings for the slot |
|---|---|---:|
| **3.1** No rule in the database, READ COMMITTED | Both saw 0 bookings, both inserted, both committed | **2: double-booked** |
| **3.2** No rule, SERIALIZABLE | Both saw 0 and both inserted, but B's commit was refused: *"could not serialize access due to read/write dependencies among transactions"* | 1 |
| **3.3** The real `appointment` table | B's insert **waited** for A (*blocked by session_a*), then failed when A committed: *"duplicate key value violates unique constraint appointment_no_double_booking"* | 1 |

3.1 is a *phantom* problem. Each transaction's check looked for a row that did not exist yet, so no row lock could protect it. 3.2 and 3.3 are two different defences:

- **SERIALIZABLE** (Serializable Snapshot Isolation) watches which rows each transaction read and wrote, and cancels one transaction if together they could not have happened one after the other.
- **The unique index** from Portfolio 1 enforces the rule in the data itself, at every isolation level. Unique checks see uncommitted inserts, so B waited to find out whether A would commit, then was refused.

The index is the better defence for this rule, because it cannot be forgotten by any program that books appointments, including the patient portal.

### 3.4: Write skew, the doctors on call

Ilorin must always have at least one doctor on call overnight. Doctors 3 and 4 are both on call, and each asks to go off call at the same time. Each request checks *"at least two doctors are on call, so I can leave"* and then updates **its own row**.

| Isolation level | What happened | Doctors on call |
|---|---|---:|
| REPEATABLE READ | Both saw 2 on call. They updated different rows, so there was no conflict and both committed | **0: the rule is broken** |
| SERIALIZABLE | Both saw 2 and both updated, but B's commit was refused. B retried, saw only 1 doctor on call, and the request was refused | 1 |

This is **write skew**. Neither transaction changed anything the other changed, so row locks and REPEATABLE READ see no conflict. The damage comes from both decisions resting on a read that the other transaction made untrue. A unique index cannot express "at least one", so this rule needs SERIALIZABLE with a retry, or an explicit lock on the branch's rota before checking it.

## Part 4: Deadlock

The head of pharmacy records a delivery of both drugs, paracetamol first. At the same moment a pharmacist dispenses both, amoxicillin first.

```
A locks paracetamol          B locks amoxicillin
                             B wants paracetamol -> waits for A
A wants amoxicillin -> waits for B

ERROR:  deadlock detected
DETAIL:  Process 82 waits for ShareLock on transaction 1926; blocked by process 81.
         Process 81 waits for ShareLock on transaction 1927; blocked by process 82.
```

Each transaction was waiting for the other, so neither could ever continue. After one second (`deadlock_timeout`) PostgreSQL detected the cycle and cancelled B, rolling back its changes. A then finished: paracetamol 64 → 164 and amoxicillin 160 → 260.

**4.2, the fix:** every program updates stock rows in the same order, lowest `drug_id` first. B then waited for paracetamol behind A instead of holding amoxicillin, A finished both rows and committed, and B carried on. No deadlock: 164 → 246 paracetamol and 260 → 350 amoxicillin.

## Part 5: Durability

[durability-test.ps1](durability-test.ps1) recreates a power cut:

1. Session 1 starts a transaction, inserts a row, and waits without committing.
2. Session 2 inserts a row and commits.
3. `docker kill` stops PostgreSQL instantly, so it has no chance to shut down cleanly.
4. The container restarts and the table is read again.

| Row | Before the crash | After the crash |
|---|---|---|
| id 2, *committed just before the crash* | Visible | **Still there** |
| *inserted but never committed* | Not visible to other sessions | **Gone** |

PostgreSQL's log shows how:

```
LOG:  database system was not properly shut down; automatic recovery in progress
LOG:  redo starts at 5/5B4DF788
LOG:  redo done at 5/5B5103D8
LOG:  database system is ready to accept connections
```

Before a `COMMIT` returns, PostgreSQL writes the change to its **write-ahead log** (WAL) and forces it to disk. On restart it replays the log from the last checkpoint (*redo*). Committed work is restored, and work that never committed is treated as never having happened. This is durability and atomicity working together.

The surviving row is **id 2, not 1**, because the uncommitted transaction had already used id 1. Identity sequences never roll back, so they can leave gaps. That is expected, and is why IDs should never be used to count rows.

## Rules for Tomiwa Hospitals' application

| Situation | Approach |
|---|---|
| Changing stock | Subtract inside the `UPDATE`, never read-then-write (2.5) |
| Reading before deciding to write | `SELECT ... FOR UPDATE` (2.6) |
| A rule about one combination of values, such as no double-booking | A unique constraint in the database (3.3) |
| A rule spanning several rows, such as at least one doctor on call | SERIALIZABLE with a retry (3.4) |
| Errors `40001` (serialisation failure) and `40P01` (deadlock) | Roll back and retry the whole transaction |
| Transactions touching several rows | Lock them in a fixed order (4.2), and keep transactions short |

## Try it yourself in two terminals

For screenshots of two sessions side by side, open two PowerShell windows and run this in each:

```powershell
docker exec -it hospital-postgres psql -U hospital_admin -d hospital
```

Then, using patient ids from your own database:

| Step | Window 1 | Window 2 |
|---|---|---|
| 1 | `BEGIN;` | |
| 2 | `INSERT INTO appointment (patient_id, doctor_id, branch_id, scheduled_for, booked_via, booked_by, status) VALUES (1, 3, 1, '2026-10-21 09:00', 'reception', 19, 'booked');` | |
| 3 | | `INSERT INTO appointment (patient_id, doctor_id, branch_id, scheduled_for, booked_via, booked_by, status) VALUES (2, 3, 1, '2026-10-21 09:00', 'reception', 20, 'booked');`, which hangs, waiting |
| 4 | `COMMIT;` | The waiting insert fails with the duplicate key error |
| 5 | `DELETE FROM appointment WHERE doctor_id = 3 AND scheduled_for = '2026-10-21 09:00';` | |
