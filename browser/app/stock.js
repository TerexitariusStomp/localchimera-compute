// app/stock.ts — a thing on the books, read off the wire once.
//
// The inventory snapshot carries each stock as a row of kebab-cased keys, and
// the scope's places as a flat table that names what each is inside. The
// inventory face, the capture sheet and the photo read each need the same few
// fields of one, so the reading lives here: pure, text and numbers in, a typed
// row out, so a unit test holds each coercion and the faces share one shape.
import { readExpected } from "./count.js";
const text = (v) => (typeof v === "string" ? v : v == null ? "" : String(v));
/**
 * One inventory row, read. Lenient: a field the wire left out reads as empty
 * (or zero), and the name falls back to the spec and then the id. Null when
 * the row is not an object.
 */
export function stockOf(raw) {
    if (!raw || typeof raw !== "object")
        return null;
    const r = raw;
    const id = text(r.id), spec = text(r["conforms-to"] ?? r.spec);
    const onhand = Number(r.onhand);
    return {
        id, name: text(r.name) || spec || id, spec, unit: text(r.unit),
        onhand: Number.isFinite(onhand) ? onhand : 0,
        location: text(r.location), code: text(r.code),
        expires: text(r.expires), expiresKind: text(r["expires-kind"]),
        containedIn: text(r["contained-in"]),
        mode: text(r["distribution-mode"]), stage: text(r.stage), state: text(r.state),
        custodian: text(r["custodian-name"]),
        emoji: text(raw.emoji),
        expected: readExpected(raw.expected),
    };
}
/** The stocks a list of rows holds, those that name themselves. */
export function stocksOf(rows) {
    return (Array.isArray(rows) ? rows : [])
        .map(stockOf)
        .filter((s) => s !== null && s.id !== "");
}
/** The scope's places, as far as a path needs them. */
export function placesOf(locations) {
    return (locations ?? []).map(l => ({
        id: text(l.id), name: l.name ? text(l.name) : undefined,
        containedIn: typeof l.containedIn === "string" ? l.containedIn : null,
    }));
}
/**
 * A lot's date as a face says it: "use by 2026-10-04", "best before …", and
 * "date …" when the lot states a date without saying which. Empty when it
 * states none.
 */
export function lotDate(expires, kind) {
    if (!expires)
        return "";
    const which = kind === "use-by" ? "use by" : kind === "best-before" ? "best before" : "date";
    return `${which} ${expires.slice(0, 10)}`;
}
/** Whether a stock keeps for a day or two: a lot with a use-by date does. */
export const perishes = (s) => s.expiresKind === "use-by";
/**
 * The things in a flat list that sit inside `rid`, at any depth. A ring of
 * things each inside the next is walked once.
 */
export function within(rid, stocks) {
    const inside = new Map(stocks.map(s => [s.id, s.containedIn]));
    const holds = (id) => {
        const seen = new Set();
        for (let at = inside.get(id); at && !seen.has(at); at = inside.get(at)) {
            if (at === rid)
                return true;
            seen.add(at);
        }
        return false;
    };
    return stocks.filter(s => s.id !== rid && holds(s.id));
}
