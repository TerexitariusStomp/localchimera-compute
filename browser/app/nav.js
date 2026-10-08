// app/nav.ts — the commons' own wayfinder.
//
// serve-static's /route reaches the local Valhalla engine, and this turns its
// answer into the dial's centre: ONE turn at a time, big enough for a wrist. A
// place beyond the atlas degrades the card to a compass — bearing arrow and the
// crow's distance, still a direction, honestly named. Tap the mode glyph to
// cycle 🚶🚲🚗; tap the card to end.
//
// In earth mode the dial's angle already means bearing, so the journey's TIME
// lives on the card and its DIRECTION belongs to the dial. That division is why
// this module draws a card and a map line and nothing else.
//
// ── THE HOST ────────────────────────────────────────────────────────────────
// Routing reached into six of main.js's live mutable bindings — the map, the
// disc's pixel radius, which face owns the stage, the device heading, the
// you-marker, and the re-weld after the card reshapes the stage. Every one is a
// question about the dial's current arrangement, and none is a question about
// routing. NavHost names them, so the coupling is one interface at the top of a
// file instead of six reads scattered through it, and so a second surface that
// can name a destination (the search panel already does) needs no more than a
// destination.
import { USER, PLACES, pcoord, HANDLERS, EXT } from './core.js';
import { locationOptions } from './slots/model.js';
import { havKm, bearingDeg } from './geom.js';
import { onMapFace } from './stage.js';
import { deviceHeading } from './compass.js';
import { MAP_EL } from './mapview.js';
import { clockOf } from './timefmt.js';
import { gateHint } from './day/respond.js';
// ── the vocabulary of a journey ─────────────────────────────────────────────
/** How you are travelling. The keys are Valhalla's own costing names. */
const NAV_MODES = { pedestrian: "🚶", bicycle: "🚲", auto: "🚗" };
/** Valhalla maneuver type → the glyph the card shows for it. */
const NAV_GLYPH = {
    1: "↑", 2: "↗", 3: "↖", 4: "🏁", 5: "🏁", 6: "🏁", 8: "↑", 9: "↗", 10: "→",
    11: "↘", 12: "⤸", 13: "⤹", 14: "↙", 15: "←", 16: "↖", 17: "↑", 18: "↗", 19: "↖", 20: "↗",
    21: "↖", 22: "↑", 23: "↗", 24: "↖", 25: "⇡", 26: "⟳", 27: "⤴", 28: "⛴", 29: "⛴"
};
/** The eight compass arrows, from north clockwise — the degraded card's glyph. */
export const ARROW8 = ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"];
/** A distance, in the unit that reads at that size. */
export const navKm = (km) => km < 1 ? `${Math.round(km * 1000)} m` : `${km.toFixed(1)} km`;
const navClock = clockOf; // an arrival time is a wall clock, in your own zone
/** Valhalla's polyline, precision 6. */
function decodePoly(str) {
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
/** Ask the local engine for a way there. Null for anything it cannot answer. */
async function fetchRoute(from, to, costing) {
    const q = new URLSearchParams({ from: `${from.lat},${from.lng}`,
        to: `${to.lat},${to.lng}`, profile: costing });
    try {
        const js = await (await fetch(`/route?${q}`)).json();
        const legs = js?.trip?.legs || [];
        if (!legs.length)
            return null;
        let coords = [];
        const mans = [];
        let base = 0;
        for (const leg of legs) {
            const pts = leg.shape ? decodePoly(leg.shape) : [];
            for (const m of leg.maneuvers || [])
                mans.push({ type: m.type || 0, instr: m.instruction || "",
                    begin: base + (m.begin_shape_index || 0) });
            coords = coords.concat(pts);
            base += pts.length;
        }
        return { coords, mans, km: js.trip.summary.length || 0, s: js.trip.summary.time || 0 };
        //                       ↑ a reply with legs but no summary is not a shape
        //                         the engine emits; legs.length above is the guard.
    }
    catch (_) {
        return null;
    }
}
// ── the module's own state ──────────────────────────────────────────────────
// One journey at a time, by design: a wayfinder that offers two ways at once is
// not answering the question it was asked.
let host;
let nav = null;
let navWatch = -1;
let navProfile = "pedestrian";
/** Where the card lives when it is not floating: its original parent. */
let navHome = null;
/** Whether a journey is under way — the ↦ go chip's two meanings. */
export const navigating = () => nav !== null;
function drawNavLine() {
    const map = host.map();
    if (!map || !nav)
        return;
    const data = { type: "Feature", geometry: { type: "LineString",
            coordinates: nav.route ? nav.route.coords
                : [[USER.lng, USER.lat], [nav.dest.lng, nav.dest.lat]] } };
    const src = map.getSource("nav");
    if (src) {
        src.setData(data);
        return;
    }
    map.addSource("nav", { type: "geojson", data });
    map.addLayer({ id: "nav-casing", type: "line", source: "nav",
        layout: { "line-cap": "round", "line-join": "round" },
        paint: { "line-color": "#0b0f14", "line-width": 8, "line-opacity": .45 } });
    map.addLayer({ id: "nav-line", type: "line", source: "nav",
        layout: { "line-cap": "round", "line-join": "round" },
        paint: { "line-color": "#4ea1ff", "line-width": 5 } });
}
/** The nearest route vertex, scanning forward from where you last were. */
function navIdxNear(j, r) {
    const c = r.coords;
    let best = j.at, bd = Infinity;
    for (let i = Math.max(0, j.at - 5); i < c.length; i++) {
        const d = havKm(USER, { lat: c[i][1], lng: c[i][0] });
        if (d < bd) {
            bd = d;
            best = i;
        }
        if (i > j.at + 80 && d > bd + 0.15)
            break; // left the neighbourhood
    }
    return best;
}
function updateNavCard() {
    if (!nav)
        return;
    const card = d3.select("#navcard");
    card.select(".mode").text(NAV_MODES[navProfile]);
    if (!nav.route) { // the compass degradation
        const b = bearingDeg(USER, nav.dest), km = havKm(USER, nav.dest);
        card.select(".glyph").text(ARROW8[Math.round(((b - deviceHeading() + 360) % 360) / 45) % 8]);
        card.select(".instr").text(nav.placeName);
        card.select(".meta").text(`${navKm(km)} as the crow flies · no route data`);
        return;
    }
    const r = nav.route;
    nav.at = navIdxNear(nav, r);
    const nxt = r.mans.find(m => m.begin > nav.at);
    const remS = r.s * (1 - nav.at / Math.max(1, r.coords.length - 1));
    if (!nxt || havKm(USER, nav.dest) < 0.03) { // the last stretch
        card.select(".glyph").text("🏁");
        card.select(".instr").text(nav.placeName);
        card.select(".meta").text(`${navKm(havKm(USER, nav.dest))} left`);
    }
    else {
        const at = r.coords[nxt.begin];
        card.select(".glyph").text(NAV_GLYPH[nxt.type] || "↑");
        card.select(".instr").text(nxt.instr);
        card.select(".meta").text(`${navKm(havKm(USER, { lat: at[1], lng: at[0] }))} · ` +
            `${Math.max(1, Math.round(remS / 60))} min · arrive ${navClock(new Date(Date.now() + remS * 1000))}`);
    }
}
/** GPS moved: you move, and so does the thread that follows you. */
function onNavPos(pos) {
    USER.lat = pos.coords.latitude;
    USER.lng = pos.coords.longitude;
    host.moveUser();
    if (!nav)
        return;
    if (!nav.route)
        drawNavLine(); // the straight thread follows you
    updateNavCard();
}
/**
 * The turn-by-turn card follows the face: the sidebar for the disc (its home),
 * floated over the map on the map face, whose sidebar stands aside.
 */
function placeNavCard() {
    const nc = document.getElementById("navcard");
    if (!nc)
        return;
    if (!navHome)
        navHome = nc.parentElement;
    // The card floats over the map on the MAP face and returns to the sidebar
    // everywhere else — the map face's sidebar stands aside.
    if (onMapFace()) {
        const wrap = document.getElementById(MAP_EL());
        if (wrap && nc.parentElement !== wrap)
            wrap.appendChild(nc);
        nc.classList.add("overmap");
    }
    else if (navHome && nc.parentElement !== navHome) {
        navHome.appendChild(nc);
        nc.classList.remove("overmap");
    }
}
/**
 * Navigate to ANY point. The places list and the search panel share this one
 * route machinery — Valhalla via /route, the walk/bike/drive card, live GPS —
 * so a surface that can name a destination needs nothing else.
 *
 * A no-op with no map: the route is drawn on one.
 */
// ── the journey as a LEDGER fact ────────────────────────────────────────────
// A real trip is an observation like any other: begin mints the journey
// commitment and its pickup event, end records the dropoff fulfilling it —
// and the planner's transport coefficients learn from this very walk
// (solve/routing.scm's table). A destination the scope KNOWS goes by its location
// id; anywhere else goes faithfully as geo:lat,lng (recorded, priced later).
let journeyCid = null;
const geoRef = (p) => `geo:${p.lat.toFixed(5)},${p.lng.toFixed(5)}`;
const placeRef = (name, at) => {
    const l = locationOptions(EXT).find(x => x.name === name);
    return l ? l.id : geoRef(at);
};
function journeyBegin(dest, placeName) {
    if (!HANDLERS.journey)
        return;
    HANDLERS.journey("begin", geoRef(USER), placeRef(placeName, dest), navProfile, "")
        .then((r) => {
        if (r && r.startsWith("ok:") && r.length > 3)
            journeyCid = r.slice(3);
        else
            gateHint(r); // a provisional member is told where to go, once, the same way everywhere
    });
}
function journeyEnd() {
    if (!(journeyCid && HANDLERS.journey && nav)) {
        journeyCid = null;
        return;
    }
    HANDLERS.journey("end", geoRef(USER), placeRef(nav.placeName, nav.dest), navProfile, journeyCid).then(() => { });
    journeyCid = null;
}
export async function startNavTo(dest, placeName) {
    const map = host.map();
    if (!map)
        return;
    endNav();
    placeNavCard();
    journeyBegin(dest, placeName);
    const route = await fetchRoute(USER, dest, navProfile);
    nav = { dest, placeName, route, at: 0 };
    drawNavLine();
    // dashed for the compass degradation, solid for a real route — the card says
    // "no route data" in words and the line says it in its stroke.
    map.setPaintProperty("nav-line", "line-dasharray", route ? [1, 0] : [0.5, 1.8]);
    d3.select("#gochip").classed("on", true);
    d3.select("#navcard").style("display", "block");
    host.restage();
    updateNavCard();
    if (route) { // frame the whole way, then walk it
        const b = route.coords.reduce((a, c) => [Math.min(a[0], c[0]), Math.min(a[1], c[1]),
            Math.max(a[2], c[0]), Math.max(a[3], c[1])], [180, 90, -180, -90]);
        map.fitBounds([[b[0], b[1]], [b[2], b[3]]], { padding: host.mapRpx() * 0.22, duration: 700 });
    }
    if (navigator.geolocation && navWatch < 0)
        navWatch = navigator.geolocation.watchPosition(onNavPos, () => { }, { enableHighAccuracy: true, maximumAge: 3000 });
}
/** Navigate to the selected place, when one is selected and a map is up. */
async function startNav() {
    const sel = host.selectedPlace();
    if (!sel || !host.map())
        return;
    return startNavTo(sel.at, sel.name);
}
/** End the journey: the watch, the card, the chip and the two map layers. */
export function endNav() {
    journeyEnd(); // reads `nav` before it clears — the dropoff names the arc
    if (navWatch >= 0 && navigator.geolocation)
        navigator.geolocation.clearWatch(navWatch);
    navWatch = -1;
    nav = null;
    d3.select("#navcard").style("display", "none");
    d3.select("#gochip").classed("on", false);
    host.restage();
    const map = host.map();
    if (map) {
        for (const l of ["nav-line", "nav-casing"])
            if (map.getLayer(l))
                map.removeLayer(l);
        if (map.getSource("nav"))
            map.removeSource("nav");
    }
}
/**
 * Wire the chip and the card. Called once at boot with the dial's arrangement;
 * everything above reads the host at call time, so the dial may rebuild its map
 * as often as it likes.
 */
export function initNav(h) {
    host = h;
    d3.select("#gochip").on("click", () => { nav ? endNav() : startNav(); });
    d3.select("#navcard").on("click", e => {
        const t = e.target;
        if (t.classList.contains("mode") && nav) { // cycle 🚶→🚲→🚗
            const ms = Object.keys(NAV_MODES);
            navProfile = ms[(ms.indexOf(navProfile) + 1) % ms.length];
            startNav();
        }
        else
            endNav();
    });
}
/** The place a places-list index names, in the shape NavHost.selectedPlace wants. */
export function placeAt(leafId, i) {
    const p = (PLACES[leafId] || [])[i];
    return p ? { at: pcoord(p), name: p.name } : null;
}
