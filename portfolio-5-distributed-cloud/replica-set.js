const wanted = ["hospital-mongo-2:27017", "hospital-mongo-3:27017"];

while (!db.hello().isWritablePrimary) {
    sleep(500);
}

const present = rs.conf().members.map((m) => m.host);
for (const host of wanted) {
    if (!present.includes(host)) {
        print(`Adding ${host} to replica set ${rs.status().set}`);
        rs.add({ host: host });
    }
}

const cfg = rs.conf();
const preferred = cfg.members.find((m) => m.host === "hospital-mongo:27017");
if (preferred.priority !== 2) {
    preferred.priority = 2;
    rs.reconfig(cfg);
    print("hospital-mongo:27017 given election priority 2, so it is preferred as primary whenever it is healthy");
}

const start = Date.now();
while (true) {
    const states = rs.status().members.map((m) => m.stateStr);
    if (states.length === 3 && states.filter((s) => s === "PRIMARY").length === 1 &&
        states.filter((s) => s === "SECONDARY").length === 2) {
        break;
    }
    if (Date.now() - start > 300000) {
        throw new Error("Members did not finish their initial sync within five minutes");
    }
    sleep(1000);
}
print(`All three members are ready after ${((Date.now() - start) / 1000).toFixed(0)} seconds of waiting`);

const status = rs.status();
const primary = status.members.find((m) => m.stateStr === "PRIMARY");
print("");
print(`Replica set ${status.set}: majority needed for writes = ${status.majorityVoteCount} of ${status.members.length} voting members`);
const priorities = Object.fromEntries(rs.conf().members.map((m) => [m.host, m.priority]));
for (const m of status.members) {
    const behind = primary.optimeDate - m.optimeDate;
    print(`  ${m.name.padEnd(24)} ${m.stateStr.padEnd(10)} priority ${priorities[m.name]}  health ${m.health}  last write applied ${m.optimeDate.toISOString()}  (${behind} ms behind the primary)`);
}

const t = db.getSiblingDB("tomiwa");
print("");
print("Visits held on each member (every member stores a full copy):");
for (const m of status.members) {
    const c = new Mongo(`mongodb://${m.name}/?directConnection=true&readPreference=secondaryPreferred`);
    print(`  ${m.name.padEnd(24)} ${c.getDB("tomiwa").visits.countDocuments({})} visits, ${c.getDB("tomiwa").patients.countDocuments({})} patients`);
}
