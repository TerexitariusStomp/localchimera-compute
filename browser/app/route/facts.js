// app/route/facts.ts — what a route SAYS, in the words and places a preview
// draws it with. Pure: no DOM, no map, no clock of its own.
//
//   fmtMinutes / fmtDistance   "7 min", "1 h 5 min", "2.2 km", "0.4 mi"
//   headline                   "7 min (2.2 km)"
//   transitLines / rides       the lines a transit route rides, in order
//   segments                   a route's shape cut into runs by mode (walk · ride · walk)
//   replTrip                   a route as the REPL page's Scheme side takes it
//   boundsOf                   the box that holds every route
//   pillAnchor                 where a route's time pill sits so no route hides it
//   swapEnds                   the from/to card's ⇅
//
// The preview (app/route/preview.ts) is the one reader; the numbers it shows
// are these, so a test can state them.
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
/**
 * A route's shape cut into contiguous runs of one travel mode — walk, ride, walk — so each can be
 * drawn its own way. A route whose maneuvers name no mode (or none at all) is one run.
 */
export function segments(r) {
    const runs = [];
    for (const m of r.mans) {
        const last = runs[runs.length - 1];
        if (last && last.mode === m.mode)
            last.end = Math.max(last.end, m.end);
        else
            runs.push({ mode: m.mode, begin: m.begin, end: m.end });
    }
    const out = runs.map(s => ({ mode: s.mode, begin: s.begin, coords: r.coords.slice(s.begin, s.end + 1) }))
        .filter(s => s.coords.length > 1);
    return out.length ? out : r.coords.length > 1 ? [{ mode: "", begin: 0, coords: r.coords }] : [];
}
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
/** The box that holds every route's shape: [[west, south], [east, north]], or null when there is no shape. */
export function boundsOf(routes) {
    let w = 180, s = 90, e = -180, n = -90, any = false;
    for (const r of routes)
        for (const [x, y] of r.coords) {
            any = true;
            if (x < w)
                w = x;
            if (x > e)
                e = x;
            if (y < s)
                s = y;
            if (y > n)
                n = y;
        }
    return any ? [[w, s], [e, n]] : null;
}
// squared distance in a flat plane scaled at `cos` — the choice between two vertices needs no more
const d2 = (ax, ay, bx, by, cos) => ((ax - bx) * cos) ** 2 + (ay - by) ** 2;
/**
 * Where `routes[ix]`'s time pill sits: the point of its own shape farthest from
 * every other route, so a pill never lands on a way it is not about. With no
 * other route it sits halfway along. The first and last tenth of a shape are
 * left to the endpoints' own markers.
 */
export function pillAnchor(routes, ix) {
    const mine = routes[ix]?.coords;
    if (!mine || !mine.length)
        return null;
    const lo = Math.floor(mine.length * 0.1), hi = Math.max(lo + 1, Math.ceil(mine.length * 0.9));
    const body = mine.slice(lo, hi);
    const others = routes.filter((_, i) => i !== ix).flatMap(r => r.coords);
    if (!others.length)
        return body[Math.floor(body.length / 2)] ?? mine[Math.floor(mine.length / 2)];
    const cos = Math.cos(mine[Math.floor(mine.length / 2)][1] * Math.PI / 180);
    const stride = Math.max(1, Math.floor(others.length / 400));
    let best = body[0], bd = -1;
    for (const [x, y] of body) {
        let near = Infinity;
        for (let i = 0; i < others.length; i += stride) {
            const d = d2(x, y, others[i][0], others[i][1], cos);
            if (d < near)
                near = d;
        }
        if (near > bd) {
            bd = near;
            best = [x, y];
        }
    }
    return best;
}
/**
 * The from/to card's ⇅: each end takes the other's place. An end that is YOU stays you wherever it
 * goes — it follows the device, so its point is read from `you` afresh.
 */
export function swapEnds(from, to, you) {
    const now = (e) => e.live ? { ...e, at: you } : e;
    return { from: now(to), to: now(from) };
}
