// app/tabs/match.ts — the "match" face: the ring of needs and offers.
//
// The match prototype's ring visualization, rehomed: every standing need in
// the scope (■, inner ring) and every declared means (●, outer ring), with a
// chord for each scored pairing — classification affinity over the commons'
// OWN folksonomy cut × time-window overlap × quantity coverage, geometric
// mean (planner matching/affinity.scm; the service's match-slots does the
// scoring, this face only draws). Click a node to lock it: its chords and its
// label (and its matches') stay lit on the ring — there is no second list.
//
// No sidepanel: browsing and searching go through the ONE shared toolbar (the
// bottom bar's Advocate box + time/location) that the map's markers already
// narrow by — a query typed there dims the ring exactly as it dims map pins,
// one filter for both surfaces rather than a second search box here. The
// match floor is the one control that IS this face's own (it shapes the
// chords, not the pool), so it rides on the stage itself, not a rail.
//
// Matching is INTRODUCTION, not provision: a chord tells two people they
// should talk. Committing provision stays with the plan (a need slot asks
// the plan first; share.js), custody with socialization. Nothing here moves.
//
// Colours come from the one palette (the slot's terms resolve to their spine
// node's hue — the same coral "nourishment" wears everywhere), never a
// per-face scheme. Standalone, the face runs on demo slots scored by a local
// twin of the affinity scorer, the same rule as every other tab: the server
// arrives, the demo yields.

import { HANDLERS } from '../core.js';
import { html, render } from '../template.js';
import { signal, effect } from '../reactive.js';
import { S } from '../state.js';
import { termNode } from '../desire-projection.js';
import { colorFor } from '../palette.js';
import { slotFace } from '../slots/card.js';
import * as share from './social/share.js';
import { passesRhythm } from './map/atlas.js';
import { SOCIAL_DEMO_POOL } from '../demo/social-pool.js';
import type { Arc } from '../slots/model.js';
import type { DesireNode } from '../desire.js';
import { mk as mkEl } from '../dom.js';

/**
 * A slot in the ring — a need or an offer. The demo pool carries the same
 * shape the server's match-slots returns, so the two are interchangeable.
 */
export interface RingSlot {
  id: string;
  spec?: string;
  name?: string;
  emoji?: string;
  /** Who asks (a need) or who provides (an offer). */
  who?: string;
  owner?: string;
  note?: string;
  qty?: number;
  unit?: string;
  /** Classification ids, most specific first. */
  cats?: string[];
  arcs?: Arc[];
  [key: string]: unknown;
}

/** How well two slots meet on ONE dimension. */
export interface Dimension {
  dim: string;
  score: number;
}

/**
 * The best shared term between two slots' classifications: how far up the
 * ladder the agreement is, and how specific the term reached.
 */
export interface CatMatch {
  term: string;
  /** Rungs climbed from the more specific side. Past 1 they stop counting. */
  distance: number;
  score: number;
  specificity: number;
}

/** One offer scored against a need. */
export interface Hit {
  id: string;
  score: number;
  term: string;
  distance: number;
  specificity: number;
  dims: Dimension[];
}

/** A need, and every offer that clears the floor. */
export interface MatchRow {
  need: string;
  hits: Hit[];
}

/** What the ring draws: the two rails and the chords between them. */
export interface MatchData {
  needs: RingSlot[];
  means: RingSlot[];
  matches: MatchRow[];
  /** True only when the server brought nothing and the demo twin stands in. */
  demo?: boolean;
}

/** A chord: one need meeting one capacity, carrying the hit that scored it. */
interface Chord {
  need: string;
  cap: string;
  hit: Hit;
}

/** A pooled slot, tagged with which rail it sits on. */
type PooledSlot = RingSlot & { kind: "need" | "capacity" };

// ── state ──────────────────────────────────────────────────────────────────
const data = signal<MatchData>({ needs: [], means: [], matches: [], demo: true });
const locked = signal<string | null>(null);        // a locked node id, or null
const hovered = signal<string | null>(null);
const threshold = signal(0.5);      // the affinity scorer's own floor

// ── the demo pool (standalone twin of the server's match-slots) ────────────
// app/demo/social-pool.ts — the SAME twin the share bar's We view stands up
// offline, so the ring and the drawer never show two unrelated worlds.
const DEMO: { needs: RingSlot[]; means: RingSlot[] } = {
  needs: SOCIAL_DEMO_POOL.needs as RingSlot[],
  means: SOCIAL_DEMO_POOL.means as RingSlot[],
};

// the DEMO scorer — the local twin of matching/affinity.scm, over the spine's
// parent pointers instead of a folksonomy template. Same formulas: distance-
// decayed chain overlap (cap 1), same-spec floor, 0.5 for the unknown side,
// geometric mean, one zero vetoes.
function chainOf(tid: string): string[] {
  let n: DesireNode | null | undefined = termNode(tid);
  if (!n) return [tid];
  const chain: string[] = [];
  for (; n && n !== S.root; n = n.parent) chain.unshift(n.id);
  return chain;
}
function bestCat(catsA: string[] | undefined, catsB: string[] | undefined): CatMatch | null {
  let best: CatMatch | null = null;
  for (const ca of catsA || []) {
    const A = chainOf(ca);
    for (const cb of catsB || []) {
      const B = new Set(chainOf(cb));
      for (let i = A.length - 1; i >= 0; i--) {
        if (!B.has(A[i])) continue;
        const dist = A.length - 1 - i;
        if (dist > 1) break;
        const score = Math.max(0.5, 1 - 0.2 * dist);
        const spec = Math.min(i + 1, 6) / 6;
        if (!best || score > best.score) best = { term: A[i], distance: dist, score, specificity: spec };
        break;
      }
    }
  }
  return best;
}
function timeScore(a: RingSlot, b: RingSlot): number {
  const A = a.arcs || [], B = b.arcs || [];
  if (!A.length || !B.length) return 0.5;
  const mins = (t: string): number => { const [h, m] = String(t).split(":").map(Number); return h * 60 + (m || 0); };
  for (const x of A) for (const y of B) {
    const days = (x.days || []).some(d => (y.days || []).includes(d));
    if (days && mins(x.start) < mins(y.end) && mins(y.start) < mins(x.end)) return 1;
  }
  return 0;
}
function demoMatches(needs: RingSlot[], means: RingSlot[]): MatchRow[] {
  return needs.map(n => ({
    need: n.id,
    hits: means.flatMap(c => {
      const cat = n.spec && n.spec === c.spec
        ? { term: n.spec, distance: 0, score: 1, specificity: 0.5 }
        : bestCat(n.cats, c.cats);
      if (!cat) return [];
      const dims: [string, number][] = [["category", cat.score], ["time", timeScore(n, c)]];
      if (Number(n.qty) > 0 && Number(c.qty) > 0)
        dims.push(["quantity", n.unit === c.unit ? Math.min(1, Number(c.qty) / Number(n.qty)) : 0.5]);
      const vals = dims.map(d => d[1]);
      const score = vals.some(v => v === 0) ? 0
        : Math.pow(vals.reduce((p, v) => p * v, 1), 1 / vals.length);
      return score >= 0.5
        ? [{ id: c.id, score, term: cat.term, distance: cat.distance,
             specificity: cat.specificity,
             dims: dims.map(([dim, s]) => ({ dim, score: s })) }]
        : [];
    }).sort((a, b) => b.score - a.score),
  }));
}

// ── fetching ───────────────────────────────────────────────────────────────
function refresh(): void {
  if (!HANDLERS.matchSlots) {
    data.set({ ...DEMO, matches: demoMatches(DEMO.needs, DEMO.means), demo: true });
    return;
  }
  HANDLERS.matchSlots().then(reply => {
    if (typeof reply !== "string" || !reply || reply.startsWith("err:")) {
      data.set({ ...DEMO, matches: demoMatches(DEMO.needs, DEMO.means), demo: true });
      return;
    }
    try {
      const v = JSON.parse(reply);
      const num = (x: unknown): number => { const n = parseFloat(String(x)); return isFinite(n) ? n : 0; };
      const slot = (s: RingSlot): RingSlot => ({ ...s, qty: num(s.qty), cats: s.cats || [] });
      data.set({
        needs: (v.needs || []).map(slot),
        means: (v.means || []).map(slot),
        matches: (v.matches || []).map((m: MatchRow) => ({
          need: m.need,
          hits: (m.hits || []).map((h: Hit) => ({
            ...h, score: num(h.score), distance: num(h.distance),
            specificity: num(h.specificity),
            dims: (h.dims || []).map((d: Dimension) => ({ dim: d.dim, score: num(d.score) })),
          })),
        })),
        demo: false,
      });
    } catch (_) { /* a malformed reply leaves the demo standing */ }
  });
}

// ── lookups over the current pool ──────────────────────────────────────────
const byId = () => {
  const m = new Map();
  const d = data();
  d.needs.forEach(s => m.set(s.id, { ...s, kind: "need" }));
  d.means.forEach(s => m.set(s.id, { ...s, kind: "capacity" }));
  return m;
};
// every chord above the slider, flattened: {need, cap, hit}
const chords = () => {
  const th = threshold();
  return data().matches.flatMap(m =>
    m.hits.filter(h => h.score >= th).map(h => ({ need: m.need, cap: h.id, hit: h })));
};
const hitsFor = (id: string): Chord[] => chords().filter(c => c.need === id || c.cap === id);
// a slot's one-line provenance: whose it is and what it comes to
const whoLine = (s: PooledSlot): string => {
  const person = s.kind === "need" ? (s.who || "someone") : (s.owner || "someone");
  const verb = s.kind === "need" ? "asks" : "offers";
  return `${person} ${verb}${Number(s.qty) > 0 ? ` · ${s.qty} ${s.unit || "each"}` : ""}`;
};
// a slot the toolbar's search excludes fades on the ring, exactly as the
// map's markers fade to what the same search names (markers.ts matchesShare)
// — one filter, two surfaces. Reading share.F/draftWhen/draftWhere here is
// what subscribes the ring's effect to a keystroke in the bottom bar.
const searching = (): boolean =>
  !!share.F.query().trim() || share.F.timeBy() !== "any" ||
  share.draftWhen().length > 0 || !!share.draftWhere();
const dimmed = (s: PooledSlot): boolean => searching() && !(
  share.F.passes(s) && passesRhythm(s, share.draftWhen()) &&
  (!share.draftWhere() || s.where === share.draftWhere())
);
const slotCol = (s: PooledSlot): string =>
  (s.cats || []).map(c => termNode(c)?.col || colorFor(c)).find(Boolean)
  || colorFor(s.spec, s.name)
  || (s.kind === "need" ? "#3d7dc8" : "#4a9d5f");

// ── the ring ───────────────────────────────────────────────────────────────
const R_CAP = 330, R_NEED = 205;
const pos = (i: number, n: number, r: number): [number, number] => {
  const a = (i / Math.max(1, n)) * 2 * Math.PI - Math.PI / 2;
  return [r * Math.cos(a), r * Math.sin(a)];
};
// a chord bowing away from the centre (the prototype's sagitta arc):
// radius from chord length L and sagitta h = 0.15 L.
function chordPath([x1, y1]: [number, number], [x2, y2]: [number, number]): string {
  const L = Math.hypot(x2 - x1, y2 - y1);
  if (L < 1) return `M${x1},${y1}`;
  const h = 0.15 * L;
  const r = (L * L / 4 + h * h) / (2 * h);
  const sweep = (x1 * y2 - y1 * x2) > 0 ? 0 : 1;   // bow outward, not through 0
  return `M${x1},${y1} A${r},${r} 0 0,${sweep} ${x2},${y2}`;
}

function drawRing() {
  const stage = d3.select("#matchring");
  if (stage.empty()) return;
  const d = data(), lock = locked(), hov = hovered();
  const focus = lock || hov;
  const connected = new Set();
  if (focus) hitsFor(focus).forEach(c => { connected.add(c.need); connected.add(c.cap); });
  const P = new Map();
  d.means.forEach((s, i) => P.set(s.id, pos(i, d.means.length, R_CAP)));
  d.needs.forEach((s, i) => P.set(s.id, pos(i, d.needs.length, R_NEED)));

  const svg = stage.selectAll("svg").data([0]).join("svg")
    .attr("viewBox", "-400 -400 800 800")
    .on("click", () => { locked.set(null); });

  svg.selectAll("g.mchords").data([0]).join("g").attr("class", "mchords")
    .selectAll("path")
    .data(chords().filter(c => P.has(c.need) && P.has(c.cap)),
          c => c.need + "→" + c.cap)
    .join("path")
    .attr("d", c => chordPath(P.get(c.need), P.get(c.cap)))
    .attr("fill", "none")
    .attr("stroke", c => slotCol(byId().get(c.need) || {}))
    .attr("stroke-width", c => Math.max(2.5, c.hit.score * 10))
    .attr("stroke-linecap", "round")
    .attr("opacity", c => {
      const on = focus && (c.need === focus || c.cap === focus);
      if (focus) return on ? 0.9 : 0.06;
      return Math.min(0.75, 0.25 + c.hit.score * c.hit.score * 0.5);
    });

  const nodes: PooledSlot[] = [...d.means.map((s): PooledSlot => ({ ...s, kind: "capacity" })),
                 ...d.needs.map((s): PooledSlot => ({ ...s, kind: "need" }))];
  svg.selectAll("g.mnodes").data([0]).join("g").attr("class", "mnodes")
    .selectAll("g.mn")
    .data(nodes, (s: PooledSlot) => s.id)
    .join(enter => {
      const g = enter.append("g").attr("class", "mn").style("cursor", "pointer");
      g.append("path");
      g.append("title");
      return g;
    })
    .attr("transform", s => { const [x, y] = P.get(s.id); return `translate(${x},${y})`; })
    .on<MouseEvent>("mouseenter", (ev, s) => { hovered.set(s.id); moveTip(ev); })
    .on("mousemove", moveTip)
    .on("mouseleave", () => hovered.set(null))
    .on("click", (ev, s) => { ev.stopPropagation();
                              locked.set(locked() === s.id ? null : s.id); })
    .call(g => {
      g.select("path")
        .attr("d", s => s.kind === "need"
          ? "M-7,-7 h14 v14 h-14 Z"
          : "M0,-8 A8,8 0 1,0 0,8 A8,8 0 1,0 0,-8 Z")
        .attr("fill", s => slotCol(s))
        .attr("stroke", s => (focus && (s.id === focus || connected.has(s.id)))
          ? "#ffffff" : "none")
        .attr("stroke-width", 2.5)
        .attr("opacity", s => dimmed(s) ? 0.12
          : (!focus || s.id === focus || connected.has(s.id)) ? 1 : 0.35);
      g.select("title")
        .text(s => `${s.emoji || ""} ${s.name} — ${whoLine(s)}`);
    });

  // labels: every node names itself on the ring; a lock or hover just raises
  // its own label (and its matches') above the rest. Radial anchor, so text
  // falls outward.
  svg.selectAll("g.mlabels").data([0]).join("g").attr("class", "mlabels")
    .selectAll("text")
    .data(nodes, (s: PooledSlot) => s.id)
    .join("text")
    .attr("x", s => { const [x] = P.get(s.id); return x + 13 * Math.sign(x || 1); })
    .attr("y", s => P.get(s.id)[1] + 4)
    .attr("text-anchor", s => P.get(s.id)[0] < 0 ? "end" : "start")
    .attr("class", "mt-label")
    .attr("opacity", s => dimmed(s) ? 0.08
      : !focus ? 0.55
      : (s.id === focus || connected.has(s.id)) ? 1 : 0.12)
    .text(s => `${s.emoji || ""} ${s.name}`);
}

// ── the hover tooltip: the slot itself, in the share bar's card grammar ─────
// The prototype floated a tooltip per node; here it is ONE card that follows
// the pointer, built by slots/card.js slotFace — the same emoji · name · qty ·
// unit head and 🕐/📍/✎ summaries the share bar draws, so a slot looks the
// same wherever it is met.
function moveTip(ev: MouseEvent): void {
  const tip = document.getElementById("matchtip");
  if (!tip) return;
  const pad = 14, w = tip.offsetWidth || 240, h = tip.offsetHeight || 90;
  const host = document.getElementById("matchstage")!.getBoundingClientRect();
  let x = ev.clientX - host.left + pad, y = ev.clientY - host.top + pad;
  if (x + w > host.width) x = ev.clientX - host.left - w - pad;
  if (y + h > host.height) y = ev.clientY - host.top - h - pad;
  tip.style.left = `${Math.max(4, x)}px`;
  tip.style.top = `${Math.max(4, y)}px`;
}
function drawTip() {
  const tip = document.getElementById("matchtip");
  if (!tip) return;
  const id = hovered(), s = id && byId().get(id);
  tip.classList.toggle("on", !!s);
  tip.replaceChildren();
  if (!s) return;
  const n = hitsFor(s.id).length;
  tip.appendChild(slotFace(s, {
    kind: s.kind, who: whoLine(s), tint: slotCol(s),
    chips: [Object.assign(document.createElement("span"),
      { className: "mt-tipmatches",
        textContent: n ? `${n} match${n === 1 ? "" : "es"} · click to hold` : "no match yet" })],
  }));
}

// ── the match floor — the one control that's this face's own ──────────────
// It shapes which chords exist (below it, a pairing doesn't draw at all), not
// which of the pool shows — so it lives on the stage beside the ring, not in
// the shared toolbar.
const pct = (x: number): string => `${Math.round(x * 100)}%`;

// built once — a rebuilt <input type=range> loses the pointer mid-drag —
// then only the label text and the input's own value are kept in step.
let floorRange: HTMLInputElement | null = null;
function drawFloor(): void {
  const bar = document.getElementById("matchfloor");
  if (!bar) return;
  const th = threshold();
  if (!floorRange) {
    bar.replaceChildren();
    const label = mkEl("label", "mt-floor-l", "match floor ");
    const b = mkEl("b", null, pct(th));
    label.append(b);
    floorRange = mkEl("input", "mt-floor-r") as HTMLInputElement;
    floorRange.type = "range"; floorRange.min = "0.3"; floorRange.max = "0.95"; floorRange.step = "0.05";
    floorRange.oninput = () => threshold.set(Number(floorRange!.value));
    label.append(floorRange);
    bar.append(label);
  }
  bar.querySelector("b")!.textContent = pct(th);
  if (document.activeElement !== floorRange) floorRange.value = String(th);
}

// ── the face ───────────────────────────────────────────────────────────────
let booted = false;
export function initMatch() {
  if (!booted) {
    booted = true;
    render("#matchstage", html`<div id="matchring"></div><div id="matchtip"></div><div id="matchfloor"></div>`);
    effect(() => { drawRing(); });
    effect(() => { drawFloor(); });
    effect(() => { drawTip(); });
    document.addEventListener("playnet:theme", () => { drawRing(); });
  }
  refresh();
}
