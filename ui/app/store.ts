// app/store.ts — the device's own memory, behind one door.
//
// Everything here is `localStorage` with the try/catch put in once. That guard
// is not decoration: a browser in private mode, with storage disabled, or over
// its quota THROWS from `getItem` and `setItem` alike, and an unguarded read at
// module scope takes the whole dial down before it paints. Fifteen files were
// each writing their own version of the same four lines, and the copies had
// already drifted — some caught the write and not the read, some returned a
// default on a parse error and some let it propagate.
//
// ── WHAT LIVES HERE, AND WHAT DOES NOT ──────────────────────────────────────
// This is the raw door. app/prefs.ts sits ON it and is what most surfaces
// actually want: a preference read through a signal, so a change repaints every
// reader without anything remembering to call a draw. Reach past prefs to here
// only for what is DATA rather than a habit — the captain's log, the world
// clock's rows, the ring's own journal — where the reader is already redrawing
// for its own reasons and a signal would buy nothing.
//
// ── A WRITE THAT CANNOT LAND ────────────────────────────────────────────────
// A read that cannot land returns the default, which is where every one of
// these values starts anyway. A write that cannot land (a full store, a
// blocked one) keeps the value for as long as the tab is open and loses it at
// reload — so it says so, twice over: the call answers `false`, for the caller
// that can do something about it, and the refusal is raised as a FAULT, for
// the one place that tells the person (app/storage-notice.ts) and the
// settings readout (app/storage-health.ts). Most callers need neither and
// ignore the answer.

// The names are app/keys.ts's. Importing it here runs its migration first: a
// value kept under a former name is under its present one before any read
// below.
import "./keys.js";

/** One refusal by the device's storage. `door` names the mechanism, `what` the key or store. */
export interface Fault {
  door: "local" | "idb";
  what: string;
  /** Milliseconds since the epoch. */
  at: number;
}

const listeners = new Set<(f: Fault) => void>();

/** Hear every storage fault from here on. Returns the way to stop hearing. */
export function onFault(fn: (f: Fault) => void): () => void {
  listeners.add(fn);
  return () => { listeners.delete(fn); };
}

/** Raise a storage fault. The other storage doors (the IndexedDB callers) raise theirs here too. */
export function fault(door: Fault["door"], what: string): void {
  const f: Fault = { door, what, at: Date.now() };
  for (const fn of listeners) { try { fn(f); } catch (_) { /* a listener's failure is its own */ } }
}

/** A string, or null when there is none — and null when the store refuses. */
export const readStr = (key: string): string | null => {
  try { return localStorage.getItem(key); } catch (_) { return null; }
};

/** Remember a string. Answers whether the store took it; a refusal is also raised as a fault. */
export const writeStr = (key: string, value: string): boolean => {
  try { localStorage.setItem(key, value); return true; }
  catch (_) { fault("local", key); return false; }
};

/** Forget one key. */
export const forget = (key: string): void => {
  try { localStorage.removeItem(key); } catch (_) { /* nothing to do about it */ }
};

/**
 * The door in the shape of a Storage, for code that is handed a store and
 * calls getItem / setItem / removeItem on it: the spine's bridge and the
 * hand-written scripts under browser/lib/. Reads and writes are the guarded
 * ones above, so a refusal there raises the same fault.
 */
export const pageStore: Pick<Storage, "getItem" | "setItem" | "removeItem"> = {
  getItem: readStr,
  setItem: (key, value) => { writeStr(key, value); },
  removeItem: forget,
};

/**
 * Whatever was parked under `key`, or `fallback`.
 *
 * The cast is a claim about our own past self, and it is the only claim made:
 * a reader with an older or hand-edited store can hold ANYTHING under a key we
 * still use, so callers whose shape matters validate what comes back rather
 * than trusting it. `worldclock` dropping rows without a `tz` is the pattern —
 * one bad entry costs its own row and not the list.
 */
export function readJSON<T>(key: string, fallback: T): T {
  const raw = readStr(key);
  if (raw === null) return fallback;
  try { return (JSON.parse(raw) as T) ?? fallback; } catch (_) { return fallback; }
}

/** Park a value as JSON. Answers and faults as writeStr does. */
export const writeJSON = (key: string, value: unknown): boolean =>
  writeStr(key, JSON.stringify(value));
