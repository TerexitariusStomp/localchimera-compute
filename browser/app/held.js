// app/held.ts — where a good is held, stock by stock.
//
// A good is a kind (bread); the ledger holds it as stocks, each at a place. The
// Resources face shows a good's sums; a count is of one stock at one place. This
// module is the join between the two: the stocks of a good, each with where it is,
// what the ledger reads and what the plan expects, and the sum said in a line.
// Pure, so the face and a unit test read it the same way.
import { quantity } from "./count.js";
import { placePath } from "./store-tree.js";
/** The stocks of the good SPEC among STOCKS, most held first: those that conform to it. */
export function heldOf(spec, stocks, places) {
    return stocks
        .filter(s => s.id && s.spec === spec)
        .map(s => ({ id: s.id, name: s.name, where: s.location ? placePath(s.location, places) : "",
        onhand: s.onhand, unit: s.unit, expected: s.expected }))
        .sort((a, b) => b.onhand - a.onhand || a.where.localeCompare(b.where));
}
/**
 * The stocks held at PLACE among STOCKS, most held first: those at it, and those
 * at a place inside it. A thing inside a container is at its container's place.
 */
export function heldAt(place, stocks, places) {
    const within = new Set([place]);
    // the places inside PLACE, however deep; each pass adds one level
    for (let grew = true; grew;) {
        grew = false;
        for (const p of places)
            if (p.containedIn && within.has(p.containedIn) && !within.has(p.id)) {
                within.add(p.id);
                grew = true;
            }
    }
    return stocks
        .filter(s => s.id && s.location && within.has(s.location))
        .map(s => ({ id: s.id, name: s.name, where: placePath(s.location, places), onhand: s.onhand, unit: s.unit, expected: s.expected }))
        .sort((a, b) => b.onhand - a.onhand || a.name.localeCompare(b.name));
}
/** The good's stocks in a line: "the ledger holds 180 kg in 2 places"; empty when it holds none. */
export function heldSummary(held) {
    if (!held.length)
        return "";
    const units = new Set(held.map(h => h.unit));
    const n = held.length;
    const where = n === 1 ? (held[0].where ? `at ${held[0].where.split(" › ").pop()}` : "in one place") : `in ${n} places`;
    // stocks held in different units have no one sum
    return units.size === 1 ? `the ledger holds ${quantity(held.reduce((a, h) => a + h.onhand, 0), held[0].unit)} ${where}`
        : `the ledger holds it ${where}`;
}
