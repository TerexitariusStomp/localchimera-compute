// app/demo/world.ts — the demo world: one set of people, places and goods.
//
// Offline, every face shows the same neighbourhood: its places on the map are the
// places the store holds stock at, the goods the Resources face lists are the goods
// those stocks conform to, and the people who offer, ask, count and contest are the
// same people everywhere. The people, the places, the venues, the goods and what
// the ledger holds of each are read off the recording of the demo neighbourhood
// (demo/recording.ts, from module/playnet/knowledge/worlds/demo-neighbourhood.scm),
// the same world a gateway adopts as the preset `neighbourhood`.
//
// Pure data and small derivations: type-only imports, no DOM, no signals, so a
// node test reads the whole world (tests/browser/demo-world-test.mjs).

import type { Arc } from "../slots/model.js";
import type * as W from "../wire-rows.js";
import { RECORDING } from "./recording.js";

const FACE = RECORDING.face;

// ── people ───────────────────────────────────────────────────────────────────

/** A person of the demo: a lowercase id, and the name a face shows. */
export interface WorldPerson {
  id: string;
  name: string;
}

/** The person the demo is seen through. */
export const YOU: string = FACE.you;

export const PEOPLE: WorldPerson[] = FACE.people.map(p => ({ id: p.id, name: p.name }));

/** The name a person is shown by; the id itself for one the world does not hold. */
export const personName = (id: string): string => PEOPLE.find(p => p.id === id)?.name ?? id;

// ── places ───────────────────────────────────────────────────────────────────
// A place is a spot in the neighbourhood, positioned as an offset from the person
// (wherever they are, the demo assembles around them) and nested by containedIn.
// What one can do at a place is a venue: the need it serves (a taxonomy leaf), on
// which rail, and when. A work shift is a venue of the place it happens at, under
// its own name.

/** How a venue is held: yours, by credit, of the commons, or as work asked for. */
export type VenueMode = "own" | "claim" | "common" | "work";

export interface WorldPlace {
  id: string;
  name: string;
  emoji: string;
  /** The place this one is inside, or null. */
  containedIn: string | null;
  /** Degrees north and east of the person. */
  dLat: number;
  dLng: number;
}

/** What a place offers toward one need. */
export interface Venue {
  /** The place it is at. */
  place: string;
  /** The taxonomy leaf it serves. */
  leaf: string;
  mode: VenueMode;
  /** When it is open, in words. */
  when: string;
  /** Its own name and emoji, where they differ from the place's (a shift). */
  name?: string;
  emoji?: string;
}

const PLACE_EMOJI = FACE.places as Record<string, string>;

export const WORLD_PLACES: WorldPlace[] = RECORDING.snapshot.locations.map(l => ({
  id: l.id, name: l.name, emoji: PLACE_EMOJI[l.id] ?? "📍",
  containedIn: (l.containedIn as string | null) ?? null,
  dLat: Number(l.lat), dLng: Number(l.lng),
}));

/** The venues, in the order a need lists them. */
export const VENUES: Venue[] = (FACE.venues as readonly { place: string; leaf: string; mode: string; when: string; name?: string; emoji?: string }[])
  .map(v => ({ place: v.place, leaf: v.leaf, mode: v.mode as VenueMode, when: v.when,
               ...(v.name ? { name: v.name } : {}), ...(v.emoji ? { emoji: v.emoji } : {}) }));

/** The place ID names, or undefined. */
export const placeOf = (id: string): WorldPlace | undefined => WORLD_PLACES.find(p => p.id === id);

/** A venue as a face lists it: its place's position, and the name, emoji, hours and rail it goes by. */
export interface VenueRow {
  dLat: number;
  dLng: number;
  name: string;
  emoji: string;
  when: string;
  mode: VenueMode;
  /** The place it is at. */
  place: string;
}

/** The venues of each taxonomy leaf, in order: what a need opens onto. */
export function venuesByLeaf(): Record<string, VenueRow[]> {
  const out: Record<string, VenueRow[]> = {};
  for (const v of VENUES) {
    const p = placeOf(v.place);
    if (!p) continue;
    (out[v.leaf] ??= []).push({ dLat: p.dLat, dLng: p.dLng, name: v.name ?? p.name, emoji: v.emoji ?? p.emoji,
                                when: v.when, mode: v.mode, place: p.id });
  }
  return out;
}

// ── what people ask for and offer ────────────────────────────────────────────
// One table of needs and means. Every face that shows them reads a projection of
// it: the share bar and the match ring read the scope's whole pool (every need,
// every declared means), and the map reads what stands at a place (every need,
// and the means socialized into the commons). So Ana's guest room is one offer,
// with one quantity, wherever it is seen.

/** A recurring window, as the slots carry one (slots/model.ts Arc). */
export type WorldArc = Arc;

/** A need or a means of a person of the world. */
export interface WorldSlot {
  id: string;
  kind: "need" | "means";
  /** Who asks, or who offers. */
  person: string;
  spec: string;
  name: string;
  emoji: string;
  note: string;
  qty: number;
  unit: string;
  cats: string[];
  arcs: WorldArc[];
  /** Where it stands, when it stands at a place. */
  place?: string;
  /** A means lent into the commons: the map shows it. */
  socialized?: boolean;
  /** How much of a socialized means is taken, 0..1. */
  drawn?: number;
  /** How many days from today it stands until. */
  untilDays?: number;
  /** The id of the means a need is matched to. */
  matched?: string;
  /** What the map calls it, where that differs from its name. */
  mapName?: string;
}

// The pool is the recording's: each person's needs and offers as their own slots
// door answered them once declared, so a slot's id, quantity, place and hours are
// the planner's. What a solve would say of a lent means (how much of it
// is taken, until when it is lent, which need it answers) is stated here.
const LENT: Record<string, { drawn: number; untilDays?: number }> = {
  "means:ana:spec-bed": { drawn: 0.5, untilDays: 60 },
  "means:sam:spec-bed": { drawn: 1, untilDays: 21 },
  "means:meiers:spec-workshop": { drawn: 0 },
  "means:bob:spec-cargo-bike": { drawn: 0 },
};
const MATCHED: Record<string, string> = {
  "need:you:spec-shelter": "means:ana:spec-bed",
  "need:priya:spec-shelter": "means:sam:spec-bed",
};
const MAP_NAME: Record<string, string> = { "need:you:spec-shelter": "your housing need" };

const DAY_MS = 86400000;
const daysOn = (date: string): number | undefined =>
  date ? Math.round((Date.parse(`${date.slice(0, 10)}T00:00:00Z`) - Date.parse(`${RECORDING.day}T00:00:00Z`)) / DAY_MS) : undefined;

type WireSlot = W.WireSlot & { who?: string; owner?: string };
const slotOfWire = (kind: "need" | "means") => (r: WireSlot): WorldSlot => {
  const lent = LENT[r.id];
  const untilDays = lent?.untilDays ?? daysOn(r.until);
  return {
    id: r.id, kind, person: (kind === "need" ? r.who : r.owner) ?? "", spec: r.spec, name: r.name, emoji: r.emoji, note: r.note,
    qty: Number(r.qty) || 0, unit: r.unit, cats: [...r.cats],
    arcs: r.arcs.map(a => ({ start: a.start, end: a.end, days: [...a.days] as Arc["days"] })),
    ...(r.where ? { place: r.where } : {}),
    ...(lent ? { socialized: true, drawn: lent.drawn } : {}),
    ...(untilDays !== undefined ? { untilDays } : {}),
    ...(MATCHED[r.id] ? { matched: MATCHED[r.id] } : {}),
    ...(MAP_NAME[r.id] ? { mapName: MAP_NAME[r.id] } : {}),
  };
};

const POOL = RECORDING.pool;
export const SLOTS: WorldSlot[] = [
  ...POOL.needs.map(slotOfWire("need")),
  ...POOL.means.map(slotOfWire("means")),
];

/** The slot ID names, or undefined. */
export const slotOf = (id: string): WorldSlot | undefined => SLOTS.find(s => s.id === id);

/** A slot as the scope's pool carries it: who asks on a need, who offers on a means. */
export interface PoolRow {
  id: string; spec: string; name: string; emoji: string; note: string; qty: number; unit: string;
  cats: string[]; arcs: WorldArc[];
  who?: string;
  owner?: string;
}

/** The scope's whole pool: every need and every declared means, as the share bar and the match ring read it. */
export function scopePool(): { needs: PoolRow[]; means: PoolRow[] } {
  const row = (s: WorldSlot): PoolRow => ({
    id: s.id, spec: s.spec, name: s.name, emoji: s.emoji, note: s.note, qty: s.qty, unit: s.unit, cats: s.cats, arcs: s.arcs,
    ...(s.kind === "need" ? { who: s.person } : { owner: s.person }),
  });
  return { needs: SLOTS.filter(s => s.kind === "need").map(row), means: SLOTS.filter(s => s.kind === "means").map(row) };
}

/** A slot as the map carries it: where it stands, as an offset from the person. */
export interface MapRow {
  id: string; spec: string; name: string; emoji: string; qty: number; unit: string; arcs?: WorldArc[];
  who?: string;
  owner?: string;
  drawn?: number;
  until?: string;
  /** The name of the means a need is matched to. */
  matched?: string;
  dLat: number;
  dLng: number;
}

/**
 * What stands at a place: every need that names one, and the means socialized
 * into the commons. ISO gives the date a count of days from today falls on.
 */
export function mapPool(iso: (days: number) => string): { needs: MapRow[]; means: MapRow[] } {
  const row = (s: WorldSlot): MapRow[] => {
    const p = s.place ? placeOf(s.place) : undefined;
    if (!p) return [];
    return [{
      id: s.id, spec: s.spec, name: s.mapName ?? s.name, emoji: s.emoji, qty: s.qty, unit: s.unit,
      ...(s.arcs.length ? { arcs: s.arcs } : {}),
      ...(s.kind === "need" ? { who: personName(s.person) } : { owner: personName(s.person) }),
      ...(s.drawn !== undefined ? { drawn: s.drawn } : {}),
      ...(s.untilDays !== undefined ? { until: iso(s.untilDays) } : {}),
      ...(s.matched ? { matched: slotOf(s.matched)?.name ?? s.matched } : {}),
      dLat: p.dLat, dLng: p.dLng,
    }];
  };
  return { needs: SLOTS.filter(s => s.kind === "need").flatMap(row),
           means: SLOTS.filter(s => s.kind === "means" && s.socialized).flatMap(row) };
}

// ── goods and what the ledger holds of them ──────────────────────────────────

/** A spec in the demo catalogue (mirrors playnet.typ Fig 3). */
export interface DemoSpec {
  id: string;
  name: string;
  unit: string;
  /** Socially-necessary labour time crystallised in one unit. */
  snlt: number;
  cats: string[];
  emoji: string;
  external?: boolean;
}

/** A resource in the demo catalogue. */
export interface DemoResource {
  id: string;
  spec: string;
  onhand: number;
  mode: string;
  met: number;
}

// ── the demo claimable catalogue ───────────────────────────────────────────
// The goods a person claims against credit: those the commons holds a claimable
// stock of. The Resources face reads them for its standalone book and the dial's
// spend wheel reads them so the experiment breathes offline too.

const STOCKS = RECORDING.snapshot.inventory.resources as readonly Record<string, unknown>[];
const CLAIMABLE = "individual-claimable";
// the commons' stocks of a good: a person's own offer of it is theirs, and is on the books under their name
const stocksOf = (spec: string) => STOCKS.filter(r => r["conforms-to"] === spec && r["custodian-name"] === FACE.commons);

/** What the demo commons holds of the good SPEC: the sum of its stocks on the books. */
export const demoHeld = (spec: string): number => stocksOf(spec).reduce((a, r) => a + (Number(r.onhand) || 0), 0);

// What the demo scope keeps of a good for production and the reserve, by spec:
// the social portion the Resources face shows beside the individual one.
export const DEMO_KEPT_BY_SPEC: Record<string, number> = { "spec-bread": 80, "spec-veg": 120 };

/** A communal good the scope shares part of out against credit. */
function demoHeldCommunal(spec: string): boolean { return spec in DEMO_KEPT_BY_SPEC; }

/** Every good the neighbourhood holds a stock of. */
export const GOODS: DemoSpec[] = (FACE.goods as readonly { id: string; name: string; unit: string; emoji: string; cats: readonly string[]; snlt: number; external: boolean }[])
  .map(g => ({ id: g.id, name: g.name, unit: g.unit, snlt: g.snlt, cats: [...g.cats], emoji: g.emoji, ...(g.external ? { external: true } : {}) }));

/** The goods a person claims against credit. */
export const DEMO_SPECS: DemoSpec[] = GOODS
  .filter(g => stocksOf(g.id).some(r => r["distribution-mode"] === CLAIMABLE) || demoHeldCommunal(g.id));

// How far each good's standing demand is met, where the demo states one.
const MET: Record<string, number> = { "spec-bread": 0.80, "spec-veg": 0.90, "spec-tea": 0.65, "spec-fabric": 0.90, "spec-coat": 0.50, "spec-chair": 0.50 };

/** One claimable resource per good: what is shared out of it, the kept portion aside. */
export const DEMO_RESOURCES: DemoResource[] = DEMO_SPECS.map(sp => ({
  id: `r-${sp.id.replace(/^spec-/, "")}-1`, spec: sp.id,
  onhand: Math.max(0, demoHeld(sp.id) - (DEMO_KEPT_BY_SPEC[sp.id] ?? 0)),
  mode: "individual-claimable", met: MET[sp.id] ?? 1,
}));
