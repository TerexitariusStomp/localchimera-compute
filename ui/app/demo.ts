// app/demo.ts — what the dial shows with nothing connected.
//
// THE SEAM has an offline side, and this is all of it: a spine, a desire signal
// over that spine, a recipe library, two communes' plans, opening hours for the
// demo's places, and a pair of bioregional clusters. Every one of them is the
// SAME SHAPE the real thing arrives in — `EXT.taxonomy || TAXONOMY`,
// `seam.data.recipes || DEMO_RECIPES` — so connecting a gateway swaps the
// data and touches no rendering code.
//
// They were scattered across five places in main.js, each beside the machinery
// that happened to read it first, and the reason to gather them is not tidiness:
// a reader could not tell which of main's 5,000 lines were the demo and which
// were the dial. Here the answer is the file name. Nothing imports this except
// the fallback expression that names it.
//
// Structure stays SEPARATE from signal — TAXONOMY carries the terms, DEMO_DESIRE
// the curves over them, keyed by id — so the spine can be swapped without
// touching either. That is the same split the live seam makes.

import type { ScopeRecipe, ScopeRef, DayEvent } from './seam.js';
import type { Bump } from './desire.js';
// a demo recipe's standing is read off its runs by the reading a live scope's
// is (tools/recipe-demo-emit.scm), so a channel's word and curve cannot drift
// from its points
import { DEMO_STANDING } from './recipe-demo-standing.js';
import { placeOf } from './demo/world.js';

// where a demo event happens: a place of the demo world (demo/world.ts), by its
// name and its position, so the calendar's places are the map's and the store's
const at = (id: string): Pick<DayEvent, "place" | "at"> => {
  const p = placeOf(id);
  if (!p) throw new Error(`the demo world holds no place ${id}`);
  return { place: p.name, at: { dLat: p.dLat, dLng: p.dLng } };
};

// ── the shapes the demo data claims ─────────────────────────────────────────
// Written here rather than in seam.ts because these are the OFFLINE authoring
// shapes: what a hand-written table looks like, which is a subset of what the
// wire may send. A field the demo never writes is absent here by choice.

/**
 * A term of the classification spine — ValueFlows `resourceClassifiedAs`
 * (schemas.scm) — addressed by a stable `id` (its taxonomy path). `col` is
 * optional: the live planner taxonomy names no colours and the palette supplies
 * them, which is exactly what the demo tree opts out of by naming its own.
 */
export interface TaxonomyTerm {
  id: string;
  label?: string;
  col?: string;
  children?: TaxonomyTerm[];
}

/** One classification's phase curve over the turn, and its met/quality curve. */
export interface DesireCurve {
  base: number;
  bumps: Bump[];
  qbase: number;
  qbumps: Bump[];
}

/** The desire signal, keyed by taxonomy id — the planner's aggregate demand. */
export type DesireTable = Record<string, DesireCurve>;

/** Hours a place is open, as [from, to) pairs on the turn. */
export type OpenHours = [number, number][];

/**
 * A need as the offline plan states it. A subset of the wire's PlanNeed: the
 * demo authors no `suggested` roster and no `willing` count, because there is
 * no one on the other side to have volunteered.
 */
export interface DemoNeed {
  id: string;
  label: string;
  emoji: string;
  met: number;
  want: number;
  recipeId: string | null;
  runs: number;
  labourH: number;
}

/** How one demo commune's plan differs: its region's topology, and coverage. */
export interface DemoScopePlan {
  /** Which recipe topology it runs — "de" is the rye chain, else the veg one. */
  region: string;
  /** The display name the plan carries. */
  scope: string;
  coverage: number;
  /** Per-need overrides, so two communes in one bioregion still read apart. */
  met?: Record<string, number>;
}

/** A located thing in a bioregional cluster: a scope root, or one of its plots. */
export interface DemoPlace {
  id: string;
  name: string;
  lat: number;
  lng: number;
  desire: number;
}

/** A commune and the plots under it, for the container overlay to nest. */
export interface DemoCluster {
  root: DemoPlace;
  plots: DemoPlace[];
}

// ── the spine ───────────────────────────────────────────────────────────────
// Each node is a CLASSIFICATION TERM, shown by its `label`. The dial expresses
// *priority over these classifications*, and nothing else: it is mode-agnostic.
// A term's actual economic resources — individual-claimable goods (drawn against
// credit), communal goods, and skills (work-intents you offer willingness on) —
// are realised on the MAP, not here; the same priority spans all of them,
// exactly as the doc's priority weights "span both rails of the means of
// consumption" (§Desire as harmony).

export const TAXONOMY: TaxonomyTerm = {
  id: "you", children: [
    { id: "rest", label: "rest", col: "#2c4a6e", children: [
      { id: "rest/sleep",        label: "sleep" },
      { id: "rest/unwinding",    label: "unwinding" },
      { id: "rest/stillness",    label: "stillness" } ] },
    { id: "nourishment", label: "nourishment", col: "#e8654f", children: [
      { id: "nourishment/meals", label: "meals" },
      { id: "nourishment/tea-snacks", label: "tea & snacks" },
      { id: "nourishment/cooking", label: "cooking" } ] },
    { id: "movement", label: "movement", col: "#0e7c7b", children: [
      { id: "movement/walking",  label: "walking" },
      { id: "movement/training", label: "training" },
      { id: "movement/stretching", label: "stretching" } ] },
    { id: "learning", label: "learning", col: "#e2a512", children: [
      { id: "learning/reading",  label: "reading" },
      { id: "learning/practice", label: "practice" },
      { id: "learning/study-circle", label: "study circle" } ] },
    { id: "connection", label: "connection", col: "#7a4bb0", children: [
      { id: "connection/family", label: "family" },
      { id: "connection/friends", label: "friends" },
      { id: "connection/community", label: "community" } ] },
    // the shelves the demo pool shelves under — bands in their own right, so a
    // coat wears clothing's hue the way bread wears nourishment's
    { id: "clothing", label: "clothing", col: "#b5638f", children: [
      { id: "clothing/fabric",   label: "fabric" },
      { id: "clothing/garments", label: "garments" } ] },
    { id: "furnishing", label: "furnishing", col: "#a67c4e", children: [
      { id: "furnishing/seating", label: "seating" },
      { id: "furnishing/storage", label: "storage" } ] },
    { id: "care", label: "care", col: "#3f9d5f", children: [
      { id: "care/medical",  label: "medical" },
      { id: "care/children", label: "children" } ] },
    { id: "housing", label: "housing", col: "#8a6f9e", children: [
      { id: "housing/shelter", label: "shelter" } ] },
    { id: "external", label: "external", col: "#6f7480", children: [
      { id: "external/fiat",   label: "fiat" },
      { id: "external/crypto", label: "crypto" } ] },
  ] };

// ── the signal over it ──────────────────────────────────────────────────────
// A stand-in for the aggregate demand the planner supplies: per-classification
// phase curve (`base` + `bumps` over the turn) and a met/quality curve (`qbase`
// + `qbumps`). Swap this for the real signal and the spine above is unchanged.

export const DEMO_DESIRE: DesireTable = {
  "rest":               { base: 0.20, bumps: [[3.0,3.8,1.8],[14.0,1.2,0.25]], qbase: 0.35, qbumps: [[3.0,4.0,0.55]] },
  "rest/sleep":         { base: 0.10, bumps: [[2.5,3.5,2.2]], qbase: 0.45, qbumps: [[3.0,4.0,0.50]] },
  "rest/unwinding":     { base: 0.15, bumps: [[21.5,1.8,1.0],[14.0,1.2,0.4]], qbase: 0.30, qbumps: [[21.5,2.0,0.35]] },
  "rest/stillness":     { base: 0.20, bumps: [[6.5,1.5,0.5],[14.0,1.5,0.5]], qbase: 0.25, qbumps: [[6.5,1.5,0.30]] },
  "nourishment":        { base: 0.10, bumps: [[7.5,1.1,0.8],[13.0,1.2,0.9],[19.5,1.4,0.9]], qbase: 0.30, qbumps: [[7.5,1.2,0.5],[13.0,1.3,0.5],[19.5,1.5,0.5]] },
  "nourishment/meals":  { base: 0.08, bumps: [[7.5,1.0,1.0],[13.0,1.1,1.1],[19.5,1.2,1.1]], qbase: 0.35, qbumps: [[7.5,1.2,0.5],[13.0,1.3,0.5],[19.5,1.4,0.5]] },
  "nourishment/tea-snacks": { base: 0.15, bumps: [[10.5,1.5,0.5],[16.5,1.5,0.6]], qbase: 0.30, qbumps: [[16.5,1.5,0.30]] },
  "nourishment/cooking": { base: 0.08, bumps: [[12.0,1.0,0.6],[18.5,1.2,0.8]], qbase: 0.40, qbumps: [[18.5,1.3,0.40]] },
  "movement":           { base: 0.10, bumps: [[7.2,1.6,0.55],[17.5,1.8,0.65]], qbase: 0.28, qbumps: [[7.2,1.6,0.25],[17.5,1.8,0.30]] },
  "movement/walking":   { base: 0.15, bumps: [[8.0,1.5,0.6],[17.5,1.5,0.5]], qbase: 0.35, qbumps: [[8.0,1.5,0.30]] },
  "movement/training":  { base: 0.05, bumps: [[7.0,1.2,0.8],[18.0,1.5,0.9]], qbase: 0.25, qbumps: [[18.0,1.5,0.35]] },
  "movement/stretching": { base: 0.12, bumps: [[6.8,1.0,0.5],[21.0,1.5,0.4]], qbase: 0.30, qbumps: [[6.8,1.0,0.30]] },
  "learning":           { base: 0.14, bumps: [[10.5,2.6,0.75]], qbase: 0.25, qbumps: [[10.5,2.6,0.35]] },
  "learning/reading":   { base: 0.12, bumps: [[9.5,2.0,0.6],[21.5,1.5,0.5]], qbase: 0.30, qbumps: [[9.5,2.0,0.35]] },
  "learning/practice":  { base: 0.08, bumps: [[11.0,2.0,0.8]], qbase: 0.25, qbumps: [[11.0,2.0,0.30]] },
  "learning/study-circle": { base: 0.05, bumps: [[10.5,1.5,0.9]], qbase: 0.20, qbumps: [[10.5,1.5,0.45]] },
  "connection":         { base: 0.14, bumps: [[20.8,2.6,1.0],[13.0,1.5,0.3]], qbase: 0.30, qbumps: [[20.8,2.6,0.45],[13.0,1.5,0.20]] },
  "connection/family":  { base: 0.15, bumps: [[19.0,2.0,0.9],[7.5,1.0,0.4]], qbase: 0.35, qbumps: [[19.0,2.0,0.40]] },
  "connection/friends": { base: 0.10, bumps: [[21.0,2.0,1.0],[13.0,1.5,0.4]], qbase: 0.25, qbumps: [[21.0,2.0,0.45]] },
  "connection/community": { base: 0.08, bumps: [[17.5,1.8,0.6]], qbase: 0.25, qbumps: [[17.5,1.8,0.30]] },
};

// ── where a priority is REALISED, and when ──────────────────────────────────
// One priority over a classification (the dial); here it is realised per
// availability window, in hours of the turn — the temporal coordinate of the
// spatial thing whose `when` strings are its display text.

export const OPEN: Record<string, OpenHours> = {
  "home": [[0, 24]], "Aleko mountain hut": [[0, 24]],
  "city garden": [[6, 22]], "mineral baths": [[10, 22]], "reading café": [[8, 23]],
  "Borisova gradina": [[0, 24]], "monastery garden": [[5, 20]],
  "Bakery Vitosha": [[6, 19]], "commons canteen": [[12, 15]], "Sourdough Co-op": [[8, 18]],
  "tea house": [[9, 21]], "corner café": [[7, 20]],
  "communal kitchen": [[16, 21]], "central market hall": [[7, 19]],
  "Vitosha trailhead": [[0, 24]], "South Park loop": [[0, 24]],
  "gym commons": [[6, 22]], "climbing wall": [[10, 22]],
  "yoga hall": [[7, 9], [18, 20]], "park pavilion": [[0, 24]],
  "city library": [[9, 20]], "book swap shelf": [[0, 24]],
  "rehearsal rooms": [[9, 22]], "makerspace south": [[10, 22]],
  "community hall": [[18, 20]], "open seminar": [[17, 19]],
  "grandma's": [[9, 20]], "cousins' place": [[18, 22]],
  "hovel café": [[17, 24]], "board-game club": [[19, 24]],
  "neighbourhood assembly": [[19, 21]], "repair café": [[11, 14]], "free kitchen": [[13, 15]],
};

// ── the recipe library ──────────────────────────────────────────────────────
// Real recipes arrive serialized from ^recipe-store via the scope snapshot;
// until a scope is connected this hand-seeded library stands in, in the same
// shape. Each recipe declares what spec it `produces`, so a resource can be
// followed back to the recipe that makes it.

// ── the day's WORK recipes — what a shift IS underneath its label ───────────
// Every shift on the demo day instantiates one of these: the block's ladder
// (calendar.ts disclosureBody) reads its role from the event's spec and its
// verbs from here. Shared by both demo scopes, since the demo day itself is.
export const DEMO_WORK_RECIPES: ScopeRecipe[] = [
  { id: "rp-harvest-morning", name: "Morning harvest", emoji: "🧺", produces: "vegetables",
    need: "nourishment/cooking",
    steps: [
      { name: "Pick & crate", emoji: "🥕", hours: 2.5,
        in:  [{ q: 1,   u: "set",   spec: "hand-tools",  name: "hand tools",  emoji: "🧤", action: "use"     },
              { q: 6,   u: "each",  spec: "crate",       name: "crates",      emoji: "📦", action: "use"     },
              { q: 1,   u: "plot",  spec: "grown-plot",  name: "ripe beds",   emoji: "🌿", action: "consume" },
              { q: 2.5, u: "h",     spec: "labour",      name: "picking",     emoji: "🧑‍🌾", action: "work"    }],
        out: [{ q: 8, u: "kg", spec: "carrots",  name: "carrots",  emoji: "🥕", action: "produce", primary: true },
              { q: 3, u: "kg", spec: "tomatoes", name: "tomatoes", emoji: "🍅", action: "produce" }] }] },
  { id: "rp-bakery-morning", name: "Morning bake", emoji: "🍞", produces: "bread",
    need: "nourishment/bread",
    steps: [
      { name: "Shape & bake", emoji: "🔥", hours: 2,
        in:  [{ q: 1,   u: "",     spec: "oven",     name: "wood oven",        emoji: "🔥", action: "use"     },
              { q: 12,  u: "each", spec: "banneton", name: "proofing baskets", emoji: "🧺", action: "use"     },
              { q: 6,   u: "kg",   spec: "flour",    name: "rye flour",        emoji: "🌾", action: "consume" },
              { q: 0.5, u: "kg",   spec: "starter",  name: "sourdough starter", emoji: "🫙", action: "consume" },
              { q: 4,   u: "L",    spec: "water",    name: "water",            emoji: "🚰", action: "consume" },
              { q: 2,   u: "h",    spec: "labour",   name: "baking",           emoji: "🧑‍🍳", action: "work"    }],
        out: [{ q: 12, u: "each", spec: "bread", name: "loaves", emoji: "🍞", action: "produce", primary: true }] }] },
  { id: "rp-repair-cafe", name: "Repair café", emoji: "🔧", produces: "repaired-item",
    need: "movement/commute",
    steps: [
      { name: "Diagnose & mend", emoji: "🛠️", hours: 1.5,
        in:  [{ q: 1,   u: "",     spec: "workbench",  name: "workbench",      emoji: "🪚", action: "use"     },
              { q: 1,   u: "",     spec: "solder-iron", name: "soldering iron", emoji: "🔌", action: "use"     },
              { q: 1,   u: "",     spec: "multimeter", name: "multimeter",     emoji: "📟", action: "use"     },
              { q: 20,  u: "g",    spec: "solder",     name: "solder",         emoji: "🧵", action: "consume" },
              { q: 3,   u: "each", spec: "spare-part", name: "spare parts",    emoji: "⚙️", action: "consume" },
              { q: 1.5, u: "h",    spec: "labour",     name: "repairing",      emoji: "🧑‍🔧", action: "work"    }],
        out: [{ q: 4, u: "each", spec: "repaired-item", name: "things mended", emoji: "✨", action: "produce", primary: true }] }] },
  { id: "rp-tool-library", name: "Tool library desk", emoji: "🧰", produces: "tool-loan",
    need: "movement/commute",
    steps: [
      { name: "Lend & log", emoji: "📒", hours: 1,
        in:  [{ q: 1, u: "",  spec: "lending-desk", name: "lending desk",  emoji: "🪑", action: "use"  },
              { q: 1, u: "",  spec: "catalogue",    name: "the catalogue", emoji: "📒", action: "use"  },
              { q: 1, u: "h", spec: "labour",       name: "tool care",     emoji: "🧑‍🔧", action: "work" }],
        out: [{ q: 6, u: "each", spec: "tool-loan", name: "tools lent out", emoji: "🧰", action: "deliver-service", primary: true }] }] },
  { id: "rp-shelving", name: "Shelving run", emoji: "📚", produces: "shelved-books",
    need: "learning/skills",
    steps: [
      { name: "Sort & shelve", emoji: "📚", hours: 2,
        in:  [{ q: 1, u: "",  spec: "book-trolley", name: "book trolley", emoji: "🛒", action: "use"  },
              { q: 2, u: "h", spec: "labour",       name: "shelving",     emoji: "🧑‍🏫", action: "work" }],
        out: [{ q: 120, u: "each", spec: "shelved-books", name: "books back in place", emoji: "📚", action: "produce", primary: true }] }] },
  { id: "rp-garden-tending", name: "Garden tending", emoji: "🌱", produces: "grown-plot",
    need: "nourishment/cooking",
    steps: [
      { name: "Weed, feed, water", emoji: "🌱", hours: 2,
        in:  [{ q: 1,  u: "pair", spec: "gloves",      name: "gloves",       emoji: "🧤", action: "use"     },
              { q: 1,  u: "",     spec: "hoe",         name: "hoe",          emoji: "⛏️", action: "use"     },
              { q: 2,  u: "each", spec: "watering-can", name: "watering cans", emoji: "🪣", action: "use"     },
              { q: 10, u: "kg",   spec: "compost",     name: "compost",      emoji: "🍂", action: "consume" },
              { q: 40, u: "L",    spec: "water",       name: "water",        emoji: "🚰", action: "consume" },
              { q: 2,  u: "h",    spec: "labour",      name: "growing",      emoji: "🧑‍🌾", action: "work"    }],
        out: [{ q: 3, u: "bed", spec: "grown-plot", name: "beds tended", emoji: "🌿", action: "produce", primary: true }] }] },
  { id: "rp-bike-desk", name: "Bike repair desk", emoji: "🚲", produces: "repaired-bike",
    need: "movement/commute",
    steps: [
      { name: "True, patch, tune", emoji: "🚲", hours: 2,
        in:  [{ q: 1, u: "",     spec: "bike-stand", name: "bike stand",  emoji: "🔩", action: "use"     },
              { q: 1, u: "",     spec: "tool-roll",  name: "tool roll",   emoji: "🧰", action: "use"     },
              { q: 1, u: "",     spec: "track-pump", name: "track pump",  emoji: "💨", action: "use"     },
              { q: 2, u: "each", spec: "inner-tube", name: "inner tubes", emoji: "⭕", action: "consume" },
              { q: 1, u: "pair", spec: "brake-pads", name: "brake pads",  emoji: "🛑", action: "consume" },
              { q: 2, u: "h",    spec: "labour",     name: "bike repair", emoji: "🧑‍🔧", action: "work"    }],
        out: [{ q: 3, u: "each", spec: "repaired-bike", name: "bikes rolling again", emoji: "🚲", action: "produce", primary: true }] }] },
  { id: "rp-school-run", name: "School run", emoji: "🚸", produces: "school-run",
    need: "movement/commute",
    steps: [
      { name: "Ride there and back", emoji: "🚲", hours: 1.25,
        in:  [{ q: 1,    u: "",  spec: "cargo-bike", name: "cargo bike", emoji: "🚲", action: "use"  },
              { q: 1.25, u: "h", spec: "labour",     name: "riding",     emoji: "🧑", action: "work" }],
        out: [{ q: 2, u: "person-trip", spec: "school-run", name: "children delivered", emoji: "🚸", action: "deliver-service", primary: true }] }] },
];

export const DEMO_RECIPES: ScopeRecipe[] = [{
      id: "rp-cooked-meal", name: "Cooked meal", emoji: "🍲", produces: "meal",
      need: "nourishment/meals",
      // standing/profile/yield/margin (recipes.ts, web.ts): read off the runs a
      // real scope would have behind it (tools/recipe-demo-emit.scm). Robust
      // here: the price of vegetables swings, the kitchen holds steady — and
      // under today's prices (stress 5) it delivers what its record shows there.
      ...DEMO_STANDING["rp-cooked-meal"],
      // a production recipe ENDS at its product: Cook yields the meal, and that
      // IS the deliverable. Eating it is consumption — a separate event on the
      // need side — not a step in the recipe that makes it.
      steps: [
        { name: "Shop", emoji: "🧺", hours: 0.4,
          in:  [],
          out: [{ q: 2, u: "kg", spec: "vegetables", emoji: "🥬", action: "produce", primary: true }] },
        { name: "Cook", emoji: "🍳", hours: 0.6,
          in:  [{ q: 2,   u: "kg", spec: "vegetables", emoji: "🥬", action: "consume" },
                { q: 1,   u: "",   spec: "stove",      emoji: "🔥", action: "use"     },
                { q: 0.6, u: "h",  spec: "labour",     emoji: "🧑‍🍳", action: "work"    }],
          // the kitchen leaves organic waste behind — the secondary output the waste hole below takes
          out: [{ q: 4, u: "each", spec: "meal", emoji: "🍲", action: "produce", primary: true },
                { q: 0.5, u: "kg", spec: "organic-waste", emoji: "🍂", action: "produce", primary: false }] },
      ],
    }, {
      // a HOLE (knowledge/holes.scm): waste management known by its boundary alone — organic
      // waste in, compost out — until a recipe for it is written. It closes the garden's loop.
      id: "rp-waste-hole", name: "Waste management", emoji: "♻️", produces: "compost",
      need: "nourishment/cooking",
      // fragile: the pile held through the mild weeks and then failed faster
      // with every degree — harm that accelerates. Under the heat live right
      // now (stress 8) its record shows 40% of what the weather allows, and
      // the plan leans on it by that much.
      ...DEMO_STANDING["rp-waste-hole"],
      steps: [
        { name: "Waste management", emoji: "♻️", hours: 1.5, tags: ["hole", "waste-management"],
          in:  [{ q: 10, u: "kg", spec: "organic-waste", emoji: "🍂", action: "consume" }],
          out: [{ q: 4,  u: "kg", spec: "compost",       emoji: "🍂", action: "produce", primary: true }] },
      ],
    }, {
      id: "rp-garden-greens", name: "Garden greens", emoji: "🥬", produces: "vegetables",
      need: "nourishment/cooking",
      // two runs in, both under drought: observed — its record reaches
      // stress 5 — with a curve the plan already reads, and one level short
      // of a bend to put a word to.
      ...DEMO_STANDING["rp-garden-greens"],
      steps: [
        { name: "Sow & tend", emoji: "🌱", hours: 0.8,
          in:  [{ q: 1,   u: "pack", spec: "seed",   emoji: "🫘", action: "consume" },
                { q: 20,  u: "L",    spec: "water",  emoji: "🚰", action: "consume" },
                { q: 0.6, u: "h",    spec: "labour", emoji: "🧑‍🌾", action: "work"    }],
          out: [{ q: 1, u: "plot", spec: "grown-plot", emoji: "🌿", action: "produce", primary: true }] },
        { name: "Harvest", emoji: "🧺", hours: 0.4,
          in:  [{ q: 1,   u: "plot", spec: "grown-plot", emoji: "🌿", action: "consume" },
                { q: 0.4, u: "h",    spec: "labour",     emoji: "🧑‍🌾", action: "work"    }],
          out: [{ q: 2, u: "kg", spec: "vegetables", emoji: "🥬", action: "produce", primary: true }] },
      ],
    }, {
      // the REAL dwelling recipe's demo twin (knowledge/recipes/dwelling.scm):
      // a bed `use`d for the night — count AND duration, nothing consumed —
      // the dwelling merely `cite`d (three beds, one flat), and the night of
      // shelter DELIVERED, never inventoried. No work flow: living-in is not
      // labour; housework and repairs are their own recipes.
      id: "rp-shelter-night", name: "A night's shelter", emoji: "🏠", produces: "shelter",
      need: "rest/shelter",
      steps: [
        { name: "The night", emoji: "🌙", hours: 8,
          in:  [{ q: 1, u: "bed", spec: "bed",    emoji: "🛏️", action: "use"  },
                { q: 1, u: "",      spec: "dwelling", emoji: "🏠", action: "cite" }],
          out: [{ q: 1, u: "person-night", spec: "shelter", emoji: "🏠",
                  action: "deliver-service", primary: true }] },
      ],
    }, ...DEMO_WORK_RECIPES];

// ── the LIVED record, offline: who else has worked these recipes ────────────
// EconomicEvents by other people, dated RELATIVE to today (dayOff), so the
// demo's past stays a few days behind whatever day it is opened on. Live,
// the observer's own events replace these (ingestLived). They are what the
// block's "alongside" line reads: the same recipe, at other space-times.
export const DEMO_LIVED: (DayEvent & { dayOff: number })[] = [
  { label: "harvest", dayOff: -1, t0: 9.0, t1: 11.5, kind: "work", action: "work", tier: "lived",
    from: "Priya", recipeId: "rp-harvest-morning", spec: "picking",
    ...at("place:community-farm") },
  { label: "harvest", dayOff: -3, t0: 8.5, t1: 11.0, kind: "work", action: "work", tier: "lived",
    from: "Jonas", recipeId: "rp-harvest-morning", spec: "picking",
    ...at("place:north-field") },
  { label: "bake", dayOff: -1, t0: 5.0, t1: 7.0, kind: "work", action: "work", tier: "lived",
    from: "Sam", recipeId: "rp-bakery-morning", spec: "baking",
    ...at("place:bakery") },
  { label: "bake", dayOff: -2, t0: 5.0, t1: 7.5, kind: "work", action: "work", tier: "lived",
    from: "Lena", recipeId: "rp-bakery-morning", spec: "baking",
    ...at("place:bakery") },
  { label: "repair", dayOff: -2, t0: 15.0, t1: 17.0, kind: "work", action: "work", tier: "lived",
    from: "Ana", recipeId: "rp-repair-cafe", spec: "electronics-repair",
    ...at("place:repair-cafe") },
  { label: "bike repair", dayOff: -1, t0: 16.0, t1: 18.0, kind: "work", action: "work", tier: "lived",
    from: "Jonas", recipeId: "rp-bike-desk", spec: "bike-repair",
    ...at("place:hub") },
  { label: "garden tending", dayOff: -2, t0: 9.0, t1: 11.0, kind: "work", action: "work", tier: "lived",
    from: "Priya", recipeId: "rp-garden-tending", spec: "growing",
    ...at("place:community-garden") },
  { label: "shelving", dayOff: -4, t0: 10.0, t1: 12.0, kind: "work", action: "work", tier: "lived",
    from: "Ana", recipeId: "rp-shelving", spec: "shelving",
    ...at("place:city-library") },
];

// ── the communes the picker offers offline ──────────────────────────────────
// Live, the gateway's scope-list fills this in. Empty (offline), these keep the
// selector explorable before connecting.

export const DEMO_SCOPES: ScopeRef[] = [
  { id: "E_commune_Berlin", name: "Berlin/Brandenburg",
    path: [{ id: "germany", name: "Germany" }, { id: "berlin", name: "Berlin/Brandenburg" }] },
  { id: "E_commune_SF", name: "San Francisco",
    path: [{ id: "usa", name: "USA" }, { id: "california", name: "California" }, { id: "bay-area", name: "Bay Area" }, { id: "san-francisco", name: "San Francisco" }] },
  { id: "E_commune_Oakland", name: "Oakland",
    path: [{ id: "usa", name: "USA" }, { id: "california", name: "California" }, { id: "bay-area", name: "Bay Area" }, { id: "oakland", name: "Oakland" }] },
];

// ── per-scope plans ─────────────────────────────────────────────────────────
// With no gateway to re-solve, switching a commune would not reshape the plan on
// its own. Each demo commune gets a distinct one so the flow is visibly
// scope-reactive locally: same-bioregion communes share a topology (Bay Area /
// SF / Oakland = a Mediterranean veg→meal chain, with their own coverage), a
// different bioregion gets a different one (Berlin/Brandenburg = a deeper
// cool-temperate rye→bread chain). LIVE this is dead weight — the gateway
// snapshot ingest drives the real per-scope solve.

export const DEMO_RECIPES_DE: ScopeRecipe[] = [
  { id: "rp-sourdough", name: "Sourdough loaf", emoji: "🍞", produces: "bread", need: "nourishment/bread",
    // a gain under stress — the dearer the flour, the more the loaf gains on
    // it — and licensed: a flour-price regime claim of thin tails and a stable
    // process stands over this domain, so the acceleration carries a standard
    // error rather than standing as bare description.
    ...DEMO_STANDING["rp-sourdough"],
    steps: [
      { name: "Bake", emoji: "🔥", hours: 1.0,
        in:  [{ q: 0.5, u: "kg", spec: "flour", emoji: "🌾", action: "consume" },
              { q: 0.35, u: "L", spec: "water", emoji: "🚰", action: "consume" },
              { q: 1,   u: "",  spec: "oven",  emoji: "🔥", action: "use"     },
              { q: 1.0, u: "h", spec: "labour", emoji: "🧑‍🍳", action: "work"  }],
        out: [{ q: 2, u: "each", spec: "bread", emoji: "🍞", action: "produce", primary: true }] }] },
  { id: "rp-stone-mill", name: "Stone mill", emoji: "⚙️", produces: "flour", need: "nourishment/milling",
    steps: [
      { name: "Mill", emoji: "⚙️", hours: 0.3,
        in:  [{ q: 0.6, u: "kg", spec: "rye-grain", emoji: "🌾", action: "consume" },
              { q: 1,   u: "",   spec: "millstone", emoji: "🪨", action: "use"     },
              { q: 0.3, u: "h",  spec: "labour",    emoji: "🧑‍🌾", action: "work"  }],
        out: [{ q: 0.5, u: "kg", spec: "flour", emoji: "🌾", action: "produce", primary: true }] }] },
  { id: "rp-rye-field", name: "Rye field", emoji: "🌾", produces: "rye-grain", need: "nourishment/grain",
    steps: [
      { name: "Sow & tend", emoji: "🌱", hours: 0.9,
        in:  [{ q: 1,   u: "pack", spec: "rye-seed", emoji: "🫘", action: "consume" },
              { q: 25,  u: "L",    spec: "water",    emoji: "🚰", action: "consume" },
              { q: 0.9, u: "h",    spec: "labour",   emoji: "🧑‍🌾", action: "work"  }],
        out: [{ q: 1, u: "plot", spec: "rye-plot", emoji: "🌿", action: "produce", primary: true }] },
      { name: "Thresh", emoji: "🌾", hours: 0.5,
        in:  [{ q: 1,   u: "plot", spec: "rye-plot", emoji: "🌿", action: "consume" },
              { q: 0.5, u: "h",    spec: "labour",   emoji: "🧑‍🌾", action: "work"  }],
        out: [{ q: 0.6, u: "kg", spec: "rye-grain", emoji: "🌾", action: "produce", primary: true }] }] },
  ...DEMO_WORK_RECIPES,
];

export const DEMO_NEEDS_CA: DemoNeed[] = [
  { id: "rest/sleep",          label: "rest",           emoji: "🛏️", met: 0.95, want: 8, recipeId: null,               runs: 0,  labourH: 0   },
  { id: "nourishment/meals",   label: "meals",          emoji: "🍲", met: 0.78, want: 3, recipeId: "rp-cooked-meal",  runs: 12, labourH: 7.2 },
  { id: "nourishment/cooking", label: "fresh veg",      emoji: "🥬", met: 0.90, want: 2, recipeId: "rp-garden-greens", runs: 30, labourH: 18  },
  { id: "movement/commute",    label: "getting around", emoji: "🚗", met: 0.55, want: 1, recipeId: null,               runs: 0,  labourH: 6   },
  { id: "learning/skills",     label: "learning",       emoji: "📚", met: 0.40, want: 1, recipeId: null,               runs: 0,  labourH: 3   },
];

export const DEMO_NEEDS_DE: DemoNeed[] = [
  { id: "rest/sleep",       label: "rest",           emoji: "🛏️", met: 0.90, want: 8, recipeId: null,          runs: 0, labourH: 0 },
  { id: "nourishment/bread", label: "bread",         emoji: "🍞", met: 0.72, want: 4, recipeId: "rp-sourdough", runs: 9, labourH: 9 },
  { id: "shelter/warmth",   label: "warmth",         emoji: "🔥", met: 0.58, want: 1, recipeId: null,          runs: 0, labourH: 4 },
  { id: "movement/commute", label: "getting around", emoji: "🚋", met: 0.48, want: 1, recipeId: null,          runs: 0, labourH: 5 },
  { id: "learning/skills",  label: "learning",       emoji: "📚", met: 0.50, want: 1, recipeId: null,          runs: 0, labourH: 3 },
];

// ── the demo DAY ────────────────────────────────────────────────────────────
// The three server-truth lists as they stand with nothing connected — the
// day the calendar paints standalone, in exactly the shapes the wire sends
// (events.ts seeds its live-mutated arrays from copies of these):
//   evs        the day's own EconomicEvents-to-be
//   proposals  Intents directed at you — work names its skill (`spec`), the
//              planner key willingness is offered over; the bed is the
//              AUTOMATCH surfaced for consent (nobody is moved by a plan
//              they didn't say yes to)
//   eligible   the catchment intersect: slots you could raise a hand into
export const DEMO_DAY: { evs: DayEvent[]; proposals: DayEvent[]; eligible: DayEvent[] } = {
  evs: [
    { label: "breakfast",     t0: 6.75,  t1: 8.0,   kind: "free", lane: 0,
      action: "consume", serves: "nourishment", ...at("place:home") },
    { label: "harvest shift", t0: 9.5,   t1: 12.0,  kind: "work", lane: 0,
      action: "work", serves: "nourishment", ...at("place:community-farm"),
      spec: "picking", recipeId: "rp-harvest-morning",
      needs: [{ kind: "use", name: "hand-tools", label: "hand tools", qty: 1, unit: "set", met: "held" },
              { kind: "use", name: "crate", label: "crates", qty: 6, unit: "each", met: "held" },
              { kind: "work", name: "picking", label: "picking", qty: 2.5, unit: "hours", met: "held" }] },
    { label: "lunch w/ Ana",  t0: 13.0,  t1: 14.25, kind: "free", lane: 0,
      action: "consume", serves: "connection", ...at("place:corner-cafe") },
    { label: "repair café",   t0: 15.0,  t1: 16.5,  kind: "work", lane: 0,
      action: "work", serves: "movement", ...at("place:repair-cafe"),
      spec: "electronics-repair", recipeId: "rp-repair-cafe",
      needs: [{ kind: "use", name: "workbench", label: "workbench", met: "held" },
              { kind: "use", name: "solder-iron", label: "soldering iron", met: "held" },
              { kind: "consume", name: "solder", label: "solder", qty: 20, unit: "g", met: "held" },
              { kind: "consume", name: "spare-part", label: "spare parts", qty: 3, unit: "each", met: "unknown" },
              { kind: "work", name: "repairing", label: "repairing", qty: 1.5, unit: "hours", met: "held" }] },
    { label: "school run",    t0: 16.0,  t1: 17.25, kind: "free", lane: 1,
      action: "deliver-service", serves: "connection", ...at("place:school"),
      spec: "cargo-bike-rider", recipeId: "rp-school-run" },
    { label: "band practice", t0: 19.25, t1: 21.25, kind: "free", lane: 0,
      action: "use", serves: "learning", ...at("place:rehearsal-rooms") },
  ],
  proposals: [
    { label: "bakery shift w/ Sam", t0: 5.0,  t1: 7.0,  kind: "work", lane: 1,
      action: "work", serves: "nourishment", from: "Sam", status: "proposed", spec: "baking",
      ...at("place:bakery"), recipeId: "rp-bakery-morning",
      needs: [{ kind: "use", name: "oven", label: "wood oven", met: "held" },
              { kind: "consume", name: "flour", label: "rye flour", qty: 6, unit: "kg", met: "held" },
              { kind: "consume", name: "starter", label: "sourdough starter", qty: 0.5, unit: "kg", met: "missing" },
              { kind: "work", name: "baking", label: "baking", qty: 2, unit: "hours", met: "held" }] },
    { label: "tool-library duty",   t0: 14.0, t1: 15.0, kind: "work", lane: 1,
      action: "work", serves: "movement", from: "the commons", status: "proposed", spec: "tool-care",
      ...at("place:tool-library"), recipeId: "rp-tool-library" },
    { label: "evening picnic",      t0: 18.0, t1: 19.0, kind: "free", lane: 1,
      action: "use", serves: "connection", from: "Ana", status: "proposed",
      ...at("place:borisova-gradina") },
    { label: "a bed at Ana's guest room", t0: 21.0, t1: 23.75, kind: "free", lane: 1,
      action: "use", serves: "rest", from: "the plan", status: "proposed",
      ...at("place:ana-home") },
  ],
  eligible: [
    { label: "library shelving", t0: 10.0, t1: 12.0, kind: "work", action: "work",
      serves: "learning", skill: "shelving", from: "open slot", recipeId: "rp-shelving",
      ...at("place:city-library") },
    { label: "community garden", t0: 9.0,  t1: 11.0, kind: "work", action: "work",
      serves: "nourishment", skill: "growing", from: "open slot", recipeId: "rp-garden-tending",
      ...at("place:community-garden"),
      needs: [{ kind: "use", name: "gloves", label: "gloves", qty: 1, unit: "pair", met: "held" },
              { kind: "use", name: "hoe", label: "hoe", met: "held" },
              { kind: "consume", name: "compost", label: "compost", qty: 10, unit: "kg", met: "held" },
              { kind: "consume", name: "water", label: "water", qty: 40, unit: "L", met: "held" },
              { kind: "work", name: "growing", label: "growing", qty: 2, unit: "hours", met: "held" }] },
    { label: "bike repair desk", t0: 16.0, t1: 18.0, kind: "work", action: "work",
      serves: "movement", skill: "bike-repair", from: "open slot", recipeId: "rp-bike-desk",
      ...at("place:hub"),
      needs: [{ kind: "use", name: "bike-stand", label: "bike stand", met: "held" },
              { kind: "use", name: "track-pump", label: "track pump", met: "held" },
              { kind: "consume", name: "inner-tube", label: "inner tubes", qty: 2, unit: "each", met: "missing" },
              { kind: "consume", name: "brake-pads", label: "brake pads", qty: 1, unit: "pair", met: "held" },
              { kind: "work", name: "bike-repair", label: "bike repair", qty: 2, unit: "hours", met: "held" }] },
  ],
};

export const DEMO_SCOPE_PLAN: Record<string, DemoScopePlan> = {
  E_commune_Berlin:  { region: "de", scope: "Berlin/Brandenburg", coverage: 0.69 },
  E_commune_SF:      { region: "ca", scope: "San Francisco",      coverage: 0.71, met: { "nourishment/cooking": 0.62 } },
  E_commune_Oakland: { region: "ca", scope: "Oakland",            coverage: 0.75, met: { "nourishment/meals": 0.86, "movement/commute": 0.66 } },
};

// ── bioregional clusters ────────────────────────────────────────────────────
// Each a small {root, plots} cluster at absolute coords inside a REAL bioregion
// (a matching feature in data/geo/boundaries.json). regionalize point-in-polygons
// them into their shed and draws its true polygon. Add one plus its boundary
// feature — done.

export const DEMO_BIOREGION_SCOPES: DemoCluster[] = [
  { // Doon Valley (India) — a Navdanya-style farm
    root:  { id: "doon-farm", name: "Navdanya farm", lat: 30.340, lng: 78.050, desire: 0.70 },
    plots: [ { id: "doon-rice-terrace",   name: "rice terrace",   lat: 30.345, lng: 78.056, desire: 0.48 },
             { id: "doon-millet-terrace", name: "millet terrace", lat: 30.335, lng: 78.044, desire: 0.86 } ] },
  { // Cascadia (Pacific NW) — a bioregional commune
    root:  { id: "cascadia-commune", name: "Cascadia commune", lat: 45.520, lng: -122.680, desire: 0.62 },
    plots: [ { id: "cascadia-orchard", name: "orchard",        lat: 45.550, lng: -122.620, desire: 0.80 },
             { id: "cascadia-fishery", name: "salmon fishery", lat: 45.480, lng: -122.760, desire: 0.40 } ] },
];
