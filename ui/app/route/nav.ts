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
import type { LatLng } from '../geom.js';
import { sheetHeight } from '../tabs/social/share.js';
import { watchFixes, youAt } from '../position.js';
import type { Fix } from '../position.js';
import { keepAwake } from '../awake.js';
import { fetchRoutes } from './data.js';
import { ROUTE_MODES, modeInfo } from './modes.js';
import type { Route } from './data.js';
import { fmtDistance, fmtMinutes, arrivalClock } from './facts.js';
import { snapToRoute, progress, courseAt, boundsOf, remainingOf } from './shape.js';
import type { Snap, Progress } from './shape.js';
import { paintLines, clearLines } from './lines.js';
import { routeBanner, bearingBanner, reroutingBanner, drawBanner, placeCard, showCard, cardHeight, onCardTap } from './banner.js';
import { offRouteWatch } from './reroute.js';
import type { OffRoute } from './reroute.js';
import { openJourneySheet } from './sheet.js';
import type { JourneySheet } from './sheet.js';
import { stepRows } from './steps.js';
import { startFollow } from './follow.js';
import type { Follow } from './follow.js';
import { rehearsal } from './drive-sim.js';
import { beginJourney } from './ledger.js';
import { gateHint } from '../day/respond.js';
import type { Ledger } from './ledger.js';

/** What routing needs to know about the dial's current arrangement. */
export interface NavHost {
  /** The map to draw the route on — null before one is built. */
  map(): maplibregl.Map | null;
  /** The map disc's radius in pixels; the route's fit padding is a share of it. */
  mapRpx(): number;
  /**
   * The card lives in flow under the dial, so showing or hiding it reshapes the
   * stage and the map disc must be re-measured to stay welded to the dial.
   */
  restage(): void;
  /** The place the ↦ go chip targets: the selected one, or null. */
  selectedPlace(): { at: LatLng; name: string } | null;
  /** Show the ways to a place — the route preview, which ends in startNavTo when a way is chosen. */
  directions(dest: LatLng, name: string): void;
}

/** Within this many kilometres of the end of the way, you have arrived. */
const ARRIVED_KM = 0.03;

/** Where you are on a way just taken up: its start. */
const START: Snap = { at: 0, t: 0, offKm: 0 };

/**
 * A journey in progress. `route` is null for the compass degradation — a destination the router could not reach still
 * has a bearing and a distance.
 */
interface Journey {
  dest: LatLng;
  placeName: string;
  /** How it is travelled: a Valhalla costing. */
  costing: string;
  route: Route | null;
  /** Where you are on the route: between vertex `at` and the next, `t` of the way. */
  snap: Snap;
  /** Latched once you are within reach of the end. */
  arrived: boolean;
  /** Whether a new way is being asked for. */
  rerouting: boolean;
  offRoute: OffRoute;
  ledger: Ledger;
  /** What the journey holds on the map face. */
  sheet: JourneySheet | null;
  follow: Follow | null;
  /** What it took up, undone in reverse when it ends. */
  held: (() => void)[];
}

// ── the module's own state ──────────────────────────────────────────────────
// One journey at a time, by design: a wayfinder that offers two ways at once is
// not answering the question it was asked.

let host: NavHost;
let nav: Journey | null = null;
/** Counts the journeys begun, so one that was asked for and then superseded is let go when its way arrives. */
let begun = 0;

/** Whether a journey is under way — the ↦ go chip's two meanings. */
export const navigating = (): boolean => nav !== null;

/** Whether the camera is held on you — the compass leaves the map's bearing to it. */
export const cameraHeld = (): boolean => nav?.follow != null && nav.follow.following();

/** Follow `route` from here: the way the journey reads from now on — a way just chosen, or a new one after a reroute. */
function setWay(j: Journey, route: Route | null): void {
  j.route = route;
  j.snap = START;
  j.arrived = false;
}

// ── reading a fix ───────────────────────────────────────────────────────────

/**
 * Where a fix puts you on the way: the snap, whether you have arrived, whether you have left it. Leaving it — for several
 * fixes, beyond the fix's own doubt, and not on a vehicle — asks for a new way.
 */
function track(j: Journey, r: Route, fix: Fix | undefined): Progress {
  j.snap = snapToRoute(r, USER, j.snap.at);
  const p = progress(r, j.snap);
  if (!j.arrived && (havKm(USER, j.dest) < ARRIVED_KM || p.aheadKm < ARRIVED_KM)) {
    j.arrived = true;
    j.follow?.stop(); j.follow = null;                // the camera is given back at the door
  }
  const riding = p.cur >= 0 && r.mans[p.cur].mode === "transit";
  if (fix && !j.arrived && !j.rerouting && j.offRoute.see(j.snap.offKm, fix.accuracy, fix.t, riding)) void reroute(j);
  return p;
}

/** Say where you are: the card, the sheet, the line, the camera. */
function show(j: Journey, p: Progress, r: Route, fix: Fix | undefined): void {
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
function drawLine(j: Journey): void {
  const map = host.map();
  if (!map) return;
  paintLines(map, j.route
    ? { ways: [j.route], pick: 0, at: j.snap.at + j.snap.t }
    : { bearing: [[USER.lng, USER.lat], [j.dest.lng, j.dest.lat]] });
}

/** A fix, or a change of state: read where you are and say it. */
function refresh(fix?: Fix): void {
  const j = nav; if (!j) return;
  const r = j.route;
  if (!r) {                                          // the compass degradation
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
async function reroute(j: Journey): Promise<void> {
  if (!j.route || j.rerouting) return;
  j.rerouting = true; j.offRoute.asked(Date.now());
  refresh();
  const [way] = await fetchRoutes(youAt(), j.dest, j.costing);
  j.rerouting = false;
  if (nav !== j) return;                      // the journey ended, or another began, while we asked
  if (way) { setWay(j, way); j.offRoute.reset(); }
  refresh();
}

// ── setting out, and ending ─────────────────────────────────────────────────

/** A way already chosen in the preview, and how it is travelled. No `route` asks the engine; `null` is the compass. */
export interface ChosenWay { costing: string; route?: Route | null }

export async function startNavTo(dest: LatLng, placeName: string, chosen: ChosenWay): Promise<void> {
  const map = host.map();
  if (!map) return;
  endNav();
  const mine = ++begun;
  const route = chosen.route !== undefined ? chosen.route : (await fetchRoutes(USER, dest, chosen.costing))[0] || null;
  if (mine !== begun) return;                 // another journey was asked for while this one's way was found
  const el = map.getContainer();
  const j: Journey = {
    dest, placeName, costing: chosen.costing, route: null, snap: START, arrived: false, rerouting: false,
    offRoute: offRouteWatch(), sheet: null, follow: null, held: [],
    // a provisional member the ledger refuses is told where to go, once, the same way everywhere
    ledger: beginJourney(USER, dest, placeName, chosen.costing, gateHint),
  };
  nav = j;
  setWay(j, route);
  const hold = (undo: () => void): void => { j.held.push(undo); };

  // registered in the order they are undone backwards: the card goes, then the chip, then the stage is re-measured, then the lines
  hold(() => clearLines(host.map()));
  hold(() => host.restage());
  d3.select("#gochip").classed("on", true); hold(() => d3.select("#gochip").classed("on", false));
  placeCard(onMapFace() ? el : null);
  showCard(true); hold(() => showCard(false));
  host.restage();                                       // the card reshapes the stage going up, and (above) again coming down

  if (onMapFace()) {
    el.classList.add("navigating"); hold(() => el.classList.remove("navigating"));
    j.sheet = openJourneySheet({
      exit: () => endNav(), done: () => endNav(),
      gone: () => { if (nav === j) endNav(); },         // the sheet left by some other road
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
  } else {                                              // on the disc: frame the whole way, then walk it
    const b = route && boundsOf([route]);
    if (b) map.fitBounds(b, { padding: host.mapRpx() * 0.22, duration: 700 });
  }

  hold(watchFixes(refresh, { highAccuracy: true }));
  const drive = route && rehearsal(route);
  if (drive) hold(drive.stop);
  refresh();
}

/** Travel the rest of the way by another mode: the journey's own destination, routed again. */
export function travelBy(costing: string): void {
  if (nav) void startNavTo(nav.dest, nav.placeName, { costing });
}

/** The ways to the selected place, when one is selected and a map is up. */
function startNav(): void {
  const sel = host.selectedPlace();
  if (!sel || !host.map()) return;
  host.directions(sel.at, sel.name);
}

/** End the journey: its record in the ledger, then everything it took up, last first. */
export function endNav(): void {
  const j = nav;
  if (!j) return;
  nav = null;                                           // before anything is undone: a sheet that leaves is no cue to end it again
  j.ledger.end(USER);
  for (const undo of j.held.reverse()) undo();
}

/**
 * Wire the chip and the card. Called once at boot with the dial's arrangement;
 * everything above reads the host at call time, so the dial may rebuild its map
 * as often as it likes.
 */
export function initNav(h: NavHost): void {
  host = h;
  d3.select("#gochip").on("click", () => { nav ? endNav() : startNav(); });
  onCardTap((target, overMap) => {
    if (overMap) return;                                // over the map the sheet's ✕ is the way out; the banner is read, not pressed
    if (target.classList.contains("mode") && nav) {     // cycle 🚌→🚶→🚲→🚗
      const ms: string[] = ROUTE_MODES;
      travelBy(ms[(ms.indexOf(nav.costing) + 1) % ms.length]);
    } else endNav();
  });
}

/** The place a places-list index names, in the shape NavHost.selectedPlace wants. */
export function placeAt(leafId: string, i: number): { at: LatLng; name: string } | null {
  const p = (PLACES[leafId] || [])[i];
  return p ? { at: pcoord(p), name: p.name } : null;
}
