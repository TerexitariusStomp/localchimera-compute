// app/reach.ts — your ways to be reached, and who you have told.
//
// The list is yours and is kept on this device. An entry of it is disclosed
// twice over, each time by your own act and each yours to take back: to this
// commune, so it notifies you there (a contact-point credential the spine
// builds and signs; the commune sends a code to the address and delivers once
// the code is said back), and to a person, on a card (the Contacts row). The
// settings view (reach-view.ts) and the card picker (tabs/contacts.ts) both
// read here.
import { HANDLERS } from './core.js';
import { on } from './bus.js';
import { signal } from './reactive.js';
import { readJSON, writeJSON } from './store.js';
import { REACH_KINDS, REACH_VALUE_MAX } from './reach-catalogue.js';
import { K } from "./keys.js";
const KEY = K.reach;
const clean = (raw) => (Array.isArray(raw) ? raw : [])
    .filter((p) => !!p && typeof p.kind === "string" && typeof p.value === "string"
    && !!kindOfReach(p.kind) && !faultOf(p.kind, p.value));
/** The catalogue row of a kind, or undefined for a kind the catalogue does not name. */
export function kindOfReach(kind) {
    return REACH_KINDS.find(k => k.id === kind);
}
/** What is wrong with VALUE as a KIND, in words, or null when it stands. The commune judges an address's shape itself. */
export function faultOf(kind, value) {
    if (!kindOfReach(kind))
        return "choose a kind";
    if (!value.trim())
        return "say where";
    if (value.length > REACH_VALUE_MAX)
        return "one short line";
    if (/[\u0000-\u001f\u007f]/.test(value))
        return "one line";
    return null;
}
/** The link a point opens with, or "" when its kind opens nothing. */
export function linkOf(p) {
    const k = kindOfReach(p.kind);
    if (!k)
        return "";
    if (k.link)
        return k.link + encodeURI(p.value.replace(/^@(?=[^:]*$)/, ""));
    return p.kind === "web" && /^https?:\/\//i.test(p.value) ? p.value : "";
}
const same = (a, b) => a.kind === b.kind && a.value === b.value;
// ── the list ────────────────────────────────────────────────────────────────
const list = signal(clean(readJSON(KEY, [])));
const keep = (next) => { list.set(next); writeJSON(KEY, next); };
/** Your ways to be reached. A tracked read. */
export const reach = () => list();
/** Add a point; answers what is wrong with it, or null once it is on the list. */
export function addReach(kind, value) {
    const p = { kind, value: value.trim() };
    const fault = faultOf(p.kind, p.value);
    if (fault)
        return fault;
    if (!list.peek().some(q => same(p, q)))
        keep([...list.peek(), p]);
    return null;
}
/** Take a point off the list, and back from the commune if it was told. */
export function removeReach(p) {
    if (toldState(p))
        void untell(p);
    keep(list.peek().filter(q => !same(p, q)));
}
const delivered = signal([]);
const told = signal([]);
/** Read again what this commune delivers on and which of your points it holds. */
export function readCommune() {
    if (!HANDLERS.reachRead)
        return;
    HANDLERS.reachRead().then(r => {
        try {
            const o = JSON.parse(String(r));
            delivered.set(Array.isArray(o.delivers) ? o.delivers.map(String) : []);
            told.set(Array.isArray(o.points) ? o.points.filter(t => t && typeof t.kind === "string") : []);
        }
        catch (_) { /* signed out, or no commune: what was read stands */ }
    });
}
// a seat taken is when the commune can first be asked
on("status", (s) => { if (typeof s === "string" && s.startsWith("ok:"))
    readCommune(); });
/** Whether this commune delivers on a kind. A tracked read. */
export const delivers = (kind) => delivered().includes(kind);
/** What this commune holds of a point: "bound" (it notifies you there), "pending" (its code is on its way), or null. A tracked read. */
export function toldState(p) {
    const t = told().find(t => t.kind === p.kind && t.value === p.value);
    return t ? (t.state === "bound" ? "bound" : "pending") : null;
}
const ask = (r) => (r ?? Promise.resolve("err:offline")).then(v => { readCommune(); return String(v ?? "err:offline"); });
/** Tell the commune a point: it sends a code to the address. "ok:pending" | "err:…". */
export const tell = (p) => ask(HANDLERS.reachPresent?.(p.kind, p.value));
/** Say back the code that arrived at the address. "ok" | "err:…". */
export const confirm = (p, code) => ask(HANDLERS.reachConfirm?.(p.kind, p.value, code));
/** Take a point back from the commune. "ok" | "err:…". */
export const untell = (p) => ask(HANDLERS.reachWithdraw?.(p.kind, p.value));
/** A card's content as the text that is sealed. */
export const cardText = (c) => JSON.stringify({ name: c.name, points: c.points });
/** The card a text opens to, or null when it is no card. A card is its giver's words: every field is read as text and shown escaped. */
export function readCard(text) {
    if (!text)
        return null;
    try {
        const o = JSON.parse(text);
        const points = (Array.isArray(o.points) ? o.points : [])
            .filter((p) => !!p && typeof p.kind === "string" && typeof p.value === "string")
            .map(p => ({ kind: p.kind.slice(0, 24), value: p.value.slice(0, REACH_VALUE_MAX) }))
            .slice(0, 24);
        return { name: typeof o.name === "string" ? o.name.slice(0, 60) : "", points };
    }
    catch (_) {
        return null;
    }
}
