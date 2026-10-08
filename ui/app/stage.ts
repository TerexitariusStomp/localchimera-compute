// app/stage.ts — how the dial is ARRANGED right now.
//
// state.ts holds what the dial is SHOWING — the turn, the tree, σ. This holds
// how it is arranged to show it: which face owns the stage, whether the angle
// means an hour or a bearing, what the earth is lensed through, and where the
// hand stands. Same reason, same shape: a value written from one module and
// read from six cannot be an exported `let`, because an importer may not
// assign one.
//
// ── WHY THIS EXISTS, AND WHAT IT REPLACED ───────────────────────────────────
// Nine modules were being handed these four values through nine HOST
// interfaces, and main answered "am I on the earth?" identically in five of
// them. A host is the right shape for a question only the dial can answer about
// ITSELF — what to redraw, where to fly, what a tap means. It is the wrong
// shape for a fact, and these are facts. Every host member that just forwarded
// one of them is gone.
//
// Keep this small, on state.ts's own rule: a field belongs here only when it is
// genuinely written from one place and read from several.


/**
 * dial or earth — and it is the ANGLE'S MEANING that changes, not merely the
 * artwork. On the dial an angle is an hour of the turn; on the earth it is a
 * compass bearing from where you stand.
 */
import type { DesireNode } from './desire.js';
import type { Sample } from './bands.js';

import type { DayEvent } from './seam.js';
/**
 * Where the dial stands.
 *
 * "exiting" is a real third state, not a moment: while the dial rises out of
 * the map it is neither on the earth nor back on the wheel, and it reports so
 * for that whole stretch. The chrome and the ribbons read it and go back to
 * speaking in τ on the way up, rather than snapping from bearings to hours at
 * the very end of the animation. Both `onEarth()` and the earth-only branches
 * read false during it, which is exactly what is wanted.
 */
export type DialMode = "dial" | "earth" | "exiting";

/**
 * The classification the earth is lensed through: its id, its label and its
 * ink. `MAP_ALL` is the unlensed sentinel that stands here for the map face,
 * where every place shows at once.
 */
// The open leaf is a taxonomy node — the very DesireNode the dial was showing
// when the earth opened, handed straight over. It was described here as its own
// structural shape for a while, which was one interface too many: the two never
// disagreed, and a module that compares `stage.leaf` to a band could not say so
// without a cast.

export interface StageState {
  mode: DialMode;
  /**
   * The ribbons the rim last drew, with their lane assignments — a READ hook.
   * The UX suites reach for it to check that overlapping events landed in
   * different lanes, which the rendered SVG cannot be asked directly.
   */
  evs?: DayEvent[];
  /**
   * Which face owns the stage — "time", "map", "law", "frag" and the rest of
   * STAGE_FACES. A plain string rather than a union: the ids come from main's
   * own registration table, which is where that union will belong once main
   * converts.
   */
  face: string;
  /** What the earth is lensed through, or null off it. */
  leaf: DesireNode | null;
  /**
   * Which band the earth was entered THROUGH, or -1. The reveal animation
   * interpolates from that band's wedge, so it has to be remembered rather
   * than recomputed — the tree may have been rebuilt since.
   */
  leafK: number;
  /**
   * Where the hand stands, in turn-hours. Not S.nowAbs: the hand can be
   * SCRUBBED away from now, and what "open now" means follows the hand rather
   * than the clock.
   */
  hand: number;
  /**
   * Whose children the dial is showing. The root at rest; a branch once you
   * have zoomed in; the leaf's PARENT while the earth is open, which is what
   * keeps a leaf's siblings one tap away on the priority bar.
   */
  focus: DesireNode;
  /**
   * That focus's live layout — the band edges and met marks at every sample of
   * the turn. Written by the wheel and read by everything that stands on it:
   * the hand reads the shares it crosses, the bar unrolls the same slice, the
   * reveal interpolates from it, a rescale morphs it in place.
   */
  cums: Sample[];
  /**
   * An animation owns the dial: a zoom, a reveal, a rescale. Every gesture
   * waits it out rather than racing it, so this is asked far more often than it
   * is set — which is why it lives here rather than behind four host members
   * that all answered the same question.
   */
  zooming: boolean;
}

export const stage: StageState = {
  mode: "dial",
  face: "time",
  leaf: null,
  leafK: -1,
  hand: 6.0,
  // `focus` is null only between this module's evaluation and the first
  // buildRoot — nothing reads the dial before there is a tree to read. Typed
  // non-null so that fact is stated once, here, rather than asserted at fifty
  // call sites.
  focus: null as unknown as DesireNode,
  cums: [],
  zooming: false,
};

/** Whether the earth is up — the angle means a bearing. */
export const onEarth = (): boolean => stage.mode === "earth";

/**
 * Whether the MAP face owns the stage.
 *
 * Distinct from onEarth, and the distinction is load-bearing: the map face is a
 * RECTANGLE with no disc geometry, while the earth reached by drilling a desire
 * band is a circular disc welded to the dial. Both are `mode === "earth"`; only
 * one of them has a dial around it.
 */
export const onMapFace = (): boolean => onFace("map");

/**
 * Whether `id` is the face that owns the stage.
 *
 * Ask the RECORD, not the paint. `setFace` writes `stage.face` and then dresses
 * the DOM to match — the `on` class on a rail, an overlay's `.on`, a layer's
 * `display` — so a module that reads its own `#…Secs.on` is reading the shadow
 * of this answer rather than the answer. Equivalent while they agree, and one
 * of them is the thing that decides.
 */
export const onFace = (id: string): boolean => stage.face === id;
