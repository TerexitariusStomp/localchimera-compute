// app/bodies.ts — the legal bodies you steward or belong to, and the one you
// are declaring.
//
// A body — an association, a cooperative, the operator — is declared in a
// scope by a recognised person, stewarded by the people it names, and given
// its identifier by k of its stewards signing the group inception from their
// own seats (docs/legal/bodies.md). Here is the model: what this commune
// says of your bodies (read on every seat taken), the one body open for
// reading, and the declaration drafted on this device. The view is
// bodies-view.ts; the doors are identity/body-doors.scm, reached through the
// seam's body handlers.
import { HANDLERS } from './core.js';
import { on } from './bus.js';
import { signal } from './reactive.js';
import { readJSON, writeJSON } from './store.js';
import { scopeSig } from './scope.js';
import { K } from './keys.js';
/** The value of a `key:value` tag on a body, or "". */
export const tagValue = (b, key) => (b.tags.find(t => t.startsWith(key + ":")) || "").slice(key.length + 1);
/** Whether a body's identifier is still the provisional one its declaration minted. */
export const provisional = (b) => b.id.startsWith("body:");
// ── reading ─────────────────────────────────────────────────────────────────
const list = signal([]);
const open = signal(null);
/** Your bodies, as last read. A tracked read. */
export const bodies = () => list();
/** The body open for reading, whole, or null. A tracked read. */
export const current = () => open();
const asBody = (o) => {
    const b = o;
    if (!b || typeof b.id !== "string" || typeof b.name !== "string")
        return null;
    return { ...b, tags: Array.isArray(b.tags) ? b.tags.map(String) : [] };
};
/** Read your bodies again from the commune. */
export function readBodies() {
    const scope = scopeSig();
    if (!HANDLERS.bodiesRead || !scope)
        return Promise.resolve();
    return HANDLERS.bodiesRead(scope).then(r => {
        try {
            const rows = JSON.parse(String(r));
            list.set(Array.isArray(rows) ? rows.map(asBody).filter((b) => !!b) : []);
        }
        catch (_) { /* signed out, or no commune: what was read stands */ }
    }, () => { });
}
/** Read one body whole; "ok" or the commune's refusal. */
export function readBody(id) {
    if (!HANDLERS.bodyRead)
        return Promise.resolve("err:offline");
    return HANDLERS.bodyRead(id).then(r => {
        const s = String(r ?? "err:offline");
        if (s.startsWith("err:"))
            return s;
        try {
            const b = asBody(JSON.parse(s));
            if (!b)
                return "err:the body could not be read";
            open.set(b);
            return "ok";
        }
        catch (_) {
            return "err:the body could not be read";
        }
    }, () => "err:offline");
}
/** Put the open body down. */
export const closeBody = () => open.set(null);
// a seat taken is when the commune can first be asked
on("status", (s) => { if (typeof s === "string" && s.startsWith("ok:"))
    void readBodies(); });
// ── acting ──────────────────────────────────────────────────────────────────
/** A reply as the commune's word: "ok", "ok:…" or "err:…" — and the bodies read again after an act. */
const said = (r) => (r ?? Promise.resolve("err:offline")).then(v => String(v ?? "err:offline"), () => "err:offline")
    .then(s => { if (s.startsWith("ok")) {
    void readBodies();
    const b = open.peek();
    if (b)
        void readBody(b.id);
} return s; });
/** The JSON an "ok:…" reply carries, or null. */
export function okJSON(r) {
    if (!r.startsWith("ok:"))
        return null;
    try {
        return JSON.parse(r.slice(3));
    }
    catch (_) {
        return null;
    }
}
export const KINDS = ["association", "cooperative", "company", "foundation", "operator"];
export const ROLES = ["provider", "seller", "employer", "adapter", "custodian"];
export const JURISDICTIONS = ["fr", "de", "es", "it", "be", "ch", "us", "ca"];
const DRAFT = K.bodiesDraft;
const blank = () => ({ name: "", kind: KINDS[0], role: ROLES[0], jurisdiction: JURISDICTIONS[0], assetLock: true, register: "inspectable", stewards: [] });
const cleanDraft = (raw) => {
    const d = { ...blank(), ...(raw && typeof raw === "object" ? raw : {}) };
    d.name = typeof d.name === "string" ? d.name.slice(0, 80) : "";
    d.stewards = Array.isArray(d.stewards) ? d.stewards.filter((s) => typeof s === "string") : [];
    d.register = d.register === "closed" ? "closed" : "inspectable";
    d.assetLock = !!d.assetLock;
    return d;
};
const draftSig = signal(cleanDraft(readJSON(DRAFT, null)));
/** The draft. A tracked read. */
export const draft = () => draftSig();
/** Change the draft; it is kept on this device until declared. */
export function setDraft(patch) {
    const next = cleanDraft({ ...draftSig.peek(), ...patch });
    draftSig.set(next);
    writeJSON(DRAFT, next);
}
/** What is wrong with the draft, or null when it can be declared. */
export const draftFault = (d) => !d.name.trim() ? "give the body a name" : d.name.length > 80 ? "a name is one short line" : null;
/** Declare the drafted body in this scope, then name its stewards; "ok" | "err:…". */
export async function declare() {
    const d = draftSig.peek();
    const fault = draftFault(d);
    if (fault)
        return "err:" + fault;
    const scope = scopeSig();
    if (!scope)
        return "err:no scope yet";
    const r = await said(HANDLERS.bodyDeclare?.(scope, JSON.stringify({
        name: d.name.trim(), kind: d.kind, role: d.role, jurisdiction: d.jurisdiction,
        assetLock: d.assetLock, register: d.register
    })));
    const b = okJSON(r);
    if (!b)
        return r;
    for (const aid of d.stewards)
        await said(HANDLERS.bodyAddSteward?.(b.id, aid));
    setDraft({ ...blank() });
    await readBodies();
    return "ok";
}
/** Name a steward of a body you steward. */
export const addSteward = (id, aid) => said(HANDLERS.bodyAddSteward?.(id, aid));
/** Open the inception: k of the stewards must sign. */
export const openCeremony = (id, k) => said(HANDLERS.bodyOpenCeremony?.(id, k));
/** Sign the open statement here, with this seat's own key. */
export const sign = (id, what = "inception") => said(HANDLERS.bodySign?.(id, what));
/** Present what a body holds. */
export const hold = (id, h) => said(HANDLERS.bodyHold?.(id, JSON.stringify(h)));
/** Admit a body to this scope — a governor's act; the commune refuses anyone else. */
export function admit(id) {
    const scope = scopeSig();
    return scope ? said(HANDLERS.bodyAdmit?.(scope, id)) : Promise.resolve("err:no scope yet");
}
/** The ceremony's standing in words: "2 of 3 signed", or the AID once published. */
export function ceremonyWords(c) {
    if (!c)
        return "not yet incepted";
    if (c.published)
        return "incepted — " + c.published.slice(0, 12) + "…";
    return `${c.have} of ${c.need} signed`;
}
