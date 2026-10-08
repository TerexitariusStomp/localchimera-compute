// app/state.ts — the dial's shared MUTABLE state.
//
// These values are reassigned across many render functions. ES module import
// bindings are read-only for the importer, so a plain `export let turnH` could
// not be written from another module. Instead they live as fields on this one
// object that every module reads and MUTATES in place (S.turnH = …) — the same
// pattern the seam uses for its data bag. Keep this list small: only add a
// field here when a value genuinely has to be written from more than one module.

import type { DesireNode, DescendantIndex } from './desire.js';

/** Where a scale-morph started: the source scale's hours-per-turn and amplitude. */
export interface ScaleMorph {
  h: number;
  A: number;
}

export interface DialState {
  /** Live ecological substance-flow snapshot, from the scope's solve. */
  matterFlow?: unknown;
  /** Hours per turn, continuous. */
  turnH: number;
  /** Absolute hours; demo: a June Friday, 06:00. */
  nowAbs: number;
  /** Whole turns ahead(+)/behind(−) of now. */
  viewTurnOffset: number;
  /** Half-width of the viewBox, dial units. */
  VE: number;
  /**
   * individual(0)⇄social(1) blend — the time face opens on your own day; flip
   * to social for the commons' aggregated cut (the UC folksonomy).
   */
  sigma: number;
  /** Source scale during a scale-morph, or null when none is running. */
  morphFrom: ScaleMorph | null;
  /** Morph progress 0→1. */
  morphU: number;
  /**
   * The desire tree.
   *
   * Null only between this module's evaluation and the first buildRoot — and
   * nothing reads the dial before there is a tree to read. Typed non-null so
   * that fact is stated once, here, rather than asserted at every use.
   */
  root: DesireNode;
  /**
   * id → its whole subtree, for multi-valued tree-based leaf matching.
   *
   * main.js writes it beside S.root; the shop, the spend wheel and main itself
   * read it. Three modules, so by this module's own rule it belongs here — it
   * was simply never written down, and lived as a field that appeared at
   * runtime and existed in no declaration.
   */
  desc: DescendantIndex | null;
}

export const S: DialState = {
  turnH: 24,
  nowAbs: 155 * 24 + 6.0,
  viewTurnOffset: 0,
  VE: 4.0,
  sigma: 0,
  morphFrom: null,
  morphU: 1,
  root: null as unknown as DesireNode,
  desc: null,
};
