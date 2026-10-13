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
//   reroute.ts  when you have left the way
//   ledger.ts   the journey as a fact of the commons' ledger
//   drive-sim   a rehearsed drive in place of the device (`?simdrive=<factor>`)
//
// Everything a journey takes up it registers in `held`, and ending it undoes them in reverse — so what
// setting out acquires and what ending releases cannot drift apart.
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
import { USER, PLACES, pcoord } from '../core.js';
import { havKm, bearingDeg } from '../geom.js';
import { onMapFace } from '../stage.js';
import { deviceHeading, compassLive } from '../compass.js';
import { sheetHeight } from '../tabs/social/share.js';
import { watchFixes } from '../position.js';
import { keepAwake } from '../awake.js';
import { fetchRoutes, ROUTE_MODES, modeInfo } from './data.js';
import { fmtDistance, fmtMinutes, arrivalClock } from './facts.js';
import { snapToRoute, progress, courseAt, boundsOf, remainingOf } from './shape.js';
import { paintLines, clearLines } from './lines.js';
import { routeBanner, bearingBanner, reroutingBanner, drawBanner, placeCard, showCard, cardHeight, onCardTap } from './banner.js';
import { offRouteWatch } from './reroute.js';
import { openJourneySheet } from './sheet.js';
import { stepRows } from './steps.js';
import { startFollow } from './follow.js';
import { rehearsal } from './drive-sim.js';
import { beginJourney } from './ledger.js';
import { gateHint } from '../day/respond.js';
/** Within this many kilometres of the end of the way, you have arrived. */
const ARRIVED_KM = 0.03;
/** Where you are on a way just taken up: its start. */
const START = { at: 0, t: 0, offKm: 0 };
// ── the module's own state ──────────────────────────────────────────────────
// One journey at a time, by design: a wayfinder that offers two ways at once is
// not answering the question it was asked.
let host;
let nav = null;
/** Counts the journeys begun, so one that was asked for and then superseded is let go when its way arrives. */
let begun = 0;
/** Whether a journey is under way — the ↦ go chip's two meanings. */
export const navigating = () => nav !== null;
/** Whether the camera is held on you — the compass leaves the map's bearing to it. */
export const cameraHeld = () => nav?.follow != null && nav.follow.following();
/** Follow `route` from here: the way the journey reads from now on — a way just chosen, or a new one after a reroute. */
function setWay(j, route) {
    j.route = route;
    j.snap = START;
    j.arrived = false;
}
// ── reading a fix ───────────────────────────────────────────────────────────
/**
 * Where a fix puts you on the way: the snap, whether you have arrived, whether you have left it. Leaving it — for several
 * fixes, beyond the fix's own doubt, and not on a vehicle — asks for a new way.
 */
function track(j, r, fix) {
    j.snap = snapToRoute(r, USER, j.snap.at);
    const p = progress(r, j.snap);
    if (!j.arrived && (havKm(USER, j.dest) < ARRIVED_KM || p.aheadKm < ARRIVED_KM)) {
        j.arrived = true;
        j.follow?.stop();
        j.follow = null; // the camera is given back at the door
    }
    const riding = p.cur >= 0 && r.mans[p.cur].mode === "transit";
    if (fix && !j.arrived && !j.rerouting && j.offRoute.see(j.snap.offKm, fix.accuracy, fix.t, riding))
        void reroute(j);
    return p;
}
/** Say where you are: the card, the sheet, the line, the camera. */
function show(j, p, r, fix) {
    const mode = modeInfo(j.costing)?.icon ?? "";
    const arrive = arrivalClock(p.remS);
    drawBanner(j.rerouting ? reroutingBanner() : routeBanner(r, p, { place: j.placeName, arrive, arrived: j.arrived }), mode);
    const steps = stepRows(r, p, j.placeName);
    j.sheet?.update(j.arrived
        ? { big: "You have arrived", sub: j.placeName, arrived: true, steps, mode: j.costing }
        : { big: fmtMinutes(p.remS), sub: `${fmtDistance(p.remKm, r.units)} · ${arrive}`, arrived: false, steps, mode: j.costing });
    drawLine(j);
    j.follow?.onFix(fix ?? { lat: USER.lat, lng: USER.lng, heading: null, speed: null, accuracy: null, t: Date.now() }, courseAt(r, j.snap));
}
/** Draw the journey: its way with what is behind you dimmed, or — with no way — a bearing thread. */
function drawLine(j) {
    const map = host.map();
    if (!map)
        return;
    paintLines(map, j.route
        ? { ways: [j.route], pick: 0, at: j.snap.at + j.snap.t }
        : { bearing: [[USER.lng, USER.lat], [j.dest.lng, j.dest.lat]] });
}
/** A fix, or a change of state: read where you are and say it. */
function refresh(fix) {
    const j = nav;
    if (!j)
        return;
    const r = j.route;
    if (!r) { // the compass degradation
        const km = havKm(USER, j.dest);
        drawBanner(bearingBanner({ bearing: bearingDeg(USER, j.dest), heading: deviceHeading(), km, place: j.placeName }), modeInfo(j.costing)?.icon ?? "");
        j.sheet?.update({ big: fmtDistance(km), sub: "as the crow flies · no route data", arrived: false, steps: [], mode: j.costing });
        drawLine(j);
        return;
    }
    show(j, track(j, r, fix), r, fix);
}
/**
 * You have left the way: ask for a new one from where you are. The journey goes on — the same ledger journey, the same
 * camera, the same sheet — only its way changes. An engine that answers nothing leaves the old way, and the watcher's
 * pause keeps the next ask from coming at once.
 */
async function reroute(j) {
    if (!j.route || j.rerouting)
        return;
    j.rerouting = true;
    j.offRoute.asked(Date.now());
    refresh();
    const [way] = await fetchRoutes({ lat: USER.lat, lng: USER.lng }, j.dest, j.costing);
    j.rerouting = false;
    if (nav !== j)
        return; // the journey ended, or another began, while we asked
    if (way) {
        setWay(j, way);
        j.offRoute.reset();
    }
    refresh();
}
export async function startNavTo(dest, placeName, chosen) {
    const map = host.map();
    if (!map)
        return;
    endNav();
    const mine = ++begun;
    const route = chosen.route !== undefined ? chosen.route : (await fetchRoutes(USER, dest, chosen.costing))[0] || null;
    if (mine !== begun)
        return; // another journey was asked for while this one's way was found
    const el = map.getContainer();
    const j = {
        dest, placeName, costing: chosen.costing, route: null, snap: START, arrived: false, rerouting: false,
        offRoute: offRouteWatch(), sheet: null, follow: null, held: [],
        // a provisional member the ledger refuses is told where to go, once, the same way everywhere
        ledger: beginJourney(USER, dest, placeName, chosen.costing, gateHint),
    };
    nav = j;
    setWay(j, route);
    const hold = (undo) => { j.held.push(undo); };
    // registered in the order they are undone backwards: the card goes, then the chip, then the stage is re-measured, then the lines
    hold(() => clearLines(host.map()));
    hold(() => host.restage());
    d3.select("#gochip").classed("on", true);
    hold(() => d3.select("#gochip").classed("on", false));
    placeCard(onMapFace() ? el : null);
    showCard(true);
    hold(() => showCard(false));
    host.restage(); // the card reshapes the stage going up, and (above) again coming down
    if (onMapFace()) {
        el.classList.add("navigating");
        hold(() => el.classList.remove("navigating"));
        j.sheet = openJourneySheet({
            exit: () => endNav(), done: () => endNav(),
            gone: () => { if (nav === j)
                endNav(); }, // the sheet left by some other road
            overview: () => j.follow?.overview(), travelBy, bannerHeight: cardHeight,
        });
        hold(() => j.sheet?.close());
        if (route) {
            j.follow = startFollow({
                map: () => host.map(), sheetHeight, bannerHeight: cardHeight,
                deviceHeading: () => compassLive() ? deviceHeading() : null,
                remaining: () => j.route ? remainingOf(j.route, j.snap) : null,
            }, j.costing, el);
            hold(() => j.follow?.stop());
        }
        hold(keepAwake());
    }
    else { // on the disc: frame the whole way, then walk it
        const b = route && boundsOf([route]);
        if (b)
            map.fitBounds(b, { padding: host.mapRpx() * 0.22, duration: 700 });
    }
    hold(watchFixes(refresh, { highAccuracy: true }));
    const drive = route && rehearsal(route);
    if (drive)
        hold(drive.stop);
    refresh();
}
/** Travel the rest of the way by another mode: the journey's own destination, routed again. */
export function travelBy(costing) {
    if (nav)
        void startNavTo(nav.dest, nav.placeName, { costing });
}
/** The ways to the selected place, when one is selected and a map is up. */
function startNav() {
    const sel = host.selectedPlace();
    if (!sel || !host.map())
        return;
    host.directions(sel.at, sel.name);
}
/** End the journey: its record in the ledger, then everything it took up, last first. */
export function endNav() {
    const j = nav;
    if (!j)
        return;
    nav = null; // before anything is undone: a sheet that leaves is no cue to end it again
    j.ledger.end(USER);
    for (const undo of j.held.reverse())
        undo();
}
/**
 * Wire the chip and the card. Called once at boot with the dial's arrangement;
 * everything above reads the host at call time, so the dial may rebuild its map
 * as often as it likes.
 */
export function initNav(h) {
    host = h;
    d3.select("#gochip").on("click", () => { nav ? endNav() : startNav(); });
    onCardTap((target, overMap) => {
        if (overMap)
            return; // over the map the sheet's ✕ is the way out; the banner is read, not pressed
        if (target.classList.contains("mode") && nav) { // cycle 🚌→🚶→🚲→🚗
            const ms = ROUTE_MODES;
            travelBy(ms[(ms.indexOf(nav.costing) + 1) % ms.length]);
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
