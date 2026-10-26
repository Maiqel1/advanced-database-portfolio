const HOSTS = "hospital-mongo:27017,hospital-mongo-2:27017,hospital-mongo-3:27017";
const env = process.env;
const now = () => Date.now();
const secs = (ms) => (ms / 1000).toFixed(1);
const firstLine = (s) => String(s).split("\n")[0].slice(0, 150);

function direct(host, timeoutMs = 3000) {
    return new Mongo(`mongodb://${host}/?directConnection=true&readPreference=primaryPreferred` +
                     `&serverSelectionTimeoutMS=${timeoutMs}&connectTimeoutMS=${timeoutMs}`);
}

function cluster(timeoutMs = 30000) {
    return new Mongo(`mongodb://${HOSTS}/?replicaSet=rs0&serverSelectionTimeoutMS=${timeoutMs}`);
}

const test = (conn) => conn.getDB("tomiwa").replication_test;
const localStatus = () => direct("localhost:27017").getDB("admin").runCommand({ replSetGetStatus: 1 });
const self = () => localStatus().members.find((m) => m.self);

function primaryName() {
    const p = localStatus().members.find((m) => m.stateStr === "PRIMARY");
    return p ? p.name : null;
}

function printStatus() {
    const st = localStatus();
    print(`Members as seen from ${st.members.find((m) => m.self).name}:`);
    for (const m of st.members) {
        print(`  ${m.name.padEnd(24)} ${m.health === 0 ? "(not reachable)" : m.stateStr}`);
    }
}

function ids(conn) {
    return test(conn).find({}, { _id: 1 }).sort({ _id: 1 }).toArray().map((d) => d._id).join(", ");
}

function waitForPrimary(notThis, limitMs = 90000) {
    const start = now();
    while (now() - start < limitMs) {
        let p = null;
        try { p = primaryName(); } catch (e) { }
        if (p && p !== notThis) return { name: p, ms: now() - start };
        sleep(200);
    }
    throw new Error("No primary appeared");
}

const steps = {
    primary() {
        print((primaryName() || "none").split(":")[0]);
    },

    status() {
        printStatus();
    },

    replication() {
        const coll = test(cluster());
        coll.drop();
        coll.insertOne({ _id: "warm-up" }, { writeConcern: { w: 3 } });
        print("How long a write takes to be acknowledged (median of 5 inserts):");
        const meaning = { 1: "the primary alone", majority: "the primary and one secondary", 3: "all three members" };
        for (const w of [1, "majority", 3]) {
            const times = [];
            for (let i = 0; i < 5; i++) {
                const t = performance.now();
                coll.insertOne({ writeConcern: String(w), n: i }, { writeConcern: { w: w } });
                times.push(performance.now() - t);
            }
            times.sort((a, b) => a - b);
            print(`  w: ${String(w).padEnd(9)} ${times[2].toFixed(2).padStart(6)} ms   confirmed by ${meaning[w]}`);
        }
        coll.deleteMany({ writeConcern: { $exists: true } }, { writeConcern: { w: 3 } });
        const secondaries = localStatus().members.filter((m) => m.stateStr === "SECONDARY").map((m) => m.name);
        print("");
        print("How long a w: 1 write takes to appear on each secondary:");
        const t0 = performance.now();
        coll.insertOne({ _id: "lag-probe" }, { writeConcern: { w: 1 } });
        for (const s of secondaries) {
            const sc = test(direct(s));
            while (!sc.findOne({ _id: "lag-probe" })) sleep(1);
            print(`  ${s.padEnd(24)} after ${(performance.now() - t0).toFixed(1)} ms`);
        }
    },

    staleread() {
        const coll = test(cluster());
        const st = localStatus();
        const primary = st.members.find((m) => m.stateStr === "PRIMARY").name;
        const [frozen, other] = st.members.filter((m) => m.stateStr === "SECONDARY").map((m) => m.name);
        const read = (host) => test(direct(host)).findOne({ _id: "ilorin-amoxicillin" }).quantityInStock;
        coll.replaceOne({ _id: "ilorin-amoxicillin" },
                        { _id: "ilorin-amoxicillin", branch: "Ilorin", drug: "Amoxicillin 500 mg capsule", quantityInStock: 638 },
                        { upsert: true, writeConcern: { w: 3 } });
        print(`Ilorin's amoxicillin stock is 638 on every member.`);
        direct(frozen).getDB("admin").runCommand({ fsync: 1, lock: true });
        print(`${frozen} is frozen with fsyncLock, so it stops applying new writes (as if its link were slow).`);
        coll.updateOne({ _id: "ilorin-amoxicillin" }, { $inc: { quantityInStock: -15 } }, { writeConcern: { w: "majority" } });
        print(`A pharmacist dispenses 15. The update is confirmed by a majority (the primary and ${other}).`);
        print(`  Read from the primary ${primary.padEnd(24)} ${read(primary)}`);
        print(`  Read from the secondary ${other.padEnd(22)} ${read(other)}`);
        print(`  Read from the frozen secondary ${frozen.padEnd(15)} ${read(frozen)}   <- out of date`);
        direct(frozen).getDB("admin").runCommand({ fsyncUnlock: 1 });
        sleep(1000);
        print(`After unfreezing, ${frozen} catches up and reads ${read(frozen)}.`);
    },

    waitprimary() {
        const found = waitForPrimary(env.OLD || null);
        print(`New primary: ${found.name}, found ${secs(found.ms)} s after this check started`);
        const t = performance.now();
        test(cluster()).insertOne({ _id: env.LABEL || "written-after-failover", at: new Date() }, { writeConcern: { w: "majority" } });
        print(`A w: majority write through the normal replica set connection succeeded in ${(performance.now() - t).toFixed(0)} ms`);
        printStatus();
    },

    stepdown() {
        const start = now();
        while (self().stateStr === "PRIMARY") {
            if (now() - start > 60000) throw new Error("did not step down");
            sleep(250);
        }
        print(`${self().name} stepped down to ${self().stateStr} ${secs(now() - start)} s after this check started: it can no longer reach a majority.`);
        try {
            test(cluster(5000)).insertOne({ _id: "no-majority" }, { writeConcern: { w: 1 } });
            print("A write succeeded (not expected)");
        } catch (e) {
            print(`A write is REFUSED (${e.name}): no member is primary, so nothing can accept it`);
        }
        const doc = test(direct("localhost:27017")).findOne({ _id: "ilorin-amoxicillin" });
        print(`A read from this member still works: amoxicillin stock ${doc.quantityInStock} (possibly out of date, since nothing can be confirmed)`);
        printStatus();
    },

    partitionold() {
        const local = test(direct("localhost:27017"));
        print(`${self().name} is cut off from the other two members, but still believes it is ${self().stateStr}.`);
        local.insertOne({ _id: "w1-during-partition", note: "confirmed by the isolated primary alone" }, { writeConcern: { w: 1 } });
        print("Insert with w: 1        -> ACKNOWLEDGED (only this member has it)");
        try {
            local.insertOne({ _id: "majority-during-partition", note: "asked for a majority" },
                            { writeConcern: { w: "majority", wtimeout: 5000 } });
            print("Insert with w: majority -> acknowledged (not expected)");
        } catch (e) {
            print("Insert with w: majority -> NOT acknowledged within 5 s: " + firstLine(e.message));
        }
        const start = now();
        while (self().stateStr === "PRIMARY" && now() - start < 60000) sleep(250);
        print(`${self().name} stepped down to ${self().stateStr} ${secs(now() - start)} s later.`);
        print("Documents on the isolated member: " + ids(direct("localhost:27017")));
    },

    partitionmajority() {
        const found = waitForPrimary(env.OLD);
        print(`On the majority side, ${found.name} is the new primary.`);
        test(cluster()).insertOne({ _id: "written-to-new-primary", note: "confirmed by a majority" }, { writeConcern: { w: "majority" } });
        print("Insert with w: majority -> ACKNOWLEDGED by the new primary and the other member");
        print("Documents on the majority side: " + ids(cluster()));
    },

    partitionheal() {
        const start = now();
        let state = "";
        while (now() - start < 120000) {
            const st = localStatus();
            state = st.members.find((m) => m.self).stateStr;
            const primary = st.members.find((m) => m.stateStr === "PRIMARY");
            if ((state === "SECONDARY" || state === "PRIMARY") && primary) break;
            sleep(500);
        }
        print(`${self().name} rejoined and is now ${state}, ${secs(now() - start)} s after the network came back.`);
        sleep(3000);
        print("Documents on this member now: " + ids(direct("localhost:27017")));
        print("Documents on the primary:     " + ids(cluster()));
        printStatus();
    },

    cleanup() {
        test(cluster()).drop({ writeConcern: { w: "majority" } });
        print("Test collection removed.");
        printStatus();
    }
};

if (!steps[env.STEP]) {
    throw new Error("Unknown step: " + env.STEP);
}
steps[env.STEP]();
