// app/route/shape.ts — the geometry of a route's shape: where you are on it, and how it divides.
// Pure: no DOM, no map, no clock.
//
//   segments                   the shape cut into runs by mode (walk · ride · walk)
//   snapToRoute / progress     where you are ON a route, and what is left of it
//   pointAt / courseAt         a point along the way, and the way it is heading there
//   boundsOf                   the box that holds every route
//   pillAnchor                 where a route's time pill sits so no route hides it
//
// The words a route says are app/route/facts.ts; this is its line.

import { havKm, bearingDeg } from '../geom.js';
import type { LatLng, Point } from '../geom.js';
import type { Route, TransitInfo } from './data.js';

/** A run of a route's shape travelled one way: "pedestrian", "transit", … ("" when the engine did not say). */
export interface Segment {
  mode: string;
  /** Where the run begins, as an index into the route's own shape. */
  begin: number;
  coords: Point[];
  /** Seconds, and distance in the route's own units, along the run — the maneuvers' own. */
  s: number;
  km: number;
  /** The line a ride run takes (its first maneuver's); null on foot, by bike or by car. */
  transit: TransitInfo | null;
}

/**
 * A route's shape cut into contiguous runs of one travel mode — walk, ride, walk — so each can be
 * drawn its own way. A route whose maneuvers name no mode (or none at all) is one run.
 */
export function segments(r: Route): Segment[] {
  const runs: { mode: string; begin: number; end: number; s: number; km: number; transit: TransitInfo | null }[] = [];
  for (const m of r.mans) {
    const last = runs[runs.length - 1];
    if (last && last.mode === m.mode) {
      last.end = Math.max(last.end, m.end); last.s += m.time; last.km += m.length;
      last.transit ??= m.transit;
    } else runs.push({ mode: m.mode, begin: m.begin, end: m.end, s: m.time, km: m.length, transit: m.transit });
  }
  const out = runs.map(s => ({ mode: s.mode, begin: s.begin, coords: r.coords.slice(s.begin, s.end + 1), s: s.s, km: s.km, transit: s.transit }))
                  .filter(s => s.coords.length > 1);
  return out.length ? out : r.coords.length > 1 ? [{ mode: "", begin: 0, coords: r.coords, s: r.s, km: r.km, transit: null }] : [];
}

// ── where you are on a route ────────────────────────────────────────────────

/** Cumulative straight-line kilometres along a route's shape, per vertex; kept per route. */
const cums = new WeakMap<Route, number[]>();
function cumKm(r: Route): number[] {
  let c = cums.get(r);
  if (!c) {
    c = [0];
    for (let i = 1; i < r.coords.length; i++)
      c.push(c[i - 1] + havKm({ lat: r.coords[i - 1][1], lng: r.coords[i - 1][0] }, { lat: r.coords[i][1], lng: r.coords[i][0] }));
    cums.set(r, c);
  }
  return c;
}

/** Where a position falls on a route: between vertex `at` and `at + 1`, `t` of the way, `offKm` from the line. */
export interface Snap { at: number; t: number; offKm: number }

/**
 * The point of a route nearest `here`, searching forward from where you last were (`hint`, a vertex index)
 * so a way that doubles back on itself is read in order. A position beside the line is `offKm` from it —
 * how far off the way you are.
 */
export function snapToRoute(r: Route, here: LatLng, hint = 0): Snap {
  const n = r.coords.length;
  if (n < 2) return { at: 0, t: 0, offKm: n ? havKm(here, { lat: r.coords[0][1], lng: r.coords[0][0] }) : Infinity };
  const kx = Math.cos(here.lat * Math.PI / 180) * 111.32, ky = 110.57;     // km per degree, here
  let best: Snap = { at: 0, t: 0, offKm: Infinity };
  for (let i = Math.max(0, hint - 2); i < n - 1; i++) {
    const [ax, ay] = r.coords[i], [bx, by] = r.coords[i + 1];
    const dx = (bx - ax) * kx, dy = (by - ay) * ky, px = (here.lng - ax) * kx, py = (here.lat - ay) * ky;
    const len2 = dx * dx + dy * dy;
    const t = len2 > 0 ? Math.max(0, Math.min(1, (px * dx + py * dy) / len2)) : 0;
    const off = Math.hypot(px - t * dx, py - t * dy);
    if (off < best.offKm - 1e-9) best = { at: i, t, offKm: off };
    else if (i > hint + 40 && off > best.offKm + 0.3) break;           // left the neighbourhood
  }
  return best;
}

/** What is left of a route from a snapped position, and what comes next. */
export interface Progress {
  /** The maneuver you are on, the next ahead, and the one after it — indices into `mans`, -1 when there is none. */
  cur: number; next: number; then: number;
  /** Distance left, in the route's own units. */
  remKm: number;
  /** Seconds left. */
  remS: number;
  /** Distance to where `next` begins, in the route's own units. */
  toNextKm: number;
  /** Metres from where `next` begins to where `then` does: how close together the two turns are. */
  nextToThenM: number;
  /** Straight-line kilometres still to go along the shape. */
  aheadKm: number;
}

/**
 * Distance and time left from `s`. Time is the maneuvers' own: what is left of the one you are on,
 * and all of those after it — so a long slow stretch ahead is not averaged away. A route with no
 * timed maneuvers is read evenly along its length.
 */
export function progress(r: Route, s: Snap): Progress {
  const c = cumKm(r), total = c[c.length - 1] || 0;
  const seg = c[Math.min(s.at + 1, c.length - 1)] - c[s.at];
  const pos = c[s.at] + s.t * seg;
  const left = total > 0 ? Math.max(0, 1 - pos / total) : 0;
  let cur = -1;
  r.mans.forEach((m, i) => { if (m.begin <= s.at) cur = i; });
  const next = r.mans.findIndex(m => m.begin > s.at);
  const then = next >= 0 && next + 1 < r.mans.length ? next + 1 : -1;
  const at = (i: number): number => c[Math.min(r.mans[i].begin, c.length - 1)];
  let remS: number;
  if (r.mans.some(m => m.time > 0) && cur >= 0) {
    const m = r.mans[cur], span = c[Math.min(m.end, c.length - 1)] - c[Math.min(m.begin, c.length - 1)];
    const frac = span > 0 ? Math.max(0, Math.min(1, (pos - c[m.begin]) / span)) : 0;
    remS = (1 - frac) * m.time + r.mans.slice(cur + 1).reduce((a, x) => a + x.time, 0);
  } else remS = r.s * left;
  return {
    cur, next, then, remKm: r.km * left, remS,
    toNextKm: next >= 0 ? r.km * Math.max(0, at(next) - pos) / (total || 1) : r.km * left,
    nextToThenM: next >= 0 && then >= 0 ? (at(then) - at(next)) * 1000 : Infinity,
    aheadKm: Math.max(0, total - pos),
  };
}

/** Straight-line kilometres from the start of the shape to `s`. */
const posKm = (r: Route, s: Snap): number => {
  const c = cumKm(r);
  return c[s.at] + s.t * (c[Math.min(s.at + 1, c.length - 1)] - c[s.at]);
};

/** The point `km` along a route's shape (straight-line kilometres), and the way it is heading there. */
export function pointAt(r: Route, km: number): { lat: number; lng: number; heading: number } {
  const c = cumKm(r), n = r.coords.length;
  if (n === 0) return { lat: 0, lng: 0, heading: 0 };
  if (n === 1) return { lat: r.coords[0][1], lng: r.coords[0][0], heading: 0 };
  const d = Math.max(0, Math.min(km, c[n - 1]));
  let i = 0;
  while (i < n - 2 && c[i + 1] < d) i++;
  const [ax, ay] = r.coords[i], [bx, by] = r.coords[i + 1];
  const t = c[i + 1] > c[i] ? (d - c[i]) / (c[i + 1] - c[i]) : 0;
  return { lat: ay + (by - ay) * t, lng: ax + (bx - ax) * t,
           heading: bearingDeg({ lat: ay, lng: ax }, { lat: by, lng: bx }) };
}

/** The way the route is heading where you are on it, in degrees from north. */
export const courseAt = (r: Route, s: Snap): number => pointAt(r, posKm(r, s)).heading;

/** What is left of a route from where you are: the same route, its shape from the vertex you last passed. */
export const remainingOf = (r: Route, s: Snap): Route => ({ ...r, coords: r.coords.slice(s.at) });

/** The total straight-line length of the shape, in kilometres. */
export const shapeKm = (r: Route): number => cumKm(r)[r.coords.length - 1] || 0;

/** The box that holds every route's shape: [[west, south], [east, north]], or null when there is no shape. */
export function boundsOf(routes: readonly { coords: readonly Point[] }[]): [[number, number], [number, number]] | null {
  let w = 180, s = 90, e = -180, n = -90, any = false;
  for (const r of routes) for (const [x, y] of r.coords) {
    any = true;
    if (x < w) w = x; if (x > e) e = x; if (y < s) s = y; if (y > n) n = y;
  }
  return any ? [[w, s], [e, n]] : null;
}

// squared distance in a flat plane scaled at `cos` — the choice between two vertices needs no more
const d2 = (ax: number, ay: number, bx: number, by: number, cos: number): number =>
  ((ax - bx) * cos) ** 2 + (ay - by) ** 2;

/**
 * Where `routes[ix]`'s time pill sits: the point of its own shape farthest from
 * every other route, so a pill never lands on a way it is not about. With no
 * other route it sits halfway along. The first and last tenth of a shape are
 * left to the endpoints' own markers.
 */
export function pillAnchor(routes: readonly Route[], ix: number): [number, number] | null {
  const mine = routes[ix]?.coords;
  if (!mine || !mine.length) return null;
  const lo = Math.floor(mine.length * 0.1), hi = Math.max(lo + 1, Math.ceil(mine.length * 0.9));
  const body = mine.slice(lo, hi);
  const others = routes.filter((_, i) => i !== ix).flatMap(r => r.coords);
  if (!others.length) return body[Math.floor(body.length / 2)] ?? mine[Math.floor(mine.length / 2)];
  const cos = Math.cos(mine[Math.floor(mine.length / 2)][1] * Math.PI / 180);
  const stride = Math.max(1, Math.floor(others.length / 400));
  let best = body[0], bd = -1;
  for (const [x, y] of body) {
    let near = Infinity;
    for (let i = 0; i < others.length; i += stride) {
      const d = d2(x, y, others[i][0], others[i][1], cos);
      if (d < near) near = d;
    }
    if (near > bd) { bd = near; best = [x, y]; }
  }
  return best;
}
