db = db.getSiblingDB("tomiwa");

const now = () => (typeof performance !== "undefined" ? performance.now() : Date.now());
const wat = (d) => d ? new Date(d.getTime() + 3600e3).toISOString().slice(0, 16).replace("T", " ") : "";

function banner(text) {
    print("");
    print("#".repeat(70));
    print(text);
    print("#".repeat(70));
}

function heading(text) {
    print("");
    print("=== " + text);
}

function table(rows) {
    if (!rows.length) {
        print("(no rows)");
        return;
    }
    const cols = Object.keys(rows[0]);
    const width = cols.map((c) => Math.max(c.length, ...rows.map((r) => String(r[c] ?? "").length)));
    const fmt = (vals) => vals.map((v, i) => String(v ?? "").padEnd(width[i])).join(" | ");
    print(fmt(cols));
    print(width.map((n) => "-".repeat(n)).join("-+-"));
    rows.forEach((r) => print(fmt(cols.map((c) => r[c]))));
    print(`(${rows.length} rows)`);
}

function planStages(node) {
    const out = [];
    while (node) {
        out.push(node.stage + (node.indexName ? ` (${node.indexName})` : ""));
        node = node.inputStage || (node.inputStages ? node.inputStages[0] : null);
    }
    return out.join(" < ");
}

function explainInfo(e) {
    let qp = e.queryPlanner;
    let es = e.executionStats;
    if (!qp && e.stages) {
        qp = e.stages[0].$cursor.queryPlanner;
        es = e.stages[0].$cursor.executionStats;
    }
    const winning = qp.winningPlan.queryPlan || qp.winningPlan;
    return {
        plan: planStages(winning),
        docs_examined: es.totalDocsExamined,
        keys_examined: es.totalKeysExamined
    };
}

function medianMs(fn, runs = 5) {
    fn();
    const times = [];
    for (let i = 0; i < runs; i++) {
        const start = now();
        fn();
        times.push(now() - start);
    }
    times.sort((a, b) => a - b);
    return times[Math.floor(runs / 2)].toFixed(2);
}

function failureReasons(node, path) {
    if (!node) return [];
    if (Array.isArray(node)) return node.flatMap((n) => failureReasons(n, path));
    const out = [];
    const here = path || "document";
    if (node.missingProperties) out.push(`${here}: missing ${node.missingProperties.join(", ")}`);
    if (node.schemaRulesNotSatisfied) out.push(...failureReasons(node.schemaRulesNotSatisfied, path));
    if (node.propertiesNotSatisfied) {
        for (const p of node.propertiesNotSatisfied) {
            out.push(...failureReasons(p.details, path ? `${path}.${p.propertyName}` : p.propertyName));
        }
    }
    if (node.details && !node.propertiesNotSatisfied) {
        out.push(...failureReasons(node.details, node.itemIndex !== undefined ? `${here}[${node.itemIndex}]` : path));
    }
    if (node.reason && !node.details && !node.propertiesNotSatisfied && !node.missingProperties) {
        const value = node.consideredValue !== undefined ? ` (got ${JSON.stringify(node.consideredValue)})` : "";
        out.push(`${here}: ${node.reason}${value}`);
    }
    return out;
}

function tryInsert(label, doc) {
    try {
        db.visits.insertOne(doc);
        print(`${label}: ACCEPTED`);
        return true;
    } catch (e) {
        print(`${label}: REJECTED, ${errorName(e)} (code ${e.code})`);
        failureReasons(e.errInfo && e.errInfo.details).forEach((r) => print("    " + r));
        return false;
    }
}

const clone = (doc) => EJSON.deserialize(EJSON.serialize(doc));
const errorName = (e) => e.codeName || (e.code === 121 ? "DocumentValidationFailure" : "Error");

banner("PORTFOLIO 4: THE TOMIWA HOSPITALS DOCUMENT MODEL IN MONGODB " + db.version());

heading("What was loaded from PostgreSQL (September 2026)");
table(["visits", "patients", "branches", "drugs", "labTests", "branchStock"].map((name) => {
    const s = db.getCollection(name).aggregate([{ $collStats: { storageStats: {} } }]).toArray()[0].storageStats;
    return {
        collection: name,
        documents: s.count,
        average_document_bytes: Math.round(s.avgObjSize || 0),
        data_mb: (s.size / 1048576).toFixed(1),
        stored_mb_compressed: (s.storageSize / 1048576).toFixed(1)
    };
}));

db.visits.deleteMany({ _id: { $gte: 9000000 } });
db.visits.dropIndexes();
try { db.patients.dropIndex("name_case_insensitive"); } catch (e) { }

const top = db.visits.aggregate([
    { $group: { _id: "$patient.id", visits: { $sum: 1 } } },
    { $sort: { visits: -1, _id: 1 } },
    { $limit: 1 }
]).toArray()[0];
const pid = top._id;
const patientDoc = db.patients.findOne({ _id: pid });
const searchLast = patientDoc.lastName.toLowerCase();
const searchFirst = patientDoc.firstName.toLowerCase();
const labVisit = 1124722;
const day0 = new Date("2026-09-15T00:00:00+01:00");
const day1 = new Date("2026-09-16T00:00:00+01:00");

heading("Inputs");
table([{
    patient: `${patientDoc.hospitalNumber} (${top.visits} visits in September)`,
    name_searched: `${searchFirst} ${searchLast}`,
    lab_report_visit: labVisit,
    takings: "Ikeja, 15 Sep 2026"
}]);

const historyFilter = { "patient.id": pid };
const historyProjection = { checkedInAt: 1, "branch.name": 1, "doctor.name": 1, diagnoses: { $elemMatch: { kind: "final" } } };

const labReport = [
    { $match: { _id: labVisit } },
    { $unwind: "$labOrders" },
    { $unwind: "$labOrders.tests" },
    { $unwind: "$labOrders.tests.results" },
    { $project: {
        _id: 0,
        test: "$labOrders.tests.name",
        measurement: "$labOrders.tests.results.name",
        result: "$labOrders.tests.results.value",
        unit: "$labOrders.tests.results.unit",
        flag: { $switch: {
            branches: [
                { case: { $and: [{ $isNumber: "$labOrders.tests.results.value" },
                                 { $lt: ["$labOrders.tests.results.value", "$labOrders.tests.results.normalLow"] }] },
                  then: "LOW" },
                { case: { $and: [{ $isNumber: "$labOrders.tests.results.value" },
                                 { $gt: ["$labOrders.tests.results.value", "$labOrders.tests.results.normalHigh"] }] },
                  then: "HIGH" }
            ],
            default: "" } }
    } }
];

const takings = [
    { $match: { "branch.id": 2, checkedInAt: { $gte: day0, $lt: day1 } } },
    { $unwind: "$charges" },
    { $match: { "charges.payment.receivedAt": { $gte: day0, $lt: day1 } } },
    { $group: {
        _id: "$charges.payment.method",
        paymentIds: { $addToSet: "$charges.payment.id" },
        amount: { $sum: { $multiply: ["$charges.quantity", "$charges.unitPrice"] } }
    } },
    { $project: { _id: 0, method: "$_id", payments: { $size: "$paymentIds" }, amount: 1 } },
    { $sort: { method: 1 } }
];

const malaria = [
    { $match: { diagnoses: { $elemMatch: { kind: "final", code: "B50.9" } } } },
    { $group: { _id: "$branch.state", cases: { $sum: 1 } } },
    { $match: { cases: { $gte: 1500 } } },
    { $project: { _id: 0, state: "$_id", month: "2026-09", cases: 1 } },
    { $sort: { state: 1 } }
];

const nameFilter = { lastName: searchLast, firstName: searchFirst };
const nameCollation = { locale: "en", strength: 2 };

const anaemiaFilter = { "labOrders.tests.results": { $elemMatch: { name: "Haemoglobin", value: { $lt: 8 } } } };
const anaemiaProjection = { "patient.hospitalNumber": 1, "branch.name": 1, checkedInAt: 1 };

const queries = [
    { id: "M1", title: "Patient history",
      run: () => db.visits.find(historyFilter, historyProjection).sort({ checkedInAt: -1 }).toArray(),
      explain: () => db.visits.find(historyFilter, historyProjection).sort({ checkedInAt: -1 }).explain("executionStats") },
    { id: "M2", title: "Lab report for one visit",
      run: () => db.visits.aggregate(labReport).toArray(),
      explain: () => db.visits.explain("executionStats").aggregate(labReport) },
    { id: "M3", title: "Daily takings at Ikeja",
      run: () => db.visits.aggregate(takings).toArray(),
      explain: () => db.visits.explain("executionStats").aggregate(takings) },
    { id: "M4", title: "Confirmed malaria per state",
      run: () => db.visits.aggregate(malaria).toArray(),
      explain: () => db.visits.explain("executionStats").aggregate(malaria) },
    { id: "M5", title: "Find a patient by name",
      run: () => db.patients.find(nameFilter).collation(nameCollation).toArray(),
      explain: () => db.patients.find(nameFilter).collation(nameCollation).explain("executionStats") },
    { id: "M6", title: "Visits with haemoglobin below 8 g/dL",
      run: () => db.visits.find(anaemiaFilter, anaemiaProjection).toArray(),
      explain: () => db.visits.find(anaemiaFilter, anaemiaProjection).explain("executionStats") }
];

banner("PART 1: THE QUERIES AND THEIR RESULTS");

heading("M1: Patient history (one collection, no joins)");
table(queries[0].run().map((v) => ({
    checked_in_wat: wat(v.checkedInAt),
    branch: v.branch.name,
    doctor: v.doctor.name,
    final_diagnosis: v.diagnoses && v.diagnoses.length ? `${v.diagnoses[0].code} ${v.diagnoses[0].description}` : ""
})));

heading("M2: Lab report for visit " + labVisit + " (the high/low flag is worked out as the report is read)");
table(queries[1].run());

heading("M3: Daily takings at Ikeja on 15 September 2026");
table(queries[2].run());

heading("M4: States with at least 1,500 confirmed malaria cases in September 2026");
table(queries[3].run());

heading(`M5: Patients named "${searchFirst} ${searchLast}" (typed in lower case; the match ignores case)`);
table(queries[4].run().map((p) => ({
    hospital_number: p.hospitalNumber, first_name: p.firstName, last_name: p.lastName,
    date_of_birth: p.dateOfBirth.toISOString().slice(0, 10), phone: p.phone
})));

heading("M6: Visits in September with a haemoglobin result below 8 g/dL");
const anaemic = queries[5].run();
print(`${anaemic.length} visits. The first five:`);
table(anaemic.slice(0, 5).map((v) => ({ visit: v._id, patient: v.patient.hospitalNumber, branch: v.branch.name, checked_in_wat: wat(v.checkedInAt) })));

banner("PART 2: BEFORE INDEXING (only the automatic _id and hospitalNumber indexes exist)");
const results = queries.map((q) => ({ id: q.id, title: q.title, before: { ...explainInfo(q.explain()), ms: medianMs(q.run) } }));
table(results.map((r) => ({ id: r.id, median_ms: r.before.ms, docs_examined: r.before.docs_examined, keys_examined: r.before.keys_examined, plan: r.before.plan })));

banner("PART 3: CREATING INDEXES");
const indexStart = now();
db.visits.createIndex({ "patient.id": 1, checkedInAt: -1 }, { name: "patient_history" });
db.visits.createIndex({ "branch.id": 1, checkedInAt: 1 }, { name: "branch_day" });
db.visits.createIndex({ "diagnoses.code": 1, "diagnoses.kind": 1 }, { name: "diagnosis_code" });
db.visits.createIndex({ "labOrders.tests.results.name": 1, "labOrders.tests.results.value": 1 }, { name: "lab_result_value" });
db.patients.createIndex({ lastName: 1, firstName: 1 }, { name: "name_case_insensitive", collation: nameCollation });
print(`Five indexes built in ${((now() - indexStart) / 1000).toFixed(1)} seconds:`);
table(["visits", "patients"].flatMap((c) => db.getCollection(c).getIndexes().map((ix) => ({ ...ix, coll: c }))).map((ix) => ({
    collection: ix.coll, name: ix.name, keys: JSON.stringify(ix.key),
    collation: ix.collation ? `${ix.collation.locale}, strength ${ix.collation.strength}` : ""
})));

banner("PART 4: AFTER INDEXING");
queries.forEach((q, i) => { results[i].after = { ...explainInfo(q.explain()), ms: medianMs(q.run) }; });
table(results.map((r) => ({ id: r.id, median_ms: r.after.ms, docs_examined: r.after.docs_examined, keys_examined: r.after.keys_examined, plan: r.after.plan })));

heading("Summary (median of 5 runs)");
table(results.map((r) => ({
    id: r.id, query: r.title,
    before_ms: r.before.ms, after_ms: r.after.ms,
    docs_before: r.before.docs_examined, docs_after: r.after.docs_examined
})));

banner("PART 5: VALIDATION AND FLEXIBILITY");
const base = db.visits.findOne({ _id: labVisit });

heading("V1 to V3: documents that break the rules are rejected");
const v1 = clone(base); v1._id = 9000001; delete v1.patient;
tryInsert("V1 a visit with no patient", v1);
const v2 = clone(base); v2._id = 9000001; v2.diagnoses[0].kind = "maybe";
tryInsert("V2 a diagnosis whose kind is not provisional or final", v2);
const v3 = clone(base); v3._id = 9000001; v3.labOrders[0].tests[0].results[0].value = true;
tryInsert("V3 a lab result whose value is true/false", v3);

heading("V4: a new kind of lab test, plus a field no other visit has, needs no schema change");
const v4 = clone(base);
v4._id = 9000001;
v4.labOrders.push({
    orderId: 9000001,
    orderedAt: new Date("2026-09-30T10:00:00+01:00"),
    tests: [{
        testId: 99, name: "SARS-CoV-2 rapid antigen", sampleType: "nasal swab",
        results: [{ name: "Antigen", value: "Not detected" }, { name: "Kit lot", value: "AG-2026-114" }]
    }]
});
v4.referral = { to: "University teaching hospital", reason: "Specialist review", writtenAt: new Date("2026-09-30T11:00:00+01:00") };
tryInsert("V4 a visit with a rapid antigen test and a referral", v4);
const stored = db.visits.findOne({ _id: 9000001 }, { referral: 1, labOrders: { $slice: -1 } });
print("Stored as: " + EJSON.stringify({ referral: stored.referral, newestLabOrder: stored.labOrders[0] }, null, 0));
db.visits.deleteOne({ _id: 9000001 });

banner("PART 6: ATOMICITY");

heading("A1: one update changes two parts of a visit together, with no transaction needed");
const a1 = clone(base);
a1._id = 9000002;
a1.status = "with_nurse";
a1.vitals = a1.vitals.slice(0, 1);
db.visits.insertOne(a1);
const retake = { ...a1.vitals[0], recordedAt: new Date("2026-09-14T09:30:00+01:00"), bloodPressure: { systolic: 128, diastolic: 84 } };
const a1Result = db.visits.updateOne({ _id: 9000002 }, { $push: { vitals: retake }, $set: { status: "with_doctor" } });
const a1After = db.visits.findOne({ _id: 9000002 });
print(`updateOne matched ${a1Result.matchedCount}, modified ${a1Result.modifiedCount}: now ${a1After.vitals.length} vitals readings and status "${a1After.status}"`);
try {
    db.visits.updateOne({ _id: 9000002 }, { $push: { vitals: retake }, $set: { status: "on_lunch" } });
} catch (e) {
    print(`An update that sets status to "on_lunch" is REJECTED (${errorName(e)}), so its vitals reading is not added either:`);
}
print(`still ${db.visits.findOne({ _id: 9000002 }).vitals.length} vitals readings and status "${db.visits.findOne({ _id: 9000002 }).status}"`);
db.visits.deleteOne({ _id: 9000002 });

heading("T1: dispensing touches two documents, the visit and the stock record, so it needs a transaction");
const rxBase = db.visits.findOne({ "branch.id": 1, "prescriptions.0": { $exists: true } }, {}, { sort: { _id: 1 } });
const t1 = clone(rxBase);
t1._id = 9000003;
t1.prescriptions.forEach((p) => p.items.forEach((it) => { delete it.dispensedAt; delete it.dispensedBy; }));
db.visits.insertOne(t1);
const line1 = t1.prescriptions[0].items[0];
const stockKey = { branchId: 1, drugId: line1.drugId };
const pharmacist = { id: 27, name: "Ilorin pharmacist" };

function dispense(visitId, drugId, quantity) {
    const session = db.getMongo().startSession();
    const sdb = session.getDatabase("tomiwa");
    session.startTransaction({ readConcern: { level: "snapshot" }, writeConcern: { w: "majority" } });
    try {
        const stock = sdb.branchStock.updateOne(
            { branchId: 1, drugId: drugId, quantityInStock: { $gte: quantity } },
            { $inc: { quantityInStock: -quantity } });
        if (stock.modifiedCount !== 1) {
            session.abortTransaction();
            return "ABORTED: not enough stock, so nothing was changed";
        }
        sdb.visits.updateOne(
            { _id: visitId },
            { $set: { "prescriptions.0.items.$[line].dispensedAt": new Date("2026-09-30T12:00:00+01:00"),
                      "prescriptions.0.items.$[line].dispensedBy": pharmacist } },
            { arrayFilters: [{ "line.drugId": drugId }] });
        session.commitTransaction();
        return "COMMITTED";
    } catch (e) {
        session.abortTransaction();
        return "ABORTED: " + e.message;
    } finally {
        session.endSession();
    }
}

const dispensedState = () => (db.visits.findOne({ _id: 9000003 }).prescriptions[0].items.find((it) => it.drugId === line1.drugId).dispensedAt ? "dispensed" : "not dispensed");
const stockNow = () => db.branchStock.findOne(stockKey).quantityInStock;
const stockBefore = stockNow();
print(`${line1.drug}: Ilorin stock ${stockBefore}, prescription line ${dispensedState()}`);
print(`Dispense ${line1.quantity}: ${dispense(9000003, line1.drugId, line1.quantity)}. Stock ${stockNow()}, line ${dispensedState()}`);
db.visits.updateOne({ _id: 9000003 }, { $unset: { "prescriptions.0.items.$[line].dispensedAt": "", "prescriptions.0.items.$[line].dispensedBy": "" } }, { arrayFilters: [{ "line.drugId": line1.drugId }] });
const tooMany = stockNow() + 1000;
print(`Dispense ${tooMany}: ${dispense(9000003, line1.drugId, tooMany)}. Stock ${stockNow()}, line ${dispensedState()}`);
db.branchStock.updateOne(stockKey, { $set: { quantityInStock: stockBefore } });
db.visits.deleteOne({ _id: 9000003 });
print(`Clean-up: stock put back to ${stockNow()} and the test visit removed.`);

banner("PART 7: STORAGE AND INDEX SIZES");
table(["visits", "patients"].map((name) => {
    const s = db.getCollection(name).aggregate([{ $collStats: { storageStats: {} } }]).toArray()[0].storageStats;
    return {
        collection: name,
        documents: s.count,
        data_mb: (s.size / 1048576).toFixed(1),
        stored_mb: (s.storageSize / 1048576).toFixed(1),
        index_mb: (s.totalIndexSize / 1048576).toFixed(1),
        indexes: Object.entries(s.indexSizes).map(([k, v]) => `${k} ${(v / 1048576).toFixed(1)} MB`).join(", ")
    };
}));

print("");
print("Done.");
