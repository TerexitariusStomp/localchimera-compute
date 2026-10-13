// app/route/nav.ts — the commons' own wayfinder: a journey under way.
//
// A journey is a chosen way (app/route/preview.ts hands it here) walked with the device's fixes
// (app/position.ts). This module keeps the journey's one record and orchestrates what reads it:
//
//   banner.ts   the turn, in words and a glyph — the card over the map, the disc's card elsewhere
//   sheet.ts    the journey's sheet: the ETA row, and the drawer that rises from it (menu, directions, modes)
//   steps.ts    the way turn by turn, for the drawer
//   follow.ts   the camera: heading-up, tipped, you low in the frame; recentre and overview
//   lines.ts    the way drawn, what is behind you dimmed
//   drive-sim   a rehearsed drive in place of the device (`?simdrive=<factor>`)
//
// A place beyond the atlas degrades the card to a compass — bearing arrow and the crow's distance,
// still a direction, honestly named. On the disc (earth mode) the dial's angle already means
// bearing, so the journey's TIME lives on the card and its DIRECTION belongs to the dial: there the
// card is all there is, and tapping it ends the journey (its mode glyph changes the mode).
//
// ── THE HOST ────────────────────────────────────────────────────────────────
// Routing reached into live mutable bindings of main.js — the map, the disc's pixel radius, the
// re-weld after the card reshapes the stage. Every one is a question about the dial's current
// arrangement, and none is a question about routing. NavHost names them, so the coupling is one
// interface at the top of a file, and so a second surface that can name a destination (the search
// panel already does) needs no more than a destination.
import { USER, PLACES, pcoord, HANDLERS, EXT } from '../core.js';
import { locationOptions } from '../slots/model.js';
import { havKm, bearingDeg } from '../geom.js';
import { onMapFace } from '../stage.js';
import { deviceHeading, compassLive } from '../compass.js';
import { MAP_EL } from '../mapview.js';
import { gateHint } from '../day/respond.js';
import { sheetHeight } from '../tabs/social/share.js';
import { watchFixes } from '../position.js';
import { fetchRoutes, ROUTE_MODES, modeInfo } from './data.js';
import { fmtDistance, fmtMinutes, arrivalClock } from './facts.js';
import { snapToRoute, progress, courseAt } from './shape.js';
import { paintLines, clearLines } from './lines.js';
import { routeBanner, bearingBanner, drawBanner } from './banner.js';
import { openJourneySheet } from './sheet.js';
import { stepRows } from './steps.js';
import { startFollow } from './follow.js';
import { startDrive } from './drive-sim.js';
/** Within this many kilometres of the end of the way, you have arrived. */
const ARRIVED_KM = 0.03;
/** Ask the local engine for a way there. Null for anything it cannot answer. */
async function fetchRoute(from, to, costing) {
    return (await fetchRoutes(from, to, costing))[0] || null;
}
// ── the module's own state ──────────────────────────────────────────────────
// One journey at a time, by design: a wayfinder that offers two ways at once is
// not answering the question it was asked.
let host;
let nav = null;
let navProfile = "pedestrian";
/** Ends the position watch the journey holds, while one is held. */
let stopWatch = null;
/** What a journey on the map face holds besides the card. */
let jsheet = null;
let follow = null;
let drive = null;
let wake = null;
/** Set while the journey itself is closing the ETA bar, so the bar's own "gone" does not end it twice. */
let closing = false;
/** Where the card lives when it is not floating: its original parent. */
let navHome = null;
/** Whether a journey is under way — the ↦ go chip's two meanings. */
export const navigating = () => nav !== null;
/** Whether the camera is held on you — the compass leaves the map's bearing to it. */
export const cameraHeld = () => follow !== null && follow.following();
/** Draw the journey: its way with what is behind you dimmed, or — with no way — a bearing thread. */
function drawNavLine() {
    const map = host.map();
    if (!map || !nav)
        return;
    paintLines(map, nav.route
        ? { ways: [nav.route], pick: 0, at: nav.snap.at + nav.snap.t }
        : { bearing: [[USER.lng, USER.lat], [nav.dest.lng, nav.dest.lat]] });
}
/** Say where you are: the card, the ETA bar, the line, the camera. */
function refresh(fix) {
    const j = nav;
    if (!j)
        return;
    const mode = modeInfo(navProfile)?.icon ?? "";
    if (!j.route) { // the compass degradation
        const km = havKm(USER, j.dest);
        drawBanner(bearingBanner({ bearing: bearingDeg(USER, j.dest), heading: deviceHeading(), km, place: j.placeName }), mode);
        jsheet?.update({ big: fmtDistance(km), sub: "as the crow flies · no route data", arrived: false, steps: [], mode: navProfile });
        return;
    }
    const r = j.route;
    j.snap = snapToRoute(r, USER, j.snap.at);
    const p = progress(r, j.snap);
    if (!j.arrived && (havKm(USER, j.dest) < ARRIVED_KM || p.aheadKm < ARRIVED_KM)) {
        j.arrived = true;
        follow?.stop();
        follow = null; // the camera is given back at the door
    }
    const arrive = arrivalClock(p.remS);
    drawBanner(routeBanner(r, p, { place: j.placeName, arrive, arrived: j.arrived }), mode);
    const steps = stepRows(r, p, j.placeName);
    jsheet?.update(j.arrived
        ? { big: "You have arrived", sub: j.placeName, arrived: true, steps, mode: navProfile }
        : { big: fmtMinutes(p.remS), sub: `${fmtDistance(p.remKm, r.units)} · ${arrive}`, arrived: false, steps, mode: navProfile });
    drawNavLine();
    const f = fix ?? { lat: USER.lat, lng: USER.lng, heading: null, speed: null, accuracy: null, t: Date.now() };
    follow?.onFix(f, courseAt(r, j.snap));
}
/** A fix: you have moved (app/position.ts moved USER and the you-marker), and so does what follows you. */
function onFix(f) { refresh(f); }
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
// ── the screen stays on ─────────────────────────────────────────────────────
async function holdScreen() {
    try {
        if (!wake || wake.released)
            wake = (await navigator.wakeLock?.request("screen")) ?? null;
    }
    catch {
        wake = null;
    }
}
// the lock is let go when the page is hidden; a journey still under way takes it again on return
document.addEventListener("visibilitychange", () => { if (nav && document.visibilityState === "visible")
    void holdScreen(); });
/** The banner's height, so the camera keeps you clear of it. */
const bannerHeight = () => {
    const nc = document.getElementById("navcard");
    return nc && nc.classList.contains("overmap") ? Math.round(nc.getBoundingClientRect().bottom - (nc.parentElement?.getBoundingClientRect().top ?? 0)) : 0;
};
export async function startNavTo(dest, placeName, chosen) {
    const map = host.map();
    if (!map)
        return;
    endNav();
    if (chosen)
        navProfile = chosen.costing;
    placeNavCard();
    journeyBegin(dest, placeName);
    const route = chosen ? chosen.route : await fetchRoute(USER, dest, navProfile);
    nav = { dest, placeName, route, snap: { at: 0, t: 0, offKm: 0 }, arrived: false };
    d3.select("#gochip").classed("on", true);
    d3.select("#navcard").style("display", "block");
    host.restage();
    const mapFace = onMapFace();
    if (mapFace) {
        document.getElementById(MAP_EL())?.classList.add("navigating");
        jsheet = openJourneySheet({
            exit: () => endNav(), done: () => endNav(),
            gone: () => { if (!closing)
                endNav(); },
            overview: () => follow?.overview(), travelBy, bannerHeight,
        });
        if (route)
            follow = startFollow({
                map: () => host.map(), sheetHeight, bannerHeight,
                deviceHeading: () => compassLive() ? deviceHeading() : null,
                remaining: () => nav?.route ? { ...nav.route, coords: nav.route.coords.slice(nav.snap.at) } : null,
            }, navProfile, document.getElementById(MAP_EL()));
        void holdScreen();
    }
    else if (route) { // on the disc: frame the whole way, then walk it
        const b = route.coords.reduce((a, c) => [Math.min(a[0], c[0]), Math.min(a[1], c[1]),
            Math.max(a[2], c[0]), Math.max(a[3], c[1])], [180, 90, -180, -90]);
        map.fitBounds([[b[0], b[1]], [b[2], b[3]]], { padding: host.mapRpx() * 0.22, duration: 700 });
    }
    refresh();
    if (!stopWatch)
        stopWatch = watchFixes(onFix, { highAccuracy: true });
    // a rehearsed drive in place of the device: `?simdrive=<times the way's own pace>`
    const sim = new URLSearchParams(location.search).get("simdrive");
    if (route && sim !== null)
        drive = startDrive(route, { factor: Number(sim) || 10 });
}
/** Travel the rest of the way by another mode: the journey's own destination, routed again. */
export function travelBy(costing) {
    if (!nav)
        return;
    navProfile = costing;
    const { dest, placeName } = nav;
    void startNavTo(dest, placeName);
}
/** The ways to the selected place, when one is selected and a map is up. */
function startNav() {
    const sel = host.selectedPlace();
    if (!sel || !host.map())
        return;
    host.directions(sel.at, sel.name);
}
/** End the journey: the watch, the camera, the bar, the card, the chip and the map's lines. */
export function endNav() {
    journeyEnd(); // reads `nav` before it clears — the dropoff names the arc
    drive?.stop();
    drive = null;
    stopWatch?.();
    stopWatch = null;
    follow?.stop();
    follow = null;
    closing = true;
    jsheet?.close();
    jsheet = null;
    closing = false;
    void wake?.release();
    wake = null;
    nav = null;
    document.getElementById(MAP_EL())?.classList.remove("navigating");
    d3.select("#navcard").style("display", "none");
    d3.select("#gochip").classed("on", false);
    host.restage();
    clearLines(host.map());
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
        // over the map the ETA bar's ✕ is the way out; the banner is read, not pressed
        if (document.getElementById("navcard")?.classList.contains("overmap"))
            return;
        const t = e.target;
        if (t.classList.contains("mode") && nav) { // cycle 🚌→🚶→🚲→🚗
            const ms = ROUTE_MODES;
            travelBy(ms[(ms.indexOf(navProfile) + 1) % ms.length]);
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
