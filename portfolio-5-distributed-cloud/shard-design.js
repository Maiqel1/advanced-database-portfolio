db = db.getSiblingDB("tomiwa");

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
}

const pct = (n, total) => (100 * n / total).toFixed(1) + "%";

const zoneOf = {
    Kwara: "North Central", Kogi: "North Central", Niger: "North Central", Plateau: "North Central",
    Kaduna: "North West", Kano: "North West",
    Lagos: "South West", Oyo: "South West", Ogun: "South West", Osun: "South West", Ondo: "South West",
    Edo: "South South", Delta: "South South", Rivers: "South South",
    Enugu: "South East", Anambra: "South East"
};
const shardOf = {
    "North Central": "shard-north", "North West": "shard-north",
    "South West": "shard-southwest",
    "South South": "shard-south", "South East": "shard-south"
};

print("SHARD KEY ANALYSIS FOR THE visits COLLECTION (September 2026, 95,845 visits)");

const total = db.visits.countDocuments({});
const byBranch = db.visits.aggregate([
    { $group: { _id: { state: "$branch.state", name: "$branch.name" }, visits: { $sum: 1 } } },
    { $sort: { visits: -1 } }
]).toArray();

print("");
print("1. Visits per branch, with the zone and proposed shard each would belong to");
table(byBranch.map((b) => ({
    branch: b._id.name.replace("Tomiwa Hospitals ", ""),
    state: b._id.state,
    zone: zoneOf[b._id.state],
    shard: shardOf[zoneOf[b._id.state]],
    visits: b.visits,
    share: pct(b.visits, total)
})));

print("");
print("2. Candidate A: zone sharding on { branch.id, checkedInAt }, three shards by region");
const perShard = {};
byBranch.forEach((b) => {
    const s = shardOf[zoneOf[b._id.state]];
    perShard[s] = (perShard[s] || 0) + b.visits;
});
table(Object.entries(perShard).sort().map(([s, n]) => ({ shard: s, visits: n, share: pct(n, total) })));

print("");
print("3. Candidate B: a hashed key on patient.id, three shards");
const hashed = db.visits.aggregate([
    { $group: { _id: { $mod: [{ $abs: { $toLong: { $toHashedIndexKey: "$patient.id" } } }, 3] }, visits: { $sum: 1 } } },
    { $sort: { _id: 1 } }
]).toArray();
table(hashed.map((h) => ({ hash_bucket: h._id, visits: h.visits, share: pct(h.visits, total) })));

print("");
print("4. Candidate C: a range key on _id (visit numbers grow with time)");
const lastDay = db.visits.countDocuments({ checkedInAt: { $gte: new Date("2026-09-30T00:00:00+01:00") } });
const maxId = db.visits.find({}, { _id: 1 }).sort({ _id: -1 }).limit(1).toArray()[0]._id;
const minLastDay = db.visits.find({ checkedInAt: { $gte: new Date("2026-09-30T00:00:00+01:00") } }, { _id: 1 }).sort({ _id: 1 }).limit(1).toArray()[0]._id;
print(`The ${lastDay} visits on 30 September have _id values ${minLastDay} to ${maxId}: one unbroken range at the top.`);
print("With range sharding on _id, every new visit would land in the highest chunk, so one shard would take all the writes.");

print("");
print("5. How often a patient's September history spans more than one shard under Candidate A");
const spread = db.visits.aggregate([
    { $group: { _id: "$patient.id", states: { $addToSet: "$branch.state" } } },
    { $project: { states: 1 } }
]).toArray();
let multiZone = 0;
let multiBranch = 0;
spread.forEach((p) => {
    const shards = new Set(p.states.map((s) => shardOf[zoneOf[s]]));
    if (shards.size > 1) multiZone++;
    if (p.states.length > 1) multiBranch++;
});
table([
    { measure: "patients with a September visit", value: spread.length },
    { measure: "visited more than one branch", value: `${multiBranch} (${pct(multiBranch, spread.length)})` },
    { measure: "visited branches on more than one shard", value: `${multiZone} (${pct(multiZone, spread.length)})` }
]);
