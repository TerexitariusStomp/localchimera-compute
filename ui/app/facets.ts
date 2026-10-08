// app/facets.ts — which KINDS of day-events are showing.
//
// The calendars (calendars.ts) answer "which SOURCE of events"; the facets
// answer "which kind": the VF action, the status, the scope it came from, the
// recipe behind it. ONE predicate — passesFacets — composed into the
// calendar's columns, the rim's gather and the map's offers, so the three
// surfaces always show the same filtered day: the discipline inTurnWindow
// already established between rim and map, extended to kind.
//
// A facet set holds the ADMITTED values; empty admits everything. An event
// that lacks the dimension fails a non-empty set — filtering to "produce"
// means "show me produce", and a row with no action is not that.
//
// It rides the reactive spine the same way the calendars do: passesFacets and
// facetOn read the rev signal, so any effect that asks re-runs on a toggle,
// and main's one repaint effect reads facetsRev beside calsRev.

import { signal } from './reactive.js';
import { PLAN } from './core.js';
import type { DayEvent } from './seam.js';

/** The dimensions a day-event can be filtered by. */
export type FacetDim = "action" | "status" | "scope" | "recipe";
export const FACET_DIMS: FacetDim[] = ["action", "status", "scope", "recipe"];

const sets: Record<FacetDim, Set<string>> = {
  action: new Set(), status: new Set(), scope: new Set(), recipe: new Set(),
};

const rev = signal(0);
const bump = (): void => rev.set(rev.peek() + 1);

/** The notifier, for a reader that wants "any facet changed" without naming one. */
export const facetsRev = (): number => rev();

/**
 * An event's value on a dimension. The recipe is the one indirect read: a row
 * that names its recipe wins; otherwise the need it serves names one through
 * the plan (need.id = serves, need.recipeId — the same join the plan column
 * draws with).
 */
export function facetValue(ev: DayEvent, dim: FacetDim): string | null {
  if (dim === "recipe") {
    if (ev.recipeId) return ev.recipeId;
    const nd = ev.serves ? (PLAN().needs || []).find(n => n.id === ev.serves) : null;
    return (nd && nd.recipeId) || null;
  }
  const v = ev[dim];
  return typeof v === "string" && v ? v : null;
}

/** Is this value admitted on this dimension? (Empty set admits all.) */
export const facetOn = (dim: FacetDim, v: string): boolean =>
  (rev(), !sets[dim].size || sets[dim].has(v));

/** Does this event pass every dimension? The one predicate every surface asks. */
export function passesFacets(ev: DayEvent): boolean {
  rev();
  for (const dim of FACET_DIMS) {
    const s = sets[dim];
    if (!s.size) continue;
    const v = facetValue(ev, dim);
    if (!v || !s.has(v)) return false;
  }
  return true;
}

/** Admit or retire one value. Toggling the last admitted value clears the dim. */
export function toggleFacet(dim: FacetDim, v: string): void {
  const s = sets[dim];
  if (s.has(v)) s.delete(v); else s.add(v);
  bump();
}

export function clearFacets(dim?: FacetDim): void {
  (dim ? [dim] : FACET_DIMS).forEach(d => sets[d].clear());
  bump();
}

/** Is a dimension filtering at all? (Its chip row must stay reachable to clear.) */
export const facetActive = (dim: FacetDim): boolean => (rev(), sets[dim].size > 0);

export const anyFacet = (): boolean => (rev(), FACET_DIMS.some(d => sets[d].size > 0));

/**
 * The values PRESENT on a dimension across a set of events, for chip rows: a
 * chip renders only for a value the day actually holds, so an action that
 * never occurs never shows a dead chip.
 */
export function facetValues(dim: FacetDim, evs: DayEvent[]): string[] {
  const out = new Set<string>();
  for (const e of evs) { const v = facetValue(e, dim); if (v) out.add(v); }
  return [...out].sort();
}
