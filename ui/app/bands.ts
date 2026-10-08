// app/bands.ts — the desire tree, read as band geometry.
//
// One question, answered in one place: given a set of sibling needs, where are
// the boundaries between their bands at each sample around the turn, and how
// far out is each band's satisfaction? That is `layout`, and everything else
// here either feeds it or reads its shape back as rhythm.
//
// It came out of main.js in four pieces that had drifted apart — the σ note and
// the means pass, the weekly/seasonal envelopes two hundred lines later, the
// hand-over mixes, and the harmonics below layout. They are one subject: how a
// need's curves become an angle and a radius. Two of the pieces ran as bare
// IIFEs over S.root at load time; they are named passes now, called by whoever
// builds a tree, which is also what lets a REBUILT spine be stamped the same way
// the first one was.
//
// The dial's own paint stays in main: this module answers where the edges are,
// never what colour they take or which arc is selected.

import { S } from './state.js';
import { n, TAU, clamp01, lerp } from './geom.js';
import { turnAnchor } from './events.js';
import { bumpSum, spendMassByTerm } from './desire-projection.js';
import { EXT } from './core.js';
import type { DesireNode } from './desire.js';

// ── individual ⇄ social (σ) ─────────────────────────────────────────────────
// "everyone" is you, phase-averaged: averaging any daily curve over the earth's
// longitudes (uniform phase shifts) is exactly its circular mean — so at σ=1 the
// shares flatten to their means and the social dial's rotational evenness is
// DERIVED, not assumed. Satisfaction additionally carries today's deprivation:
// most of what humanity wants, hour by hour, goes unmet.

/** How much of the social cut's satisfaction survives the world's shortfall. */
export const DEPRIVATION = 0.55;

/**
 * Stamp each node's phase-averaged weight and satisfaction — the values σ
 * flattens toward. A node with no curve of its own (an interior term the
 * taxonomy carries) keeps whatever it had; only the curved ones are averaged.
 */
export function stampMeans(node: DesireNode): void {
  if (node.bumps) {
    let mw = 0, mq = 0;
    for (let i = 0; i < n; i++) {
      const t = 24 * i / n;
      mw += bumpSum(node.base, node.bumps, t);
      mq += bumpSum(node.qbase, node.qbumps, t);
    }
    node._meanW = mw / n;
    node._meanQ = mq / n;
  }
  (node.children || []).forEach(stampMeans);
}

// ── the coarser envelopes ───────────────────────────────────────────────────
// Weekly and seasonal multipliers (Monday-first / January-first). Keyed by the
// TOP-LEVEL term's name, and children inherit their parent's — a week has a
// shape for "rest" as a whole, not one per way of resting.

const WEEKENV: Record<string, number[]> = {
  rest:        [1, 1, 1, 1, 1.05, 1.2, 1.25],
  nourishment: [1, 1, 1, 1, 1.05, 1.15, 1.15],
  movement:    [0.9, 0.95, 0.95, 0.95, 1, 1.3, 1.25],
  learning:    [1.15, 1.15, 1.1, 1.1, 1, 0.8, 0.75],
  connection:  [0.85, 0.85, 0.9, 0.95, 1.2, 1.45, 1.3],
};

const YEARENV: Record<string, number[]> = {
  rest:        [1.15, 1.1, 1, 0.95, 0.9, 0.85, 0.85, 0.9, 0.95, 1, 1.1, 1.2],
  nourishment: [1, 1, 1, 1, 1, 1, 1.05, 1.15, 1.2, 1.1, 1, 1.1],
  movement:    [0.8, 0.85, 1, 1.15, 1.25, 1.3, 1.3, 1.25, 1.1, 1, 0.85, 0.8],
  learning:    [1.1, 1.15, 1.15, 1.1, 1, 0.85, 0.75, 0.8, 1.15, 1.2, 1.15, 1],
  connection:  [1.05, 0.95, 0.95, 1, 1.05, 1.15, 1.25, 1.3, 1.05, 1, 1, 1.35],
};

/** The arithmetic mean of an envelope, or 1 for a term that has none. */
const envMean = (env: number[] | null): number => (env ? d3.mean(env)! : 1);
//                                       every envelope above is a non-empty ↑
//                                       array of numbers, so the mean exists.

/**
 * Stamp the weekly and seasonal envelopes down a tree, each node taking its own
 * by name or inheriting the one handed down. Call it on a root with no
 * inherited pair; the recursion supplies the rest.
 */
export function stampEnvelopes(node: DesireNode,
                               wk: number[] | null = null,
                               yr: number[] | null = null): void {
  node._week = WEEKENV[node.name] || wk;
  node._year = YEARENV[node.name] || yr;
  node._weekMean = envMean(node._week ?? null);
  node._yearMean = envMean(node._year ?? null);
  (node.children || []).forEach(c => stampEnvelopes(c, node._week ?? null, node._year ?? null));
}

// ── rhythm hand-over ────────────────────────────────────────────────────────
// Desire lives on the torus day × week × year, and each rhythm is legible only
// at its own scale: 240 samples of a year cannot carry the day-pulse, so the
// day-pulse hands over to its mean rather than aliasing. These two are how far
// through each hand-over the current turn sits.

const mixDay  = (): number => clamp01((Math.log(S.turnH) - Math.log(240)) / (Math.log(2160) - Math.log(240)));
const mixWeek = (): number => clamp01((Math.log(S.turnH) - Math.log(2160)) / (Math.log(8766) - Math.log(2160)));

/** Weight of need `d` at turn-position `t` (turn units, 0..24), at this scale. */
export function weightAt(d: DesireNode, t: number): number {
  const a = turnAnchor() + (t / 24) * S.turnH;             // absolute hours
  const day = bumpSum(d.base, d.bumps, ((a % 24) + 24) % 24);
  const wDay = lerp(day, d._meanW as number, mixDay());
  const wk = d._week ? d._week[Math.floor(a / 24) % 7] : 1;
  const wWeek = lerp(wk, d._weekMean || 1, mixWeek());
  const yr = d._year ? d._year[Math.floor(((a / 8766) % 1) * 12) % 12] : 1;
  return wDay * wWeek * yr;
}

/** Satisfaction of need `d` at turn-position `t`. */
export function qAt(d: DesireNode, t: number): number {
  const a = turnAnchor() + (t / 24) * S.turnH;
  const qDay = bumpSum(d.qbase, d.qbumps, ((a % 24) + 24) % 24);
  return lerp(qDay, d._meanQ as number, mixDay());
}

// ── the layout ──────────────────────────────────────────────────────────────

/** One sample around the turn: where every band's edges are at that angle. */
export interface Sample {
  /** Cumulative band edges, `nodes.length + 1` long and starting at 0. */
  cum: number[];
  /** Each band's satisfaction boundary, as an absolute position in `cum`'s frame. */
  met: number[];
  /**
   * The RAW desire mass at this sample, which normalization discards. It is
   * exactly the spend wheel's envelope — the un-normalized intensity that turns
   * the priority wheel (shares of 1) into the spend wheel (a disc that breathes
   * with how much is wanted when).
   */
  tot: number;
}

/**
 * Band geometry ALONE: the edges and the met marks, without `tot`.
 *
 * The spend envelope is a property of a whole wheel's desire mass, and the
 * frames a transition builds are not wheels — a dilating leaf is one band held
 * in its own range. So the drawers that only place edges are typed to this, and
 * a Sample is simply a frame that also knows its mass.
 */
export type BandFrame = Pick<Sample, "cum" | "met">;

/** A share-remap: where a cumulative share sits, part-way through a transition. */
export type Remap = (f: number, i: number) => number;

/**
 * Express a set of shares INSIDE band `k` of an outer layout.
 *
 * A child level's shares run 0..1 in their own frame; nesting maps them into
 * the slice of the parent's frame that band `k` occupies at every sample. It is
 * how a zoom knows where the children START before they dilate.
 */
export function nestInto(sub: BandFrame[], outer: BandFrame[], k: number): BandFrame[] {
  return d3.range(n + 1).map(i => {
    const lo = outer[i].cum[k], hi = outer[i].cum[k + 1], w = hi - lo;
    return { cum: sub[i].cum.map(f => lo + f * w),
             met: sub[i].met.map(f => lo + f * w) };
  });
}

/**
 * The dilation remap at progress `u` — identity at 0, band `k`'s own frame at 1.
 *
 * THE ONE PIECE OF ARITHMETIC BEHIND EVERY TRANSITION ON THE DIAL. Zooming in
 * runs u from 0 to 1; zooming out runs it back; the earth's reveal holds it at
 * 1 while the pigment fades and then runs it back as the band contracts. The
 * band's interior stretches to fill the disc while its siblings squash onto the
 * centre and the rim, and which of those you are watching is only a matter of
 * which way u is going.
 */
export const dilate = (lay: BandFrame[], k: number, u: number): Remap =>
  (f, i) => {
    const lo = lay[i].cum[k], hi = lay[i].cum[k + 1];
    return lerp(f, clamp01((f - lo) / (hi - lo)), u);
  };

/**
 * Both wheels' curves, sampled once around the turn.
 *
 * The means go through d3 rather than a plain fold on purpose: d3.mean SKIPS an
 * unreadable sample, and a node the stamping passes never reached has an
 * undefined `_meanW`, which makes weightAt NaN for its whole column. Folding by
 * hand would spread that one hole across every band; d3 steps over it, and the
 * `!` at each use says only that an all-unreadable column stays NaN exactly as
 * it did before.
 */
interface Curves {
  /** Weight per sample per node. */
  W: number[][];
  /** Satisfaction per sample per node. */
  Q: number[][];
  /** Each node's phase-average weight — what σ flattens toward. */
  mW: (number | undefined)[];
  /** Each node's phase-average satisfaction. */
  mQ: (number | undefined)[];
}

const sampleCurves = (nodes: DesireNode[]): Curves => {
  const W = d3.range(n + 1).map(i => nodes.map(d => weightAt(d, 24 * i / n)));
  const Q = d3.range(n + 1).map(i => nodes.map(d => qAt(d, 24 * i / n)));
  return {
    W, Q,
    mW: nodes.map((_, k) => d3.mean(W, row => row[k])),
    mQ: nodes.map((_, k) => d3.mean(Q, row => row[k])),
  };
};

/**
 * Raw weights → one sample's band edges. Normalising to shares is what makes
 * the two wheels the same instrument: whatever the weights MEAN — an hour of
 * the turn, or a share of drawable credit — the edges are their proportions,
 * and satisfaction rides inside each band at the same σ blend.
 */
const assemble = (ws: number[], i: number, c: Curves): Sample => {
  const tot = d3.sum(ws);
  let acc = 0;
  const cum = [0], met = [];
  for (let k = 0; k < ws.length; k++) {
    const s = ws[k] / tot;
    const q = Math.min(0.97,
      c.Q[i][k] * (1 - S.sigma) + c.mQ[k]! * DEPRIVATION * S.sigma);
    met.push(acc + q * s);
    acc += s;
    cum.push(acc);
  }
  return { cum, met, tot };
};

/**
 * THE PRIORITY WHEEL: cumulative band edges + met boundaries for a sibling set.
 * Unit-sum at every angle, because it is the TIME budget and every hour holds
 * exactly one hour. σ flattens the weights toward their phase-average over THIS
 * turn — the average at every scale, not only the day's.
 */
export function layout(nodes: DesireNode[]): Sample[] {
  const c = sampleCurves(nodes);
  return d3.range(n + 1).map(i =>
    assemble(nodes.map((_, k) => c.W[i][k] * (1 - S.sigma) + c.mW[k]! * S.sigma), i, c));
}

/**
 * THE SPEND WHEEL: the same geometry, re-denominated in credit-flow. Each
 * band's mass is the share of drawable credit its subtree's claimable goods
 * carry (the shop's order-book projection), shaped through time by the band's
 * own phase curve, mean-normalized so the shape contributes rhythm and not
 * level. Radius is then credit-flow density — embodied-hours per clock-hour
 * once scaled by K·v, a real unit — and non-purchasable bands (rest, movement…)
 * honestly collapse to hairlines rather than being hidden.
 *
 * Null when nothing under this focus is claimable; spend mode falls back to
 * priority, which always has an answer.
 */
export function spendLayout(nodes: DesireNode[]): Sample[] | null {
  const mass = spendMassByTerm(nodes, EXT);
  let maxM = 0;
  for (const m of mass.values()) maxM = Math.max(maxM, m);
  if (maxM <= 0) return null;
  const floor = 0.006 * maxM;                    // hairline: keep navigation alive
  const c = sampleCurves(nodes);
  const mW = c.mW.map(m => Math.max(1e-9, m!));  // the divisor below, kept off 0
  return d3.range(n + 1).map(i =>
    assemble(nodes.map((d, k) => {
      const shape = (c.W[i][k] * (1 - S.sigma) + mW[k] * S.sigma) / mW[k];
      return Math.max(floor, mass.get(d) || 0) * shape;
    }), i, c));
}

/**
 * Blend priority (`a`) and spend (`b`) geometry by u — the tween's road as the
 * wheel morphs from one denomination to the other. `tot` takes the spend
 * envelope outright rather than interpolating: it is a radial scale, and a
 * half-way scale between two units is not a unit.
 */
export function blendLay(a: Sample[], b: Sample[] | null, u: number): Sample[] {
  if (!b || u <= 0) return a;
  if (u >= 1) return b;
  return a.map((sa, i) => ({
    cum: sa.cum.map((v, k) => lerp(v, b[i].cum[k], u)),
    met: sa.met.map((v, k) => lerp(v, b[i].met[k], u)),
    tot: b[i].tot,
  }));
}

// ── rhythm (harmonics) ──────────────────────────────────────────────────────
// Per-harmonic mean resultants of a band's share curve: R̄_k measures how locked
// the need is to rhythm k (k=1 circadian, 2 the commute pair, 3 mealtimes …).
// The FIRST resultant alone misleads — two antipodal peaks cancel at k=1 and
// shine at k=2 — so the whole spectrum is read.

/** How many harmonics the spectrum carries. */
export const KMAX = 6;

/** A band's share at sample `i`, which is all the harmonics need to see. */
export type ShareAt = (i: number) => number;

/** The mean resultants [R̄_1 … R̄_KMAX] of a share curve. */
export function spectrum(share: ShareAt): number[] {
  let tot = 0;
  for (let i = 0; i < n; i++) tot += share(i);
  const out: number[] = [];
  for (let k = 1; k <= KMAX; k++) {
    let re = 0, im = 0;
    for (let i = 0; i < n; i++) {
      const th = TAU * i / n, w = share(i);
      re += w * Math.cos(k * th); im += w * Math.sin(k * th);
    }
    out.push(Math.hypot(re, im) / Math.max(tot, 1e-9));
  }
  return out;
}

/** A local maximum of a share curve: the hour, the height, and the sample. */
export interface Peak {
  t: number;
  w: number;
  i: number;
}

/** The four strongest peak hours of a share curve, for the lead markers. */
export function peakHours(share: ShareAt): Peak[] {
  const pk: Peak[] = [];
  for (let i = 0; i < n; i++) {
    const a = share((i + n - 1) % n), b = share(i), c = share((i + 1) % n);
    if (b > a && b >= c) pk.push({ t: 24 * i / n, w: b, i });
  }
  pk.sort((x, y) => y.w - x.w);
  return pk.slice(0, 4);
}
