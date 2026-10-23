try {
    rs.status();
} catch (e) {
    rs.initiate({ _id: "rs0", members: [{ _id: 0, host: "hospital-mongo:27017" }] });
}
while (!db.hello().isWritablePrimary) {
    sleep(500);
}
print(`Replica set ${rs.status().set} is ready; this member is ${db.hello().me}`);

db = db.getSiblingDB("tomiwa");
db.dropDatabase();

const number = { bsonType: ["int", "long", "double", "decimal"] };
const person = {
    bsonType: "object",
    required: ["id", "name"],
    properties: { id: { bsonType: ["int", "long"] }, name: { bsonType: "string" } }
};

db.createCollection("visits", {
    validator: {
        $jsonSchema: {
            bsonType: "object",
            required: ["_id", "patient", "branch", "doctor", "checkedInAt", "status", "payer",
                       "vitals", "notes", "diagnoses", "labOrders", "prescriptions", "charges"],
            properties: {
                _id: { bsonType: ["int", "long"] },
                patient: {
                    bsonType: "object",
                    required: ["id", "hospitalNumber", "name"],
                    properties: {
                        id: { bsonType: ["int", "long"] },
                        hospitalNumber: { bsonType: "string", pattern: "^TH-" },
                        name: { bsonType: "string" }
                    }
                },
                branch: {
                    bsonType: "object",
                    required: ["id", "name", "state"],
                    properties: { id: { bsonType: ["int", "long"] } }
                },
                doctor: person,
                checkedInAt: { bsonType: "date" },
                status: { enum: ["checked_in", "with_nurse", "with_doctor", "at_lab", "at_pharmacy", "completed"] },
                payer: {
                    bsonType: "object",
                    required: ["type"],
                    properties: { type: { enum: ["cash", "insurance"] } }
                },
                vitals: {
                    bsonType: "array",
                    items: {
                        bsonType: "object",
                        required: ["recordedAt", "recordedBy"],
                        properties: {
                            recordedAt: { bsonType: "date" },
                            recordedBy: person,
                            temperatureC: { bsonType: number.bsonType, minimum: 30, maximum: 45 },
                            pulseBpm: { bsonType: number.bsonType, minimum: 20, maximum: 250 }
                        }
                    }
                },
                notes: { bsonType: "array", items: { bsonType: "object", required: ["writtenAt"] } },
                diagnoses: {
                    bsonType: "array",
                    items: {
                        bsonType: "object",
                        required: ["kind", "code", "madeAt"],
                        properties: {
                            kind: { enum: ["provisional", "final"] },
                            code: { bsonType: "string" },
                            madeAt: { bsonType: "date" }
                        }
                    }
                },
                labOrders: {
                    bsonType: "array",
                    items: {
                        bsonType: "object",
                        required: ["orderedAt", "tests"],
                        properties: {
                            tests: {
                                bsonType: "array",
                                minItems: 1,
                                items: {
                                    bsonType: "object",
                                    required: ["name", "results"],
                                    properties: {
                                        results: {
                                            bsonType: "array",
                                            items: {
                                                bsonType: "object",
                                                required: ["name", "value"],
                                                properties: {
                                                    name: { bsonType: "string" },
                                                    value: { bsonType: ["int", "long", "double", "decimal", "string"] }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                },
                prescriptions: {
                    bsonType: "array",
                    items: {
                        bsonType: "object",
                        required: ["prescribedAt", "items"],
                        properties: {
                            items: {
                                bsonType: "array",
                                minItems: 1,
                                items: {
                                    bsonType: "object",
                                    required: ["drugId", "dose", "quantity"],
                                    properties: { quantity: { bsonType: ["int", "long"], minimum: 1 } }
                                }
                            }
                        }
                    }
                },
                charges: {
                    bsonType: "array",
                    items: {
                        bsonType: "object",
                        required: ["type", "quantity", "unitPrice"],
                        properties: {
                            type: { enum: ["consultation", "lab_test", "drug"] },
                            quantity: { bsonType: ["int", "long"], minimum: 1 },
                            unitPrice: { bsonType: number.bsonType, minimum: 0 }
                        }
                    }
                }
            }
        }
    },
    validationLevel: "strict",
    validationAction: "error"
});

db.createCollection("patients", {
    validator: {
        $jsonSchema: {
            bsonType: "object",
            required: ["_id", "hospitalNumber", "firstName", "lastName", "dateOfBirth", "sex",
                       "registeredBranch", "registeredAt", "insurance"],
            properties: {
                hospitalNumber: { bsonType: "string", pattern: "^TH-" },
                dateOfBirth: { bsonType: "date" },
                sex: { enum: ["F", "M"] },
                registeredAt: { bsonType: "date" },
                insurance: {
                    bsonType: "array",
                    items: {
                        bsonType: "object",
                        required: ["insurer", "policyNumber", "validFrom", "validTo"],
                        properties: { validFrom: { bsonType: "date" }, validTo: { bsonType: "date" } }
                    }
                }
            }
        }
    }
});

db.createCollection("branchStock", {
    validator: {
        $jsonSchema: {
            bsonType: "object",
            required: ["branchId", "drugId", "quantityInStock", "reorderLevel"],
            properties: {
                quantityInStock: { bsonType: ["int", "long"], minimum: 0 },
                reorderLevel: { bsonType: ["int", "long"], minimum: 0 }
            }
        }
    }
});

db.createCollection("branches");
db.createCollection("drugs");
db.createCollection("labTests");

db.patients.createIndex({ hospitalNumber: 1 }, { unique: true });
db.branchStock.createIndex({ branchId: 1, drugId: 1 }, { unique: true });

print("Collections created: " + db.getCollectionNames().sort().join(", "));
