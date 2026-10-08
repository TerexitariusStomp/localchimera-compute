// app/outbox-idb.ts — where the waiting acts are kept: one IndexedDB store.
//
// The acts a person made with no gateway in reach (outbox.ts) are the one thing
// the device must not lose: the copy of the scope can be asked of a gateway
// again, the acts cannot. They are kept in `playnet-outbox`, each under a key
// that grows with the order they were made in, so reading the store reads them
// oldest first.

import { table, type Schema } from "./idb.js";
import type { Box, Waiting } from "./outbox.js";

const SCHEMA: Schema = {
  name: "playnet-outbox",
  version: 1,
  upgrade(db) { if (!db.objectStoreNames.contains("acts")) db.createObjectStore("acts"); },
};

/** The device's box of waiting acts. */
export function idbBox(): Box {
  const acts = table<Waiting>(SCHEMA, "acts");
  let last = 0;
  // a key later than every key given before, on this page and on the ones before it
  const next = (): number => (last = Math.max(last + 1, Date.now() * 1000));
  const inOrder = async (): Promise<Array<[IDBValidKey, Waiting]>> =>
    (await acts.entries()).sort((a, b) => Number(a[0]) - Number(b[0]));
  return {
    add: act => acts.put(act, next()),
    all: inOrder,
    drop: key => acts.del(key),
    keep: (key, act) => acts.put(act, key),
  };
}
