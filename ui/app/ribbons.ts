// app/ribbons.ts — the day's events, as arcs on the rim.
//
// An event is a span of the turn you have said yes to, and a ribbon is that
// span drawn where it actually falls: the angle is WHEN, the arc length is HOW
// LONG. Nothing here decides what an event is — the plan, the proposals and
// your own ring each supply theirs, and this module only asks where each one
// stands and paints it.
//
// ── THE SELECTION IS A SIGNAL, NOT A CALLBACK ───────────────────────────────
// `selectedEv` is read by the rim, the calendar list, the week grid, the map's
// markers and the detail card. A writer sets it and every one of them follows,
// so no writer has to know which surfaces are on screen. Its twin is the `day`
// notifier in core: state more than one view reads is a signal, not a `let`
// plus a fan-out the next caller has to remember to extend.
//
// ── ONE EVENT, MANY INSTANCES ───────────────────────────────────────────────
// A daily routine repeats on every day the window spans: once on the hour and
// day dials, three times on the 3-day, seven on the week. So the drawing pass
// runs per in-window DAY, not per event, and each instance is clipped to the
// turn's window independently. The chord anchor (_tmid/_r) is pinned to today's
// instance when today is on screen, because a chord should leave from the
// ribbon a reader is actually looking at.
//
// ── EARTH MODE RE-ANGLES, IT DOES NOT RE-TIME ───────────────────────────────
// On the earth the day reorganizes by BEARING: an arc stands in the true
// direction of where its event happens, keeping its length as its duration. The
// angle becomes space and the span stays time — which is also why earth mode
// draws a single instance per event: seven copies of one bearing would stack.

import { S } from './state.js';
import { U, PT, TAU, ang, xy } from './geom.js';
import { cWarm, cYea, inkFor, haloed, USER } from './core.js';
import { evs, pending, spanOnDay, turnAnchor } from './events.js';
import { pick } from './calendars.js';
import { signal } from './reactive.js';
import { stage, mapUp } from './stage.js';
import { goToMapPlace, hereOfEvent } from './gohere.js';
import { passesFacets } from './facets.js';
import { absUnits } from './turn.js';
import { av_hourAt, av_snap, steady as steadyDay } from './ring.js';
import { angDeg, bearingTo } from './threads.js';
import { theMap } from './mapview.js';
import { availRing, eventRing, personalEvs, drawAvail, drawMyEvents } from './day/mytime.js';
import { L, outerEdge } from './layers.js';
import type { DayEvent } from './seam.js';
import type { RingItem } from './ring.js';

/** What the ribbons need the dial to answer. */
export interface RibbonHost {
  /**
   * The scrub wipe at a turn-unit position, 0..1 — 1 solid, 0 erased. Owned by
   * the hand, because it is the hand walking off "now" that erases the past.
   */
  scrubWin(t: number | null): number;
  /** Is the hand scrubbing? Only then is the wipe fine-grained enough to matter. */
  wiping(): boolean;
  /** The ribbons changed: repaint the calendar lists and the detail card. */
  afterEdit(): void;
}

let host: RibbonHost;

// ── the selection ───────────────────────────────────────────────────────────

/** The selected event, or null. Every view that dims or describes one reads it. */
export const selectedEv = signal<DayEvent | null>(null);

/** A list row's class: the selected one is `sel`, its siblings `dim`. */
export const evCls = (d: DayEvent): string =>
  selectedEv() ? (d === selectedEv() ? "sel" : "dim") : "";

/**
 * Select an event — or nothing.
 *
 * REFLECTING a selection is reactive: the rim, the lists and the markers each
 * follow the signal in their own effect, including when a decline clears the
 * selection out from under them. RESPONDING TO THE GESTURE is imperative and
 * stays here — the camera move belongs to the tap that asked for it, and would
 * be an ambush if a background state change did it.
 */
export function selectEvent(ev: DayEvent | null): void {
  eventRing.clearSel(); availRing.clearSel();   // ring editing and the card are exclusive
  selectedEv.set(ev);
  const m = theMap();
  if (mapUp() && m && ev?.at)    // fly to where it happens
    m.flyTo({ center: [USER.lng + ev.at.dLng, USER.lat + ev.at.dLat],
              zoom: 14, duration: 700 });
}

/**
 * The location line's own gesture, from wherever it is read: the calendar
 * grid, the calendar's detail card, the dial's own event card. An adapter
 * over the one navigation door — gohere owns opening the map, moving the
 * viewed window to the event's day, and flying.
 */
export function showEventOnMap(ev: DayEvent): void {
  goToMapPlace(hereOfEvent(ev));
}

// ── editing your own ribbon in place ────────────────────────────────────────

/**
 * Direct edit of an OWN event: drag the body to move (15-min snap), drag the
 * end handles to resize. `item` is the live ring record, mutated in place;
 * save() schedules the planner's availability sync.
 *
 * The drag's coordinate container is pinned to gEvents, which SURVIVES a
 * redraw — only its children are recreated. Without that pin, the per-tick
 * redraw detaches the node being dragged, d3 falls back to raw viewport
 * coordinates, and the handle stops tracking the mouse partway through.
 */
function attachRibbonEdit(grp: d3.Selection, item: RingItem, rr: number,
                          a0: number, a1: number, sel: boolean): void {
  const span = item.t1 - item.t0;
  const cont = (): Element => L.events.node()!;
  grp.style("cursor", "grab").call(d3.drag().container(cont)
    // SELECTING REDRAWS THE RIBBON TOO, not only the card. The resize handles
    // are drawn by this very function behind `if (!sel)`, so a select that only
    // re-rendered the card left the ribbon exactly as it was — selected, with
    // its editor open, and no handles to grab until something else happened to
    // repaint the rim.
    .on("start", () => { eventRing.select(item.id); drawEvents(); host.afterEdit(); })
    .on("drag", function (ev: d3.DragEvent) {
      const cur = av_hourAt(ev.x, ev.y), ref = av_hourAt(ev.x - ev.dx, ev.y - ev.dy);
      let d = cur - ref; if (d > 12) d -= 24; else if (d < -12) d += 24;   // unwrap
      let nt0 = item.t0 + d, nt1 = item.t1 + d;
      if (nt0 < 0) { nt1 -= nt0; nt0 = 0; }
      if (nt1 > 24) { nt0 -= (nt1 - 24); nt1 = 24; }
      item.t0 = av_snap(nt0); item.t1 = av_snap(item.t0 + span); drawEvents();
    })
    .on("end", () => { eventRing.save(); drawEvents(); host.afterEdit(); }));
  if (!sel) return;
  ([["t0", a1], ["t1", a0]] as [string, number][]).forEach(([k, a]) => {
    grp.append("circle").attr("cx", xy(rr, a)[0]).attr("cy", xy(rr, a)[1]).attr("r", 5)
      .attr("fill", "#fff").attr("stroke", "#cf962a").attr("stroke-width", 2)
      .style("cursor", "ew-resize")
      .on("pointerdown.stop", (e: Event) => e.stopPropagation())   // not the body move-drag
      .call(d3.drag().container(cont).on("drag", function (ev: d3.DragEvent) {
        const h = av_snap(av_hourAt(ev.x, ev.y));
        if (k === "t0") item.t0 = Math.min(h, item.t1 - 0.25);
        else             item.t1 = Math.max(h, item.t0 + 0.25);
        drawEvents();
      }).on("end", () => { eventRing.save(); host.afterEdit(); }));
  });
}

// ── the passes ──────────────────────────────────────────────────────────────

/**
 * A transparent ring across the empty lane: tap it to create an own event at
 * that hour. Drawn FIRST so the ribbons paint over it and keep their own clicks.
 */
function drawCreateLane(base: number, bw: number): void {
  const crr = base + bw / 2;
  L.events.append("circle").attr("r", crr * U)
    .attr("fill", "none").attr("stroke", "transparent")
    .attr("stroke-width", bw * U).attr("pointer-events", "stroke")
    .style("cursor", "crosshair")
    .on("click", function (this: Element, ev: Event) {
      ev.stopPropagation();
      const [x, y] = d3.pointer(ev, this);
      eventRing.addAt(av_hourAt(x, y));
    });
}

/**
 * Pack the ribbons into radial lanes so no two TIME-OVERLAPPING arcs share a
 * radius — clean, unambiguous touch zones and no wasted rim.
 *
 * Greedy interval colouring: sort by start, and give each arc the innermost
 * lane whose last arc has already ended. Optimal for intervals, and it keeps
 * the common case (a day of non-overlapping events) in one lane.
 */
function assignLanes(all: DayEvent[]): void {
  const sorted = all.slice().sort((a, b) => a.t0 - b.t0 || a.t1 - b.t1);
  const laneEnd: number[] = [];         // laneEnd[i] = end of the last arc in lane i
  for (const e of sorted) {
    let ln = 0;
    while (ln < laneEnd.length && laneEnd[ln] > e.t0 + 1e-6) ln++;
    e.lane = ln; laneEnd[ln] = e.t1;
  }
}

/** Everything that draws on the rim this turn, in the order it should stack. */
function gatherEvents(): DayEvent[] {
  return pick("plan", evs)
    .concat(pick("props", pending()))
    .concat(pick("mine", personalEvs()))
    .filter(passesFacets);   // the same kind-filter the grid and the map read
}

/** Where one instance of an event stands on this turn, or null if off-window. */
interface Instance {
  /** Start and end in turn-units, clipped to the window. */
  tt0: number;
  tt1: number;
  /** Midpoint, the wipe's and the chord's anchor. */
  tmid: number;
}

/**
 * Place event `ev`'s instance on day `dd`, clipped to the turn's window.
 *
 * The start glides by phase and the SPAN blends between the two periods'
 * proportions while a re-scale is in flight, so an arc shrinks or grows in
 * place instead of orbiting to its new home.
 */
function instanceOn(ev: DayEvent, dd: number, A: number): Instance | null {
  // a DATED event stands on its own day(s) only, clock-clipped at its true
  // ends by the shared spanOnDay arithmetic; an undated one repeats daily
  const sp = spanOnDay(ev, dd);
  if (!sp) return null;
  const dayBase = dd * 24;
  const sAbs = Math.max(dayBase + sp.t0, A);
  const eAbs = Math.min(dayBase + sp.t1, A + S.turnH);
  if (eAbs <= sAbs) return null;        // this day's instance is outside the window
  const tt0 = absUnits(sAbs);
  const durU = S.morphFrom && S.morphU < 1
    ? (1 - S.morphU) / S.morphFrom.h + S.morphU / S.turnH
    : 1 / S.turnH;
  const tt1 = tt0 + (eAbs - sAbs) * 24 * durU;
  return { tt0, tt1, tmid: (tt0 + tt1) / 2 };
}

/** Turn-units per radian — the length of the scrub's erasing tail. */
const radHr = 24 / 6.2832;

/**
 * Draw one instance of one event.
 *
 * Returns false when the instance is a sliver at this scale: the band is drawn
 * but the label will not fit, and the calendar names it instead.
 */
function drawRibbon(ev: DayEvent, inst: Instance, rr: number): void {
  const { tt0, tt1, tmid } = inst;
  const winMid = host.scrubWin(tmid);
  const proposed = ev.status === "proposed";
  const col = ev.kind === "work" ? cWarm : cYea;
  const sel = ev._pid ? (eventRing.selId() === ev._pid) : (selectedEv() === ev);
  const dimmed = !!selectedEv() && !sel;

  // in earth mode the arc stands in the true direction of where the event
  // happens — the angle is space, the span is still time
  let a0: number, a1: number;
  if (stage.mode === "earth" && ev.at) {
    const aM = angDeg(bearingTo(ev.at));
    const half = (ev.t1 - ev.t0) / 2 * (TAU / 24);
    a0 = aM - half; a1 = aM + half;
  } else { a0 = ang(tt1); a1 = ang(tt0); }
  const [ex0, ey0] = xy(rr, a0), [ex1, ey1] = xy(rr, a1);

  const grp = L.events.append("g").classed("clickable", true)
    .attr("opacity", dimmed ? 0.35 : 1)
    .attr("data-pid", ev._pid || null)
    .on("click", (e: Event) => {
      // tap an event → SELECT it; its card shows below the dial. An OWN event
      // is drag-editable, so it only ever selects — a click-to-toggle would
      // fight the drag-start; deselect it by clicking away. A read-only event
      // has no drag, so clicking it again DESELECTS (the natural toggle).
      if (ev._pid) {
        if (e) e.stopPropagation();
        selectedEv.set(null); availRing.clearSel();
        eventRing.select(ev._pid);
      } else selectEvent(selectedEv.peek() === ev ? null : ev);
    });
  // own events edit DIRECTLY on the ribbon, in the steady day view only.
  // An invited proposal has no ring record, and stays read-only.
  if (ev._pid && ev._pref && steadyDay()) attachRibbonEdit(grp, ev._pref, rr, a0, a1, sel);

  // The arc's span, and the large-arc flag that MATCHES it — band, wash and
  // outline must all sweep the same way, or a >½-turn event draws them on
  // opposite sides of the dial. When an event fills (near enough) the whole
  // turn its endpoints coincide, which would be a degenerate arc, so it draws
  // as a clean ring instead: it is not AT a place in the turn, it IS the turn.
  const span = (stage.mode === "earth") ? 0 : (tt1 - tt0);
  const fullTurn = span >= 23.8;
  const laf = span > 12 ? 1 : 0;
  const arcPath = (r: number): string =>
    `M${xy(r, a0)[0]},${xy(r, a0)[1]}A${r * U},${r * U} 0 ${laf} 0 ${xy(r, a1)[0]},${xy(r, a1)[1]}`;
  const bandShape = (r: number): d3.Selection => fullTurn
    ? grp.append("circle").attr("r", r * U)
    : grp.append("path").attr("d", arcPath(r));

  // While scrubbing, the colour band IS the wipe: split into short arcs, each
  // as faded as its own slice of time, so a long block erases continuously
  // from its trailing edge instead of vanishing all at once.
  const segWipe = host.wiping() && stage.mode === "dial" && !fullTurn;
  const invT = (a: number): number => (Math.PI / 2 - a) / (TAU / 24);   // angle → units
  const bandStroke = (r: number, stroke: string, sw: number): void => {
    if (!segWipe) {
      bandShape(r).attr("fill", "none").attr("stroke", stroke)
        .attr("stroke-width", sw).attr("stroke-linecap", "butt").attr("opacity", winMid);
      return;
    }
    const K = Math.max(2, Math.ceil(Math.abs(tt1 - tt0) / (radHr / 12)));
    for (let i = 0; i < K; i++) {
      const u0 = tt0 + (tt1 - tt0) * i / K, u1 = tt0 + (tt1 - tt0) * (i + 1) / K;
      const op = host.scrubWin((u0 + u1) / 2);
      if (op <= 0.01) continue;
      const [q0x, q0y] = xy(r, ang(u1)), [q1x, q1y] = xy(r, ang(u0));
      grp.append("path").attr("d", `M${q0x},${q0y}A${r * U},${r * U} 0 0 0 ${q1x},${q1y}`)
        .attr("fill", "none").attr("stroke", stroke).attr("stroke-width", sw)
        .attr("stroke-linecap", "butt").attr("opacity", op);
    }
  };

  // the centre wash — the hours the event claims, from the centre out — only
  // when the event sits AT a place in the turn (≤ half). A near-full event
  // would wash the whole disc, so there the rim band carries it alone.
  if (!fullTurn && span <= 12)
    grp.append("path")
      .attr("d", `M0,0L${ex0},${ey0}A${rr * U},${rr * U} 0 0 0 ${ex1},${ey1}Z`)
      .attr("fill", col).attr("opacity", (proposed ? 0.03 : (sel ? 0.10 : 0.045)) * winMid)
      .attr("pointer-events", "none");
  if (sel)
    bandShape(rr).attr("fill", "none").attr("stroke", "#000")
      .attr("stroke-width", bw * U + 2.6 * PT).attr("stroke-linecap", "butt")
      .attr("opacity", 0.9 * winMid);
  // a proposal is an outline of the event it could become: hollow band, dashed
  // edge, label in the event's own colour — accept to fill it in
  bandStroke(rr, proposed ? "#fff" : col, bw * U);
  // a fat, transparent hit-arc filling this lane's radial slot (lane pitch is
  // bw+0.09, so bw+0.08 tiles cleanly — adjacent lanes' touch zones meet but
  // never overlap). This is the reliable target: a tap anywhere across the band
  // selects, instead of missing the thin stroke and falling through to the dial
  // (which would deselect). Drawn last among the band elements, so it sits on top.
  bandShape(rr).attr("fill", "none").attr("stroke", "transparent")
    .attr("stroke-width", (bw + 0.08) * U).attr("stroke-linecap", "butt")
    .attr("pointer-events", "stroke")
    .style("cursor", (ev._pid && steadyDay()) ? "grab" : "pointer");
  if (proposed)
    for (const rEdge of [rr - bw / 2, rr + bw / 2])
      bandShape(rEdge).attr("fill", "none").attr("stroke", col)
        .attr("stroke-width", 0.7 * PT).attr("stroke-dasharray", "4,3").attr("opacity", winMid);

  drawArcLabel(grp, ev, rr, a0, a1, col, proposed, winMid, segWipe, invT);
}

/**
 * The event's name, set letter by letter along its own arc.
 *
 * Per-character placement rather than SVG textPath because the label has to
 * flip: on the bottom half of the dial the text runs the other way round, or a
 * reader has to tilt their head. A label that cannot fit is simply not drawn —
 * the band still reads as time, and the calendar list names it.
 */
function drawArcLabel(grp: d3.Selection, ev: DayEvent, rr: number,
                      a0: number, a1: number, col: string, proposed: boolean,
                      winMid: number, segWipe: boolean,
                      invT: (a: number) => number): void {
  const chars = [...ev.label], nch = chars.length;
  const amid = (a0 + a1) / 2;
  const bottom = Math.sin(amid) < 0;
  const arclen = Math.abs(a1 - a0) * rr;
  const pitch = Math.min(0.105, arclen * 0.88 / Math.max(nch, 1));
  if (pitch < 0.028) return;            // a sliver at this scale: band only
  const fs = Math.max(3.6, 5.6 * pitch / 0.105) * PT;
  const dth = pitch / rr;
  const ink = proposed ? col : inkFor(col);
  chars.forEach((ch, i) => {
    const off = (i - (nch - 1) / 2) * dth;
    const th = bottom ? amid + off : amid - off;
    const rot = -(bottom ? th + Math.PI / 2 : th - Math.PI / 2) * 180 / Math.PI;
    const [cx, cy] = xy(rr, th);
    haloed(
      grp.append("text").attr("x", cx).attr("y", cy)
        .attr("text-anchor", "middle").attr("dominant-baseline", "central")
        .attr("font-size", fs).attr("font-weight", 600)
        .attr("font-style", proposed ? "italic" : null)
        .attr("opacity", segWipe ? host.scrubWin(invT(th)) : winMid)
        .attr("transform", `rotate(${rot},${cx},${cy})`).text(ch),
      ink, fs);
  });
}

/** Band width: wide enough to read, narrow enough to stack several lanes. */
const bw = 0.34;

/** Redraw every ribbon on the rim, and the two editable rings alongside them. */
export function drawEvents(): void {
  L.events.selectAll("*").remove();
  const A = turnAnchor();
  const base = outerEdge() + 0.66;        // past the τ labels of the outermost ring
  const d0 = Math.floor(A / 24), d1 = Math.floor((A + S.turnH - 1e-6) / 24);
  const nowDay = Math.floor(S.nowAbs / 24);
  const single = stage.mode === "earth";  // one bearing arc per event, not seven

  if (steadyDay()) drawCreateLane(base, bw);

  const all = gatherEvents();
  assignLanes(all);
  stage.evs = all;   // the read hook the UX suites check lanes through

  all.forEach(ev => {
    ev._tmid = null;                      // not on this turn unless proven below
    const rr = base + bw / 2 + (ev.lane || 0) * (bw + 0.09);
    for (let dd = d0; dd <= d1; dd++) {
      const inst = instanceOn(ev, dd, A);
      if (!inst) continue;
      if (ev._tmid == null || dd === nowDay) { ev._tmid = inst.tmid; ev._r = rr; }
      // wholly erased by the scrub: nothing of it would show
      if (Math.max(host.scrubWin(inst.tmid),
                   host.scrubWin(inst.tt0),
                   host.scrubWin(inst.tt1)) <= 0.01) continue;
      drawRibbon(ev, inst, rr);
      if (single) break;
    }
  });

  drawAvail();                            // co-render the availability ring
  drawMyEvents();                         // …and your personal events ring
}

/** Wire the ribbons' host. */
export function initRibbons(h: RibbonHost): void { host = h; }
