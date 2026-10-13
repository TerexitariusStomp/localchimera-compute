// tests/browser/route-data-test.mjs — the one reader of /route's reply
// (browser/app/route/data.js, from ui/app/route/data.ts): the polyline, the
// trip → Route reading with its alternates and transit legs, the query a mode
// asks with, and the short-lived cache the preview's tabs share.
//
// The replies are synthesised in Valhalla's documented shape
// (tests/browser/route-fixture.mjs); no engine runs.
//
// Run: node tests/browser/route-data-test.mjs

import { harness } from './assert.mjs';
import { encodePoly, routeReply, havKm } from './route-fixture.mjs';
const { decodePoly, readRoutes, routeQuery, fetchRoutes, fetchModes, clearRouteCache } =
  await import("../../browser/app/route/data.js");
const { ROUTE_MODES } = await import("../../browser/app/route/modes.js");
const { check, section, done } = harness();

const A = { lat: 37.7749, lng: -122.4194 }, B = { lat: 37.7849, lng: -122.4094 };
const q = o => new URLSearchParams({ from: `${A.lat},${A.lng}`, to: `${B.lat},${B.lng}`, ...o });

section("the polyline");
{
  const pts = [[-122.4194, 37.7749], [-122.4194, 37.7849], [-122.4094, 37.7849]];
  const back = decodePoly(encodePoly(pts));
  check("encode then decode returns every vertex", back.length === 3 &&
        back.every((p, i) => Math.abs(p[0] - pts[i][0]) < 1e-6 && Math.abs(p[1] - pts[i][1]) < 1e-6));
  check("an empty shape decodes to no points", decodePoly("").length === 0);
}

section("reading a walking trip");
{
  const [r, ...more] = readRoutes(routeReply(q({ profile: "pedestrian" })), "pedestrian");
  check("one route, no alternates, when none were asked", !!r && more.length === 0);
  check("the shape is the dog-leg's three vertices", r.coords.length === 3);
  check("three maneuvers: depart, turn, arrive", r.mans.map(m => m.type).join() === "1,10,4");
  check("the instruction text is kept", r.mans[1].instr === "Turn right onto Oak Avenue.");
  check("street names are kept", r.mans[0].streets.join() === "Main Street");
  check("each maneuver knows where it ends", r.mans[0].begin === 0 && r.mans[0].end === 1 && r.mans[1].end === 2);
  check("the leg lengths sum to the summary", Math.abs(r.mans.reduce((a, m) => a + m.length, 0) - r.km) < 1e-9);
  check("the summary distance is the dog-leg's", Math.abs(r.km - (havKm(A, { lat: B.lat, lng: A.lng }) + havKm({ lat: B.lat, lng: A.lng }, B))) < 1e-6);
  check("time is the legs' seconds", r.s === r.mans.reduce((a, m) => a + m.time, 0) && r.s > 0);
  check("the spoken forms are kept", r.mans[1].verbal.pre === "Turn right onto Oak Avenue." && r.mans[0].verbal.post.startsWith("Continue"));
  check("units default to kilometres", r.units === "kilometers");
  check("the costing asked for rides on the route", r.costing === "pedestrian");
  check("a plain maneuver has no transit and no roundabout exit", r.mans[1].transit === null && r.mans[1].roundaboutExit === 0);
  check("the travel mode is kept", r.mans[0].mode === "pedestrian");
}

section("alternates");
{
  const rs = readRoutes(routeReply(q({ profile: "bicycle", alternates: "2" })), "bicycle");
  check("the chosen way, then each alternate", rs.length === 3);
  check("alternates are slower here (the synthetic engine bends them)", rs[1].s > rs[0].s && rs[2].s > rs[1].s,
        rs.map(r => r.s).join(" < "));
  check("waypoints offer no alternates", readRoutes(routeReply(q({ profile: "auto", alternates: "2", via: "37.78,-122.41" })), "auto").length === 1);
}

section("a transit trip");
{
  const [r] = readRoutes(routeReply(q({ profile: "multimodal", depart: "now" })), "multimodal");
  const ride = r.mans.find(m => m.transit);
  check("walk · ride · walk: the ride carries its line", !!ride && ride.transit.line === "48" && ride.transit.headsign === "Downtown");
  check("the line's numeric colours read as hex", ride.transit.color === "#1565c0" && ride.transit.textColor === "#ffffff");
  check("the operator and the stops are kept", ride.transit.operator === "Muni" && ride.transit.stops.length === 2 &&
        ride.transit.stops[0].departs === "2026-10-14T08:06");
  check("the ride's travel mode is transit", ride.mode === "transit");
  check("maneuver indices run on across legs", r.mans.every((m, i) => i === 0 || m.begin >= r.mans[i - 1].begin));
  check("every maneuver begins inside the shape", r.mans.every(m => m.begin < r.coords.length));
  check("three legs make one shape", r.coords.length === 9, String(r.coords.length));
}

section("what a stretch passes through, and where the destination is");
{
  const [w] = readRoutes(routeReply(q({ profile: "pedestrian" })), "pedestrian");
  check("a gate on the second stretch of a walk", w.mans[1].gate && !w.mans[0].gate && !w.mans[1].toll);
  const [d] = readRoutes(routeReply(q({ profile: "auto" })), "auto");
  check("a toll on the first stretch of a drive", d.mans[0].toll && !d.mans[1].toll);
  check("no flag is false, not absent", w.mans[0].rough === false && w.mans[0].ferry === false);
  check("the destination's side of the street", w.destSide === "right");
  check("a reply that does not say is not a side", readRoutes({ trip: { legs: [{}], summary: {}, locations: [{}, { side_of_street: "none" }] } }, "x")[0].destSide === "");
  check("nor one with no locations", readRoutes({ trip: { legs: [{}], summary: {} } }, "x")[0].destSide === "");
}

section("what is not a route");
{
  check("an empty reply is no route", readRoutes({}, "pedestrian").length === 0);
  check("null is no route", readRoutes(null, "pedestrian").length === 0);
  check("legs with no summary are no route", readRoutes({ trip: { legs: [{ shape: "" }] } }, "x").length === 0);
  check("no legs are no route", readRoutes({ trip: { legs: [], summary: { length: 1, time: 1 } } }, "x").length === 0);
  const r = readRoutes({ trip: { legs: [{ maneuvers: [{}] }], summary: {} } }, "x")[0];
  check("a bare maneuver reads as absent fields, not guesses",
        r.mans[0].instr === "" && r.mans[0].streets.length === 0 && r.mans[0].length === 0 && r.mans[0].transit === null && r.km === 0);
  check("a leg with no shape contributes no points", r.coords.length === 0);
  check("a miles reply says so", readRoutes({ trip: { legs: [{ maneuvers: [] }], summary: {}, units: "miles" } }, "x")[0].units === "miles");
  check("toll and ferry flags read through",
        (() => { const t = readRoutes({ trip: { legs: [{}], summary: { has_toll: true, has_ferry: true } } }, "x")[0]; return t.hasToll && t.hasFerry; })());
}

section("the query");
{
  const p = s => new URLSearchParams(s);
  const base = p(routeQuery(A, B, "pedestrian"));
  check("two ends and a profile", base.get("from") === "37.7749,-122.4194" && base.get("to") === "37.7849,-122.4094" && base.get("profile") === "pedestrian");
  check("nothing else unless asked", [...base.keys()].join() === "from,to,profile");
  check("transit with no clock leaves now", p(routeQuery(A, B, "multimodal")).get("depart") === "now");
  check("transit with an arrival asks for no departure", p(routeQuery(A, B, "multimodal", { arrive: "2026-10-14T09:00" })).get("depart") === null);
  check("an explicit departure rides", p(routeQuery(A, B, "multimodal", { depart: "2026-10-14T08:00" })).get("depart") === "2026-10-14T08:00");
  check("other modes ask for no clock", p(routeQuery(A, B, "bicycle")).get("depart") === null);
  check("alternates, language and miles ride", (() => { const x = p(routeQuery(A, B, "auto", { alternates: 2, lang: "de-DE", units: "miles" }));
        return x.get("alternates") === "2" && x.get("lang") === "de-DE" && x.get("units") === "mi"; })());
  check("waypoints are joined with semicolons", p(routeQuery(A, B, "auto", { via: [{ lat: 1, lng: 2 }, { lat: 3, lng: 4 }] })).get("via") === "1,2;3,4");
}

section("asking, and the cache");
{
  const realFetch = globalThis.fetch;
  let calls = [], engineUp = true;
  globalThis.fetch = async url => {
    calls.push(String(url));
    if (!engineUp) throw new Error("connection refused");
    return { json: async () => routeReply(String(url).split("?")[1]) };
  };
  try {
    clearRouteCache();
    const [r1, r2] = await Promise.all([fetchRoutes(A, B, "bicycle"), fetchRoutes(A, B, "bicycle")]);
    check("two asks for the same way make one request", calls.length === 1);
    check("…and both get the route", r1.length === 1 && r2.length === 1 && r1[0] === r2[0]);
    await fetchRoutes(A, B, "bicycle");
    check("a later ask is still served from the cache", calls.length === 1);
    await fetchRoutes(A, B, "bicycle", { alternates: 2 });
    check("a different ask is a different request", calls.length === 2);

    calls = []; clearRouteCache();
    const all = await fetchModes(A, B);
    check("fetchModes asks every tab's mode, all at once", calls.length === ROUTE_MODES.length &&
          ROUTE_MODES.every(m => calls.some(c => c.includes(`profile=${m}`))));
    check("each mode answers under its own key", ROUTE_MODES.every(m => all[m].length === 1 && all[m][0].costing === m));
    check("walking is slower than cycling is slower than driving",
          all.pedestrian[0].s > all.bicycle[0].s && all.bicycle[0].s > all.auto[0].s);
    check("the transit ask carried its clock", calls.some(c => c.includes("profile=multimodal") && c.includes("depart=now")));

    calls = []; clearRouteCache();
    check("a place beyond the atlas answers []", (await fetchRoutes(A, { lat: 85, lng: 0 }, "pedestrian")).length === 0);
    await fetchRoutes(A, { lat: 85, lng: 0 }, "pedestrian");
    check("an empty answer is never kept", calls.length === 2);

    calls = []; clearRouteCache(); engineUp = false;
    check("an engine that is not there answers []", (await fetchRoutes(A, B, "auto")).length === 0);
    engineUp = true;
    check("…and is asked again once it is", (await fetchRoutes(A, B, "auto")).length === 1 && calls.length === 2);

    clearRouteCache(); calls = [];
    for (let i = 0; i < 40; i++) await fetchRoutes(A, { lat: B.lat + i * 1e-4, lng: B.lng }, "auto");
    await fetchRoutes(A, { lat: B.lat + 39e-4, lng: B.lng }, "auto");
    check("the cache is bounded, newest kept", calls.length === 40);
    await fetchRoutes(A, { lat: B.lat, lng: B.lng }, "auto");
    check("…and the oldest is let go", calls.length === 41);
  } finally { globalThis.fetch = realFetch; }
}

done();
