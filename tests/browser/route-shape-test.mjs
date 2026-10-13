// tests/browser/route-shape-test.mjs — the geometry of a route's shape (browser/app/route/shape.js,
// from ui/app/route/shape.ts): the box that holds every way, where a time pill sits, where you are ON a
// route and what is left of it, a point along the way and the way it is heading there.
//
// Run: node tests/browser/route-shape-test.mjs

import { harness } from './assert.mjs';
import { routeReply } from './route-fixture.mjs';
const { readRoutes } = await import("../../browser/app/route/data.js");
const { boundsOf, pillAnchor, snapToRoute, progress, pointAt, courseAt, shapeKm, segments } =
  await import("../../browser/app/route/shape.js");
const { check, section, done } = harness();

const A = { lat: 37.7749, lng: -122.4194 }, B = { lat: 37.7849, lng: -122.4094 };
const q = o => new URLSearchParams({ from: `${A.lat},${A.lng}`, to: `${B.lat},${B.lng}`, ...o });

section("the box that holds every way");
{
  const rs = readRoutes(routeReply(q({ profile: "bicycle", alternates: "2" })), "bicycle");
  const [[w, s], [e, n]] = boundsOf(rs);
  check("every vertex of every way is inside it", rs.every(r => r.coords.every(([x, y]) => x >= w && x <= e && y >= s && y <= n)));
  check("and it is no larger than they make it", rs.some(r => r.coords.some(([x]) => x === w)) && rs.some(r => r.coords.some(([, y]) => y === n)));
  check("no shape, no box", boundsOf([]) === null && boundsOf([{ coords: [] }]) === null);
  check("two ends make a box", JSON.stringify(boundsOf([{ coords: [[1, 2], [3, 0]] }])) === "[[1,0],[3,2]]");
}

section("where a time pill sits");
{
  const rs = readRoutes(routeReply(q({ profile: "bicycle", alternates: "2" })), "bicycle");
  check("every way has an anchor", rs.every((_, i) => pillAnchor(rs, i) !== null));
  check("an anchor is on its own way", rs.every((r, i) => { const a = pillAnchor(rs, i); return r.coords.some(c => c[0] === a[0] && c[1] === a[1]); }));
  const d = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1]);
  const near = (r, p) => Math.min(...r.coords.map(c => d(c, p)));
  const a0 = pillAnchor(rs, 0), a1 = pillAnchor(rs, 1);
  check("a pill keeps off the other ways: no nearer to them than the way's own start is",
        near(rs[1], a0) >= 0 && Math.min(...rs.slice(1).map(r => near(r, a0))) >= Math.min(...rs.slice(1).map(r => near(r, rs[0].coords[0]))) - 1e-12);
  check("two ways' pills do not sit on the same point", d(a0, a1) > 1e-6);
  check("a lone way's pill sits inside the way, off its ends", (() => {
    const lone = [{ coords: Array.from({ length: 21 }, (_, i) => [i, 0]) }];
    const a = pillAnchor(lone, 0); return a[0] > 2 && a[0] < 18; })());
  check("no way, no anchor", pillAnchor([], 0) === null && pillAnchor([{ coords: [] }], 0) === null);
  check("with two ways the pill goes to where they part",
        (() => { const x = { coords: Array.from({ length: 11 }, (_, i) => [i * 0.001, 0]) };
                 const y = { coords: Array.from({ length: 11 }, (_, i) => [i * 0.001, i < 5 ? 0 : (i - 4) * 0.01]) };
                 return pillAnchor([x, y], 1)[1] > 0.04; })());
}

section("where you are on a route");
{
  const [r] = readRoutes(routeReply(q({ profile: "pedestrian" })), "pedestrian");   // north, then east
  const corner = { lat: r.coords[1][1], lng: r.coords[1][0] };
  const s0 = snapToRoute(r, A);
  check("at the start you are at the first vertex, on the line", s0.at === 0 && s0.t < 0.01 && s0.offKm < 0.001);
  const half = { lat: (A.lat + corner.lat) / 2, lng: A.lng };
  const s1 = snapToRoute(r, half);
  check("half way up the first leg you are half way along it", s1.at === 0 && Math.abs(s1.t - 0.5) < 0.01 && s1.offKm < 0.001, JSON.stringify(s1));
  const beside = snapToRoute(r, { lat: half.lat, lng: A.lng + 0.001 });
  check("a position beside the way is that far from it", beside.at === 0 && beside.offKm > 0.05 && beside.offKm < 0.12, String(beside.offKm));
  check("on the second leg you are past the first vertex", snapToRoute(r, { lat: B.lat, lng: (A.lng + B.lng) / 2 }).at === 1);
  check("beyond the end you are at the end", (s => s.at === 1 && s.t === 1)(snapToRoute(r, { lat: B.lat + 0.01, lng: B.lng + 0.01 })));
  check("the search goes forward from where you were: a way that doubles back is read in order", (() => {
    const out = [[0, 0], [0, 0.004], [0, 0.008], [0, 0.012], [0, 0.008], [0, 0.004], [0, 0]];   // north, then back the same road
    const loop = { ...r, coords: out, mans: [] };
    const here = { lat: 0.006, lng: 0 };
    return snapToRoute(loop, here, 0).at < 3 && snapToRoute(loop, here, 5).at >= 4;
  })());
  check("a one-point route has no line to be on", snapToRoute({ ...r, coords: [[1, 1]] }, A).at === 0);

  const p0 = progress(r, s0);
  check("at the start all of it is left", Math.abs(p0.remKm - r.km) < 0.01 && Math.abs(p0.remS - r.s) < 1, `${p0.remKm} of ${r.km} · ${p0.remS} of ${r.s}`);
  check("the turn ahead is the second maneuver", p0.cur === 0 && p0.next === 1 && p0.then === 2);
  const leg1 = shapeKm(r) * 0; void leg1;
  check("the distance to the turn is the first leg", Math.abs(p0.toNextKm - r.mans[0].length) < 0.01, `${p0.toNextKm} vs ${r.mans[0].length}`);
  const p1 = progress(r, s1);
  check("half way up, half the leg and all of the next remain", Math.abs(p1.remS - (r.mans[0].time / 2 + r.mans[1].time)) < 2);
  check("and half the leg to the turn", Math.abs(p1.toNextKm - r.mans[0].length / 2) < 0.01);
  const p2 = progress(r, snapToRoute(r, B));
  check("at the end nothing is left", p2.remKm < 0.01 && p2.remS < 2 && p2.aheadKm < 0.001);
  check("time left only falls as you go", p0.remS > p1.remS && p1.remS > p2.remS);
  check("a turn close behind the next is near: the arrival after the last turn", p1.nextToThenM > 0);
  const flat = { ...r, mans: [] };
  const pf = progress(flat, s1);
  check("a route with no maneuvers is read evenly along its length", Math.abs(pf.remS - r.s * (1 - 0.5 * shapeKm({ ...r, coords: r.coords.slice(0, 2) }) / shapeKm(r))) < 2 && pf.next === -1);
}

section("the runs of a trip");
{
  const [bus] = readRoutes(routeReply(q({ profile: "multimodal", depart: "now" })), "multimodal");
  const runs = segments(bus);
  check("walk, ride, walk", runs.map(r => r.mode).join() === "pedestrian,transit,pedestrian");
  check("each run's time and distance are its maneuvers' own", runs.every(r => r.s > 0 && r.km > 0) &&
        Math.abs(runs.reduce((a, r) => a + r.s, 0) - bus.s) < 2 && Math.abs(runs.reduce((a, r) => a + r.km, 0) - bus.km) < 0.01,
        runs.map(r => `${r.s}s`).join());
  check("the ride carries its line, the walks none", runs[1].transit?.line === "48" && runs[0].transit === null && runs[2].transit === null);
  const [walk] = readRoutes(routeReply(q({ profile: "pedestrian" })), "pedestrian");
  const one = segments({ ...walk, mans: [] });
  check("a way with no maneuvers is one run, with the route's own totals", one.length === 1 && one[0].s === walk.s && one[0].km === walk.km && one[0].transit === null);
}

section("a point along the way");
{
  const [r] = readRoutes(routeReply(q({ profile: "pedestrian" })), "pedestrian");
  const total = shapeKm(r);
  check("the start is the start", (p => Math.abs(p.lat - A.lat) < 1e-6 && Math.abs(p.lng - A.lng) < 1e-6)(pointAt(r, 0)));
  check("the end is the end", (p => Math.abs(p.lat - B.lat) < 1e-6 && Math.abs(p.lng - B.lng) < 1e-6)(pointAt(r, total)));
  check("past the end stays at the end", pointAt(r, total + 5).lat === pointAt(r, total).lat);
  check("heading north on the first leg, east on the second", Math.abs(pointAt(r, 0.01).heading) < 1 || Math.abs(pointAt(r, 0.01).heading - 360) < 1);
  check("…", Math.abs(pointAt(r, total - 0.01).heading - 90) < 1);
  check("the course where you are is the way ahead", Math.abs(courseAt(r, snapToRoute(r, { lat: B.lat, lng: (A.lng + B.lng) / 2 })) - 90) < 1);
  check("no shape, no point", pointAt({ ...r, coords: [] }, 1).lat === 0);
}

done();
