// app/forum/subjects.ts — what a proposal can be about.
//
// A proposal is born from something the commune already knows: a recipe in
// the library, a need in the plan, a means or need in the pool, a commune in
// the roster. This module names those subjects, drafts the question a
// proposal about one would ask, and resolves a thread's "kind:id" subject
// back to the thing — against the live data when the gateway speaks, the
// demo fixtures otherwise, exactly as the faces that draw those things do.
import { seam } from '../seam.js';
import type { ScopeRecipe, PlanNeed, ScopeRef } from '../seam.js';
import { recipes, recipeById, recipeOutSpec } from '../recipe-graph.js';
import { allScopes } from '../scope.js';
import { DEMO_NEEDS_CA, DEMO_NEEDS_DE, DEMO_SCOPE_PLAN, DEMO_RECIPES, DEMO_RECIPES_DE } from '../demo.js';
import { SOCIAL_DEMO_POOL } from '../demo/social-pool.js';
import type { SocialDemoRow } from '../demo/social-pool.js';
import { subjectRef, classOfDomain, pct, shortAid } from './model.js';
import type { Proposal } from './model.js';

import { scopeSig, scopeName } from '../scope.js';
export type SubjectKind = "recipe" | "need" | "slot" | "scope";

/** A subject, resolved against what the dial knows. */
export interface Subject {
  kind: SubjectKind;
  id: string;
  emoji: string;
  name: string;
  /** One line under the name. */
  line: string;
  recipe?: ScopeRecipe;
  need?: PlanNeed;
  slot?: SocialDemoRow;
  scope?: ScopeRef;
  /** The domain a proposal about this subject opens under. */
  domain: string;
  /** The question drafted from it. */
  draft: string;
}

/** A band of subjects the picker offers. */
export interface SubjectBand { title: string; items: Subject[] }

/** The roster, with the scope you stand in present even when the roster has not named it yet. */
export function scopesKnown(): ScopeRef[] {
  const all = allScopes();
  const sid = scopeSig();
  return sid && !all.some(s => s.id === sid) ? [...all, { id: sid, name: shortAid(sid) }] : all;
}
export { scopeName };
/** The name a "scope:<sid>" franchise reads as. */
export const nameOfScope = (sid: string): string =>
  scopesKnown().find(s => s.id === sid)?.name || shortAid(sid);

/** A recipe by id: the library in hand, else either demo library — a demo
 *  thread about the Berlin loaf resolves from the earth standpoint too. */
export const anyRecipe = (id: string): ScopeRecipe | null =>
  recipeById(id) || [...DEMO_RECIPES, ...DEMO_RECIPES_DE].find(r => r.id === id) || null;

/** The plan's needs: the live plan's, else the demo plan of the scope you stand in. */
export function planNeeds(): PlanNeed[] {
  const live = seam.data?.plan?.needs;
  if (Array.isArray(live) && live.length) return live;
  const sid = scopeSig();
  const region = (sid && DEMO_SCOPE_PLAN[sid]?.region) || "ca";
  return (region === "de" ? DEMO_NEEDS_DE : DEMO_NEEDS_CA) as unknown as PlanNeed[];
}
const anyNeed = (id: string): PlanNeed | null =>
  planNeeds().find(x => x.id === id)
  || ([...DEMO_NEEDS_DE, ...DEMO_NEEDS_CA] as unknown as PlanNeed[]).find(x => x.id === id) || null;

const poolRows = (): SocialDemoRow[] => [...SOCIAL_DEMO_POOL.means, ...SOCIAL_DEMO_POOL.needs];
export const isMeans = (s: SocialDemoRow): boolean => SOCIAL_DEMO_POOL.means.some(m => m.id === s.id);
const whoOf = (s: SocialDemoRow): string => String((s as { who?: unknown }).who || (s as { owner?: unknown }).owner || "you");

export function subjectOfRecipe(r: ScopeRecipe): Subject {
  const makes = r.produces || recipeOutSpec(r) || "";
  const hours = (r.steps || []).reduce((s, st) => s + (Number(st.hours) || 0), 0);
  return { kind: "recipe", id: r.id || "", emoji: r.emoji || "🍲", name: r.name || r.id || "recipe", recipe: r,
    line: [makes && `makes ${makes}`, r.need && `for ${r.need}`, hours && `${hours}h`].filter(Boolean).join(" · "),
    domain: "recipe",
    draft: `Adopt “${r.name || r.id}” as ${scopeName()}'s recipe for ${makes || "this"}?` };
}
export function subjectOfNeed(n: PlanNeed): Subject {
  return { kind: "need", id: n.id, emoji: n.emoji || "🎯", name: n.label || n.id, need: n,
    line: `${pct(n.met || 0)}% met` + (n.labourH ? ` · ${n.labourH}h labour` : "") + (n.recipeId ? ` · ${anyRecipe(n.recipeId)?.name || n.recipeId}` : ""),
    domain: "desire",
    draft: `Raise the priority of ${n.label || n.id} — it is ${pct(n.met || 0)}% met?` };
}
export function subjectOfSlot(s: SocialDemoRow): Subject {
  const means = isMeans(s), who = whoOf(s);
  return { kind: "slot", id: s.id, emoji: s.emoji || (means ? "🎁" : "🎯"), name: s.name || s.spec, slot: s,
    line: [means ? "a means" : "a need", who !== "you" && who, s.qty && `${s.qty} ${s.unit || ""}`.trim()].filter(Boolean).join(" · "),
    domain: means ? "capacity" : "plan",
    draft: means
      ? `Bring ${who === "you" ? "your" : who + "'s"} ${s.name || s.spec} into the commune's use-pool?`
      : `Provision ${s.name || s.spec}${who !== "you" ? ` for ${who}` : ""} from the common plan?` };
}
export function subjectOfScope(s: ScopeRef): Subject {
  return { kind: "scope", id: s.id, emoji: "🏘️", name: s.name, scope: s,
    line: (s.path || []).map(p => p.name).join(" › ") || "a commune",
    domain: "formation",
    draft: s.id === scopeSig() ? `Amend how ${s.name} governs itself?` : `Federate ${scopeName()} with ${s.name}?` };
}

/** Resolve what a thread is about against what the dial knows. */
export function subjectOf(p: Proposal): Subject | null {
  const ref = subjectRef(p);
  if (!ref) return null;
  const [kind, id] = ref;
  if (kind === "recipe") { const r = anyRecipe(id); return r ? subjectOfRecipe(r) : null; }
  if (kind === "need")   { const n = anyNeed(id); return n ? subjectOfNeed(n) : null; }
  if (kind === "slot")   { const s = poolRows().find(x => x.id === id); return s ? subjectOfSlot(s) : null; }
  if (kind === "scope")  { const s = scopesKnown().find(x => x.id === id); return s ? subjectOfScope(s) : null; }
  return null;
}
/** The subject as the wire's "kind:id". */
export const refOf = (s: Subject): string => `${s.kind}:${s.id}`;

/** Every subject the picker offers, banded by what it is. */
export function subjectBands(): SubjectBand[] {
  return [
    { title: "a recipe — how something is made", items: recipes().map(subjectOfRecipe) },
    { title: "a need in the plan — what is short", items: planNeeds().map(subjectOfNeed) },
    { title: "a means someone holds — what could be shared", items: SOCIAL_DEMO_POOL.means.map(subjectOfSlot) },
    { title: "a need someone stated — what could be provisioned", items: SOCIAL_DEMO_POOL.needs.map(subjectOfSlot) },
    { title: "a commune — who we stand with", items: scopesKnown().map(subjectOfScope) },
  ].filter(b => b.items.length);
}

/**
 * Whose voice weighs a proposal in this domain: production is decided in the
 * commune where the work is done, consumption over the federation.
 */
export const franchiseFor = (domain: string): string =>
  classOfDomain(domain) === "production" && scopeSig() ? `scope:${scopeSig()}` : "federation";
