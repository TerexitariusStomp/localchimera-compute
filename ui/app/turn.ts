// app/turn.ts — absolute hours, read as a position within the turn.
//
// Everything timed on the dial — the hand, the ribbons, the sun marks, the
// chords — needs the same answer to one question: given an hour on the absolute
// clock, WHERE does it stand on the face we are looking at? That answer depends
// on the turn's length, its anchor, and whether a re-scale is mid-flight, so it
// is written once here rather than in each drawer.
//
// ── A RE-SCALE GLIDES BY PHASE, NOT BY ORBIT ────────────────────────────────
// While the turn changes length, an element is at one position on the OLD turn
// and another on the NEW one. Interpolating the two ANGLES directly would send
// it the long way round often enough to look like a spin, so `phaseLerp` walks
// the shortest arc: an element slides to its new phase, it never orbits through
// the intermediate periods to get there.

import { S } from './state.js';
import { turnAnchor } from './events.js';

/** Absolute hours → units (0..24) within a turn of length `h` anchored at `A`. */
export const toUnits = (abs: number, h: number, A: number): number =>
  ((((abs - A) % h) + h) % h) / h * 24;

/** Between two turn-unit phases, the shortest way round the face. */
export const phaseLerp = (a: number, b: number, u: number): number => {
  const d = (((b - a) % 24) + 36) % 24 - 12;   // shortest way round
  return (((a + d * u) % 24) + 24) % 24;
};

/**
 * Absolute hours → the turn-units the dial is DISPLAYING.
 *
 * Settled, that is just the current turn. Mid-morph it is the glide between the
 * old turn's phase and the new one's, which is why every drawer calls this and
 * none of them computes a phase itself.
 */
export const absUnits = (abs: number): number => {
  const now = toUnits(abs, S.turnH, turnAnchor());
  return (!S.morphFrom || S.morphU >= 1) ? now
    : phaseLerp(toUnits(abs, S.morphFrom.h, S.morphFrom.A), now, S.morphU);
};

/** Now, in turn units. */
export const turnPos = (): number => absUnits(S.nowAbs);
