// app/lend-core.ts — the lend, as far as it is words and a door: no page in it.
//
// What app/lend.ts mounts and signs, stated so a test reads each part: the
// AUDIENCE a steward rule names and the rule an audience writes, who in a
// contact book it admits, the LEND through the socialize door (the resource
// named so the title gate engages, the kept-back names as attestations the
// owner holds), the recall, and how a grant reads.

import { humanDate, specOf } from "./slots/model.js";
import { DEFAULT_REL } from "./rel-catalogue.js";
import type { Rule } from "./slots/model.js";
import type { Grant, GrantKind, Contact } from "./seam.js";
import type { SeamHandlers } from "./seam-wire.js";
import { isCountUnit } from "./units-catalogue.js";

/** A thing of yours that can be lent: a declared means, or one named resource. */
export interface Lendable {
  spec: string;
  name: string;
  unit?: string;
  /** How much of it you declared — the lend's ceiling. */
  qty: number;
  /** The resource the grant names, when it is one particular thing. */
  resource?: string;
}

/** The terms a lend is signed with — the whole grant, as composed. */
export interface GrantTerms {
  /** "use": lend the service, it comes back whole. "consume": lend a quantity to spend. */
  kind: GrantKind;
  qty: number | string;
  /** "" is open-ended. */
  until: string;
  movable: boolean;
  returnTo: string;
  conditionFloor: string;
  retain: string;
  /** The steward rule, as criteria JSON; "" = anyone. */
  eligible?: string;
}

/** What a lend or a recall says when it is done, and whether it went through. */
export interface Said { ok: boolean; says: string; }

// ── who may work on it: an audience, and the rule it writes ────────────────
// Three kinds of pick — the people you vouch for, kinds of people, people by
// name — and the rule admits whoever ANY of them names.
export interface Audience { vouched: boolean; kinds: Set<string>; people: Set<string>; }

const clauseInto = (a: Audience, r: Rule): boolean => {
  if (!Array.isArray(r)) return false;
  const [op, ...args] = r;
  if (op === "vouched") { a.vouched = true; return true; }
  if (op === "in-group") { for (const k of args) a.kinds.add(String(k)); return true; }
  if (op === "aid") { for (const p of args) a.people.add(String(p)); return true; }
  return false;
};

/** The audience a rule names; null when the rule says something an audience does not write. */
export function audienceOf(rule: Rule | null | undefined): Audience | null {
  const a: Audience = { vouched: false, kinds: new Set(), people: new Set() };
  if (rule === undefined || rule === null || rule === true) return a;
  if (!Array.isArray(rule)) return null;
  const clauses = rule[0] === "or" ? (rule.slice(1) as Rule[]) : [rule];
  return clauses.every(c => clauseInto(a, c)) ? a : null;
}

/** The rule an audience writes; undefined when it names no one in particular (anyone). */
export function ruleOf(a: Audience): Rule | undefined {
  const parts: Rule[] = [];
  if (a.vouched) parts.push(["vouched"]);
  if (a.kinds.size) parts.push(["in-group", ...a.kinds]);
  if (a.people.size) parts.push(["aid", ...a.people]);
  return parts.length === 0 ? undefined : parts.length === 1 ? parts[0] : ["or", ...parts];
}

/** Whether the audience names no one in particular. */
export const openTo = (a: Audience): boolean => !a.vouched && !a.kinds.size && !a.people.size;

/** The kind a contact is known as. */
export const relOf = (c: Contact): string => c.rel || DEFAULT_REL;

/** Who in PEOPLE the audience admits today — the gate's own reading: a kind is
 *  the tag you gave them or the kind your vouch states. */
export const admitted = (a: Audience, people: Contact[]): Contact[] =>
  people.filter(c => (a.vouched && !!c.mine) || a.kinds.has(relOf(c)) || (!!c.mine && a.kinds.has(c.mine)) || a.people.has(c.aid));

// ── how a grant reads ──────────────────────────────────────────────────────
/** A thing counted in itself reads by its own name: "1 bicycle", "2 hours of your oven". */
export const counted = isCountUnit;
export const possessive = (name: string): string => name + (name.endsWith("s") ? "'" : "'s");
export const untilWords = (until: string | null | undefined): string =>
  until ? `until ${humanDate(until) || until}` : "until you recall it";
/** How much a grant lends, in the thing's own words. */
export const grantAmount = (g: Grant, t: { name: string; unit?: string }): string =>
  (g.qty === "" || g.qty == null) ? "all of it" : `${g.qty} ${counted(t.unit) ? t.name : t.unit}`;

// ── the acts, through the door they are given ──────────────────────────────
/** Where a lend goes and who signs it: the socialize door, the commune stood in, and your own AID. */
export interface LendDoor {
  socialize?: NonNullable<SeamHandlers["socialize"]>;
  commune: string | null;
  communeName: string;
  me?: string;
}

/** What a lend says when it stands. */
export const lentSays = (t: Lendable, terms: GrantTerms, communeName: string): string =>
  `${t.name} is ${possessive(communeName)} to draw on ${untilWords(terms.until)} — you still own it`;

/** Lend T on TERMS through DOOR. */
export async function lendThrough(door: LendDoor, t: Lendable, terms: GrantTerms): Promise<Said> {
  const { socialize, commune } = door;
  if (!socialize || !commune) return { ok: false, says: "pick a commune to lend into" };
  let reply: unknown;
  try {
    reply = await socialize(commune, t.spec, terms.qty, terms.until, terms.movable, terms.returnTo,
                            terms.conditionFloor, t.resource || "", terms.kind, undefined, terms.eligible || "");
  } catch { return { ok: false, says: "the gateway did not answer" }; }
  if (reply !== "ok") return { ok: false, says: String(reply).replace(/^err:/, "") || "the lend did not go through" };
  const done = lentSays(t, terms, door.communeName);
  // RETENTIONS ride after the grant lands: each kept-back name becomes a
  // custody attestation HELD BY THE OWNER — the same door, holder = your own
  // AID. That attestation is what the cascade reads as "kept back": it stands
  // the content on its own custody and cuts the carry at a retained container.
  const kept = String(terms.retain || "").split(",").map(x => x.trim()).filter(Boolean);
  if (!kept.length) return { ok: true, says: done };
  const me = door.me;
  if (!me) return { ok: true, says: `${done}; the kept-back items wait for a signed-in identity` };
  const rs = await Promise.all(kept.map(name => socialize(me, specOf(name), 1, terms.until, false, "", "", "")));
  const bad = rs.filter(r => r !== "ok").length;
  return { ok: true, says: bad ? `${done}; ${bad} kept-back item(s) stayed unrecorded` : done };
}

/** End grant G through the recall door. */
export async function recallThrough(recall: SeamHandlers["recall"], g: Grant): Promise<Said> {
  if (!recall) return { ok: false, says: "sign in to recall it" };
  let reply: unknown;
  try { reply = await recall(g.id); } catch { return { ok: false, says: "the gateway did not answer" }; }
  return reply === "ok" ? { ok: true, says: "recalled — custody is yours again" }
                        : { ok: false, says: String(reply).replace(/^err:/, "") || "the recall did not go through" };
}
