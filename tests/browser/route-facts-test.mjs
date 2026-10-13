// tests/browser/route-facts-test.mjs — what a route says, in the words and
// places the preview draws it with (browser/app/route-facts.js, from
// ui/app/route-facts.ts): durations, distances, the headline, the lines a
// transit route rides, the box that holds every way, where a time pill sits,
// and ⇅.
//
// Run: node tests/browser/route-facts-test.mjs

import { harness } from './assert.mjs';
import { routeReply } from './route-fixture.mjs';
const { readRoutes } = await import("../../browser/app/route-data.js");
const { fmtMinutes, fmtDistance, headline, transitLines, rides, boundsOf, pillAnchor, swapEnds } =
  await import("../../browser/app/route-facts.js");
const { check, section, done } = harness();

section("durations");
{
  check("under a minute reads as one minute", fmtMinutes(10) === "1 min");
  check("seconds round to the nearest minute", fmtMinutes(89) === "1 min" && fmtMinutes(91) === "2 min");
  check("an hour is hours", fmtMinutes(3600) === "1 h");
  check("hours and minutes", fmtMinutes(3600 + 5 * 60) === "1 h 5 min");
  check("59 minutes stays minutes", fmtMinutes(59 * 60) === "59 min");
  check("a long way", fmtMinutes(3 * 3600 + 40 * 60) === "3 h 40 min");
}

section("distances");
{
  check("under a kilometre in metres", fmtDistance(0.85) === "850 m");
  check("a kilometre and over in tenths", fmtDistance(2.24) === "2.2 km" && fmtDistance(1) === "1.0 km");
  check("miles in tenths", fmtDistance(1.44, "miles") === "1.4 mi");
  check("a short way in miles is feet", fmtDistance(0.05, "miles") === "264 ft");
}

const A = { lat: 37.7749, lng: -122.4194 }, B = { lat: 37.7849, lng: -122.4094 };
const q = o => new URLSearchParams({ from: `${A.lat},${A.lng}`, to: `${B.lat},${B.lng}`, ...o });

section("the headline and the lines");
{
  const [walk] = readRoutes(routeReply(q({ profile: "pedestrian" })), "pedestrian");
  check("headline: minutes, then the distance in brackets", /^\d+ min \(\d\.\d km\)$/.test(headline(walk)), headline(walk));
  check("a walk rides no lines", transitLines(walk).length === 0 && rides(walk) === 0);
  const [bus] = readRoutes(routeReply(q({ profile: "multimodal", depart: "now" })), "multimodal");
  const ls = transitLines(bus);
  check("a transit route names the line it boards", ls.length === 1 && ls[0].line === "48" && ls[0].headsign === "Downtown");
  check("with its colours", ls[0].color === "#1565c0" && ls[0].textColor === "#ffffff");
  check("and counts one vehicle", rides(bus) === 1);
  const two = { ...bus, mans: [...bus.mans, { ...bus.mans.find(m => m.transit), type: 31 }] };
  check("a transfer boards another", rides(two) === 2 && transitLines(two).length === 2);
  const stay = { ...bus, mans: [...bus.mans, { ...bus.mans.find(m => m.transit), type: 32 }] };
  check("staying aboard does not", rides(stay) === 1);
}

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

section("⇅");
{
  const you = { lat: 1, lng: 2 };
  const from = { at: { lat: 9, lng: 9 }, name: "Your location", live: true };
  const to = { at: { lat: 5, lng: 5 }, name: "Oak Cafe" };
  const s = swapEnds(from, to, you);
  check("the ends trade places", s.from.name === "Oak Cafe" && s.to.name === "Your location");
  check("you stay you, and are read afresh", s.to.live === true && s.to.at.lat === 1 && s.to.at.lng === 2);
  check("a place stays where it is, and is not you", s.from.live === undefined && s.from.at.lat === 5);
  const back = swapEnds(s.from, s.to, { lat: 3, lng: 4 });
  check("swapping back puts you at the start, wherever you have moved to", back.from.live === true && back.from.at.lat === 3 && back.to.name === "Oak Cafe");
}

done();
