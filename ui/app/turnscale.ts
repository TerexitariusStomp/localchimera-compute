// app/turnscale.ts — rescaling the turn: pinch, scroll, or name it.
//
// The dial's whole subject is desire over a period, and this is where the
// period is chosen. Rescale and the same desires redraw as desire over an hour,
// a day, a week, a year — the wheel does not zoom, it re-reads.
//
// ── PRESETS ARE THE DESTINATIONS, THE MORPH IS THE JOURNEY ──────────────────
// The turn lives ON the named scales and moves between them by smooth
// interpolation only. Continuous free-scaling looked sporadic and snapped to a
// name in the end anyway; rapid discrete steps could strobe. This is the
// synthesis — one unhurried eased morph at a time, and input during a morph is
// simply ignored, so the dial can never animate faster than a reader can follow.
//
// ── THE TREEMAP LESSON: DO NOT RE-DERIVE THE WORLD MID-MORPH ────────────────
// Tweening S.turnH itself would sweep every band boundary through every period
// in between, and because a boundary's ANGLE depends on the period — hour 3 of
// a day sits at 45°, hour 3 of a week at 6° — the peaks would spiral around the
// dial on the way. So the destination distributions are computed ONCE, up
// front, and only the drawing blends: every boundary glides radially toward its
// new place and the dial breathes like a flower, in place.
//
// S.turnH is set to the destination immediately, on the first line of the
// morph. The world IS the new period from that instant; `morphFrom`/`morphU`
// exist so that the timed elements — the hand, the ribbons, the sun marks —
// know to glide by phase rather than jump (app/turn.ts does that arithmetic).

import { S } from './state.js';
import { stage } from './stage.js';
import { settle } from './wheel.js';
import { turnAnchor } from './events.js';
import { SCALES } from './scales.js';
import { layout } from './bands.js';
import { svg } from './layers.js';
import { homeHand } from './hand.js';

/** What rescaling needs the dial to answer. */

/** Which named scale the strip marks as current. */
let scaleIdx = SCALES.findIndex(s => s.h === 24);
/** A morph is in flight. Every input is dropped until it ends. */
let morphing = false;

const MORPH = 600;
const REDUCED = !!(window.matchMedia &&
  window.matchMedia("(prefers-reduced-motion: reduce)").matches);

/** The scale strip: every named turn, the current one in bold. Click to go. */
function renderStrip(): void {
  const strip = d3.select("#scalestrip");
  strip.selectAll("*").remove();
  SCALES.forEach((s, i) => {
    if (i) strip.append("span").style("color", "#ccc").text(" · ");
    strip.append("span")
      .style("cursor", "pointer")
      .style("font-weight", i === scaleIdx ? "bold" : "normal")
      .style("color", i === scaleIdx ? "#2c4a6e" : "#999")
      .attr("title", s.label)
      .text(s.label.replace("one ", ""))
      .on("click", () => goToScale(i));
  });
}

// ── moving ──────────────────────────────────────────────────────────────────

/** Set the turn directly, in hours — the seam's own way in. */
export function setTurn(h: number): void {
  S.turnH = Math.max(1, Math.min(8766, h));
  stage.cums = layout(stage.focus.children || []);
  if (stage.mode === "dial" && !stage.zooming) settle();
}

/** Morph to named scale `ni`, gliding every band boundary to its new place. */
export function goToScale(ni: number): void {
  ni = Math.max(0, Math.min(SCALES.length - 1, ni));
  const to = SCALES[ni].h, from = S.turnH;
  scaleIdx = ni;
  renderStrip();
  if (Math.abs(Math.log(to / from)) < 1e-4) return;   // already there

  const layFrom = stage.cums.map(s => ({ cum: s.cum.slice(), met: s.met.slice(), tot: s.tot }));
  const fromA = turnAnchor();
  S.turnH = to;                                   // the world IS the destination;
  const layTo = layout(stage.focus.children || []);         // only the DRAWING blends
  S.morphFrom = { h: from, A: fromA };
  S.morphU = 0;
  morphing = true;
  d3.transition("turnsnap").duration(REDUCED ? 0 : MORPH).ease(d3.easeCubicInOut)
    .tween("snap", () => (u: number) => {
      S.morphU = u;                               // hand/ribbons/sun glide by phase
      stage.cums = layFrom.map((s, i) => ({
        cum: s.cum.map((v, j) => v + (layTo[i].cum[j] - v) * u),
        met: s.met.map((v, j) => v + (layTo[i].met[j] - v) * u),
        tot: s.tot + (layTo[i].tot - s.tot) * u,
      }));
      if (stage.mode === "dial" && !stage.zooming) settle();
    })
    .on("end interrupt", () => { morphing = false; S.morphFrom = null; S.morphU = 1; });
}

/** Step to the neighbouring named scale. */
export function stepTurn(dir: number): void {
  if (morphing) return;
  homeHand();                          // a rescale re-homes the hand on now
  goToScale(scaleIdx + Math.sign(dir));
}

/** Snap the strip to whichever named scale the turn is nearest, without moving. */
export function syncScaleIdx(): void {
  scaleIdx = SCALES.reduce((best, s, i) =>
    Math.abs(Math.log(s.h / S.turnH)) < Math.abs(Math.log(SCALES[best].h / S.turnH)) ? i : best, 0);
  renderStrip();
}

// ── the gestures ────────────────────────────────────────────────────────────

/**
 * Wheel, trackpad swipe and two-finger pinch, all stepping the same way.
 *
 * The wheel ACCUMULATES to a threshold rather than stepping per event: a
 * trackpad emits a stream of small deltas where a mouse emits one large notch,
 * and banking them is what makes one gesture mean one step on both. Nothing is
 * banked mid-morph, so a long scroll cannot queue up four scales to fly through
 * after it ends.
 *
 * The pinch measures against the distance the two fingers STARTED at, not the
 * last frame: each ×1.6 of spread is one step, so the gesture is absolute and a
 * slow drift back does not ratchet.
 */
export function initTurnScale(): void {
  let wheelAcc = 0;
  svg.on("wheel", (e: WheelEvent) => {
    // the frag face has its own zoom; the earth has the map's
    if (stage.face !== "time" || stage.mode !== "dial" || stage.zooming) return;
    e.preventDefault();
    if (morphing) return;              // never bank scrolls mid-morph
    wheelAcc += e.deltaY;
    if (Math.abs(wheelAcc) >= 90) { stepTurn(Math.sign(wheelAcc)); wheelAcc = 0; }
  });

  const pinchPts = new Map<number, [number, number]>();
  let pinchD0 = 0, pinchSteps = 0;
  const spread = (): number => {
    const [a, b] = [...pinchPts.values()];
    return Math.hypot(a[0] - b[0], a[1] - b[1]);
  };

  svg.on("pointerdown.turn", (e: PointerEvent) => {
    if (stage.face !== "time" || e.pointerType !== "touch" || stage.mode !== "dial") return;
    pinchPts.set(e.pointerId, [e.clientX, e.clientY]);
    if (pinchPts.size === 2) { pinchD0 = spread(); pinchSteps = 0; }
  });
  svg.on("pointermove.turn", (e: PointerEvent) => {
    if (!pinchPts.has(e.pointerId)) return;
    pinchPts.set(e.pointerId, [e.clientX, e.clientY]);
    if (pinchPts.size !== 2 || pinchD0 <= 1) return;
    e.preventDefault();
    // spread apart = a SHORTER turn, pinch together = a longer one
    const steps = Math.round(Math.log(pinchD0 / spread()) / Math.log(1.6));
    if (steps !== pinchSteps && !morphing) {
      stepTurn(Math.sign(steps - pinchSteps));
      pinchSteps = steps;
    }
  });
  for (const evn of ["pointerup.turn", "pointercancel.turn"])
    svg.on(evn, (e: PointerEvent) => { pinchPts.delete(e.pointerId); });

  renderStrip();
}
