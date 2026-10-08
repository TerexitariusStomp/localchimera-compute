// app/queue.ts — photographs waiting to be read.
//
// A walk through the store shoots each shelf and reads them afterwards: with no
// seat, with the week's reads spent, or simply later. The pictures stay in the
// evidence store (photo.ts) under their hashes; this keeps what the walk knew of
// each scene, so it can be read as it was taken: when, where, which container,
// which planned count. A count lands only when a person confirms a row, so a
// read deferred is safe. The entries are kept on this device (store.ts, the one
// localStorage door), newest last, a few dozen at most.

import { readJSON, writeJSON } from "./store.js";
import { signal } from "./reactive.js";
import { K } from "./keys.js";

/** The planned count a scene is a count of. */
export interface QueuedPlan {
  fulfills: string;
  blind: boolean;
}

/** One scene waiting to be read. */
export interface Queued {
  id: string;
  /** The instant the first shot was taken, ISO. */
  at: string;
  /** The hashes of the shots, in the order they were taken. */
  shots: string[];
  /** The place the scene was in, by id; empty when none was known. */
  place: string;
  /** The container in view, by id; empty when none. */
  container: string;
  plan?: QueuedPlan;
  /** What the scene was, in words: the container's name, or the place's. */
  label: string;
}

const KEY = K.photoQueue;
/** How many scenes wait at most; the oldest give way. */
export const QUEUE_MAX = 24;

/** The scenes waiting, oldest first. */
export const listQueued = (): Queued[] => readJSON<Queued[]>(KEY, []).filter(e => e && typeof e.id === "string" && Array.isArray(e.shots));

/** How many scenes wait; a face that shows it redraws as it changes. */
export const waiting = signal(listQueued().length);
const keep = (all: Queued[]): void => { writeJSON(KEY, all); waiting.set(all.length); };

/** Put a scene in the queue; the entry as kept. */
export function enqueue(scene: Omit<Queued, "id">, now = Date.now()): Queued {
  const entry: Queued = { ...scene, id: `q-${now.toString(36)}-${Math.random().toString(36).slice(2, 6)}` };
  keep([...listQueued(), entry].slice(-QUEUE_MAX));
  return entry;
}

/** Take a scene out of the queue. */
export function dequeue(id: string): void {
  keep(listQueued().filter(e => e.id !== id));
}

/** The hashes of every shot waiting, for the sweep to spare. */
export const queuedHashes = (): Set<string> => new Set(listQueued().flatMap(e => e.shots));

/**
 * Let go of the scenes whose pictures this device no longer holds (HAS says
 * whether it holds one) and the shots of a scene that are gone; the scenes
 * that keep at least one shot stay. Returns how many scenes went.
 */
export async function pruneQueued(has: (hash: string) => Promise<boolean>): Promise<number> {
  const all = listQueued();
  const kept: Queued[] = [];
  for (const e of all) {
    const here: string[] = [];
    for (const h of e.shots) if (await has(h)) here.push(h);
    if (here.length) kept.push({ ...e, shots: here });
  }
  if (kept.length !== all.length || kept.some((e, i) => e.shots.length !== all[i].shots.length)) keep(kept);
  return all.length - kept.length;
}

/** A scene in a line: what, how many photographs, and when they were taken. */
export function queuedLine(e: Queued): string {
  const d = new Date(e.at);
  const when = Number.isNaN(d.getTime()) ? "" : ` · ${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  return `${e.label || "a scene"} · ${e.shots.length} photo${e.shots.length === 1 ? "" : "s"}${when}`;
}
