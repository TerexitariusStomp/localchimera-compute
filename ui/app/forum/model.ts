// app/forum/model.ts — the forum's vocabulary: the wire's shapes, the two
// classes, the topics, and the pure readings over a proposal.
//
// Nothing here touches the DOM or the seam; every face-level module imports
// from this one and none of them from each other's state.

/** How a tally splits across stances, by weight. */
export type Tally = Record<string, number>;

/** A proposal's outcome, once the registry has counted it. */
export interface ProposalResult {
  state?: string;
  /** Present on an expression rather than a ballot. */
  kind?: string;
  domain?: string;
  /** The question, in the proposer's words. */
  text?: string;
  /** "federation" or "scope:<sid>" — whose voice weighs it. */
  franchise?: string;
  /** What it is about, as "kind:id" — the registry's meta. */
  subject?: string;
  /** When it opened, seconds since the epoch — the registry's meta. */
  openedAt?: number;
  tally?: Tally;
  abstain?: number;
  [key: string]: unknown;
}

/** A proposal, as the governance wire carries it. */
export interface Proposal {
  id: string;
  status?: string;
  domain?: string;
  result?: ProposalResult | null;
  /** Days since it opened, where known (the demo docket says). */
  age?: number;
  [key: string]: unknown;
}

/** A delegation you have made: a fraction of your voice, carried by someone else. */
export interface Delegation {
  to?: string;
  /** A per-scope override; absent = the federation default. */
  scope?: string;
  /** 0..1 of your voice. What is left is what you act with directly. */
  fraction?: number;
  /** A mandated delegation is bound to an instruction, not just a person. */
  mandated?: boolean;
  [key: string]: unknown;
}

/**
 * Your own voice, by class: your share of the scope's labour, and your share
 * of the claimable pool. Absent where the registry has not weighed you yet.
 */
export interface Voice {
  producer?: number;
  consumer?: number;
  [key: string]: unknown;
}

/** One message under a thread, as the chat rail carries it. */
export interface ChatMessage {
  id?: string;
  stratum?: string;
  kind?: string;
  author?: string;
  body?: string;
  [key: string]: unknown;
}

/** Which class a proposal belongs to — and so which voice weighs it. */
export type GovClass = "production" | "consumption";
/** The three sub-faces. */
export type SubTab = "open" | "decided" | "voice";

const PRODUCTION_DOMAINS = new Set([
  "recipe", "plan", "scope", "capacity", "formation",
  "admission", "merger", "split", "production"
]);
export const CLASS_TITLE: Record<GovClass, string> = {
  production: "how the work is done",
  consumption: "what the community needs",
};
export const CLASS_VOICE: Record<GovClass, string> = {
  production: "decided by those who do the work — producer voice",
  consumption: "decided by everyone — consumer voice",
};
export const classOfDomain = (d: string): GovClass => PRODUCTION_DOMAINS.has(d) ? "production" : "consumption";

/** The topics a voice speaks across, in the order the map lays them out. */
export const TOPICS: { d: string; label: string }[] = [
  { d: "recipe", label: "recipes" }, { d: "plan", label: "the plan" }, { d: "capacity", label: "capacity" },
  { d: "formation", label: "formation" }, { d: "policy", label: "policy" }, { d: "desire", label: "desires" },
];

export function classOf(p: Proposal): GovClass {
  const r = p.result || {};
  if (r.kind === "expression") return "consumption";
  return classOfDomain(r.domain || p.domain || "");
}
export const domainOf = (p: Proposal): string => p.result?.domain || p.domain || "";
export const statusOf = (p: Proposal): string => p.status || "open";

/** What a proposal is about, as [kind, id] — the registry's "kind:id" field. */
export function subjectRef(p: Proposal): [string, string] | null {
  const f = p.result?.subject;
  if (typeof f !== "string" || !f.includes(":")) return null;
  const i = f.indexOf(":");
  return [f.slice(0, i), f.slice(i + 1)];
}
/** Days since a proposal opened: the docket's own count, else the registry's clock. */
export function ageOf(p: Proposal): number | null {
  if (p.age != null) return p.age;
  const t = p.result?.openedAt;
  if (typeof t === "number" && t > 0) return Math.max(0, Math.floor((Date.now() / 1000 - t) / 86400));
  return null;
}
/** The thread's title: the question, or the id when the wire had no words. */
export const titleOf = (p: Proposal): string => (p.result?.text || "").trim() || prettyId(p.id);

export const prettyId = (id: unknown): string => (typeof id === "string" ? id.replace(/^p[-_]/, "") : String(id));
export const shortAid = (a: unknown): string => (typeof a === "string" && a.length > 12 ? a.slice(0, 6) + "…" + a.slice(-4) : String(a));
export const pct = (w: number): number => Math.round(w * 100);
export const ucId = (u: Proposal): string => "uc:" + String(u.a) + ":" + String(u.b);
export const ago = (days: number | undefined): string =>
  days == null ? "" : days === 0 ? "today" : days === 1 ? "yesterday" : days < 14 ? `${days} days ago`
  : days < 60 ? `${Math.round(days / 7)} weeks ago` : `${Math.round(days / 30)} months ago`;

/** The tally's leading stance, for a decided row's verdict. */
export function verdictOf(tally: Tally | null | undefined): string {
  const entries = Object.entries(tally || {}).filter(([, w]) => w > 0);
  if (!entries.length) return "no votes";
  entries.sort((a, b) => b[1] - a[1]);
  const total = entries.reduce((s, [, w]) => s + w, 0) || 1;
  return `${entries[0][0]} · ${pct(entries[0][1] / total)}%`;
}

/** The scope a "scope:<sid>" franchise names, or null for the federation. */
export const franchiseScope = (f: string | undefined): string | null =>
  f && f.startsWith("scope:") ? f.slice(6) : null;

/**
 * The delegations that resolve for a franchise: the federation default, each
 * delegate's entry replaced by their override in that scope (delegation-map.scm).
 */
export function resolvedFor(dels: Delegation[], scopeId: string | null): Delegation[] {
  const base = dels.filter(d => !d.scope);
  if (!scopeId) return base;
  const over = dels.filter(d => d.scope === scopeId);
  return [...base.filter(b => !over.some(o => o.to === b.to)), ...over];
}
/** What you keep of your voice in a franchise, after its delegations. */
export const keptIn = (dels: Delegation[], scopeId: string | null): number =>
  Math.max(0, 1 - resolvedFor(dels, scopeId).reduce((s, d) => s + (d.fraction || 0), 0));
