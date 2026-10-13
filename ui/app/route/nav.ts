// app/route/nav.ts — the commons' own wayfinder.
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

import { USER, PLACES, pcoord, HANDLERS, EXT } from '../core.js';
import { locationOptions } from '../slots/model.js';
import { havKm, bearingDeg, ARROW8 } from '../geom.js';
import { onMapFace } from '../stage.js';
import { deviceHeading } from '../compass.js';
import { MAP_EL } from '../mapview.js';
import { clockOf } from '../timefmt.js';
import type { LatLng } from '../geom.js';
import { gateHint } from '../day/respond.js';
import { fetchRoutes, ROUTE_MODES, modeInfo } from './data.js';
import { fmtDistance } from './facts.js';
import { paintLines, clearLines } from './lines.js';
import { watchFixes } from '../position.js';
import type { Route } from './data.js';

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

// ── the vocabulary of a journey ─────────────────────────────────────────────

/** Valhalla maneuver type → the glyph the card shows for it. */
const NAV_GLYPH: Record<number, string> = {
  1:"↑",2:"↗",3:"↖",4:"🏁",5:"🏁",6:"🏁",8:"↑",9:"↗",10:"→",
  11:"↘",12:"⤸",13:"⤹",14:"↙",15:"←",16:"↖",17:"↑",18:"↗",19:"↖",20:"↗",
  21:"↖",22:"↑",23:"↗",24:"↖",25:"⇡",26:"⟳",27:"⤴",28:"⛴",29:"⛴",
  // transit: board, transfer, stay aboard, and the walks to and from the stops
  30:"🚌",31:"⇄",32:"🚌",33:"🚶",34:"🚶",35:"🚶",36:"🚶",37:"↗",38:"↖" };

const navClock = clockOf;   // an arrival time is a wall clock, in your own zone

/**
 * A journey in progress. `route` is null for the compass degradation — a
 * destination the router could not reach still has a bearing and a distance.
 */
interface Journey {
  dest: LatLng;
  placeName: string;
  route: Route | null;
  /** How far along the shape you are, as an index into route.coords. */
  at: number;
}

/** Ask the local engine for a way there. Null for anything it cannot answer. */
async function fetchRoute(from: LatLng, to: LatLng, costing: string): Promise<Route | null> {
  return (await fetchRoutes(from, to, costing))[0] || null;
}

// ── the module's own state ──────────────────────────────────────────────────
// One journey at a time, by design: a wayfinder that offers two ways at once is
// not answering the question it was asked.

let host: NavHost;
let nav: Journey | null = null;
/** Ends the position watch the journey holds, while one is held. */
let stopWatch: (() => void) | null = null;
let navProfile = "pedestrian";
/** Where the card lives when it is not floating: its original parent. */
let navHome: HTMLElement | null = null;

/** Whether a journey is under way — the ↦ go chip's two meanings. */
export const navigating = (): boolean => nav !== null;

/** Draw the journey: its way with what is behind you dimmed, or — with no way — a bearing thread. */
function drawNavLine(): void {
  const map = host.map();
  if (!map || !nav) return;
  paintLines(map, nav.route
    ? { ways: [nav.route], pick: 0, at: nav.at }
    : { bearing: [[USER.lng, USER.lat], [nav.dest.lng, nav.dest.lat]] });
}

/** The nearest route vertex, scanning forward from where you last were. */
function navIdxNear(j: Journey, r: Route): number {
  const c = r.coords;
  let best = j.at, bd = Infinity;
  for (let i = Math.max(0, j.at - 5); i < c.length; i++) {
    const d = havKm(USER, { lat: c[i][1], lng: c[i][0] });
    if (d < bd) { bd = d; best = i; }
    if (i > j.at + 80 && d > bd + 0.15) break;   // left the neighbourhood
  }
  return best;
}

function updateNavCard(): void {
  if (!nav) return;
  const card = d3.select("#navcard");
  card.select(".mode").text(modeInfo(navProfile)?.icon ?? "");
  if (!nav.route) {                   // the compass degradation
    const b = bearingDeg(USER, nav.dest), km = havKm(USER, nav.dest);
    card.select(".glyph").text(ARROW8[Math.round(((b - deviceHeading() + 360) % 360) / 45) % 8]);
    card.select(".instr").text(nav.placeName);
    card.select(".meta").text(`${fmtDistance(km)} as the crow flies · no route data`);
    return;
  }
  const r = nav.route;
  nav.at = navIdxNear(nav, r);
  const nxt = r.mans.find(m => m.begin > nav!.at);
  const remS = r.s * (1 - nav.at / Math.max(1, r.coords.length - 1));
  if (!nxt || havKm(USER, nav.dest) < 0.03) {       // the last stretch
    card.select(".glyph").text("🏁");
    card.select(".instr").text(nav.placeName);
    card.select(".meta").text(`${fmtDistance(havKm(USER, nav.dest))} left`);
  } else {
    const at = r.coords[nxt.begin];
    card.select(".glyph").text(NAV_GLYPH[nxt.type] || "↑");
    card.select(".instr").text(nxt.instr);
    card.select(".meta").text(`${fmtDistance(havKm(USER, { lat: at[1], lng: at[0] }))} · ` +
      `${Math.max(1, Math.round(remS / 60))} min · arrive ${navClock(new Date(Date.now() + remS * 1000))}`);
  }
}

/** A fix: you have moved (app/position.ts moved USER and the you-marker), and so does what follows you. */
function onFix(): void {
  if (!nav) return;
  updateNavCard();
  drawNavLine();                      // the way's dimmed part, or the straight thread, follows you
}

/**
 * The turn-by-turn card follows the face: the sidebar for the disc (its home),
 * floated over the map on the map face, whose sidebar stands aside.
 */
function placeNavCard(): void {
  const nc = document.getElementById("navcard");
  if (!nc) return;
  if (!navHome) navHome = nc.parentElement;
  // The card floats over the map on the MAP face and returns to the sidebar
  // everywhere else — the map face's sidebar stands aside.
  if (onMapFace()) {
    const wrap = document.getElementById(MAP_EL());
    if (wrap && nc.parentElement !== wrap) wrap.appendChild(nc);
    nc.classList.add("overmap");
  } else if (navHome && nc.parentElement !== navHome) {
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
let journeyCid: string | null = null;

const geoRef = (p: LatLng): string => `geo:${p.lat.toFixed(5)},${p.lng.toFixed(5)}`;
const placeRef = (name: string, at: LatLng): string => {
  const l = locationOptions(EXT).find(x => x.name === name);
  return l ? l.id : geoRef(at);
};

function journeyBegin(dest: LatLng, placeName: string): void {
  if (!HANDLERS.journey) return;
  HANDLERS.journey("begin", geoRef(USER), placeRef(placeName, dest), navProfile, "")
    .then((r: string) => {
      if (r && r.startsWith("ok:") && r.length > 3) journeyCid = r.slice(3);
      else gateHint(r);   // a provisional member is told where to go, once, the same way everywhere
    });
}

function journeyEnd(): void {
  if (!(journeyCid && HANDLERS.journey && nav)) { journeyCid = null; return; }
  HANDLERS.journey("end", geoRef(USER), placeRef(nav.placeName, nav.dest),
                   navProfile, journeyCid).then(() => {});
  journeyCid = null;
}

/** A way already chosen in the preview: the journey takes it as it is and asks the engine nothing. */
export interface ChosenWay { route: Route | null; costing: string }

export async function startNavTo(dest: LatLng, placeName: string, chosen?: ChosenWay): Promise<void> {
  const map = host.map();
  if (!map) return;
  endNav();
  if (chosen) navProfile = chosen.costing;
  placeNavCard();
  journeyBegin(dest, placeName);
  const route = chosen ? chosen.route : await fetchRoute(USER, dest, navProfile);
  nav = { dest, placeName, route, at: 0 };
  drawNavLine();
  d3.select("#gochip").classed("on", true);
  d3.select("#navcard").style("display", "block");
  host.restage();
  updateNavCard();
  if (route) {                        // frame the whole way, then walk it
    const b = route.coords.reduce((a, c) => [Math.min(a[0], c[0]), Math.min(a[1], c[1]),
                                             Math.max(a[2], c[0]), Math.max(a[3], c[1])],
                                  [180, 90, -180, -90]);
    map.fitBounds([[b[0], b[1]], [b[2], b[3]]], { padding: host.mapRpx() * 0.22, duration: 700 });
  }
  if (!stopWatch) stopWatch = watchFixes(onFix, { highAccuracy: true });
}

/** The ways to the selected place, when one is selected and a map is up. */
function startNav(): void {
  const sel = host.selectedPlace();
  if (!sel || !host.map()) return;
  host.directions(sel.at, sel.name);
}

/** End the journey: the watch, the card, the chip and the two map layers. */
export function endNav(): void {
  journeyEnd();   // reads `nav` before it clears — the dropoff names the arc
  stopWatch?.(); stopWatch = null; nav = null;
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
export function initNav(h: NavHost): void {
  host = h;
  d3.select("#gochip").on("click", () => { nav ? endNav() : startNav(); });
  d3.select("#navcard").on<MouseEvent>("click", e => {
    const t = e.target as HTMLElement;
    if (t.classList.contains("mode") && nav) {   // cycle 🚶→🚲→🚗
      const ms: string[] = ROUTE_MODES;
      navProfile = ms[(ms.indexOf(navProfile) + 1) % ms.length];
      // the journey's own destination, not the selected place: a journey begun
      // from the search panel has no selected place to route to
      const { dest, placeName } = nav;
      startNavTo(dest, placeName);
    } else endNav();
  });
}

/** The place a places-list index names, in the shape NavHost.selectedPlace wants. */
export function placeAt(leafId: string, i: number): { at: LatLng; name: string } | null {
  const p = (PLACES[leafId] || [])[i];
  return p ? { at: pcoord(p), name: p.name } : null;
}
