# Portfolio 5: Distributed and Cloud Databases

Case study: **Tomiwa Hospitals** (see the [main README](../README.md)).

Tomiwa Hospitals runs 16 branches across Nigeria, and a database on one server is a single point of failure: if that server stops, every branch stops. This portfolio turns the Portfolio 4 MongoDB database into a **three-member replica set**, tests what happens when members crash or lose their network, designs how the data would be **sharded** across regions, demonstrates a **two-phase commit** between two branch databases, and sets out how the system would be deployed in the cloud under Nigeria's data protection law.

| File | What it is |
|---|---|
| [replica-set.js](replica-set.js) and [its output](replica-set-output.txt) | Adds two members to the replica set and reports its state |
| [failover-test.ps1](failover-test.ps1) and [steps.js](steps.js) | Replication, stale reads, crashes, loss of majority and a network partition |
| [failover-output.txt](failover-output.txt) | The output of the failover tests |
| [shard-design.js](shard-design.js) and [its output](shard-design-output.txt) | Measures how the visits would spread under three possible shard keys |
| [two-phase-commit.ps1](two-phase-commit.ps1) and [its output](two-phase-commit-output.txt) | An inter-branch stock transfer committed across two databases |

To reproduce them:

```powershell
docker compose up -d
docker exec hospital-mongo mongosh --quiet --file /portfolio/portfolio-5-distributed-cloud/replica-set.js
powershell -ExecutionPolicy Bypass -File portfolio-5-distributed-cloud/failover-test.ps1
docker exec hospital-mongo mongosh --quiet --file /portfolio/portfolio-5-distributed-cloud/shard-design.js
powershell -ExecutionPolicy Bypass -File portfolio-5-distributed-cloud/two-phase-commit.ps1
```

## The replica set

A replica set is a group of MongoDB servers that each hold a full copy of the data. One member, the **primary**, accepts all writes. It records each change in its operation log (the *oplog*), and the **secondaries** copy and replay that log continuously.

| Member | Role | Election priority | Visits held |
|---|---|---:|---:|
| `hospital-mongo` | Primary | 2 | 95,845 |
| `hospital-mongo-2` | Secondary | 1 | 95,845 |
| `hospital-mongo-3` | Secondary | 1 | 95,845 |

The two new members copy the full data set when they join (*initial sync*), then keep up from the oplog. A write needs a **majority, 2 of the 3 members**, to be safe, and an election needs a majority of votes. `hospital-mongo` has a higher priority, standing in for the Ilorin head office's server, so it is preferred as primary whenever it is healthy. Each member runs in its own Docker container with its own storage, and its memory cache is limited to 0.5 GB so all three fit on one machine.

## Part 1: Replication

| Write concern | What must confirm the write | Time to confirm |
|---|---|---:|
| `w: 1` | The primary alone | 5.38 ms |
| `w: "majority"` | The primary and one secondary | 12.76 ms |
| `w: 3` | All three members | 8.47 ms |

A `w: 1` write appeared on the two secondaries **34.8 ms** and **60.3 ms** later. Here all three members share one machine, so the differences are small and partly noise. Across real sites in Lagos and Ilorin, `w: "majority"` would add at least one network round trip between cities to every write. That is the price of knowing the write is safe.

## Part 2: A secondary can return an out-of-date answer

Reading from a secondary spreads the load, but a secondary can be behind. To show this, one secondary was frozen with `fsyncLock`, so it stopped applying new writes, as if its link to the primary were slow:

| Read from | Ilorin amoxicillin stock after 15 were dispensed |
|---|---:|
| The primary | 623 |
| The other secondary | 623 |
| The frozen secondary | **638**, out of date |
| The frozen secondary, once unfrozen | 623 |

This is **eventual consistency**: every copy ends up the same, but not at every moment. A pharmacist checking stock against the frozen copy would see 15 capsules that are no longer on the shelf.

## Part 3: Automatic failover

The primary was killed with `docker kill`, which stops it instantly, as a crash or power cut would.

| Event | Time |
|---|---|
| The two survivors stopped hearing from the primary and held an election | `hospital-mongo-2` became primary 8.5 s after checking began |
| The first write through the normal connection succeeded | **14.0 s after the kill** |
| The old primary was restarted | It rejoined, caught up, and took back the primary role because of its higher priority |

The application did not need reconfiguring. Its connection string lists all three members (`replicaSet=rs0`), so the driver found the new primary on its own. For about 14 seconds no writes were possible, which is the time needed to be sure the primary is really gone rather than slow. The surviving members could still answer reads in that time, as Part 4 shows a secondary doing.

## Part 4: Losing the majority

Both secondaries were stopped, leaving the primary alone.

- **8.6 s** later the primary **stepped down to secondary by itself**, because it could no longer reach a majority.
- A write was **refused**: *"no member is primary, so nothing can accept it"*.
- A read from the remaining member **still worked**, returning the stock level of 623, but nothing could confirm it was current.
- When the secondaries returned, `hospital-mongo` was primary again within 0.2 s, and writes resumed.

A lone member refuses writes because it cannot tell "the others have crashed" apart from "I am cut off and they have elected a new primary". If it accepted writes, two primaries could take conflicting writes, the *split-brain* problem.

## Part 5: A network partition, and why w: majority matters

`hospital-mongo`, the primary, was disconnected from the network. For a few seconds it could not know whether it was the one cut off, so it still believed it was primary.

| Step | What happened |
|---|---|
| Insert with `w: 1` on the isolated primary | **Acknowledged**: only that member had it |
| Insert with `w: "majority"` on the isolated primary | **Not acknowledged** after 5 s: *"waiting for replication timed out"* |
| 2.9 s later | The isolated member stepped down to secondary |
| On the other side | `hospital-mongo-2` and `hospital-mongo-3` elected `hospital-mongo-2` as primary, which accepted a `w: "majority"` write |
| The network was reconnected | `hospital-mongo` rejoined as a secondary within 0.3 s |
| Afterwards | **Both writes made during the partition had disappeared from every member** |

MongoDB had **rolled them back**. The rejoining member found that its history disagreed with the new primary's, undid its own unconfirmed writes, and saved them to a rollback file:

```
/data/db/rollback/a18f9947-0469-44ac-ba35-e62acf9592af/removed.2026-10-24T00-03-13.0.bson
  {"_id":"w1-during-partition","note":"confirmed by the isolated primary alone"}
  {"_id":"majority-during-partition","note":"asked for a majority"}
```

This is the most important result in the portfolio. **A `w: 1` write was acknowledged, and later lost.** If that write had been a prescription or a payment, the application would have told staff it was saved. The `w: "majority"` write was lost too, but it was never acknowledged: the application was told it had *not* been confirmed, so it could retry or warn the user. **Only majority-acknowledged writes are guaranteed to survive a failover.** Tomiwa Hospitals must use `w: "majority"` for anything clinical or financial.

## Consistency and availability: what this showed

The CAP theorem says that when the network splits (a *partition*), a distributed database must choose between **consistency** (every read sees the latest write) and **availability** (every request gets an answer).

| Situation | What the replica set chose | Shown in |
|---|---|---|
| Writes during a partition or after losing the majority | **Consistency**: the minority side refuses writes rather than risk conflicting data | Parts 4 and 5 |
| Reads from secondaries | **Availability**: answers keep coming, even if out of date | Parts 2 and 4 |
| Normal running | A trade between **latency and consistency**: `w: "majority"` costs a round trip but is safe | Part 1 |

MongoDB lets each operation choose its own balance:

| Tomiwa Hospitals operation | Write concern | Where to read from |
|---|---|---|
| Diagnoses, prescriptions, dispensing, payments | `w: "majority"` | The primary |
| A doctor reviewing a patient's record | | The primary, or `readConcern: "majority"`, to see only confirmed data |
| The patient portal's history page | | The nearest member: a few seconds out of date is acceptable |
| Monthly reports (such as Portfolio 2's malaria report) | | Secondaries, to keep load off the primary |
| Anything that must not be lost | Never `w: 1` | |

## Sharding: splitting the data across regions

Replication copies **all** the data to every member. **Sharding** splits the data into parts (*shards*), each held by its own replica set, so that no single server holds or serves everything. A **shard key** decides which shard each document lives on. [shard-design.js](shard-design.js) measured three candidate keys on the 95,845 September visits, using three shards.

**Candidate A: zone sharding on `{ branch.id, checkedInAt }`.** Branches are grouped by Nigeria's geopolitical zones, and each group is pinned to a shard in that region:

| Shard | Zones | Branches | Visits | Share |
|---|---|---|---:|---:|
| shard-north | North Central, North West | Ilorin, Kano, Kaduna, Jos, Lokoja, Minna | 34,508 | 36.0% |
| shard-southwest | South West | Ikeja, Ibadan, Abeokuta, Akure, Osogbo | 32,116 | 33.5% |
| shard-south | South South, South East | Port Harcourt, Benin City, Enugu, Asaba, Awka | 29,221 | 30.5% |

**Candidate B: a hashed key on `patient.id`.** The shares were 33.4%, 33.3% and 33.3%, an almost perfectly even spread, with no regard for where the visits happened.

**Candidate C: a range key on `_id`.** Visit numbers grow with time: the 3,204 visits on 30 September are numbers 1,164,797 to 1,168,000, one unbroken range at the top. Under range sharding, every new visit would go to the shard holding the highest range, so **one shard would take all the writes**. This key is rejected.

How the main queries would be routed:

| Query | A: branch and zone | B: hashed patient |
|---|---|---|
| A branch's daily work: takings, attendance, the doctor's day list | **One shard** | Every shard |
| New visits being written | Spread across 16 branches and 3 regions | Spread evenly |
| One patient's history | Every shard, in parallel | **One shard** |
| National reports, such as malaria by state | Every shard, in parallel | Every shard, in parallel |
| Data stays in its own region | **Yes** | No |

**Recommendation: Candidate A.** Almost all of the hospital's traffic is branch-local: each branch's reception, nurses, doctors, lab and pharmacy work on that branch's visits. Zone sharding sends that traffic to one shard close to the branch, and the three shards are balanced to within 6 percentage points. Its weakness is the patient history, which has to ask every shard. The data shows that costs little: only **2,457 of 81,832 patients (3.0%)** visited branches on more than one shard in September, and asking three shards at once is quick. The `patients` collection, which is looked up by patient rather than branch, would be sharded separately on a hashed `_id`.

The deployment would have three shards, each a three-member replica set, plus a small *config server* replica set that records which data lives where, and *mongos* routers that send each query to the right shards. Data is never stored in a single place.

## Part 6: Two-phase commit between two branches

Ilorin is running low on amoxicillin and Ikeja has plenty, so Ikeja sends some. If each branch had its own database, the transfer would have to change **both**. Ikeja's stock goes down and Ilorin's goes up, and either both changes happen or neither does. **Two-phase commit** (2PC) achieves this:

1. **Prepare:** a coordinator asks each site to do its part and vote. A site that votes yes writes its changes durably and promises it can commit (`PREPARE TRANSACTION`).
2. **Commit:** only if every site voted yes does the coordinator tell them all to commit (`COMMIT PREPARED`). If any voted no, it tells the rest to undo (`ROLLBACK PREPARED`).

[two-phase-commit.ps1](two-phase-commit.ps1) gives each branch its own PostgreSQL database with its own stock table.

| Case | What happened | Ikeja | Ilorin |
|---|---|---:|---:|
| Start | | 900 | 40 |
| 1. Transfer 300 | Both sites prepared and voted yes, then both committed | 600 | 340 |
| 2. Transfer 700, but Ikeja holds 600 | Ilorin prepared, but Ikeja's update broke its `quantity >= 0` rule, so it voted no. The coordinator rolled back Ilorin's prepared part | 600 | 340 |
| 3. Transfer 100, with a crash | Both sites prepared, then PostgreSQL was killed before the decision. **After the restart, both prepared transactions were still waiting**, and they still held their locks: an attempt to dispense amoxicillin at Ikeja timed out. The coordinator then completed the commit | 500 | 440 |

The total of 940 capsules is the same after every case: none was ever lost or invented.

**Case 3 shows 2PC's main weakness: it can block.** After voting yes, a site cannot decide alone. It has promised to commit if told to, so it must keep its locks until the coordinator returns. While Ikeja waited for a decision, its pharmacy could not dispense amoxicillin at all. This is why many systems avoid distributed transactions for everyday work. A common alternative for a stock transfer is a **saga**: Ikeja first records the 100 capsules as dispatched, and Ilorin later records them as received. Each step is a normal local transaction, and a failed step is corrected by a compensating step, for example returning the stock to Ikeja.

Two smaller findings:

- **Prepared transaction names are unique across a whole PostgreSQL server, not per database.** Because both branch databases share one server here, each site needs its own name (`transfer-1-ikeja`, `transfer-1-ilorin`). On separate servers they could share one, but a unique name per participant is good practice anyway.
- **The coordinator must never commit without every vote.** An early version of the script carried on after one site's prepare failed, and committed the other. Ikeja lost 300 capsules that Ilorin never received: exactly the inconsistency 2PC exists to prevent.

MongoDB itself uses two-phase commit internally for transactions that span more than one shard.

## Cloud deployment

### Deployment models

| Model | What it would mean for Tomiwa Hospitals | Main concern |
|---|---|---|
| **Private** (own data centre) | Servers in the Ilorin head office and a second Tomiwa site | The hospital must staff, power and protect them itself |
| **Public cloud** (managed service) | A managed MongoDB service, and managed PostgreSQL, run by a cloud provider | Where the data physically lives, and whether that is lawful |
| **Hybrid** | Identifiable patient data kept in Nigerian data centres; anonymised data sent to the public cloud for reporting and analytics | More moving parts, but meets the law and the business needs |

**Recommendation: hybrid.** Run the clinical and billing databases in Nigerian data centres, either Tomiwa's own or a local colocation or cloud provider. Use public cloud services for analytics on anonymised data.

### The Nigeria Data Protection Act 2023

Health records are sensitive personal data. Under the NDPA 2023 and the Nigeria Data Protection Commission (NDPC) that enforces it:

| Requirement | How the design meets it |
|---|---|
| Personal data may only leave Nigeria with adequate protection in the receiving country, or another lawful basis such as the patient's consent or approved safeguards | Zone sharding keeps every shard in Nigeria. Only anonymised data goes to the public cloud |
| Appropriate technical and organisational security measures | Encryption in transit (TLS) and at rest, authentication, role-based access, and audit logs. See the next table |
| Breaches must be reported to the NDPC | Monitoring and audit logs, so a breach can be detected and its scope measured |
| Collect and keep only what is needed | The MongoDB copy already leaves out password hashes (Portfolio 4) |

### What this demonstration leaves out

The demonstration runs on one laptop, so it shows how the software behaves when one member fails, not how the hardware would. A production deployment would also need:

| Area | This demonstration | Production |
|---|---|---|
| Placement | All members on one machine | Each member in a different building or region, so one fire or power cut cannot stop a majority |
| Authentication | None; reachable only from this machine | User accounts with passwords, and key files or certificates between members |
| Encryption | None | TLS between all servers and clients, and encrypted disks |
| Backups | None | Regular backups with point-in-time recovery, tested by restoring them |
| Monitoring | Manual checks | Alerts on replication lag, elections and disk space |
