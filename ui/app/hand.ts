// app/hand.ts — the hand, and the time you can walk with it.
//
// The hand is not a pointer laid over the dial: it IS the distribution. It is
// segmented exactly where it crosses the bands, each stretch in the colour of
// the need whose share it traverses, so reading along the radius reads your own
// prioritization at that instant. A white casing lifts it off the very bands it
// is quoting, and the segment colours run darker so they register against them.
//
// ── SCRUBBING: WALK TIME BY THE NODE ────────────────────────────────────────
// Grab the hand's end node and walk, sectograph-style. The wipe is fixed to the
// CLOCK and not to which way you drag: the future — clockwise, larger t — is
// always solid, and the past — the radian just behind the hand — always erases,
// fading to nothing one radian back where a dotted horizon marks the edge.
//
// Walk past 0/τ and the dial becomes the NEXT rotation: tomorrow's turn, not a
// re-loop of today. S.viewTurnOffset counts how many turns off "now" we have
// walked, so the date header above the dial names a real day rather than a
// phase. Tapping the node (a press with no drag) walks straight back to now,
// and so does a live tick or a rescale.
//
// ── ONE RADIAN IS THE UNIT ──────────────────────────────────────────────────
// The erasing tail is exactly one radian long, which is the dial's own claim
// about time made visible: the hand IS the radius, so laid back along the rim
// it spans 24/τ ≈ 3h49m. The "radian" toggle draws that construction — the arc,
// its tick and its label — directly on the face.

import { S } from './state.js';
import { U, PT, R, n, TAU, ang, xy, rad, clamp01 } from './geom.js';
import { stage } from './stage.js';
import { turnPos } from './turn.js';
import { drawEarthArcs } from './threads.js';
import { drawPriorityBar } from './pribar.js';
import { drawEvents } from './ribbons.js';
import { L } from './layers.js';

/** Turn-units in one radian — the length of the scrub's erasing tail. */
export const radHr = 24 / 6.2832;

/** What the hand needs the dial to answer. */
export interface HandHost {
  /** The hand moved: everything that follows the viewed instant, but is not it. */
  afterMove(now: number): void;
}

let host: HandHost;

// ── where the hand stands ───────────────────────────────────────────────────

/** The hand has walked off "now". */
let scrubbing = false;
/** Where it walked to, in units within the viewed turn (0..24). Null at home. */
let scrubU: number | null = null;

/** Is the hand off "now"? */
export const isScrubbing = (): boolean => scrubbing;

/** The instant the dial is showing: the scrubbed phase, or now. */
export const handNow = (): number => (scrubbing && scrubU != null) ? scrubU : turnPos();

/**
 * The scrub wipe at a turn-unit position: 1 solid, 0 fully erased.
 *
 * NO WRAP around the rim. Within the rendered turn an event later than the hand
 * is future and stays solid; earlier is past, erasing over the trailing radian
 * and gone beyond it. So the end of a turn empties out as the hand nears 0/τ,
 * and the next rotation fills in solid ahead of it — which is the point: the
 * dial is showing one turn of a continuous line, not a loop.
 */
export const scrubWin = (tmid: number | null): number => {
  if (!scrubbing || scrubU == null || stage.mode !== "dial" || tmid == null) return 1;
  const s = tmid - scrubU;             // linear within the turn, no ±12 wrap
  if (s >= 0) return 1;                // ahead in the turn (future): solid
  return clamp01(1 + s / radHr);       // behind (past): erase over one radian
};

/**
 * Let go of the scrub, leaving the viewed turn where it is.
 *
 * This is for a caller that is about to CHOOSE a turn — jumping to a date sets
 * its own offset, and homing the hand first would throw that away.
 */
export function stopScrub(): void {
  scrubbing = false;
  scrubU = null;
}

/**
 * Walk the hand back to now, without redrawing.
 *
 * A live tick and a rescale both call this: neither is a gesture, and leaving
 * the hand parked in a turn that has just changed length would be showing an
 * instant that no longer exists.
 */
export function homeHand(): void {
  stopScrub();
  S.viewTurnOffset = 0;
}

// ── the gesture ─────────────────────────────────────────────────────────────

/** Drag the end node to walk time; tap it to come home. */
const nodeDrag = d3.drag()
  .on("start", function (this: { __moved?: boolean }) { this.__moved = false; })
  .on("drag", function (this: { __moved?: boolean }, event: d3.DragEvent) {
    this.__moved = true;
    scrubbing = true;
    // gHand carries no transform → event.x/y are already centred user coords
    const a = Math.atan2(-event.y, event.x);
    let t = (Math.PI / 2 - a) / (TAU / 24);
    t = ((t % 24) + 24) % 24;
    if (scrubU != null) {                                      // a 0/τ crossing?
      if (scrubU > 18 && t < 6) S.viewTurnOffset += 1;         // into the next turn
      else if (scrubU < 6 && t > 18) S.viewTurnOffset -= 1;    // back into the previous
    }
    scrubU = t;
    drawHand(scrubU);
    drawEvents();
  })
  .on("end", function (this: { __moved?: boolean }) {
    if (this.__moved) return;          // a drag ends where it was left
    homeHand();                        // a tap on the node walks back to now
    drawHand(turnPos());
    drawEvents();
  });

// ── drawing ─────────────────────────────────────────────────────────────────

/** Draw the hand at turn-unit `now`, and everything that reads off it. */
export function drawHand(now: number): void {
  stage.hand = now;
  host.afterMove(now);
  if (stage.mode === "earth") drawEarthArcs();   // open/shut follows the hour
  L.hand.selectAll("*").remove();
  const na = ang(now);
  const [hx0, hy0] = xy(0.12, na), [hx1, hy1] = xy(R, na);

  L.hand.append("line").attr("x1", hx0).attr("y1", hy0).attr("x2", hx1).attr("y2", hy1)
    .attr("stroke", "#fff").attr("stroke-width", 3.4 * PT)
    .attr("stroke-linecap", "round").attr("opacity", 0.9);

  const hi = Math.max(0, Math.min(n, Math.round(now / 24 * n)));
  drawShares(na, stage.cums[hi].cum);
  drawNode(hx1, hy1);
  if (scrubbing && stage.mode === "dial") drawHorizon(now);
  drawPriorityBar(hi);        // the hand, unrolled: the same slice of now, flat
  if (d3.select("#radian").property("checked")) drawRadian(now, na);
}

/** The hand's segments: one per band it crosses, in that band's own colour. */
function drawShares(na: number, cs: number[]): void {
  (stage.focus.children || []).forEach((d, k) => {
    const r0 = Math.max(0.12, rad(cs[k])), r1 = rad(cs[k + 1]);
    if (r1 - r0 < 0.015) return;          // a sliver of a share: skip, not smear
    const [sx0, sy0] = xy(r0, na), [sx1, sy1] = xy(r1, na);
    L.hand.append("line").attr("x1", sx0).attr("y1", sy0).attr("x2", sx1).attr("y2", sy1)
      .attr("stroke", d3.color(d.col!).darker(0.7) + "")
      .attr("stroke-width", 1.9 * PT).attr("stroke-linecap", "butt");
  });
}

/**
 * The grab node: a small black dot, and a much wider invisible disc around it.
 *
 * The layer is pointer-events:none precisely so the hand does not swallow taps
 * meant for the bands underneath — the disc is where that is switched back on,
 * and it is thumb-sized rather than dot-sized because the dot is a mark to read,
 * not a target to hit.
 */
function drawNode(x: number, y: number): void {
  L.hand.append("circle").attr("cx", x).attr("cy", y).attr("r", 0.06 * U).attr("fill", "#000");
  L.hand.append("circle").attr("cx", x).attr("cy", y).attr("r", 0.20 * U)
    .attr("fill", "transparent").attr("pointer-events", "all")
    .style("cursor", scrubbing ? "grabbing" : "grab").call(nodeDrag);
}

/**
 * The horizon: one radian into the PAST, where the erasing finishes vanishing.
 *
 * Anti-clockwise of the hand — the side it is always leaving — because the wipe
 * is fixed to the clock and not to the direction of the drag. Which rotation we
 * have wound into is named by the date header above the dial, so the horizon
 * carries no caption of its own.
 *
 * Faint round DOTS rather than a dashed line: a dash length of 0 with a round
 * cap puts one dot of the stroke's width in every gap, and the gap has to
 * exceed that width or the dots merge back into a line.
 */
function drawHorizon(now: number): void {
  const ha = ang(now - radHr);
  const [dx0, dy0] = xy(0.12, ha), [dx1, dy1] = xy(R, ha);
  L.hand.append("line").attr("x1", dx0).attr("y1", dy0).attr("x2", dx1).attr("y2", dy1)
    .attr("stroke", "#9a9a9a").attr("stroke-width", 1.1 * PT)
    .attr("stroke-dasharray", `0,${3.4 * PT}`)
    .attr("stroke-linecap", "round").attr("opacity", 0.5);
}

/** The radian construction, on demand: the hand's own length, laid on the rim. */
function drawRadian(now: number, na: number): void {
  const a1 = ang(now - radHr), rr = (R - 0.05) * U;
  const [ax0, ay0] = xy(R - 0.05, na), [ax1, ay1] = xy(R - 0.05, a1);
  L.hand.append("path")
    .attr("d", `M${ax0},${ay0}A${rr},${rr} 0 0 0 ${ax1},${ay1}`)
    .attr("fill", "none").attr("stroke", "#000")
    .attr("stroke-width", 1.4 * PT).attr("stroke-linecap", "round");
  const [tx0, ty0] = xy(R - 0.16, a1), [tx1, ty1] = xy(R + 0.02, a1);
  L.hand.append("line").attr("x1", tx0).attr("y1", ty0).attr("x2", tx1).attr("y2", ty1)
    .attr("stroke", "#000").attr("stroke-width", 1.2 * PT);
  const am = ang(now - radHr / 2);
  const rot = -(Math.sin(am) < 0 ? am + Math.PI / 2 : am - Math.PI / 2) * 180 / Math.PI;
  const [lx, ly] = xy(R - 0.30, am);
  L.hand.append("text").attr("x", lx).attr("y", ly)
    .attr("text-anchor", "middle").attr("dominant-baseline", "central")
    .attr("font-size", 4.8 * PT).attr("font-weight", "bold")
    .attr("transform", `rotate(${rot},${lx},${ly})`).text("1 rad");
}

/** Wire the hand's host, and the radian toggle to a redraw. */
export function initHand(h: HandHost): void {
  host = h;
  d3.select("#radian").on("change", () => drawHand(stage.hand));
}
