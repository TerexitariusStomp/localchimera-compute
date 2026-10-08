// app/layers.ts — the canvas: one svg, and the stack of layers on it.
//
// THE ORDER OF THIS FILE IS THE Z-ORDER. SVG paints in document order, so the
// sequence of appends below is the design decision it looks like it isn't: the
// globe is beneath the bands ALWAYS (which is what lets the earth's reveal fade
// pigment off a planet that was already there rather than build one), the
// chrome sits over the bands it annotates, and the flat faces sit over
// everything because they replace the dial rather than decorate it.
//
// ── LAYERS ARE A FACT, NOT A DECISION ───────────────────────────────────────
// Seven modules draw into these, and each used to be HANDED its own subset
// through init — four different shapes of the same argument. They are read
// here instead, the way `stage` is read: nothing chooses which layer the hand
// draws into, so nothing should have to be told.
//
// ── POINTER EVENTS ARE PART OF THE STACK ────────────────────────────────────
// A layer above the bands would swallow the clicks meant for them, so every
// purely-decorative layer is `pointer-events: none` and switches it back on
// only for the one element that is a target (the hand's grab node is the
// example). That is why the flag is set HERE, with the ordering it depends on,
// rather than at each drawer.

import { S } from './state.js';
import { U, R } from './geom.js';

/** The dial's root. Faces read the viewBox off it; none of them resizes it. */
export const svg = d3.select("#dial")
  .attr("viewBox", [-S.VE * U, -S.VE * U, 2 * S.VE * U, 2 * S.VE * U].join(" "))
  .attr("width", 2 * S.VE * U).attr("height", 2 * S.VE * U);

/** A decorative layer: drawn over the bands, never in the way of them. */
const inert = (): d3.Selection => svg.append("g").attr("pointer-events", "none");
/** A flat face's layer: hidden until its face takes the stage, and then it IS the stage. */
const flat = (): d3.Selection =>
  svg.append("g").attr("display", "none").attr("pointer-events", "all");

/** Every layer on the dial, in the order it paints. */
export const L = {
  /** The earth — beneath the bands, always. */
  globe:    svg.append("g"),
  bands:    svg.append("g"),
  seams:    svg.append("g"),
  /** The hover preview, and the anticipation-lead marks. */
  prev:     inert(),
  spiral:   inert(),
  chords:   inert(),
  /** Ancestor context. Empty since the crumb took navigation over; the map fades it. */
  rings:    svg.append("g"),
  /** Rim + τ marks. */
  chrome:   inert(),
  hand:     inert(),
  /** The social work↔free ring, in the lane the personal events dissolve out of. */
  toil:     inert(),
  events:   svg.append("g"),
  /** The two editable rings: availability (blue) and your own events (yellow). */
  avail:    svg.append("g"),
  myEvents: svg.append("g"),
  /** Earth mode: the bearing annulus and its cardinal marks. */
  earth:    svg.append("g"),
  centre:   svg.append("g"),
  /** The globe's gradients and clip. Position is immaterial; order is not. */
  defs:     svg.append("defs"),
  // ── the flat faces, over everything ──────────────────────────────────────
  /** The ecological substance-flow Sankey. */
  rift:     flat(),
  /** The burden choropleth. */
  law:      flat(),
  /** The two fragility wheels. */
  frag:     flat(),
};

/**
 * The bearing threads, on their own svg over the map.
 *
 * A separate element because it has to sit ABOVE the map's canvas while the
 * dial's own svg sits behind it — one stack cannot hold both.
 */
export const threads = d3.select("#threads")
  .attr("viewBox", [-S.VE * U, -S.VE * U, 2 * S.VE * U, 2 * S.VE * U].join(" "));

// Every layer wears its own name in the DOM.
//
// The record above is the only place these layers are named, and that name was
// invisible from the browser: in devtools, and to anything reading the page
// from outside, the stack was twenty anonymous <g>s distinguishable only by
// counting. So a bug report pointing INTO the dial could say no more than
// "#dial > g:nth-of-type(18)", and the reader had to come back here and count
// to eighteen to learn it meant the fragility wheel.
//
// A data attribute rather than a class, deliberately: nothing styles these
// layers by class today, and stamping one would invite a stylesheet to start —
// which would make this name load-bearing for appearance rather than purely a
// label. Derived from the key so it cannot drift from the record.
for (const [name, layer] of Object.entries(L)) layer.attr("data-layer", name);

/**
 * The rim: where the τ chrome ends and the event lanes may begin.
 *
 * Constant since the ancestor rings stopped being drawn — the chrome hugs the
 * rim at every depth now, rather than being pushed out by the levels above.
 */
export const outerEdge = (): number => R;

/**
 * Re-fit the viewBox so nothing is ever clipped.
 *
 * The extent breathes with the dial: rim, chrome, and the two event lanes must
 * all fit. Both svgs get the same box, because the threads are drawn in the
 * dial's own coordinates and would otherwise drift off it.
 */
export function setViewExtent(): void {
  S.VE = outerEdge() + 1.58;      // base 0.66 past the rim + two wide lanes + air
  const vb = [-S.VE * U, -S.VE * U, 2 * S.VE * U, 2 * S.VE * U].join(" ");
  svg.attr("viewBox", vb);
  threads.attr("viewBox", vb);
}

/**
 * The layers the TIME face draws into — every one of them, hidden wholesale by
 * any other face.
 *
 * The two editable rings are in the list because they are the time face's
 * alone: an availability arc and your own event are read against the clock, and
 * a flat face has no clock to read them against.
 */
export const timeLayers = (): d3.Selection[] =>
  [L.globe, L.bands, L.seams, L.prev, L.spiral, L.chords, L.rings, L.chrome,
   L.hand, L.toil, L.events, L.avail, L.myEvents, L.earth, L.centre];
