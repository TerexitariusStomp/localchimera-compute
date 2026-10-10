// app/lend-core.ts — the lend, as far as it is words and a door: no page in it.
//
// What app/lend.ts mounts and signs, stated so a test reads each part: the
// AUDIENCE a steward rule names and the rule an audience writes, who in a
// contact book it admits, the LEND through the socialize door (the resource
// named so the title gate engages, the kept-back names as attestations the
// owner holds), the recall, and how a grant reads.
import { humanDate, specOf } from "./slots/model.js";
import { DEFAULT_REL } from "./rel-catalogue.js";
import { isCountUnit } from "./units-catalogue.js";
const clauseInto = (a, r) => {
    if (!Array.isArray(r))
        return false;
    const [op, ...args] = r;
    if (op === "vouched") {
        a.vouched = true;
        return true;
    }
    if (op === "in-group") {
        for (const k of args)
            a.kinds.add(String(k));
        return true;
    }
    if (op === "aid") {
        for (const p of args)
            a.people.add(String(p));
        return true;
    }
    return false;
};
/** The audience a rule names; null when the rule says something an audience does not write. */
export function audienceOf(rule) {
    const a = { vouched: false, kinds: new Set(), people: new Set() };
    if (rule === undefined || rule === null || rule === true)
        return a;
    if (!Array.isArray(rule))
        return null;
    const clauses = rule[0] === "or" ? rule.slice(1) : [rule];
    return clauses.every(c => clauseInto(a, c)) ? a : null;
}
/** The rule an audience writes; undefined when it names no one in particular (anyone). */
export function ruleOf(a) {
    const parts = [];
    if (a.vouched)
        parts.push(["vouched"]);
    if (a.kinds.size)
        parts.push(["in-group", ...a.kinds]);
    if (a.people.size)
        parts.push(["aid", ...a.people]);
    return parts.length === 0 ? undefined : parts.length === 1 ? parts[0] : ["or", ...parts];
}
/** Whether the audience names no one in particular. */
export const openTo = (a) => !a.vouched && !a.kinds.size && !a.people.size;
/** The kind a contact is known as. */
export const relOf = (c) => c.rel || DEFAULT_REL;
/** Who in PEOPLE the audience admits today — the gate's own reading: a kind is
 *  the tag you gave them or the kind your vouch states. */
export const admitted = (a, people) => people.filter(c => (a.vouched && !!c.mine) || a.kinds.has(relOf(c)) || (!!c.mine && a.kinds.has(c.mine)) || a.people.has(c.aid));
// ── how a grant reads ──────────────────────────────────────────────────────
/** A thing counted in itself reads by its own name: "1 bicycle", "2 hours of your oven". */
export const counted = isCountUnit;
export const possessive = (name) => name + (name.endsWith("s") ? "'" : "'s");
export const untilWords = (until) => until ? `until ${humanDate(until) || until}` : "until you recall it";
/** How much a grant lends, in the thing's own words. */
export const grantAmount = (g, t) => (g.qty === "" || g.qty == null) ? "all of it" : `${g.qty} ${counted(t.unit) ? t.name : t.unit}`;
/** What a lend says when it stands. */
export const lentSays = (t, terms, communeName) => `${t.name} is ${possessive(communeName)} to draw on ${untilWords(terms.until)} — you still own it`;
/** Lend T on TERMS through DOOR. */
export async function lendThrough(door, t, terms) {
    const { socialize, commune } = door;
    if (!socialize || !commune)
        return { ok: false, says: "pick a commune to lend into" };
    let reply;
    try {
        reply = await socialize(commune, t.spec, terms.qty, terms.until, terms.movable, terms.returnTo, terms.conditionFloor, t.resource || "", terms.kind, undefined, terms.eligible || "");
    }
    catch {
        return { ok: false, says: "the gateway did not answer" };
    }
    if (reply !== "ok")
        return { ok: false, says: String(reply).replace(/^err:/, "") || "the lend did not go through" };
    const done = lentSays(t, terms, door.communeName);
    // RETENTIONS ride after the grant lands: each kept-back name becomes a
    // custody attestation HELD BY THE OWNER — the same door, holder = your own
    // AID. That attestation is what the cascade reads as "kept back": it stands
    // the content on its own custody and cuts the carry at a retained container.
    const kept = String(terms.retain || "").split(",").map(x => x.trim()).filter(Boolean);
    if (!kept.length)
        return { ok: true, says: done };
    const me = door.me;
    if (!me)
        return { ok: true, says: `${done}; the kept-back items wait for a signed-in identity` };
    const rs = await Promise.all(kept.map(name => socialize(me, specOf(name), 1, terms.until, false, "", "", "")));
    const bad = rs.filter(r => r !== "ok").length;
    return { ok: true, says: bad ? `${done}; ${bad} kept-back item(s) stayed unrecorded` : done };
}
/** End grant G through the recall door. */
export async function recallThrough(recall, g) {
    if (!recall)
        return { ok: false, says: "sign in to recall it" };
    let reply;
    try {
        reply = await recall(g.id);
    }
    catch {
        return { ok: false, says: "the gateway did not answer" };
    }
    return reply === "ok" ? { ok: true, says: "recalled — custody is yours again" }
        : { ok: false, says: String(reply).replace(/^err:/, "") || "the recall did not go through" };
}
