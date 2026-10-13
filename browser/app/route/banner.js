// app/route/banner.ts — what the wayfinder says, one turn at a time.
//
// The turn-by-turn card (#navcard) reads, over the map, as the maneuver banner: a big
// arrow, the distance to the turn in large type, the street, and — when the turn after
// is close — a *Then* chip. On the disc it is the same card, with its one-line meta.
// `routeBanner` and `bearingBanner` are the pure half (progress in, words out);
// `drawBanner` writes them to the card.
import { ARROW8 } from '../geom.js';
import { fmtDistance, fmtMinutes, rideLine } from './facts.js';
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
/** Whether a maneuver is the arrival. */
export const isArrival = (type) => ARRIVAL.has(type);
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
    const ride = m.transit ? rideLine(m.transit) : null;
    const street = ride ? (ride.headsign ? `${ride.line} toward ${ride.headsign}` : ride.line) : m.streets[0] || m.instr;
    return { state: "route", glyph: glyphOf(m.type), dist, street, then: after,
        meta: `${dist} · ${mins} · arrive ${o.arrive}` };
}
/** The card while a new way is being found: you left the old one. */
export const reroutingBanner = () => ({ state: "rerouting", glyph: "⟳", dist: "Rerouting…", street: "", then: null, meta: "Rerouting…" });
/** The card with no way to follow: an arrow toward the place, and how far it is as the crow flies. */
export function bearingBanner(o) {
    const dist = fmtDistance(o.km);
    return { state: "bearing", glyph: ARROW8[Math.round(((o.bearing - o.heading + 360) % 360) / 45) % 8], dist,
        street: o.place, then: null, meta: `${dist} as the crow flies · no route data` };
}
// ── the card itself ─────────────────────────────────────────────────────────
// #navcard is one element with two homes: floated over the map (the banner), or in the disc's sidebar (its place in
// the page). This module is the only one that reaches it.
const cardEl = () => document.getElementById("navcard");
/** Where the card lives when it is not floating: the parent it was found in. */
let cardHome = null;
/** Float the card over `container` (the map), or — with none — return it to its place in the page. */
export function placeCard(container) {
    const nc = cardEl();
    if (!nc)
        return;
    if (!cardHome)
        cardHome = nc.parentElement;
    if (container) {
        if (nc.parentElement !== container)
            container.appendChild(nc);
        nc.classList.add("overmap");
    }
    else if (cardHome && nc.parentElement !== cardHome) {
        cardHome.appendChild(nc);
        nc.classList.remove("overmap");
    }
}
/** Show or hide the card. */
export function showCard(on) { if (cardEl())
    cardEl().style.display = on ? "block" : "none"; }
/** How far down the map the floating card reaches, in pixels; 0 when it is not over the map. */
export function cardHeight() {
    const nc = cardEl();
    return nc && nc.classList.contains("overmap")
        ? Math.round(nc.getBoundingClientRect().bottom - (nc.parentElement?.getBoundingClientRect().top ?? 0)) : 0;
}
/** A tap on the card: `overMap` tells whether it is the banner (read, not pressed) or the disc's card. */
export function onCardTap(fn) {
    cardEl()?.addEventListener("click", e => fn(e.target, cardEl().classList.contains("overmap")));
}
/** Write a view to the card. */
export function drawBanner(v, mode) {
    const card = cardEl();
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
