// app/tabs/map/pins.ts — the pin book: collections of things on the map.
//
// A LIST is a name and a face you give to a set of places ("Squats", 🌱); a
// PIN files one map row under it, with a note of your own. The book is
// yours: local-first (store.ts), backed up per AID through HANDLERS.pins,
// exactly the captain's log's shape. A list you mark SHARED folds into the
// commune's pin book on the gateway (folksonomy/pins.scm) — the My/Our
// standpoint once more: your leaf writes, the fold is what others read —
// and `ourLists()` is that fold, fetched when the Saved view opens.
//
// A pin's SUBJECT is the atlas row's id (a pooled slot, a declared place, a
// drop point) or a bare spot you dropped on the map. The pin keeps a
// snapshot of what it pinned — name, face, coordinates — so a list still
// reads when the row has left the pool, and a spot has nowhere else to be.
import { signal } from '../../reactive.js';
import { readJSON, writeJSON } from '../../store.js';
import { HANDLERS } from '../../core.js';
import { idHint } from '../social/id.js';
import { K } from "../../keys.js";
const bookKey = () => { const h = idHint(); return K.pins + ((h && h.aid) || "anon"); };
const book = signal(readJSON(bookKey(), { lists: [], pins: [] }));
const LKEY = (id) => "L:" + id;
const PKEY = (list, subject) => "P:" + list + "\t" + subject;
const DEAD_KEEP_MS = 120 * 24 * 3600e3; // a tombstone outlives any sync gap
const bury = (b, keys) => {
    const now = Date.now();
    const dead = {};
    for (const [k, t] of Object.entries(b.dead || {}))
        if (now - t < DEAD_KEEP_MS)
            dead[k] = t;
    for (const k of keys)
        dead[k] = now;
    return dead;
};
const unbury = (b, key) => {
    if (!b.dead || !(key in b.dead))
        return b.dead;
    const { [key]: _, ...rest } = b.dead;
    return rest;
};
/** Read this to follow the book: every write below moves it. */
export const version = () => book();
/** The commune's shared lists (the fold), fetched on demand. */
export const ourLists = signal(null);
let serverMerged = false;
export const view = signal(null);
export const close = () => view.set(null);
export const openBook = () => { mergeServer(); fetchOurLists(); view.set({ kind: "lists" }); };
export const openMine = (id) => view.set({ kind: "mine", id });
export async function openOurs(l) {
    view.set({ kind: "ours", l, subjects: new Set(await fetchOurPins(l.id)) });
}
export const hasPins = () => book().pins.length > 0;
export const lists = () => book().lists;
export const pinsIn = (list) => book().pins.filter(p => p.list === list);
export const listsOf = (subject) => book().lists.filter(l => book().pins.some(p => p.list === l.id && p.subject === subject));
export const listById = (id) => book().lists.find(l => l.id === id);
/** The face a pinned subject wears on the map: its first list's emoji, or null. */
export const badgeOf = (subject) => {
    const l = listsOf(subject)[0];
    return l ? l.emoji : null;
};
function persist(next) {
    book.set(next);
    writeJSON(bookKey(), next);
    if (HANDLERS.pins)
        HANDLERS.pins("sync", JSON.stringify(next)).catch(() => { });
}
/**
 * The gateway's copy, merged in once per session. Additive by id — except
 * where a tombstone (either side's) is newer than the entry it names: a
 * deletion made on any device wins over an older copy everywhere, which is
 * what makes the book ONE book rather than one per browser.
 */
export async function mergeServer() {
    if (serverMerged || !HANDLERS.pins)
        return;
    serverMerged = true;
    try {
        const raw = await HANDLERS.pins("list", "");
        if (!raw || raw.startsWith("err:"))
            return;
        const remote = JSON.parse(raw);
        const cur = book();
        // the union of both sides' tombstones, newest word per key
        const dead = { ...(cur.dead || {}) };
        for (const [k, t] of Object.entries(remote.dead || {}))
            if (typeof t === "number" && t > (dead[k] || 0))
                dead[k] = t;
        const alive = (key, t) => !(dead[key] > (t || 0));
        const haveL = new Set(cur.lists.map(l => l.id));
        const haveP = new Set(cur.pins.map(p => PKEY(p.list, p.subject)));
        const lists = [...cur.lists.filter(l => alive(LKEY(l.id), l.t)),
            ...(remote.lists || []).filter(l => l && l.id && !haveL.has(l.id)
                && alive(LKEY(l.id), l.t))];
        const ids = new Set(lists.map(l => l.id));
        const pins = [...cur.pins, ...(remote.pins || []).filter(p => p && p.list && p.subject
                && !haveP.has(PKEY(p.list, p.subject)))]
            .filter(p => ids.has(p.list) && alive(PKEY(p.list, p.subject), p.t));
        const next = { lists, pins, dead };
        if (JSON.stringify(next) !== JSON.stringify(cur))
            persist(next);
    }
    catch (_) { }
}
export async function fetchOurLists() {
    if (!HANDLERS.pins) {
        ourLists.set([]);
        return;
    }
    try {
        const raw = await HANDLERS.pins("ourLists", "");
        const v = JSON.parse(raw || "[]");
        ourLists.set(Array.isArray(v) ? v.filter(l => l && l.id) : []);
    }
    catch (_) {
        ourLists.set([]);
    }
}
/** One shared list's members, as subject ids (the fold carries no rows). */
export async function fetchOurPins(list) {
    if (!HANDLERS.pins)
        return [];
    try {
        const v = JSON.parse((await HANDLERS.pins("ourPins", list)) || "[]");
        return Array.isArray(v) ? v.map(p => p.subject).filter(Boolean) : [];
    }
    catch (_) {
        return [];
    }
}
// ── the writes: every one a whole-book replacement, then one sync ──────────
const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");
export function createList(name, emoji) {
    const base = "list:" + (slug(name) || "list");
    let id = base, n = 2;
    while (book().lists.some(l => l.id === id))
        id = `${base}-${n++}`;
    const l = { id, name: name.trim(), emoji: emoji || "📌", shared: false, t: Date.now() };
    persist({ ...book(), lists: [...book().lists, l] });
    return l;
}
export function updateList(id, patch) {
    persist({ ...book(), lists: book().lists.map(l => l.id === id ? { ...l, ...patch } : l) });
}
export function deleteList(id) {
    const b = book();
    persist({ lists: b.lists.filter(l => l.id !== id),
        pins: b.pins.filter(p => p.list !== id),
        dead: bury(b, [LKEY(id), ...b.pins.filter(p => p.list === id)
                .map(p => PKEY(p.list, p.subject))]) });
    const v = view.peek();
    if (v && v.kind === "mine" && v.id === id)
        view.set({ kind: "lists" });
}
export const isPinned = (list, subject) => book().pins.some(p => p.list === list && p.subject === subject);
/** File ROW under LIST, or take it out if it is already there. */
export function togglePin(list, row) {
    const subject = subjectOf(row);
    if (isPinned(list, subject)) {
        unpin(list, subject);
        return;
    }
    const b = book();
    const pin = { list, subject, t: Date.now(), name: row.name || "", emoji: row.emoji,
        kind: row.kind, lat: row.lat, lng: row.lng };
    persist({ ...b, pins: [...b.pins, pin], dead: unbury(b, PKEY(list, subject)) });
}
export function unpin(list, subject) {
    const b = book();
    persist({ ...b, pins: b.pins.filter(p => !(p.list === list && p.subject === subject)),
        dead: bury(b, [PKEY(list, subject)]) });
}
export function setNote(list, subject, note) {
    persist({ ...book(), pins: book().pins.map(p => p.list === list && p.subject === subject ? { ...p, note: note.trim() || undefined } : p) });
}
// ── subjects ───────────────────────────────────────────────────────────────
/** A row's identity in the book: its atlas id, or its spot when it has none. */
export const subjectOf = (row) => row.id || `spot:${row.lat.toFixed(5)},${row.lng.toFixed(5)}`;
/** A bare spot on the map as a row — what a dropped pin is before it is anything. */
export function spotRow(lat, lng) {
    return { id: `spot:${lat.toFixed(5)},${lng.toFixed(5)}`, kind: "place", emoji: "📌",
        name: "Dropped pin", provider: "you", lat, lng, arcs: [] };
}
/** A pin as a row again — the snapshot, for a list entry whose row is gone. */
export function pinRow(p) {
    return { id: p.subject, kind: p.kind, emoji: p.emoji, name: p.name, provider: "pinned",
        lat: p.lat, lng: p.lng, arcs: [], note: p.note };
}
/** While a list is open the map shows only what it holds. */
export function passes(subject) {
    const v = view.peek();
    if (!v || v.kind === "lists")
        return true;
    if (!subject)
        return false;
    return v.kind === "mine" ? isPinned(v.id, subject) : v.subjects.has(subject);
}
/** Is any list narrowing the map right now? */
export const narrowing = () => { const v = view.peek(); return !!v && v.kind !== "lists"; };
