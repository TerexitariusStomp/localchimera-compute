// app/scope.ts — which commune you are looking at, as a reactive signal.
//
// The whole UI subscribes to the selected scope. day-boot writes it through
// `seam.scope`, which is an ACCESSOR over the signal below — so a switch made
// from the spine, from the breadcrumb, or from a `?scope=` deep link all take
// the one path and re-run every effect that read it: the breadcrumb, the desire
// band, each face.
//
// Only the question "which commune, and what is its path" lives here. How the
// header DRAWS that — the wordmark, the segments, the ＋ picker — is app/crumb.js,
// and the split is why a face can ask what scope it is in without importing a
// renderer.

import { signal } from './reactive.js';
import { seam } from './seam.js';
import { DEMO_SCOPES } from './demo.js';
import { readStr, writeStr, forget } from './store.js';
import type { ScopeRef } from './seam.js';
import { K } from "./keys.js";

/** The current scope-aid, or null for earth — the whole commons. */
export const scopeSig = signal<string | null>(seam.scope || null);

/** The roster you belong to, as the gateway pushed it. */
export const scopesSig = signal<ScopeRef[]>(
  seam.data.scopes || []);

Object.defineProperty(seam, "scope", {
  get() { return scopeSig(); },
  set(v: string | null) { scopeSig.set(v || null); },
  configurable: true,
});

/**
 * One step of a scope's path — earth → region → commune. `scope` is the id to
 * switch TO when the segment is tapped, and it is null for every step but the
 * last: an intermediate segment names a place, not a commune you can be in.
 */
export interface ChainStep {
  id: string;
  name: string;
  scope: string | null;
}

/**
 * A scope's path from the backend. Absent ⇒ a flat `earth › <name>`, which is
 * what the founding commune with no geography gets.
 */
function scopePathOf(s: ScopeRef): { id: string; name: string }[] {
  return (Array.isArray(s.path) && s.path.length) ? s.path.slice()
       : [{ id: s.id, name: s.name || s.id }];
}

/**
 * The roster the picker filters over. Live: the gateway's scope-list. Empty
 * (offline): the demo communes, so the selector is explorable before connecting.
 */
export function allScopes(): ScopeRef[] {
  const s = scopesSig();
  return (s && s.length) ? s : DEMO_SCOPES;
}

/** The scope you stand in, by name: the whole commons at the root. */
export function scopeName(): string {
  const id = scopeSig();
  if (!id) return "the whole commons";
  const s = allScopes().find(x => x.id === id) || ((seam.data && seam.data.scopes) || []).find(x => x.id === id);
  return (s && s.name) || "your commune";
}

/** The crumb chain: earth, then the path segments of the selected scope. */
export function scopeChain(): ChainStep[] {
  const root: ChainStep = { id: "earth", name: "earth", scope: null };
  const cur = scopeSig();
  const s = cur ? allScopes().find(x => x.id === cur) : null;
  if (!s) return [root];
  const segs = scopePathOf(s);
  return [root, ...segs.map((seg, i): ChainStep => ({ id: seg.id, name: seg.name,
    scope: i === segs.length - 1 ? s.id : null }))];
}

/**
 * Switch scope. Tells the spine when there is one, then writes the signal —
 * reactive, so the whole UI follows whether or not a gateway answered.
 */
export function goToScope(sid: string | null): void {
  if (sid) writeStr(K.scope, sid); else forget(K.scope);
  // the signal FIRST: the spine's setScope repaints synchronously, and the
  // ingest facet reads this signal — told first, it would facet the repaint
  // by the scope being LEFT (earth painted an empty day that way).
  seam.scope = sid;
  if (seam.handlers && seam.handlers.setScope) seam.handlers.setScope(sid);
}

// ── the device remembers which commune you were in ──────────────────────────
// The wasm session defaults to the roster's FIRST commune (fetch-snapshot!'s
// fallback), and its sticky choice lives only as long as the session — so a
// reload landed everyone back on the first seed commune. `pn.scope` is the
// device's memory of the choice; re-dialing it when the roster arrives is
// what carries the choice across reloads. Once per boot: after that, the
// live choice is the user's own.
let recalled = false;
export function recallScope(): void {
  if (recalled) return;
  const kept = readStr(K.scope);
  const roster = scopesSig();
  if (!roster.length) return;              // no live roster yet — keep waiting
  recalled = true;
  if (kept && kept !== scopeSig() && roster.some(s => s.id === kept))
    goToScope(kept);
}
