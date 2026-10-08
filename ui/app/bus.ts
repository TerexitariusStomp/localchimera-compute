// app/bus.ts — the app's own wires: one topic, many readers.
//
// Two kinds of traffic ran over the seam that never crossed a language
// boundary: a push from the spine that more than one face wanted (grants,
// chat, the slot pool), and a module telling another that something it owns
// changed (the plan landed, the recipes reloaded, stock moved). Both are one
// wire with more than one reader, and both are TypeScript talking to
// TypeScript. This module carries them; the seam carries only what the spine
// and the app actually exchange.
//
// A topic is a name and its argument list, typed once in Topics. `on` adds a
// reader, `emit` calls every reader in order; a reader that throws does not
// stop the ones behind it, and a topic with no reader is a push nobody wanted
// yet, never an error. A leaf module: nothing here imports anything at runtime.

import type { Dispose } from './reactive.js';
import type { SeamPushes } from './seam-wire.js';

/** spine → app: one topic per push, its arguments the push's own. */
type PushTopics = { [K in keyof SeamPushes]: Parameters<SeamPushes[K]> };

/** app → app: a module telling the others that something it owns changed. */
export interface AppTopics {
  /** A solve landed (ingest, or a probe standing in for one). */
  plan: [plan: unknown];
  /** The plan column re-rendered for a new scope → the plan face redraws. */
  planRender: [];
  /** The scope's recipe library reloaded → the recipes face redraws. */
  recipes: [];
  /** Re-proportion the desire wheel, keyed by classification id. */
  desire: [signal: unknown];
  /** The federation's registered fragilities and live slack. */
  fragility: [snapshot: unknown];
  /** The scope's on-hand stock changed (seam.data.inventory holds it). */
  inventory: [];
  /** A count of a stock landed (the capture sheet): its readings, history and due date moved. */
  counted: [resource: string];
  /** The citizen's credit standing changed (seam.data.credit holds it). */
  credit: [];
  /** Someone asks for a room's sheet to open (voice/room.ts openRoom). */
  openRoom: [topic: string];
  /** The room's own transcript posted a line to its chat. */
  roomPosted: [topic: string];
  /** We went live in a room, or left one — the wake's map just changed. */
  roomChanged: [];
}

export type Topics = PushTopics & AppTopics;

type Reader<K extends keyof Topics> = (...args: Topics[K]) => void;

const readers: { [K in keyof Topics]?: Reader<K>[] } = {};

/** Read TOPIC. Returns the unsubscribe. */
export function on<K extends keyof Topics>(topic: K, fn: Reader<K>): Dispose {
  const list = (readers[topic] ||= []) as Reader<K>[];
  list.push(fn);
  return () => { const i = list.indexOf(fn); if (i >= 0) list.splice(i, 1); };
}

/** Tell every reader of TOPIC. */
export function emit<K extends keyof Topics>(topic: K, ...args: Topics[K]): void {
  const list = readers[topic] as Reader<K>[] | undefined;
  if (!list) return;
  [...list].forEach(fn => {
    try { fn(...args); } catch (e) { console.warn(`[bus] ${topic} reader threw`, e); }
  });
}
