// tests/browser/fakes.mjs — stand-ins for the browser's two stores, for node.
//
// node has no localStorage and no IndexedDB. The storage tests share these two
// fakes, so a test states only what it is about: a store that is full, a
// transaction that aborts, a device whose IndexedDB is gone.

/**
 * A localStorage. Stored keys are the object's own enumerable properties and
 * the accessors sit on its prototype, as on a real Storage — so
 * `Object.keys(storage)` lists the keys.
 *
 *   full     setItem throws QuotaExceededError (reads work)
 *   blocked  every access throws (private mode, storage disabled)
 */
export function memStorage({ full = false, blocked = false } = {}) {
  const deny = () => { throw new Error('denied'); };
  const proto = blocked ? { getItem: deny, setItem: deny, removeItem: deny } : {
    getItem(k) { return Object.prototype.hasOwnProperty.call(this, k) ? this[k] : null; },
    setItem(k, v) {
      if (full) throw new DOMException('quota', 'QuotaExceededError');
      this[k] = String(v);
    },
    removeItem(k) { delete this[k]; },
  };
  return Object.create(proto);
}

/**
 * An IndexedDB: databases by name, each with a version and object stores
 * (in-line keys by keyPath, or out-of-line). Writes are staged and land when
 * the transaction completes. Events fire on the microtask queue, after the
 * handlers are assigned, as the real API orders them.
 *
 * The returned object is the `indexedDB` global, plus what a test steers:
 *
 *   fate      how the next transactions end: "complete" | "abort" | "error" |
 *             "hold" (the transaction ends when the test calls settle(how))
 *   settle    ends a held transaction
 *   down      every open fails (no IndexedDB on this device)
 *   blocked   every open is blocked by another tab
 *   closed    how many databases have been closed
 *   wipe()    forget every database (the browser evicted them)
 *   rows(db, store)  the Map behind one store
 */
export function fakeIndexedDB() {
  const dbs = new Map();                         // name → { version, stores: Map }
  const idb = {
    fate: 'complete', settle: null, down: false, blocked: false, closed: 0,
    wipe() { dbs.clear(); },
    rows(name, store) { return dbs.get(name)?.stores.get(store)?.rows; },
    open(name, version = 1) {
      const req = {};
      queueMicrotask(() => {
        if (idb.down) { req.error = new Error('no IndexedDB here'); req.onerror && req.onerror(); return; }
        if (idb.blocked) { req.onblocked && req.onblocked(); return; }
        let d = dbs.get(name);
        const from = d ? d.version : 0;
        if (!d) { d = { version: 0, stores: new Map() }; dbs.set(name, d); }
        req.result = {
          objectStoreNames: { contains: (n) => d.stores.has(n) },
          createObjectStore(n, opts) { d.stores.set(n, { keyPath: opts?.keyPath, rows: new Map() }); return {}; },
          transaction(storeName) {
            const st = d.stores.get(storeName);
            const staged = new Map(st.rows);
            const t = { error: null };
            const r = (get) => ({ get result() { return get(); } });
            t.objectStore = () => ({
              put(v, k) { staged.set(k ?? v[st.keyPath], v); return r(() => undefined); },
              get(k) { return r(() => staged.get(k)); },
              getAll() { return r(() => [...staged.values()]); },
              getAllKeys() { return r(() => [...staged.keys()]); },
              delete(k) { staged.delete(k); return r(() => undefined); },
            });
            const end = (how) => {
              if (how === 'complete') { st.rows = staged; t.oncomplete && t.oncomplete(); }
              else if (how === 'abort') { t.error = new DOMException('full', 'QuotaExceededError'); t.onabort && t.onabort(); }
              else { t.error = new Error('boom'); t.onerror && t.onerror(); }
            };
            if (idb.fate === 'hold') idb.settle = end;
            else { const how = idb.fate; queueMicrotask(() => end(how)); }
            return t;
          },
          close() { idb.closed++; },
        };
        if (version > from) { d.version = version; req.onupgradeneeded && req.onupgradeneeded({ oldVersion: from }); }
        req.onsuccess && req.onsuccess();
      });
      return req;
    },
  };
  return idb;
}
