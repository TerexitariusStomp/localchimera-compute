// app/route/facts.ts — what a route SAYS, in the words and places a preview
// draws it with. Pure: no DOM, no map — and no clock but the one `arrivalClock` reads.
//
//   fmtMinutes / fmtDistance   "7 min", "1 h 5 min", "2.2 km", "0.4 mi"
//   headline                   "7 min (2.2 km)"
//   transitLines / rides       the lines a transit route rides, in order
//   replTrip                   a route as the REPL page's Scheme side takes it
//   arrivalClock               when you get there, as the clock says it
//   swapEnds                   the from/to card's ⇅
//
// The preview (app/route/preview.ts) is the one reader; the numbers it shows
// are these, so a test can state them.
import { clockOf } from '../timefmt.js';
import { segments } from './shape.js';
/** A duration the way a person says it: under an hour in minutes, else hours and minutes. */
export function fmtMinutes(s) {
    const m = Math.max(1, Math.round(s / 60));
    if (m < 60)
        return `${m} min`;
    const h = Math.floor(m / 60), r = m % 60;
    return r ? `${h} h ${r} min` : `${h} h`;
}
/**
 * A distance in the unit the engine answered with, at the size it reads at: metres
 * under a kilometre, tenths to ten, whole numbers beyond. THE one formatter —
 * the wayfinder, the places list and the map's search all print through it.
 */
export function fmtDistance(km, units = "kilometers") {
    if (units === "miles")
        return km < 0.1 ? `${Math.round(km * 5280)} ft` : `${km < 10 ? km.toFixed(1) : km.toFixed(0)} mi`;
    return km < 1 ? `${Math.round(km * 1000)} m` : `${km < 10 ? km.toFixed(1) : km.toFixed(0)} km`;
}
/** "7 min (2.2 km)" — the preview's summary line. */
export const headline = (r) => `${fmtMinutes(r.s)} (${fmtDistance(r.km, r.units)})`;
/** The maneuvers that board a vehicle — a transfer boards another; "remain on" (type 32) stays on the same. */
const boards = (m) => !!m.transit && m.type !== 32;
/** The lines a route rides, in order. Empty for a route on foot, by bike or by car. */
export function transitLines(r) {
    return r.mans.filter(boards).map(m => ({
        line: m.transit.line || m.transit.name, headsign: m.transit.headsign,
        color: m.transit.color, textColor: m.transit.textColor
    }));
}
/** How many vehicles a route boards. */
export const rides = (r) => r.mans.filter(boards).length;
/** The wall clock, in your own zone, `secondsFromNow` ahead — "17:05". */
export const arrivalClock = (secondsFromNow) => clockOf(new Date(Date.now() + secondsFromNow * 1000));
/**
 * A route in the one normalized contract the REPL page's Scheme side pipes around
 * (hoot/repl.scm's journey): { engine, profile, coordinates, segments, distance_km,
 * time_s, maneuvers }. The page reads Valhalla through the same reader the dial does.
 */
export function replTrip(r, profile) {
    return {
        engine: "valhalla", profile: profile || "foot",
        coordinates: r.coords,
        segments: segments(r).map(s => ({ mode: s.mode, coordinates: s.coords })),
        distance_km: r.km, time_s: r.s,
        maneuvers: r.mans.map(m => ({ instruction: m.instr, type: m.type, distance_km: m.length,
            time_s: m.time, travel_mode: m.mode, begin: m.begin, end: m.end })),
    };
}
/**
 * The from/to card's ⇅: each end takes the other's place. An end that is YOU stays you wherever it
 * goes — it follows the device, so its point is read from `you` afresh.
 */
export function swapEnds(from, to, you) {
    const now = (e) => e.live ? { ...e, at: you } : e;
    return { from: now(to), to: now(from) };
}
