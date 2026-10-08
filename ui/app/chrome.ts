// app/chrome.ts — the rim, and the marks that say what a turn IS.
//
// Everything outside the bands: the circle that closes the dial, the ticks and
// labels that divide the turn, and the sun. It is the smallest surface on the
// face and the one that carries the dial's whole claim, because it is where the
// turn is NAMED.
//
// ── THE ANGLE IS TIME, OR THE ANGLE IS SPACE ────────────────────────────────
// Those are the two chromes, and they are not variations of one drawing. In
// dial mode an angle is an hour and the marks read in τ or in the period's own
// symbol; on the earth an angle is a BEARING and the same marks read in degrees
// — north at the top, or your heading at the top with the compass on. The
// horizon is a turn too, which is why the bearing marks wear τ fractions as
// well: north is 0 and τ at once, east is a quarter turn.
//
// The sun follows the same split, and this is the clearest place to see it. When
// the angle is time, a gold mark stands at each sunrise IN THE WINDOW and a deep
// one at each sunset — one pair on the day dial, seven on the week's. When the
// angle is space, the same two marks stand at the sun's true BEARINGS: where it
// rose and where it will set, seen from where you are standing.
//
// ── THE DAY IS A CLOCK, NOT A τ ─────────────────────────────────────────────
// At the day scale the marks read 0, 3, 6 … because turn-units ARE hours there
// and a reader already owns that dial. The three-day turn divides at its two
// interior midnights and names them by weekday, since "3D∕4" is a true fraction
// that tells you less than "Mon 17" does.

import { S } from './state.js';
import { U, PT, R, ang, xy } from './geom.js';
import { cDeep } from './core.js';
import { stage } from './stage.js';
import { turnAnchor } from './events.js';
import { absUnits } from './turn.js';
import { turnSym } from './scales.js';
import { dateOf, wd, dm } from './timefmt.js';
import { sunFor, drawSkyRing } from './sky.js';
import { angDeg } from './threads.js';
import { L, outerEdge, setViewExtent } from './layers.js';

/** What the chrome needs the dial to answer. */
export interface ChromeHost {
  /**
   * The extent changed. The viewBox follows by itself (app/layers.ts); this is
   * for what ELSE has to be re-fitted, which is the map welded into the disc.
   */
  afterResize(): void;
}

let host: ChromeHost;

/** The radius the marks currently hang off, re-read when the rim moves. */
let chromeBase = R;

/** The rim moved: re-aim the marks and let the viewBox catch up. */
export function updateChromeTargets(): void {
  chromeBase = outerEdge();
  setViewExtent();
  host.afterResize();
}

/** Draw the rim and its marks, in whichever of the two readings is live. */
export function drawChrome(): void {
  L.chrome.selectAll("*").remove();
  const B = chromeBase;
  // the day dial's rim IS the sky — sunrise to sunset drawn as the ring itself,
  // rather than a plain circle with marks laid on it
  const dayDial = stage.mode !== "earth" && Math.abs(S.turnH - 24) < 0.5;
  if (dayDial) drawSkyRing(L.chrome, Math.floor(turnAnchor() / 24) % 365);
  else L.chrome.append("circle").attr("r", R * U)
    .attr("fill", "none").attr("stroke", cDeep).attr("stroke-width", 0.7 * PT);

  if (stage.mode === "earth") drawBearingMarks(B);
  else { drawTurnMarks(B); drawSunHours(B); }
}

// ── the two mark sets ───────────────────────────────────────────────────────

/** A tick at angle `a`, `len` long and `w` wide. */
function tickAt(a: number, B: number, len: number, w: number): void {
  const [x0, y0] = xy(B, a), [x1, y1] = xy(B + len, a);
  L.chrome.append("line").attr("x1", x0).attr("y1", y0).attr("x2", x1).attr("y2", y1)
    .attr("stroke", "#000").attr("stroke-width", w * PT);
}

/** A label at radius `r`, angle `a`. */
function labAt(s: string, r: number, a: number, fs: number, bold: boolean): void {
  const [x, y] = xy(r, a);
  L.chrome.append("text").attr("x", x).attr("y", y)
    .attr("text-anchor", "middle").attr("dominant-baseline", "central")
    .attr("font-size", fs * PT).attr("font-weight", bold ? "bold" : null)
    .text(s);
}

/** The sun's two marks, gold for the rise and deep for the set. */
function sunMark(r: number, a: number, kind: "rise" | "set", rad: number): void {
  const [x, y] = xy(r, a);
  L.chrome.append("circle").attr("cx", x).attr("cy", y).attr("r", rad)
    .attr("fill", kind === "rise" ? "#f6b40e" : cDeep)
    .attr("stroke", "#fff").attr("stroke-width", 0.7 * PT);
}

/** Earth mode: the marks read in bearing, and the sun stands where it rises. */
function drawBearingMarks(B: number): void {
  const tick = (b: number, len: number, w: number): void => tickAt(angDeg(b), B, len, w);
  const lab = (s: string, r: number, b: number, fs: number, bold: boolean): void =>
    labAt(s, r, angDeg(b), fs, bold);

  for (const [s, c, b] of [["0, τ", "N", 0], ["τ∕4", "E", 90],
                           ["τ∕2", "S", 180], ["3τ∕4", "W", 270]] as [string, string, number][]) {
    tick(b, 0.12, 1.3);
    lab(s, B + 0.68, b, 6.5, true);
    lab(c, B + 0.26, b, 3.8, false);   // the cardinal, small, beside its tick
  }
  for (const [s, b] of [["τ∕8", 45], ["3τ∕8", 135], ["5τ∕8", 225], ["7τ∕8", 315]] as [string, number][]) {
    tick(b, 0.08, 0.8);
    lab(s, B + 0.22, b, 4.5, false);
  }

  const sn = sunFor(Math.floor(S.nowAbs / 24) % 365);
  if (sn.rise == null) return;         // a polar day or night has no bearings
  for (const [az, kind] of [[sn.azRise, "rise"], [sn.azSet, "set"]] as [number, "rise" | "set"][]) {
    sunMark(B + 0.16, angDeg(az), kind, 0.07 * U);
    lab(kind === "rise" ? "☀ rise" : "☀ set", B + 0.40, az, 4.2, false);
  }
}

/** Dial mode: the marks divide the turn, in hours, weekdays or τ fractions. */
function drawTurnMarks(B: number): void {
  const tick = (h: number, len: number, w: number): void => tickAt(ang(h), B, len, w);
  const lab = (s: string, r: number, h: number, fs: number, bold: boolean): void =>
    labAt(s, r, ang(h), fs, bold);

  if (Math.abs(S.turnH - 24) < 0.5) {
    // the day is a 24-hour clock: turn-units ARE hours here, so an hour is at
    // its own position — 0 at the top, 12 at the foot, every three hours round
    for (const hh of [0, 6, 12, 18]) { tick(hh, 0.12, 1.3); lab(`${hh}`, B + 0.50, hh, 6.5, true); }
    for (const hh of [3, 9, 15, 21]) { tick(hh, 0.08, 0.8); lab(`${hh}`, B + 0.22, hh, 4.5, false); }
    return;
  }
  if (Math.abs(S.turnH - 72) < 0.5) {
    // the 3-day turn divides at its two interior midnights, named by weekday.
    // Day i begins at i∕3 of the turn = 8i.
    const dd0 = Math.floor(turnAnchor() / 24);
    for (let i = 0; i < 3; i++) {
      const d = dateOf(dd0 + i);
      tick(8 * i, 0.12, 1.3);
      lab(`${wd(d)} ${dm(d)}`, B + 0.50, 8 * i, 5.0, true);
      tick(8 * i + 4, 0.06, 0.7);                   // a faint nick at each midday
    }
    return;
  }
  const sym = turnSym();
  for (const [s, h] of [[`0, ${sym}`, 0], [`${sym}∕4`, 6],
                        [`${sym}∕2`, 12], [`3${sym}∕4`, 18]] as [string, number][]) {
    tick(h, 0.12, 1.3); lab(s, B + 0.50, h, 6.5, true);
  }
  for (const [s, h] of [[`${sym}∕12`, 2], [`${sym}∕8`, 3],
                        [`${sym}∕6`, 4], [`${sym}∕3`, 8]] as [string, number][]) {
    tick(h, 0.08, 0.8); lab(s, B + 0.22, h, 4.5, false);
  }
}

/**
 * The sun at its HOURS: a mark at every sunrise and sunset the window holds.
 *
 * One pair on the day dial, seven on the week's — and beyond a fortnight the
 * marks step aside entirely, because thirty overlapping pairs say nothing that
 * the sky ring already says better. Only the day dial names them, for the same
 * reason: at a week the marks are legible and the labels would not be.
 */
function drawSunHours(B: number): void {
  const A = turnAnchor();
  if (S.turnH > 14 * 24) return;
  for (let dd = Math.floor(A / 24); dd * 24 < A + S.turnH; dd++) {
    const s = sunFor(dd % 365);
    if (s.rise == null) continue;
    for (const [t, kind] of [[s.rise, "rise"], [s.set, "set"]] as [number, "rise" | "set"][]) {
      const abs = dd * 24 + t;
      if (abs < A || abs >= A + S.turnH) continue;
      const tu = absUnits(abs);
      sunMark(B + 0.16, ang(tu), kind, (S.turnH <= 24 ? 0.07 : 0.042) * U);
      if (S.turnH <= 24)
        labAt(kind === "rise" ? "☀ rise" : "☀ set", B + 0.40, ang(tu), 4.2, false);
    }
  }
}

/** Wire the chrome's one host answer. */
export function initChrome(h: ChromeHost): void { host = h; }
