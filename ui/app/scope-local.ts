// app/scope-local.ts — a scope on the device.
//
// With no gateway in reach the page still has books to read and count: a copy
// of the scope its person is in, or the demo neighbourhood's where they are in
// none. They are a real scope, the planner's scope root, observer and
// door functions compiled for the browser (hoot/scope-worker.scm over
// module/playnet/planner/doors/page-scope.scm), held in a worker of its own
// (browser/scope-worker.js). A door asked here is answered by the code a gateway
// answers it with, so a count made offline lands as a count lands.
//
// `askScope` is the whole surface: a door's name and its arguments in, the door's
// JSON (or "err:…") out. A reply beginning UNAVAILABLE means the device could not
// run the scope (no Worker, no scope.wasm, a failed boot, no answer in time) or
// the scope takes no such door; the caller reads its recording instead
// (demo/seat.ts). Any other "err:…" is the door's own refusal.
//
// `?scope=recorded` on the page's URL keeps the scope from starting: the
// recording answers, as it does where the wasm is absent.

import { doorWorker, UNAVAILABLE } from "./rpc.js";
import { table, type Schema } from "./idb.js";
import { fault } from "./store.js";

export { UNAVAILABLE };

const recordedOnly = (): boolean => new URLSearchParams(location.search).get("scope") === "recorded";

// The scope stands on its first call, which is the long one; a door asked of a
// standing scope answers in a fraction of that.
const DEADLINE = 120_000;

const scope = doorWorker<string>({
  spawn: () => new Worker(new URL("../scope-worker.js", import.meta.url)),
  deadline: DEADLINE,
});

// The copy of a gateway's scope this device holds is kept, so the app opened
// with no gateway in reach shows the scope as it was last seen. One row: the
// copy is replaced whole each time a gateway answers a newer one.
interface Kept { scope: string; me: string; text: string }
const KEPT: Schema = {
  name: "playnet-scope",
  version: 1,
  upgrade(db) { if (!db.objectStoreNames.contains("replica")) db.createObjectStore("replica"); },
};
const kept = table<Kept>(KEPT, "replica");

let held: string | null = null;
/** The scope this device holds a copy of, or null where it holds the demo neighbourhood. */
export const replicaOf = (): string | null => held;

async function hold(k: Kept): Promise<boolean> {
  const reply = await scope("hold", [k.scope, k.me, k.text]);
  if (reply.startsWith("err:")) return false;
  held = k.scope;
  return true;
}

// the copy kept from an earlier seat, read once
let keeping: Promise<Kept | undefined> | null = null;
const keptCopy = (): Promise<Kept | undefined> => keeping ??= kept.get("held").catch(() => undefined);

/** The scope a copy is kept of on this device, or null: known before the scope itself has started. */
export const keptScope = (): Promise<string | null> => keptCopy().then(k => k?.scope ?? null);

// before the first door: a kept copy is held again; with none, the first door stands the neighbourhood
let opened: Promise<void> | null = null;
const open = (): Promise<void> => opened ??= keptCopy().then(k => (k ? hold(k) : false)).then(() => undefined);

/**
 * Hold a copy of SCOPE as its member ME from the replica TEXT a gateway answered
 * (the `scopeReplica` door), and keep it for the next start. Answers whether the
 * copy is held.
 */
export async function holdReplica(scopeId: string, me: string, text: string): Promise<boolean> {
  if (recordedOnly() || !scopeId || !text) return false;
  await open();
  const k: Kept = { scope: scopeId, me, text };
  keeping = Promise.resolve(k);
  kept.put(k, "held").catch(() => fault("idb", KEPT.name));
  return hold(k);
}

export function askScope(door: string, args: unknown[] = []): Promise<string> {
  if (recordedOnly()) return Promise.resolve(`${UNAVAILABLE}: ?scope=recorded`);
  return open().then(() => scope(door, args));
}
