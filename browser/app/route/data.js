// app/route/data.ts — what /route says, read once into the shapes the journey
// UI draws from.
//
// serve-static's /route is a thin relay to the local Valhalla engine, so a
// reply is Valhalla's own JSON. This module is the one reader of it: the
// polyline decode, the trip → Route reading (the chosen way and its
// alternates), the request a mode asks with, and a short-lived cache so the
// preview's four mode tabs and a re-opened sheet do not ask the engine twice.
// It draws nothing and holds no journey; app/route/nav.ts and the preview sit on it.
//
// Every field is read defensively. A leg may carry no shape, a maneuver no
// street names: an absent field reads as absent (empty list, 0, ""), never as a
// guess, and a reply with no legs is no route at all.
/**
 * THE table of modes, in the order a preview shows its tabs (transit first, as the
 * phone's do) and the wayfinder's mode glyph cycles. The preview, the wayfinder and
 * the REPL page all read their words and glyphs from here.
 */
export const MODES = [
    { costing: "multimodal", label: "Transit", icon: "🚌" },
    { costing: "pedestrian", label: "Walk", icon: "🚶" },
    { costing: "bicycle", label: "Bicycle", icon: "🚲" },
    { costing: "auto", label: "Drive", icon: "🚗" },
];
export const ROUTE_MODES = MODES.map(m => m.costing);
/** What a mode is called and drawn as; undefined for a costing the UI has no tab for. */
export const modeInfo = (costing) => MODES.find(m => m.costing === costing);
/** The mode that travels each way a stretch can go: the engine's `travel_mode` → our costing. */
const COSTING_OF_TRAVEL = { pedestrian: "pedestrian", bicycle: "bicycle", drive: "auto", transit: "multimodal" };
/** The glyph for how a stretch is travelled — the engine's `travel_mode` — "" for one we have none for. */
export const travelIcon = (travelMode) => modeInfo(COSTING_OF_TRAVEL[travelMode] ?? "")?.icon ?? "";
/**
 * UI words → Valhalla costing — the one vocabulary boundary, where the words are
 * born; the wire and the server speak costing names natively. A name already a
 * costing passes through, and no word at all is a walk.
 */
export function costingOf(word) {
    return { foot: "pedestrian", bike: "bicycle", car: "auto", scooter: "motor_scooter",
        transit: "multimodal", bus: "bus" }[word || ""] || word || "pedestrian";
}
/** Valhalla's polyline, precision 6. */
export function decodePoly(str) {
    const out = [];
    let i = 0, lat = 0, lng = 0;
    const val = () => {
        let s = 0, r = 0, b;
        do {
            b = str.charCodeAt(i++) - 63;
            r |= (b & 0x1f) << s;
            s += 5;
        } while (b >= 0x20);
        return (r & 1) ? ~(r >> 1) : (r >> 1);
    };
    while (i < str.length) {
        lat += val();
        lng += val();
        out.push([lng / 1e6, lat / 1e6]);
    }
    return out;
}
/** Valhalla's numeric colour (0xRRGGBB as a number) as "#rrggbb". */
const colorHex = (n) => typeof n === "number" && n >= 0 ? "#" + n.toString(16).padStart(6, "0") : "";
function readTransit(t) {
    if (!t)
        return null;
    return {
        line: t.short_name || "", name: t.long_name || "", headsign: t.headsign || "",
        color: colorHex(t.color), textColor: colorHex(t.text_color),
        operator: t.operator_name || "",
        stops: (t.transit_stops || []).map(s => ({
            name: s.name || "", arrives: s.arrival_date_time || "", departs: s.departure_date_time || ""
        })),
    };
}
/** The side of the street the last location is on. */
function sideOf(locs) {
    const s = locs && locs.length ? locs[locs.length - 1].side_of_street : "";
    return s === "left" || s === "right" ? s : "";
}
/** One trip, or null for anything that is not a route: no legs, or no summary. */
function readTrip(trip, costing) {
    const legs = trip?.legs || [];
    if (!legs.length || !trip?.summary)
        return null;
    let coords = [];
    const mans = [];
    let base = 0;
    for (const leg of legs) {
        const pts = leg.shape ? decodePoly(leg.shape) : [];
        for (const m of leg.maneuvers || []) {
            const begin = base + (m.begin_shape_index || 0);
            mans.push({
                type: m.type || 0, instr: m.instruction || "", begin,
                end: m.end_shape_index === undefined ? begin : base + m.end_shape_index,
                streets: m.street_names || [], length: m.length || 0, time: m.time || 0,
                verbal: { alert: m.verbal_transition_alert_instruction || "",
                    pre: m.verbal_pre_transition_instruction || "",
                    post: m.verbal_post_transition_instruction || "" },
                roundaboutExit: m.roundabout_exit_count || 0,
                toll: !!m.toll, gate: !!m.gate, rough: !!m.rough, ferry: !!m.ferry,
                mode: m.travel_mode || "", transit: readTransit(m.transit_info),
            });
        }
        coords = coords.concat(pts);
        base += pts.length;
    }
    return { coords, mans, km: trip.summary.length || 0, s: trip.summary.time || 0,
        units: trip.units === "miles" ? "miles" : "kilometers",
        hasToll: !!trip.summary.has_toll, hasFerry: !!trip.summary.has_ferry,
        destSide: sideOf(trip.locations), costing };
}
/** A whole reply: the engine's chosen way first, then each alternate. [] when it answered nothing. */
export function readRoutes(js, costing) {
    const r = (js || {});
    return [readTrip(r.trip, costing), ...(r.alternates || []).map(a => readTrip(a.trip, costing))]
        .filter((x) => x !== null);
}
const ll = (p) => `${p.lat},${p.lng}`;
/**
 * The /route query for a request. Transit is a timetable: a multimodal ask with
 * no clock leaves now, so the tab shows the next departure, not nothing.
 */
export function routeQuery(from, to, costing, o = {}) {
    const q = new URLSearchParams({ from: ll(from), to: ll(to), profile: costing });
    if (o.via && o.via.length)
        q.set("via", o.via.map(ll).join(";"));
    if (o.alternates)
        q.set("alternates", String(o.alternates));
    const depart = o.depart || (costing === "multimodal" && !o.arrive ? "now" : "");
    if (depart)
        q.set("depart", depart);
    if (o.arrive)
        q.set("arrive", o.arrive);
    if (o.lang)
        q.set("lang", o.lang);
    if (o.units === "miles")
        q.set("units", "mi");
    return q.toString();
}
// A route answered a moment ago is the route now: a preview's four tabs, and a
// sheet closed and opened again, share one ask. Nothing outlives two minutes —
// a timetable and the road both move — and an empty answer is never kept, so
// an engine that comes up mid-session is found on the next ask.
const TTL_MS = 120_000;
const CACHE_MAX = 32;
const cache = new Map();
export const clearRouteCache = () => cache.clear();
/**
 * Routes from `from` to `to` by `costing`: the engine's chosen way, then its
 * alternates. [] for anything it cannot answer — a down engine, a place beyond
 * its atlas, a mode with no network there.
 */
export function fetchRoutes(from, to, costing, o = {}) {
    const q = routeQuery(from, to, costing, o);
    const now = Date.now();
    const hit = cache.get(q);
    if (hit && now - hit.at < TTL_MS)
        return hit.p;
    const p = (async () => {
        try {
            return readRoutes(await (await fetch(`/route?${q}`)).json(), costing);
        }
        catch (_) {
            return [];
        }
    })();
    cache.set(q, { at: now, p });
    if (cache.size > CACHE_MAX)
        cache.delete(cache.keys().next().value);
    p.then(rs => { if (!rs.length && cache.get(q)?.p === p)
        cache.delete(q); });
    return p;
}
/** One ask per mode, all at once: each key holds that mode's routes ([] when it has none). */
export async function fetchModes(from, to, modes = ROUTE_MODES, o = {}) {
    const rs = await Promise.all(modes.map(m => fetchRoutes(from, to, m, o)));
    return Object.fromEntries(modes.map((m, i) => [m, rs[i]]));
}
