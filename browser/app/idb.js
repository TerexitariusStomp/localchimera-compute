// app/idb.ts — IndexedDB behind one door.
//
// A database here is a SCHEMA (name, version, and the upgrade that builds or
// migrates its stores) and a TABLE is one object store of it. Every operation
// opens the database, runs one transaction and closes; it resolves when the
// transaction COMPLETES — the moment the write is durable — and rejects on an
// error or an abort (a quota refusal arrives as an abort). Nothing is caught
// here: what a failed write means is the caller's to decide, and the callers
// (app/photo.ts, lib/keystore.js) each say.
//
// `upgrade` receives the version the device holds (0 on a first open), so a
// schema change is a new branch there and a bumped `version`.
//
// This module imports nothing and touches `indexedDB` only inside a call, so
// the worker, the REPL page and a node test can all load it.
function open(schema) {
    return new Promise((ok, no) => {
        const req = indexedDB.open(schema.name, schema.version);
        req.onupgradeneeded = (e) => schema.upgrade(req.result, e?.oldVersion ?? 0);
        req.onsuccess = () => ok(req.result);
        req.onerror = () => no(req.error);
        // another tab holds an older version open; the open stays pending until
        // that tab closes, so say so instead of waiting on it
        req.onblocked = () => no(new Error(`${schema.name}: an older version is open in another tab`));
    });
}
async function run(schema, store, mode, f) {
    const db = await open(schema);
    try {
        return await new Promise((ok, no) => {
            const t = db.transaction(store, mode);
            const result = f(t.objectStore(store));
            t.oncomplete = () => ok(result());
            t.onerror = () => no(t.error);
            t.onabort = () => no(t.error ?? new Error(`${schema.name}/${store}: the transaction was aborted`));
        });
    }
    finally {
        db.close();
    }
}
/** The object store STORE of SCHEMA. */
export function table(schema, store) {
    return {
        put: (value, key) => run(schema, store, "readwrite", s => {
            if (key === undefined)
                s.put(value);
            else
                s.put(value, key);
            return () => undefined;
        }),
        get: key => run(schema, store, "readonly", s => {
            const r = s.get(key);
            return () => r.result;
        }),
        all: () => run(schema, store, "readonly", s => {
            const r = s.getAll();
            return () => r.result;
        }),
        entries: () => run(schema, store, "readonly", s => {
            const ks = s.getAllKeys(), vs = s.getAll();
            return () => ks.result.map((k, i) => [k, vs.result[i]]);
        }),
        del: key => run(schema, store, "readwrite", s => {
            s.delete(key);
            return () => undefined;
        }),
    };
}
