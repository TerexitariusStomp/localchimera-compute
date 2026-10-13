// app/route/banner.ts — what the wayfinder says, one turn at a time.
//
// The turn-by-turn card (#navcard) reads, over the map, as the maneuver banner: a big
// arrow, the distance to the turn in large type, the street, and — when the turn after
// is close — a *Then* chip. On the disc it is the same card, with its one-line meta.
// `routeBanner` and `bearingBanner` are the pure half (progress in, words out);
// `drawBanner` writes them to the card.
import { ARROW8 } from '../geom.js';
import { fmtDistance, fmtMinutes } from './facts.js';
/** Valhalla maneuver type → the glyph the card shows for it. */
const NAV_GLYPH = {
    1: "↑", 2: "↗", 3: "↖", 4: "🏁", 5: "🏁", 6: "🏁", 8: "↑", 9: "↗", 10: "→",
    11: "↘", 12: "⤸", 13: "⤹", 14: "↙", 15: "←", 16: "↖", 17: "↑", 18: "↗", 19: "↖", 20: "↗",
    21: "↖", 22: "↑", 23: "↗", 24: "↖", 25: "⇡", 26: "⟳", 27: "⤴", 28: "⛴", 29: "⛴",
    // transit: board, transfer, stay aboard, and the walks to and from the stops
    30: "🚌", 31: "⇄", 32: "🚌", 33: "🚶", 34: "🚶", 35: "🚶", 36: "🚶", 37: "↗", 38: "↖"
};
/** The glyph for a maneuver type; straight on when the engine names one we have no picture of. */
export const glyphOf = (type) => NAV_GLYPH[type] || "↑";
/** The maneuver types that mean *you are there*. */
const ARRIVAL = new Set([4, 5, 6]);
/** Within this many metres of the next turn, the turn after it is shown too. */
export const THEN_M = 150;
/** The card for a journey along `r`, `p` of the way. `arrive` is the arrival clock, already formatted. */
export function routeBanner(r, p, o) {
    const mins = fmtMinutes(p.remS);
    if (o.arrived)
        return { state: "arrived", glyph: "🏁", dist: "Arrived", street: o.place, then: null, meta: `You have arrived · ${o.place}` };
    const m = p.next >= 0 ? r.mans[p.next] : null;
    if (!m || ARRIVAL.has(m.type)) { // the last stretch
        const dist = fmtDistance(m ? p.toNextKm : p.remKm, r.units);
        return { state: "route", glyph: "🏁", dist, street: o.place, then: null,
            meta: `${dist} left · ${mins} · arrive ${o.arrive}` };
    }
    const dist = fmtDistance(p.toNextKm, r.units);
    const after = p.then >= 0 && p.nextToThenM < THEN_M && !ARRIVAL.has(r.mans[p.then].type) ? glyphOf(r.mans[p.then].type) : null;
    return { state: "route", glyph: glyphOf(m.type), dist, street: m.streets[0] || m.instr, then: after,
        meta: `${dist} · ${mins} · arrive ${o.arrive}` };
}
/** The card with no way to follow: an arrow toward the place, and how far it is as the crow flies. */
export function bearingBanner(o) {
    const dist = fmtDistance(o.km);
    return { state: "bearing", glyph: ARROW8[Math.round(((o.bearing - o.heading + 360) % 360) / 45) % 8], dist,
        street: o.place, then: null, meta: `${dist} as the crow flies · no route data` };
}
/** Write a view to the card. */
export function drawBanner(v, mode) {
    const card = document.getElementById("navcard");
    if (!card)
        return;
    card.dataset.state = v.state;
    const set = (sel, text) => { const e = card.querySelector(sel); if (e)
        e.textContent = text; };
    set(".glyph", v.glyph);
    set(".dist", v.dist);
    set(".street", v.street);
    set(".meta", v.meta);
    set(".mode", mode);
    const then = card.querySelector(".nb-then");
    if (then) {
        then.hidden = v.then === null;
        then.querySelector(".then-glyph").textContent = v.then ?? "";
    }
}
