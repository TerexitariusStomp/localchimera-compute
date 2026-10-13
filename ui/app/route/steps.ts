// app/route/steps.ts — the way, turn by turn: what is left of it, as a list.
//
// From the turn ahead to the door: each row an arrow and the engine's own sentence ("Turn right
// onto Treptower Str."), a chip for what the stretch passes through (a toll, a gate, rough
// ground, a ferry), the distance to the next turn between rows, and the destination last with
// the side of the street it is on. The first row says how far off it is. Turns behind you are
// not listed. `stepRows` is the pure half (a route and where you are in, rows out);
// `renderSteps` writes them.

import { glyphOf, isArrival } from './banner.js';
import { fmtDistance } from './facts.js';
import type { Progress } from './shape.js';
import type { Route } from './data.js';
import { mk } from '../dom.js';

/** One line of the list. */
export interface StepRow {
  /** "next": the turn ahead; "step": a turn after it; "destination": the door. */
  kind: "next" | "step" | "destination";
  glyph: string;
  /** How far off, on the turn ahead: "In 400 m"; empty after it. */
  lead: string;
  /** The engine's sentence, or the place for the destination. */
  text: string;
  /** What the stretch after this passes through: "Toll", "Gate", "Rough ground", "Ferry". */
  warns: string[];
  /** Beneath the destination: "Destination will be on the right"; empty elsewhere and when unsaid. */
  note: string;
  /** The distance to the next row — the divider that follows this one; null for the last. */
  after: string | null;
}

/** The rows from the turn ahead to the destination; none for a way with no maneuvers. */
export function stepRows(r: Route, p: Progress, place: string): StepRow[] {
  if (!r.mans.length) return [];
  const last = r.mans.length - 1;
  const from = p.next >= 0 ? p.next : last;
  const out: StepRow[] = [];
  for (let i = from; i <= last; i++) {
    const m = r.mans[i];
    const dest = i === last || isArrival(m.type);
    const warns = [m.toll && "Toll", m.gate && "Gate", m.rough && "Rough ground", m.ferry && "Ferry"].filter((w): w is string => !!w);
    out.push({
      kind: dest ? "destination" : i === from ? "next" : "step",
      glyph: dest ? "🏁" : glyphOf(m.type),
      lead: i === from ? `In ${fmtDistance(p.next >= 0 ? p.toNextKm : p.remKm, r.units)}` : "",
      text: dest ? place : m.instr,
      warns: dest ? [] : warns,
      note: dest && r.destSide ? `Destination will be on the ${r.destSide}` : "",
      after: dest ? null : fmtDistance(m.length, r.units),
    });
    if (dest) break;
  }
  return out;
}

/** The rows as a list: a divider with the distance between each. */
export function renderSteps(rows: readonly StepRow[]): HTMLElement {
  const ol = mk("ol", "jv-steps");
  rows.forEach(r => {
    const li = mk("li", `jv-step ${r.kind}`);
    const body = mk("div", "jv-sb");
    if (r.lead) body.append(mk("div", "jv-lead", r.lead));
    body.append(mk("div", "jv-st", r.text));
    if (r.warns.length) {
      const w = mk("div", "jv-warns");
      r.warns.forEach(t => w.append(mk("span", "jv-warn", t)));
      body.append(w);
    }
    if (r.note) body.append(mk("div", "jv-note", r.note));
    li.append(mk("span", "jv-sg", r.glyph), body);
    ol.append(li);
    if (r.after) ol.append(mk("li", "jv-gap", r.after));
  });
  return ol;
}
