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

import type { LatLng, Point } from '../geom.js';

/** Valhalla's costing names — the keys the UI's mode tabs ride on. */
export type Costing = "multimodal" | "pedestrian" | "bicycle" | "auto";

/** A way of travelling: the engine's name for it, and what it is called and drawn as. */
export interface ModeInfo { costing: Costing; label: string; icon: string }

/**
 * THE table of modes, in the order a preview shows its tabs (transit first, as the
 * phone's do) and the wayfinder's mode glyph cycles. The preview, the wayfinder and
 * the REPL page all read their words and glyphs from here.
 */
export const MODES: readonly ModeInfo[] = [
  { costing: "multimodal", label: "Transit", icon: "🚌" },
  { costing: "pedestrian", label: "Walk",    icon: "🚶" },
  { costing: "bicycle",    label: "Bicycle", icon: "🚲" },
  { costing: "auto",       label: "Drive",   icon: "🚗" },
];

export const ROUTE_MODES: Costing[] = MODES.map(m => m.costing);

/** What a mode is called and drawn as; undefined for a costing the UI has no tab for. */
export const modeInfo = (costing: string): ModeInfo | undefined => MODES.find(m => m.costing === costing);

/** The mode that travels each way a stretch can go: the engine's `travel_mode` → our costing. */
const COSTING_OF_TRAVEL: Record<string, Costing> = { pedestrian: "pedestrian", bicycle: "bicycle", drive: "auto", transit: "multimodal" };

/** The glyph for how a stretch is travelled — the engine's `travel_mode` — "" for one we have none for. */
export const travelIcon = (travelMode: string): string => modeInfo(COSTING_OF_TRAVEL[travelMode] ?? "")?.icon ?? "";

/**
 * UI words → Valhalla costing — the one vocabulary boundary, where the words are
 * born; the wire and the server speak costing names natively. A name already a
 * costing passes through, and no word at all is a walk.
 */
export function costingOf(word?: string | null): string {
  return ({ foot: "pedestrian", bike: "bicycle", car: "auto", scooter: "motor_scooter",
            transit: "multimodal", bus: "bus" } as Record<string, string>)[word || ""] || word || "pedestrian";
}

/** One stop on a transit maneuver. Times are the engine's local ISO minutes. */
export interface TransitStop {
  name: string;
  arrives: string;
  departs: string;
}

/** The line a transit maneuver rides. Colours are "#rrggbb", "" when unknown. */
export interface TransitInfo {
  /** Short name — "N", "48". */
  line: string;
  /** Long name — "Broadway Express". */
  name: string;
  headsign: string;
  color: string;
  textColor: string;
  operator: string;
  stops: TransitStop[];
}

/** One instruction along the way, and where on the shape it begins and ends. */
export interface Maneuver {
  /** Valhalla's maneuver type — the glyph table's key. */
  type: number;
  instr: string;
  begin: number;
  end: number;
  /** The street names consistent along the maneuver; [] when it has none. */
  streets: string[];
  /** Distance along this maneuver, in the route's units. */
  length: number;
  /** Seconds along this maneuver. */
  time: number;
  /** The three spoken forms: the alert ahead, the cue at the turn, the cue after. */
  verbal: { alert: string; pre: string; post: string };
  /** The spoke to leave a roundabout by; 0 when this is not one. */
  roundaboutExit: number;
  /** What the stretch passes through: a toll, a gate, rough pavement, a ferry. */
  toll: boolean;
  gate: boolean;
  rough: boolean;
  ferry: boolean;
  /** "drive" · "pedestrian" · "bicycle" · "transit", or "" when the engine did not say. */
  mode: string;
  transit: TransitInfo | null;
}

/** A route, flattened across its legs into one shape and one instruction list. */
export interface Route {
  coords: Point[];
  mans: Maneuver[];
  /** Total distance, in `units`. */
  km: number;
  /** Total time, seconds. */
  s: number;
  units: "kilometers" | "miles";
  hasToll: boolean;
  hasFerry: boolean;
  /** Which side of the street the destination is on, from the way in: "left", "right", or "" when not said. */
  destSide: "left" | "right" | "";
  /** The costing this route was asked for. */
  costing: string;
}

/** Valhalla's polyline, precision 6. */
export function decodePoly(str: string): Point[] {
  const out: Point[] = [];
  let i = 0, lat = 0, lng = 0;
  const val = (): number => {
    let s = 0, r = 0, b: number;
    do { b = str.charCodeAt(i++) - 63; r |= (b & 0x1f) << s; s += 5; } while (b >= 0x20);
    return (r & 1) ? ~(r >> 1) : (r >> 1);
  };
  while (i < str.length) { lat += val(); lng += val(); out.push([lng / 1e6, lat / 1e6]); }
  return out;
}

// ── reading a reply ─────────────────────────────────────────────────────────

interface RawStop { name?: string; arrival_date_time?: string; departure_date_time?: string }
interface RawTransit {
  short_name?: string; long_name?: string; headsign?: string;
  color?: number; text_color?: number; operator_name?: string;
  transit_stops?: RawStop[];
}
interface RawManeuver {
  type?: number; instruction?: string;
  begin_shape_index?: number; end_shape_index?: number;
  street_names?: string[]; length?: number; time?: number;
  verbal_transition_alert_instruction?: string;
  verbal_pre_transition_instruction?: string;
  verbal_post_transition_instruction?: string;
  roundabout_exit_count?: number; travel_mode?: string;
  toll?: boolean; gate?: boolean; rough?: boolean; ferry?: boolean;
  transit_info?: RawTransit;
}
interface RawLeg { shape?: string; maneuvers?: RawManeuver[] }
interface RawTrip {
  legs?: RawLeg[];
  locations?: { side_of_street?: string }[];
  summary?: { length?: number; time?: number; has_toll?: boolean; has_ferry?: boolean };
  units?: string;
}
interface TripReply { trip?: RawTrip; alternates?: { trip?: RawTrip }[] }

/** Valhalla's numeric colour (0xRRGGBB as a number) as "#rrggbb". */
const colorHex = (n: number | undefined): string =>
  typeof n === "number" && n >= 0 ? "#" + n.toString(16).padStart(6, "0") : "";

function readTransit(t: RawTransit | undefined): TransitInfo | null {
  if (!t) return null;
  return {
    line: t.short_name || "", name: t.long_name || "", headsign: t.headsign || "",
    color: colorHex(t.color), textColor: colorHex(t.text_color),
    operator: t.operator_name || "",
    stops: (t.transit_stops || []).map(s => ({
      name: s.name || "", arrives: s.arrival_date_time || "", departs: s.departure_date_time || "" })),
  };
}

/** The side of the street the last location is on. */
function sideOf(locs: RawTrip["locations"]): "left" | "right" | "" {
  const s = locs && locs.length ? locs[locs.length - 1].side_of_street : "";
  return s === "left" || s === "right" ? s : "";
}

/** One trip, or null for anything that is not a route: no legs, or no summary. */
function readTrip(trip: RawTrip | undefined, costing: string): Route | null {
  const legs = trip?.legs || [];
  if (!legs.length || !trip?.summary) return null;
  let coords: Point[] = [];
  const mans: Maneuver[] = [];
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
    coords = coords.concat(pts); base += pts.length;
  }
  return { coords, mans, km: trip.summary.length || 0, s: trip.summary.time || 0,
           units: trip.units === "miles" ? "miles" : "kilometers",
           hasToll: !!trip.summary.has_toll, hasFerry: !!trip.summary.has_ferry,
           destSide: sideOf(trip.locations), costing };
}

/** A whole reply: the engine's chosen way first, then each alternate. [] when it answered nothing. */
export function readRoutes(js: unknown, costing: string): Route[] {
  const r = (js || {}) as TripReply;
  return [readTrip(r.trip, costing), ...(r.alternates || []).map(a => readTrip(a.trip, costing))]
    .filter((x): x is Route => x !== null);
}

// ── asking ──────────────────────────────────────────────────────────────────

/** What a request may add to the two ends and a costing. */
export interface RouteOpts {
  /** Extra ways to offer, 0–3; the engine offers fewer, or none, for waypoint and timed routes. */
  alternates?: number;
  /** "now", or a local ISO minute, "YYYY-MM-DDThh:mm" — leave then. */
  depart?: string;
  /** A local ISO minute — be there by then. */
  arrive?: string;
  /** A language tag for the instructions: "en-US". */
  lang?: string;
  units?: "kilometers" | "miles";
  /** Waypoints, in order, between the ends. */
  via?: LatLng[];
}

const ll = (p: LatLng): string => `${p.lat},${p.lng}`;

/**
 * The /route query for a request. Transit is a timetable: a multimodal ask with
 * no clock leaves now, so the tab shows the next departure, not nothing.
 */
export function routeQuery(from: LatLng, to: LatLng, costing: string, o: RouteOpts = {}): string {
  const q = new URLSearchParams({ from: ll(from), to: ll(to), profile: costing });
  if (o.via && o.via.length) q.set("via", o.via.map(ll).join(";"));
  if (o.alternates) q.set("alternates", String(o.alternates));
  const depart = o.depart || (costing === "multimodal" && !o.arrive ? "now" : "");
  if (depart) q.set("depart", depart);
  if (o.arrive) q.set("arrive", o.arrive);
  if (o.lang) q.set("lang", o.lang);
  if (o.units === "miles") q.set("units", "mi");
  return q.toString();
}

// A route answered a moment ago is the route now: a preview's four tabs, and a
// sheet closed and opened again, share one ask. Nothing outlives two minutes —
// a timetable and the road both move — and an empty answer is never kept, so
// an engine that comes up mid-session is found on the next ask.
const TTL_MS = 120_000;
const CACHE_MAX = 32;
const cache = new Map<string, { at: number; p: Promise<Route[]> }>();

export const clearRouteCache = (): void => cache.clear();

/**
 * Routes from `from` to `to` by `costing`: the engine's chosen way, then its
 * alternates. [] for anything it cannot answer — a down engine, a place beyond
 * its atlas, a mode with no network there.
 */
export function fetchRoutes(from: LatLng, to: LatLng, costing: string, o: RouteOpts = {}): Promise<Route[]> {
  const q = routeQuery(from, to, costing, o);
  const now = Date.now();
  const hit = cache.get(q);
  if (hit && now - hit.at < TTL_MS) return hit.p;
  const p = (async (): Promise<Route[]> => {
    try { return readRoutes(await (await fetch(`/route?${q}`)).json(), costing); }
    catch (_) { return []; }
  })();
  cache.set(q, { at: now, p });
  if (cache.size > CACHE_MAX) cache.delete(cache.keys().next().value as string);
  p.then(rs => { if (!rs.length && cache.get(q)?.p === p) cache.delete(q); });
  return p;
}

/** One ask per mode, all at once: each key holds that mode's routes ([] when it has none). */
export async function fetchModes(from: LatLng, to: LatLng, modes: readonly string[] = ROUTE_MODES,
                                 o: RouteOpts = {}): Promise<Record<string, Route[]>> {
  const rs = await Promise.all(modes.map(m => fetchRoutes(from, to, m, o)));
  return Object.fromEntries(modes.map((m, i) => [m, rs[i]]));
}
