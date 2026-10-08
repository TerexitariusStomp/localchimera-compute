// app/spine.ts — the dial's spine: the taxonomy, become a tree you can draw.
//
// The planner classifies work through `resourceClassifiedAs`, the gateway
// derives the tree from it, and it is pushed here. So the dial's spine IS the
// planner's taxonomy — which is the whole point: a work-intent's `serves` then
// matches the leaf you are looking at, and eligible work lands on the map with
// no mapping table anywhere in between. Standalone, the demo tree stands.
//
// ── STRUCTURE AND SIGNAL ARE SEPARATE, AND JOINED HERE ──────────────────────
// A TAXONOMY carries terms and nothing else. A DESIRE TABLE carries a curve per
// term, keyed by id. buildRoot joins them into the working tree the dial
// renders, and either can be replaced without touching the other — a new spine
// keeps your priorities, a new priority signal keeps the spine.
//
// ── THE COLOURS ARE SHARED, NOT LOCAL ───────────────────────────────────────
// A top-level term first asks the app-wide palette by id and name, so a need
// that also names a limit on the fragility dials wears the SAME hue there. Only
// what the palette does not know falls back to the rotating list. Children then
// inherit shades of their parent, dark to light. The demo taxonomy names its
// own colours and skips the whole thing.
//
// ── REBUILDS ARE STRUCTURAL, NOT PER-TICK ───────────────────────────────────
// Both entry points compare against what they last saw and return early when
// nothing changed: a re-solve that re-sends the same taxonomy, or the same
// desire signal, must not reset the view you were reading.

import { S } from './state.js';
import { EXT, cDeep, cYea } from './core.js';
import { seam } from './seam.js';
import { registerTree, colorFor } from './palette.js';
import { stampMeans, stampEnvelopes } from './bands.js';
import { DEMO_DESIRE } from './demo.js';
import type { TaxonomyTerm, DesireTable, DesireCurve } from './demo.js';
import type { DesireNode, DescendantIndex } from './desire.js';

import { on } from './bus.js';

/** Publish the hand-edited spine over the handler; installed by initSpine. */
let publishSpine: () => Promise<unknown> = () => Promise.resolve("err");
/** What rebuilding the spine needs the dial to do afterwards. */
export interface SpineHost {
  /** A new tree: drop the focus and the open card, re-lay-out, repaint. */
  afterRebuild(): void;
  /** The same tree, re-shaped: re-lay-out the current view and repaint. */
  redraw(): void;
}

let host: SpineHost;

/**
 * Join a taxonomy and a desire table into the working tree.
 *
 * A term the desire table does not name still renders, riding a gentle default
 * — and `expressed` records which it was, because the shop's filter bar
 * separates the two groups and "no opinion" is not the same as "a small one".
 */
export function buildRoot(tax: TaxonomyTerm, desire: DesireTable): DesireNode {
  const DEFAULT: DesireCurve = { base: 0.12, bumps: [], qbase: 0.30, qbumps: [] };
  const walk = (node: TaxonomyTerm): DesireNode => {
    const sig = (node.id && desire[node.id]) || DEFAULT;
    const out: DesireNode = {
      id: node.id, name: node.label || node.id,
      count: (node as { count?: number }).count || 0,   // how many nest this term here
      expressed: !!(node.id && desire[node.id]),
      base: sig.base, bumps: sig.bumps, qbase: sig.qbase, qbumps: sig.qbumps,
    };
    if (node.col) out.col = node.col;
    if (node.children) out.children = node.children.map(walk);
    return out;
  };
  return walk(tax);
}

/** The fallback hues, for terms the shared palette does not know. */
const TOP_PALETTE = [cDeep, "#e8654f", "#0e7c7b", cYea, "#7a4bb0",
                     "#b8860b", "#2e7d32", "#1581a8", "#c2756a", "#3f8f6a"];

/** A distinct hue per top-level term: the shared palette first, then the list. */
export function colorTop(r: DesireNode): void {
  (r.children || []).forEach((c, i) => {
    if (!c.col) c.col = colorFor(c.id, c.name) || TOP_PALETTE[i % TOP_PALETTE.length];
  });
}

/** Children inherit shades of the parent, dark to light — unless named. */
export function tintTree(node: DesireNode): void {
  if (!node.children) return;
  node.children.forEach((c, i) => {
    if (!c.col) {
      const t = node.children!.length === 1 ? 0.5 : i / (node.children!.length - 1);
      c.col = colorFor(c.id, c.name) || d3.interpolateRgb(
        d3.color(node.col!).darker(0.55),
        d3.color(node.col!).brighter(0.85))(t).toString();
    }
    c.parent = node;
    tintTree(c);
  });
  node.children.forEach(c => c.parent = node);
}

/**
 * id → the ids of that term's whole subtree, itself included.
 *
 * Term ids are FLAT (`term:grain`), so ancestry is the TREE and not slashes in
 * the string — this index is what a thing's classification is matched against
 * when the question is "at-or-under the leaf".
 */
export function indexDescendants(root: DesireNode): DescendantIndex {
  const m: DescendantIndex = new Map();
  const walk = (n: DesireNode): void => {
    const set = new Set([n.id]);
    for (const c of (n.children || [])) {
      walk(c);
      for (const x of m.get(c.id)!) set.add(x);
    }
    m.set(n.id, set);
  };
  walk(root);
  return m;
}

/**
 * A term's chain, leaf first, up to (not including) the root — the ladder a
 * slot's cats carry so two cousins can meet inside the affinity scorer's
 * distance cap. tintTree wrote the `parent` links this climbs.
 */
export function termChain(n: DesireNode): string[] {
  const out: string[] = [];
  for (let c: DesireNode | undefined = n; c && c !== S.root && c.id !== "all"; c = c.parent)
    out.push(c.id);
  return out;
}

// ── publishing the spine back ───────────────────────────────────────────────

/**
 * The spine as the wire's own line format: a T line per term, an E line per
 * edge. Tabs separate, so tabs and newlines are scrubbed out of names rather
 * than escaped — a term whose label breaks the format is a term nobody can
 * read anyway.
 */
function spineToWire(root: DesireNode): string {
  const lines: string[] = [];
  const clean = (s: unknown): string => String(s).replace(/[\t\n]/g, " ");
  const walk = (n: DesireNode, parent: string | null): void => {
    if (n && n.id && n.id !== "all") {
      lines.push("T\t" + clean(n.id) + "\t" + clean(n.name || n.id));
      if (parent && parent !== "all") lines.push("E\t" + clean(parent) + "\t" + clean(n.id));
    }
    (n.children || []).forEach(c => walk(c, n.id));
  };
  walk(root, null);
  return lines.join("\n");
}

// ── the live spine ──────────────────────────────────────────────────────────

/** The taxonomy the wheel is currently built over. The folksonomy may swap it. */
let curTax: TaxonomyTerm;
/** The last desire signal, serialized — the guard against a pointless rebuild. */
let lastDesireSig: string | null = null;
/** The last taxonomy, serialized. Same guard, other entry point. */
let lastTaxSig: string | null = null;

/**
 * Build the wheel's desire signal from a scope's aggregate demand.
 *
 * Each need's `want` sizes its sector and `met` tints the quality ring, matched
 * to a taxonomy node by id and then by name — the same per-scope fold the plan
 * sidebar shows, so the wheel's shape and the sidebar's numbers cannot disagree.
 *
 * Null when nothing is wanted: an empty signal would flatten the wheel, and
 * "the plan asked for nothing" is not the same as "nobody wants anything".
 */
export function desireFromNeeds(
  needs: { id?: string; label?: string; want?: number | string; met?: number | string }[]
): DesireTable | null {
  const wants = (needs || []).filter(n => +(n.want ?? 0) > 0);
  const total = wants.reduce((s, n) => s + (+(n.want ?? 0) || 0), 0);
  if (!total) return null;
  const byKey: Record<string, DesireNode> = {};
  const idx = (nd: DesireNode | null | undefined): void => {
    if (!nd) return;
    if (nd.id)   byKey[String(nd.id).toLowerCase()]   = nd;
    if (nd.name) byKey[String(nd.name).toLowerCase()] = nd;
    (nd.children || []).forEach(idx);
  };
  idx(S.root);
  const sig: DesireTable = {};
  wants.forEach(n => {
    const node = byKey[String(n.id).toLowerCase()] || byKey[String(n.label || "").toLowerCase()];
    if (node && node.id)
      sig[node.id] = { base: (+(n.want ?? 0) || 0) / total, bumps: [],
                       qbase: +(n.met ?? 0) || 0.3, qbumps: [] };
  });
  return Object.keys(sig).length ? sig : null;
}

/** Rebuild the working tree over a taxonomy, and repaint everything. */
export function rebuildSpine(tax: TaxonomyTerm): void {
  curTax = tax;
  S.root = buildRoot(tax, (EXT.desire as DesireTable) || DEMO_DESIRE);
  colorTop(S.root); tintTree(S.root); S.root.col = "#999";
  // BOTH stamping passes, as at boot: buildRoot makes fresh nodes, so a rebuilt
  // spine carries neither the phase-averages σ flattens toward nor the
  // weekly/seasonal envelopes until they are stamped on it.
  stampMeans(S.root); stampEnvelopes(S.root);
  S.desc = indexDescendants(S.root);
  host.afterRebuild();
}

/**
 * Build the spine at boot and install the two inbound seams.
 *
 * EXT.root is the escape hatch for a host that has already built a tree; every
 * other path goes through buildRoot so the colouring and the stamping cannot be
 * skipped by accident.
 */
export function initSpine(h: SpineHost, tax: TaxonomyTerm, desire: DesireTable): void {
  host = h;
  curTax = tax;
  S.root = (EXT.root as DesireNode | undefined) || buildRoot(tax, desire);
  colorTop(S.root); tintTree(S.root); S.root.col = "#999";
  // Seed the app-wide colour registry from the tree, so the fragility dials
  // colour a need by the same hue it wears here.
  registerTree(S.root);

  publishSpine = () => {
    const h2 = seam.handlers;
    return (h2 && h2.publishSpine && S.root)
      ? h2.publishSpine(spineToWire(S.root))
      : Promise.resolve("err");
  };

  /**
   * A per-scope desire signal reshapes the wheel — the aggregation of desires
   * for the SELECTED scope. Its temporal shape still rides the shared curves
   * until the backend emits per-scope ones.
   */
  on("desire", (sig: unknown) => {
    if (!sig || typeof sig !== "object" || !Object.keys(sig).length) return;
    const key = JSON.stringify(sig);
    if (key === lastDesireSig) return;   // a re-solve must not reset the view
    lastDesireSig = key;
    EXT.desire = { ...((EXT.desire as DesireTable) || DEMO_DESIRE), ...(sig as DesireTable) };
    rebuildSpine(curTax);
  });

  on("taxonomy", (tx: unknown) => {
    const t = tx as TaxonomyTerm | null;
    if (!t || !Array.isArray(t.children) || !t.children.length) return;
    const key = JSON.stringify(t);
    if (key === lastTaxSig) return;      // structural changes only
    lastTaxSig = key;
    rebuildSpine(t);
  });
}

// ── editing the spine ───────────────────────────────────────────────────────
//
// The TWEAK arm of the folksonomy loop. Alt+click a term to GRAB it, Alt+click
// another to NEST it there. The edited tree is published (publishSpine →
// sync-taxonomy → the folksonomy actor), so your tweak becomes a VOTE: the
// aggregate re-derives and the authoritative cut is pushed back down through
// seam.taxonomy. It is the same shape as labour-skill aggregation — a
// per-AID change folds into the scope aggregate, and the query reflects it.
//
// Which is why the local edit is not the point of it. What you see immediately
// is your own reading; what everyone sees is what the aggregate makes of it.

/** The term lifted and awaiting a drop, by id. Null when nothing is grabbed. */
let grabbedId: string | null = null;

/** Which term is lifted — the wheel draws it at half opacity. */
export const grabbedTerm = (): string | null => grabbedId;

/** Find a term anywhere in the tree. */
function findById(node: DesireNode | null | undefined, id: string): DesireNode | null {
  if (!node) return null;
  if (node.id === id) return node;
  for (const c of (node.children || [])) { const r = findById(c, id); if (r) return r; }
  return null;
}

const isAncestorOf = (a: DesireNode, b: DesireNode): boolean => {
  for (let x: DesireNode | undefined = b; x; x = x.parent) if (x === a) return true;
  return false;
};

/** Move `node` under `newParent`, and publish the reading. */
function reparentTerm(node: DesireNode | null, newParent: DesireNode): void {
  if (!node || !newParent || node === newParent || !node.parent) return;
  if (isAncestorOf(node, newParent)) return;      // a term cannot nest inside itself
  const sibs = node.parent.children || [];
  const i = sibs.indexOf(node);
  if (i >= 0) sibs.splice(i, 1);
  (newParent.children || (newParent.children = [])).push(node);
  node.parent = newParent;
  host.redraw();
  publishSpine();   // → aggregate → re-derive → back
}

/** Alt+click a term: grab it, cancel it, or drop the held one onto it. */
export function spineEditClick(d: DesireNode): void {
  if (!grabbedId)              { grabbedId = d.id; host.redraw(); }
  else if (grabbedId === d.id) { grabbedId = null; host.redraw(); }   // onto itself: cancel
  else { const g = findById(S.root, grabbedId); grabbedId = null; reparentTerm(g, d); }
}

/** Escape drops whatever is held — a grab must never be a state you are stuck in. */
window.addEventListener("keydown", e => {
  if (e.key === "Escape" && grabbedId) { grabbedId = null; host.redraw(); }
});
