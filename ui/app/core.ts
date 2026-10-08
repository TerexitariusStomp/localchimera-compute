// app/core.ts — the shared ground: the state and constants every face reads.
//
// These lived in main.js, which made every panel that needed one of them import
// the whole dial — and main.js imports the panels back. That mutual import is
// why a panel could not run an effect at module scope (main.js's bindings are
// still in their temporal dead zone while a panel it imports is evaluating), and
// why cross-module redraws had to go through `window.drawX` globals instead of
// an import. Nothing here imports a face, so a face importing THIS is a leaf
// edge, not a cycle.
//
// What belongs here: state and constants with no behaviour of their own. What
// does NOT: the dial's rendering surface (svg, gLaw, gFrag, the d3 groups) and
// the event model (evs, commit/decline, the rings) — those are main.js's own,
// and the faces that need them are still coupled to it on purpose.
//
// main.js re-exports every one of these, so `import { EXT } from './main.js'`
// keeps working; new code should import from here.

import { venuesByLeaf } from './demo/world.js';
import { seam } from './seam.js';
import { signal } from './reactive.js';
import { toast } from './toast.js';
import type { Plan } from './seam.js';
import type { ToastKind } from './toast.js';
import type { LatLng } from './geom.js';
import { CREDIT } from './palette.js';

/** How a located resource reads, and what act it affords. */
export type ModeKey = "own" | "claim" | "common" | "work";

export interface Mode {
  label: string;
  col: string;
  /** The act it affords, or null where it simply IS yours / the commons'. */
  act: string | null;
}

/** An offset from the user, not an absolute spot — the demo fabric of places
 *  assembles around wherever you are. */
export interface Offset {
  dLat: number;
  dLng: number;
}

/** A slot at a SpatialThing (schemas.scm), placed relative to you. */
export interface Place extends Offset {
  name: string;
  emoji: string;
  /** When it is open, in the demo's own words ("now", "12–15h", "always"). */
  when: string;
  mode: ModeKey;
  /** The id of the place it is at, where the table names one. */
  place?: string;
  /**
   * The same thing as `when`, MACHINE-READABLE: hours of the turn as [from, to)
   * pairs. Stamped at boot from the demo's opening-hours table; absent means
   * open all turn, which is what every reader falls back to.
   */
  open?: [number, number][];
}

/** A walking ring around you, labelled in fractions of the turn. */
export type IsoRing = [minutes: number, label: string];

// `day` is a notifier signal: the day's events/proposals are deep-mutated in
// place (p.status = …), so instead of per-field signals we bump this whenever
// the day changes and let the panel effects (see initDay) re-render. Actions
// and ingest call markDayChanged() rather than hard-coding which views redraw.
const day = signal(0);
const markDayChanged = () => day.update(n => n + 1);

// Standalone, the demo data below carries the design unchanged.
const EXT = (seam.data = seam.data || {});
const HANDLERS = (seam.handlers = seam.handlers || {});

/**
 * Ask the gateway for JSON, or take the fallback.
 *
 * Every handler answers a STRING, so every reader parses — and every reader
 * needs the same three misses to read alike: no gateway configured (the handler
 * is absent), the gateway reached and refused (the promise rejects), and a
 * reply that is not JSON. All three mean "the commons did not answer", and a
 * face that draws its empty state is right in all three.
 *
 * Pass a THUNK rather than the handler itself, so `?.()` does the absence check
 * and the call stays bound to HANDLERS:
 *
 *     const props = await askJSON(() => HANDLERS.listProposals?.(), []);
 *     const r     = await askJSON(() => HANDLERS.getResult?.(id), null);
 */
export async function askJSON<T>(ask: () => Promise<unknown> | undefined, fallback: T): Promise<T> {
  try {
    const reply = await ask();
    return reply === undefined ? fallback : (JSON.parse(String(reply)) as T);
  } catch (_) {
    return fallback;
  }
}

// ------------------------------------------------------- where on earth
// every leaf need is met SOMEWHERE: EconomicResources / open slots at
// SpatialThings (schemas.scm), as in treemap.html's spatial layer.
// San Francisco (the routing atlas's home extent — SF + Berlin tiles) until
// geolocation says otherwise, so live directions resolve on real roads from
// the default position instead of straight-lining outside the tileset.
const USER: LatLng & { label: string } = { lat: 37.7749, lng: -122.4194, label: "you" };
// offsets from the user, not absolute spots: wherever you are, the demo
// fabric of places assembles around you (geolocation recenters everything)
const ploc = (dLat: number, dLng: number): Offset => ({ dLat, dLng });
const pcoord = (p: Offset): LatLng => ({ lat: USER.lat + p.dLat, lng: USER.lng + p.dLng });

/**
 * THE DIAL'S THREE FIXED INKS.
 *
 * Everything else the dial paints is per-identity and comes from
 * app/palette.ts, which is the point: these three are NOT identities. They are
 * states of a commitment — deep for the ground the bands sit on, warm for work,
 * yellow for a thing you have said yes to — so they mean the same on the clock
 * face, in the week grid and on the map, and a reader learns them once.
 *
 * Held here rather than in main because three surfaces read them, and the third
 * one to want them would otherwise have copied the hex.
 */
export const cDeep = "#2c4a6e", cWarm = "#1581a8", cYea = "#e2a512";

// mode — the doc's "priority weights span both rails" extended by the skill
// rail. Each mode is the single source of truth for how a resource reads and
// what act it affords. `own`/`claim`/`common` are means-of-consumption you
// RECEIVE; `work` is the skill rail — a work-intent you GIVE willingness to.
const MODES: Record<ModeKey, Mode> = {
  own:    { label: "yours",       col: "#6a8aaa", act: null },                 // your own resource
  claim:  { label: "credit",      col: CREDIT,    act: "claim" },              // individual-claimable
  common: { label: "commons",     col: "#2e7d32", act: null },                 // communal
  work:   { label: "work-intent", col: "#1581a8", act: "offer willingness" },  // skill → labour
};
// place/slot at a SpatialThing (schemas.scm). `mode` keys MODES above.
// PLACES is keyed by classification id — the same taxonomy id the dial

// prioritises over, so a band opens straight onto its located resources.
// The table is the demo world's venues (demo/world.ts), each standing where its
// place stands and naming that place, so a place on the map is a place the store
// holds stock at.
const PLACES: Record<string, Place[]> = venuesByLeaf();

// availability window (set-availability) via HANDLERS.setAvailability, so the
// matcher only offers you work that intersects your hours. localStorage is the
// live buffer (works offline / gateway away); a debounced sync pushes to the
// gateway when connected. v1 renders + edits in the steady DAY view only.
const AV_DAYS: string[] = ["monday","tuesday","wednesday","thursday","friday","saturday","sunday"];
const AV_LBL: string[] = ["M","T","W","T","F","S","S"];

// accessible ink: choose dark or white text by the luminance of what it
// sits on, and halo it with the opposite — readable on every band colour
const lum = (c: string): number => { const { r, g, b } = d3.rgb(c); return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255; };
const inkFor = (bg: string): string => lum(bg) > 0.55 ? "#1b1b1b" : "#ffffff";
const haloFor = (ink: string): string => ink === "#ffffff" ? "rgba(0,0,0,0.45)" : "rgba(255,255,255,0.8)";
/**
 * Paint a <text> in `ink` and ring it with the opposing halo.
 *
 * `paint-order: stroke` is what makes this a halo rather than an outline: the
 * stroke lands UNDER the fill, so the letterform stays its own shape and only
 * gains a rim. Every label the dial draws over a coloured band goes through
 * here, which is why they stay readable wherever the band happens to be.
 */
const haloed = (sel: d3.Selection, ink: string, fs: number): d3.Selection => sel
  .attr("fill", ink)
  .attr("stroke", haloFor(ink)).attr("stroke-width", fs * 0.16)
  .attr("stroke-linejoin", "round").attr("paint-order", "stroke");


// THE SEAM: a scope's PLAN arrives from the planner (live.scm / plan-scope) as
// EXT.plan — for each need, how met it is and the recipe + labour that fills it,
// plus the scope-wide totals (the solve's ledger). Until then a hand-seeded
// plan stands in. The plan is the bridge from the dial's DESIRE (needs) to the
// recipes that provision them: need ↦ recipe ↦ work. Mutable: a scope switch
// re-feeds it through the "plan" topic.
const PLAN = signal<Plan>((seam.data.plan) || {
  scope: "neighbourhood commons",
  needs: [
    { id: "rest/sleep", label: "rest", emoji: "🛏️", met: 0.95,
      recipeId: null, runs: 0, labourH: 0, suggested: [], willing: 0 },
    // housing rides the same plan rail: the shelter recipe's runs are nights,
    // and the suggestion is the socialized bed the solve matched you to —
    // the acceptance is the proposal it minted (the rim's "a bed at Ana's")
    { id: "rest/shelter", label: "housing", emoji: "🏠", met: 0.67,
      recipeId: "rp-shelter-night", runs: 2, labourH: 0,
      suggested: ["Ana's guest room"], willing: 1 },
    { id: "nourishment/meals", label: "meals", emoji: "🍲", met: 0.78,
      recipeId: "rp-cooked-meal", runs: 12, labourH: 7.2, suggested: ["Ana", "Priya"], willing: 2 },
    { id: "nourishment/cooking", label: "fresh veg", emoji: "🥬", met: 0.90,
      recipeId: "rp-garden-greens", runs: 30, labourH: 18, suggested: ["Sam"], willing: 1 },
    { id: "movement/commute", label: "getting around", emoji: "🚗", met: 0.55,
      recipeId: null, runs: 0, labourH: 6, suggested: [], willing: 0 },
    { id: "learning/skills", label: "learning", emoji: "📚", met: 0.40,
      recipeId: null, runs: 0, labourH: 3, suggested: [], willing: 0 },
  ],
  produced: [{ emoji: "🍲", q: 48, u: "each" }, { emoji: "🥬", q: 60, u: "kg" }],
});

// over the satellite: walking rings around you, labelled in fractions of
// the turn — the radius IS time again — and a thread from each marker to
// its annulus arc: solid if you would arrive within its open window
// setting out NOW on foot, dashed if you would knock on a shut door.
const ISO: IsoRing[] = [[15, "τ∕96 · 15 m"], [45, "τ∕32 · 45 m"]];   // minutes walking

// hover pedagogy is gone — the selection detail card under the dial does the
// talking. hint() carries the REPLIES: what the gateway just said about a thing
// you did. It writes the voice-state line beside the mic (the time face's own
// running commentary) and raises a toast (app/toast.js), which speaks over
// whichever face you are on — the log, the shop, the map. `kind` is "notice",
// "success", "warn" or "error"; sites that know which one they hold say so.
function hint(s: string | null | undefined, kind?: ToastKind): void {
  // the orb owns its line while it listens, transcribes or thinks (voice/orb.ts)
  if (d3.select("#voicerow.busy").empty()) d3.select("#voicestate").text(s || "hold to speak");
  if (s) toast(s, kind);
}

export { day, markDayChanged, EXT, HANDLERS, USER, ploc, pcoord,
         MODES, PLACES, AV_DAYS, AV_LBL, lum, inkFor, haloFor, haloed, PLAN, ISO, hint,
         toast };
