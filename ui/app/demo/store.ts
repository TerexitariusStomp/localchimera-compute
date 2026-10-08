// app/demo/store.ts — the offline store: the recording's books, as of today.
//
// The store face and the rail's inventory read their stock, the schedule of
// counts, the readings of each spec, the counts of each stock and the contests
// open from the gateway. Offline they read this: what the planner and
// governance answered the demo's person in the demo neighbourhood
// (demo/recording.ts, written by tools/demo-emit.scm from a real scope), read
// by the readers a gateway's replies are read by (count.ts, contest.ts). So
// the figures here are the engine's own, in the wire's own shapes.
//
// The recording was made on one day; its dates are moved by whole days to the
// day the page is opened on, so "due yesterday" and "use by today" hold
// whatever day it is.
//
// The recording is what the page shows before the device's own scope has
// answered (demo/seat.ts, scope-local.ts), and what answers a read where that
// scope cannot run.

import type { Inventory, InventoryResource, SnapshotLocation } from "../seam.js";
import { readSchedule, type CountRow } from "../count.js";
import { readHistory, readContests, type CountEntry, type ContestEntry } from "../contest.js";
import { readsOf, type Allot } from "../allotment.js";
import type { ReadingsWire, ReadingRow } from "../store-data.js";
import { RECORDING } from "./recording.js";

const DAY = 86400000;

/** Everything the offline store knows, as of one day. */
export interface DemoStore {
  inventory: Inventory;
  /** The places, as offsets in degrees from the person (lat north, lng east). */
  places: SnapshotLocation[];
  /** What the recording answers DOOR, asked of OF (a stock or a spec), as the wire carries it. */
  reply(door: DemoDoor, of?: string): string;
  schedule: CountRow[];
  /** What the sources say of a spec; none for a spec nothing has been read of. */
  readings(spec: string): ReadingsWire | null;
  /** The readings of a spec in time order, each as its technique saw it. */
  history(spec: string): ReadingRow[];
  /** The counts of one stock, newest first. */
  counts(resource: string): CountEntry[];
  contests: ContestEntry[];
  allot: Allot;
}

type Json = null | boolean | number | string | Json[] | { [k: string]: Json };

const STAMP = /^(\d{4}-\d{2}-\d{2})(T\d{2}:\d{2}:\d{2}Z)?$/;

/** The recording, each of its dates moved DAYS on. */
function moved<T>(value: T, days: number): T {
  const walk = (v: Json): Json => {
    if (typeof v === "string") {
      const m = STAMP.exec(v);
      if (!m) return v;
      const day = new Date(Date.parse(`${m[1]}T00:00:00Z`) + days * DAY).toISOString().slice(0, 10);
      return day + (m[2] ?? "");
    }
    if (Array.isArray(v)) return v.map(walk);
    if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, walk(x)]));
    return v;
  };
  return walk(value as unknown as Json) as unknown as T;
}

const num = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) ? v : Number(v) || 0);

/** The doors the recording answers, by the name the seam knows each by. */
export type DemoDoor = "countSchedule" | "countHistory" | "scopeReadings" | "readingsBetween" | "contests" | "allotment"
                     | "mySlots" | "ourSlots";

function build(now: number): DemoStore {
  const today = Math.floor(now / DAY) * DAY;
  // a copy of the recording, its dates moved to today
  const rec = moved(RECORDING, Math.round((today - Date.parse(`${RECORDING.day}T00:00:00Z`)) / DAY));
  const face = rec.face;
  const stockEmoji = face.stocks as Record<string, string>;
  const iso = (t: number): string => new Date(t).toISOString().slice(0, 19) + "Z";
  type Rows = { rows: Record<string, unknown>[] };

  const places = rec.snapshot.locations as unknown as SnapshotLocation[];
  // a stock's row is the snapshot's, with the emoji a face shows it by
  const resources: InventoryResource[] = (rec.snapshot.inventory.resources as unknown as InventoryResource[])
    .map(r => ({ ...r, onhand: num(r.onhand), emoji: stockEmoji[String(r.id)] ?? "" }));

  const scheduled = rec.replies.countSchedule as unknown as Rows;
  const histories = rec.replies.countHistory as unknown as Record<string, Rows>;
  const said = rec.replies.scopeReadings as unknown as Record<string, ReadingsWire>;
  const between = rec.replies.readingsBetween as unknown as Record<string, Rows>;
  // a recording moved by days keeps its figures; the week opens again on the Monday after today
  const toMonday = ((8 - new Date(now).getUTCDay()) % 7) || 7;
  const reads = { ...rec.replies.allotment, opens: iso(today + toMonday * DAY) };

  const NONE = { rows: [], drift: { n: 0, meanAbs: 0, net: 0 }, latest: null };
  const reply = (door: DemoDoor, of = ""): string => JSON.stringify(
    door === "countSchedule" ? scheduled
    : door === "countHistory" ? histories[of] ?? { rows: [] }
    : door === "scopeReadings" ? said[of] ?? NONE
    : door === "readingsBetween" ? between[of] ?? { rows: [], fold: [] }
    : door === "contests" ? rec.replies.contests
    : door === "mySlots" ? rec.replies.mySlots
    : door === "ourSlots" ? rec.replies.ourSlots
    : reads);

  return {
    inventory: { resources },
    places,
    reply,
    get schedule() { return readSchedule(reply("countSchedule")); },
    readings: spec => { const r = said[spec]; return r && (r.drift.n > 0 || r.latest) ? r : null; },
    history: spec => (between[spec]?.rows ?? []).map(x => ({
      technique: String(x.technique ?? ""), action: String(x.action ?? ""), unit: String(x.unit ?? ""),
      latest: num(x.latest), at: String(x.at ?? ""),
    })),
    counts: rid => readHistory(reply("countHistory", rid)),
    get contests() { return readContests(reply("contests")); },
    get allot() { return readsOf(reply("allotment")) as Allot; },
  };
}

let held: { day: number; store: DemoStore } | null = null;

/** The offline store as of NOW (default: the present), built once per day. */
export function demoStore(now: number = Date.now()): DemoStore {
  const day = Math.floor(now / DAY);
  if (!held || held.day !== day) held = { day, store: build(now) };
  return held.store;
}
