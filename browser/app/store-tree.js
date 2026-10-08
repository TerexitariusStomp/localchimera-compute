// app/store-tree.ts — a store as it is arranged: places inside places, things
// inside things.
//
// Two trees, kept apart by whether a thing moves (docs/observation/capture.md
// §6): a shelf is a place, a bin on the shelf is a container and is carried to
// another shelf with what is in it. This module reads both off flat lists, the
// way the wire carries them, each entry naming what it is inside. Pure, so the
// inventory face, the capture sheet and a unit test read the same arrangement.
const SEPARATOR = " › ";
/**
 * A place's path from the outermost place inward: "Mill House › Pantry ›
 * Shelf 1". An id the table does not hold reads as itself, and a table that
 * names a place inside itself is walked once.
 */
export function placePath(id, places) {
    if (!id)
        return "";
    const by = new Map(places.map(p => [p.id, p]));
    const names = [];
    const seen = new Set();
    for (let at = id; at && !seen.has(at); at = by.get(at)?.containedIn) {
        seen.add(at);
        const p = by.get(at);
        names.unshift(p?.name || at);
        if (!p)
            break;
    }
    return names.join(SEPARATOR);
}
/**
 * Things in the order a store is read: each container, then what is in it, a
 * level deeper. A thing inside something the list does not hold stands at the
 * top, and the order given is kept among siblings.
 */
export function nest(rows) {
    const ids = new Set(rows.map(r => r.id).filter((x) => !!x));
    const kids = new Map();
    const tops = [];
    for (const r of rows) {
        const p = r.containedIn;
        if (p && p !== r.id && ids.has(p))
            kids.set(p, [...(kids.get(p) ?? []), r]);
        else
            tops.push(r);
    }
    const out = [];
    const seen = new Set();
    const walk = (r, depth) => {
        if (seen.has(r))
            return;
        seen.add(r);
        const mine = (r.id && kids.get(r.id)) || [];
        out.push({ row: r, depth, holds: mine.length });
        mine.forEach(k => walk(k, depth + 1));
    };
    tops.forEach(r => walk(r, 0));
    // a ring of things each inside the next has no top; they are read flat
    rows.forEach(r => walk(r, 0));
    return out;
}
