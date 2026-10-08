// app/scales.ts — the named turns, and which one you are on.
//
// τ is the VARIABLE; a scale instantiates it. Desire lives on the torus
// day × week × year, and each rhythm becomes visible at its own scale and is
// averaged away above it — 240 samples of a year cannot carry the day-pulse, so
// the day-pulse hands over to its own mean. No aliasing, only structure.
//
// The turn is continuous: a pinch lands anywhere between these names. So the
// table is not a set of modes but a set of LANDMARKS on that continuum, and
// `nearScale` asks whether the dial has settled close enough to one to speak in
// its symbol. Between names the marks read in τ, which is the honest answer.
//
// The tolerance is on the LOG of the ratio, not the difference: a scale is
// "near" when it is within about 2% of the turn either way, which reads the
// same whether the turn is one hour or one year.

import { S } from './state.js';

/** A named turn: how it reads, the symbol its rim marks wear, and its hours. */
export interface Scale {
  label: string;
  sym: string;
  h: number;
}

export const SCALES: Scale[] = [
  { label: "one hour",   sym: "Hr", h: 1 },
  { label: "one day",    sym: "D",  h: 24 },
  { label: "three days", sym: "3D", h: 72 },
  { label: "one week",   sym: "W",  h: 168 },
  { label: "one moon",   sym: "☾",  h: 708.7 },
  { label: "one month",  sym: "Mo", h: 730.5 },
  { label: "one season", sym: "Se", h: 2191.5 },
  { label: "one year",   sym: "Y",  h: 8766 },
];

/** The named scale the turn has settled on, or undefined mid-pinch. */
export const nearScale = (): Scale | undefined =>
  SCALES.find(s => Math.abs(Math.log(s.h / S.turnH)) < 0.02);

/** The symbol the rim marks read in — the period's own, or τ between names. */
export const turnSym = (): string => (nearScale() || { sym: "τ" }).sym;
