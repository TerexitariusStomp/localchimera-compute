// app/offers.ts — the offer field: what belongs to this lens, and this turn.
//
// The rim and the map are ONE field. Every offer with a place carries `at`, so
// the same thing that rides the rim at its bearing lands on the map at its
// coordinate — and it is the same object, tiered by how it relates to you: your
// day's events, proposals directed at you, and the open work-intents you are
// eligible for.
//
// Nothing here draws. It answers two questions the map and the rim both ask —
// does this offer fall under the classification being looked at, and does it
// fall inside the turn currently on the dial — and answering them in one place
// is what keeps the two surfaces showing the same set.

import { S } from './state.js';
import type { DesireNode } from './desire.js';
import { PLACES } from './core.js';
import { evs, pending, eligible, sched, lived, spanOnDay, turnAnchor } from './events.js';
import { pick } from './calendars.js';
import { passesFacets } from './facets.js';
import type { DayEvent } from './seam.js';

/** An offer on the field: an event, plus how it relates to you. */
export interface MapOffer extends DayEvent {
  /** day (yours) | offered (proposed to you) | open (eligible, unclaimed). */
  tier: string;
}

/**
 * The "map" tab enters the earth view directly, UNLENSED — not through a single
 * desire band. This sentinel leaf aggregates every place, so the tested openMap
 * path shows the whole community at once, and atOrUnder short-circuits it for
 * offers too.
 */
export const MAP_ALL_ID = "*all*";
/**
 * The unlensed sentinel: the map face's "leaf", standing for every place at once.
 *
 * Shaped as a real DesireNode so it can BE what `stage.leaf` holds, rather than
 * a second thing the readers have to allow for. Its desire curve is flat and its
 * `count` zero — it names no term, so nothing nests under it and nobody
 * expressed a priority for it.
 */
export const MAP_ALL: DesireNode = {
  id: MAP_ALL_ID, name: "the map", col: "#999",
  count: 0, expressed: false, base: 0, bumps: [], qbase: 0, qbumps: [],
};

/** Aggregate every place under the sentinel. Call once the places are formed. */
export function seedMapAll(): void {
  PLACES[MAP_ALL_ID] = Object.values(PLACES).flat();
}

/** Every offer with a place, tiered by how it relates to you. */
export function mapOffers(): MapOffer[] {
  const out: MapOffer[] = [];
  for (const e of pick("plan", evs))        if (e.at) out.push({ tier: "day",     ...e });
  for (const p of pick("props", pending())) if (p.at) out.push({ tier: "offered", ...p });
  for (const w of pick("open", eligible))   if (w.at) out.push({ tier: "open",    ...w });
  for (const s of pick("sched", sched))     if (s.at) out.push({ tier: "day",     ...s });
  for (const e of pick("lived", lived))     if (e.at) out.push({ tier: "day",     ...e });
  return out;
}

/**
 * Is classification CAT at-or-under LEAF? Tree-based over the flat term-ids of
 * the folksonomy spine, with a slash-path fallback for legacy ids. At-or-under
 * means CAT is LEAF or sits in LEAF's subtree.
 */
export function atOrUnder(cat: string, leaf: string): boolean {
  if (leaf === MAP_ALL_ID) return true;   // the unlensed "map" tab: everything shows
  if (!cat || !leaf) return false;
  const sub = S.desc && S.desc.get(leaf);
  if (sub && sub.has(cat)) return true;
  return cat === leaf || cat.startsWith(leaf + "/");   // legacy slash-path ids
}

/**
 * A thing's full classification list (multi-valued), falling back to its single
 * primary `serves` — so a loaf tagged both grain AND local shows under EITHER
 * branch, not just the first (folksonomy.md Phase 0b).
 *
 * BOTH the raw tag and its flat segments are kept, because two spine sources
 * are in play: the raw tag matches a legacy slash-path spine (browser-derived,
 * no server aggregate) through atOrUnder's slash rule, and the segments match
 * the flat term-ids of a seeded or aggregated spine ("Food/Grain" → also
 * {Food, Grain}). One offer set, correct against either.
 */
export function offerCats(o: MapOffer): string[] {
  // isArray, not just truthiness: `cats` rides the seam as unknown, and a
  // string would have been iterated character by character.
  const raw: unknown[] = (Array.isArray(o.cats) && o.cats.length) ? o.cats
                       : (o.serves ? [o.serves] : []);
  const out = new Set<string>();
  for (const c of raw) {
    const s = String(c);
    out.add(s);                                             // raw tag (legacy slash spine)
    for (const seg of s.split("/")) if (seg) out.add(seg);  // flat segments (aggregated spine)
  }
  return [...out];
}

/**
 * Does the offer fall in the turn currently on the dial? The SAME window
 * drawEvents clips the rim to, so map and rim show one set: at day scale,
 * today; zoom the scale strip and the map follows.
 */
export function inTurnWindow(o: MapOffer): boolean {
  const A = turnAnchor();
  const d0 = Math.floor(A / 24), d1 = Math.floor((A + S.turnH - 1e-6) / 24);
  for (let dd = d0; dd <= d1; dd++) {   // a daily routine repeats on each day of the window
    // a DATED event stands on its own day(s) only, clock-clipped at its true
    // ends by the shared spanOnDay arithmetic
    const sp = spanOnDay(o, dd);
    if (!sp) continue;
    const s = Math.max(dd * 24 + sp.t0, A), e = Math.min(dd * 24 + sp.t1, A + S.turnH);
    if (e > s) return true;
  }
  return false;
}

/** What the map shows: offers of the zoomed classification, within the turn. */
export function relevantOffers(leafId: string | null): MapOffer[] {
  if (!leafId) return [];
  return mapOffers().filter(o =>
    offerCats(o).some(c => atOrUnder(c, leafId)) && inTurnWindow(o) && passesFacets(o));
}
