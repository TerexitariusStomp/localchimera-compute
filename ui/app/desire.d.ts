// app/desire.d.ts — the vocabulary of the desire tree. Types only, no runtime.
//
// The tree is the dial's central structure and four modules speak about it:
// main.js BUILDS it (buildRoot → colorTop → tintTree), state HOLDS it (S.root),
// desire-projection WALKS it, and palette is SEEDED from it. Saying its shape
// once here is what keeps those four saying the same thing.
//
// It costs nothing at runtime. Every import of this file is `import type`, and a
// .d.ts emits no module at all — so state.ts stays the leaf it has always been,
// and desire-projection keeps its "imports only state" promise. The type graph
// gains a shared vocabulary; the module graph is untouched.

import type { ColouredNode } from './palette.js';

/**
 * A bump on a need's phase curve over the turn: [peak hour, width, amplitude].
 * A tuple rather than an object because that is how the desire table is
 * authored, and the fold in bumpSum destructures it positionally.
 */
export type Bump = [peak: number, width: number, amp: number];

/**
 * A node of the working tree the dial renders.
 *
 * It extends ColouredNode because the desire tree IS a coloured tree — that is
 * precisely why main.js can hand its root to palette's registerTree and have the
 * identity registry seeded. The relationship is stated rather than left for a
 * reader to notice.
 *
 * Fields arrive in three waves, which is why the last three are optional:
 * buildRoot writes the classification and the curve; colorTop/tintTree add `col`
 * and `parent`; the means() pass stamps `_meanW`.
 */
export interface DesireNode extends ColouredNode {
  /** The classification id this node keeps from the taxonomy. */
  id: string;
  /** The label the renderer uses. */
  name: string;
  /** How many nest this term under its chosen parent. */
  count: number;
  /**
   * Whether the citizen actually EXPRESSED a priority here (the desire table
   * names the id) rather than riding the gentle default — the shop's filter bar
   * separates the two groups by this.
   */
  expressed: boolean;
  base: number;
  bumps: Bump[];
  qbase: number;
  qbumps: Bump[];

  col?: string;
  children?: DesireNode[];
  /** Set by tintTree, so a walk can climb back toward the root. */
  parent?: DesireNode;

  // ── stamped by the two passes in bands.ts ────────────────────────────────
  // The phase-average of each curve over the turn, and the coarser envelopes
  // the day-pulse hands over TO as the scale widens. Optional because they
  // arrive after the tree is built, and every reader has a fallback for the
  // node that predates the pass.

  /** Mean desire weight over the turn (stampMeans). */
  _meanW?: number;
  /** Mean satisfaction over the turn (stampMeans). */
  _meanQ?: number;
  /** Weekly multipliers, Monday-first — inherited from the parent term. */
  _week?: number[] | null;
  /** Seasonal multipliers, January-first — inherited from the parent term. */
  _year?: number[] | null;
  /** The weekly envelope's own mean, which the week-pulse hands over to. */
  _weekMean?: number;
  /** The seasonal envelope's mean. Stamped for symmetry; nothing reads it. */
  _yearMean?: number;
}

/**
 * id → the ids of its whole subtree, itself included (main.js's
 * indexDescendants). The one index that turns a spec's categories into the term
 * it shelves under, shared by the shop and the spend wheel.
 */
export type DescendantIndex = Map<string, Set<string>>;
