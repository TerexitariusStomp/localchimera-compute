// tests/browser/route-fixture.mjs — Valhalla-shaped /route replies, synthesised.
//
// No engine runs in a test, so a reply is built here in the shape the vendored
// reference documents (docs/valhalla/api/turn-by-turn/api-reference.md): a
// `trip` of `legs`, each an encoded precision-6 `shape` and its `maneuvers`,
// a `summary`, and `alternates[].trip`. The way is a dog-leg — out along the
// meridian, then across — so it has a start, one turn and an arrival; transit
// is three legs (walk, ride, walk) with the ride carrying `transit_info`.
//
// Used by tests/browser/route-data-test.mjs (node) and the UX probes
// (tests/ux/route-stub.mjs answers the page's /route calls from it).

import { havKm } from '../../browser/app/geom.js';
export { havKm };

/** Valhalla's polyline, precision 6 — the inverse of app/route/data.ts decodePoly. */
export function encodePoly(coords) {
  let plat = 0, plng = 0, out = "";
  const enc = v => {
    v = v < 0 ? ~(v << 1) : v << 1;
    let s = "";
    while (v >= 0x20) { s += String.fromCharCode((0x20 | (v & 0x1f)) + 63); v >>= 5; }
    return s + String.fromCharCode(v + 63);
  };
  for (const [lng, lat] of coords) {
    const la = Math.round(lat * 1e6), lo = Math.round(lng * 1e6);
    out += enc(la - plat) + enc(lo - plng);
    plat = la; plng = lo;
  }
  return out;
}

// km/h by costing; the time of a leg is its length at that speed.
const SPEED = { pedestrian: 5, bicycle: 15, auto: 30, multimodal: 5 };
const TRAVEL = { pedestrian: "pedestrian", bicycle: "bicycle", auto: "drive", multimodal: "pedestrian" };
const sec = (km, kmh) => Math.round(km / kmh * 3600);

/** One leg along `pts` (≥ 3 points: depart, turn, arrive) at `kmh`, as a Valhalla leg. */
function leg(pts, kmh, mode, streets, final = true) {
  const A = { lat: pts[0][1], lng: pts[0][0] }, T = { lat: pts[1][1], lng: pts[1][0] },
        B = { lat: pts[2][1], lng: pts[2][0] };
  const d1 = havKm(A, T), d2 = havKm(T, B);
  return { shape: encodePoly(pts), maneuvers: [
    { type: 1, instruction: `Head north on ${streets[0]}.`, street_names: [streets[0]],
      length: d1, time: sec(d1, kmh), begin_shape_index: 0, end_shape_index: 1, travel_mode: mode,
      verbal_transition_alert_instruction: `Head north on ${streets[0]}.`,
      verbal_pre_transition_instruction: `Head north on ${streets[0]}.`,
      verbal_post_transition_instruction: `Continue for ${Math.round(d1 * 1000)} meters.` },
    { type: 10, instruction: `Turn right onto ${streets[1]}.`, street_names: [streets[1]],
      length: d2, time: sec(d2, kmh), begin_shape_index: 1, end_shape_index: 2, travel_mode: mode,
      verbal_transition_alert_instruction: `Turn right onto ${streets[1]}.`,
      verbal_pre_transition_instruction: `Turn right onto ${streets[1]}.`,
      verbal_post_transition_instruction: `Continue for ${Math.round(d2 * 1000)} meters.` },
    { type: final ? 4 : 1, instruction: final ? "You have arrived at your destination." : "Continue.",
      length: 0, time: 0, begin_shape_index: 2, end_shape_index: 2, travel_mode: mode },
  ] };
}

const trip = (legs, units = "kilometers") => {
  const ms = legs.flatMap(l => l.maneuvers);
  return { legs, units, language: "en-US", status: 0,
           summary: { length: ms.reduce((a, m) => a + m.length, 0), time: ms.reduce((a, m) => a + m.time, 0),
                      has_toll: false, has_ferry: false } };
};

/** The dog-leg corner for from→to; an alternate's corner lies out past the box, so its way is longer. */
const corner = (a, b, bend) => bend ? [b.lng + bend, a.lat - bend] : [a.lng, b.lat];

/**
 * The reply for a /route query. `q` is a URLSearchParams (or a query string).
 * `alternates=N` adds N more ways, each a little longer. A `profile` of
 * "nowhere" answers `{}` — the engine's refusal — as does a destination whose
 * latitude is above 80 (beyond any atlas).
 */
export function routeReply(q) {
  q = new URLSearchParams(q);
  const [fl, fg] = (q.get("from") || "").split(",").map(Number);
  const [tl, tg] = (q.get("to") || "").split(",").map(Number);
  const costing = q.get("profile") || "pedestrian";
  if (costing === "nowhere" || !(tl < 80)) return {};
  const a = { lat: fl, lng: fg }, b = { lat: tl, lng: tg };
  const kmh = SPEED[costing] || 5, mode = TRAVEL[costing] || "pedestrian";
  const ways = n => Array.from({ length: n }, (_, i) =>
    [[a.lng, a.lat], corner(a, b, (i + 1) * 0.002), [b.lng, b.lat]]);
  const one = (pts, slow = 1) => {
    if (costing !== "multimodal") return trip([leg(pts, kmh / slow, mode, ["Main Street", "Oak Avenue"])]);
    // walk · ride · walk: thirds of the way, the middle on a bus
    const at = t => [a.lng + (b.lng - a.lng) * t, a.lat + (b.lat - a.lat) * t];
    const s1 = at(1 / 3), s2 = at(2 / 3);
    const walk1 = leg([pts[0], [s1[0], pts[0][1]], s1], 5, "pedestrian", ["Main Street", "Oak Avenue"], false);
    const ride = leg([s1, [s2[0], s1[1]], s2], 20, "transit", ["Line 48", "Line 48"], false);
    ride.maneuvers[0] = { type: 30, instruction: "Take the 48 toward Downtown.", length: ride.maneuvers[0].length,
      time: ride.maneuvers[0].time, begin_shape_index: 0, end_shape_index: 2, travel_mode: "transit",
      transit_info: { short_name: "48", long_name: "Quintara-24th Street", headsign: "Downtown",
        color: 0x1565c0, text_color: 0xffffff, operator_name: "Muni",
        transit_stops: [
          { name: "Oak & Main", arrival_date_time: "2026-10-14T08:05", departure_date_time: "2026-10-14T08:06" },
          { name: "Downtown", arrival_date_time: "2026-10-14T08:19", departure_date_time: "2026-10-14T08:19" }] } };
    ride.maneuvers.length = 2; ride.maneuvers[1] = { type: 36, instruction: "Get off at Downtown.",
      length: 0, time: 0, begin_shape_index: 2, end_shape_index: 2, travel_mode: "transit" };
    const walk2 = leg([s2, [pts[2][0], s2[1]], pts[2]], 5, "pedestrian", ["Market Street", "Pine Street"]);
    return trip([walk1, ride, walk2]);
  };
  const [first, ...alts] = [[[a.lng, a.lat], corner(a, b, 0), [b.lng, b.lat]], ...ways(+q.get("alternates") || 0)];
  const reply = { trip: one(first) };
  if (alts.length && !q.get("via") && !q.get("depart") && !q.get("arrive") && costing !== "multimodal")
    reply.alternates = alts.map((p, i) => ({ trip: one(p, 1 + 0.15 * (i + 1)) }));
  return reply;
}
