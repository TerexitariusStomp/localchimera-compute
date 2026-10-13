// tests/browser/route-lines-test.mjs — a route on the map (browser/app/route/lines.js,
// from ui/app/route/lines.ts): which lines a spec draws, and in which kind. The
// pure half only — a spec in, features out — so what is drawn is stated without a map.
//
// Run: node tests/browser/route-lines-test.mjs

import { harness } from './assert.mjs';
import { routeReply } from './route-fixture.mjs';
const { readRoutes } = await import("../../browser/app/route/data.js");
const { lineFeatures } = await import("../../browser/app/route/lines.js");
const { segments } = await import("../../browser/app/route/facts.js");
const { check, section, done } = harness();

const A = { lat: 37.7749, lng: -122.4194 }, B = { lat: 37.7849, lng: -122.4094 };
const q = o => new URLSearchParams({ from: `${A.lat},${A.lng}`, to: `${B.lat},${B.lng}`, ...o });
const kinds = fs => fs.map(f => f.properties.kind).join();

section("the preview: every way");
{
  const ways = readRoutes(routeReply(q({ profile: "bicycle", alternates: "2" })), "bicycle");
  const fs = lineFeatures({ ways, pick: 0 });
  check("the chosen way, then each alternative", kinds(fs) === "sel,alt,alt", kinds(fs));
  check("each feature is a line through its way's own shape", fs[0].geometry.coordinates.length === ways[0].coords.length &&
        fs[1].geometry.coordinates.length === ways[1].coords.length);
  check("choosing another way swaps which is chosen", kinds(lineFeatures({ ways, pick: 1 })) === "alt,sel,alt");
  check("a pick of nothing real draws every way pale", !kinds(lineFeatures({ ways, pick: 9 })).includes("sel"));
  check("no ways, nothing drawn", lineFeatures({}).length === 0 && lineFeatures({ ways: [] }).length === 0);
}

section("on a journey: what is behind you");
{
  const [r] = readRoutes(routeReply(q({ profile: "pedestrian" })), "pedestrian");
  check("at the start nothing is behind you", kinds(lineFeatures({ ways: [r], pick: 0, at: 0 })) === "sel");
  const mid = lineFeatures({ ways: [r], pick: 0, at: 1 });
  check("past the first vertex, the part behind is done and the rest is ahead", kinds(mid) === "done,sel", kinds(mid));
  check("done runs from the start to where you are", mid[0].geometry.coordinates.length === 2 &&
        mid[0].geometry.coordinates[1][0] === r.coords[1][0]);
  check("what is ahead begins where you are", mid[1].geometry.coordinates[0][0] === r.coords[1][0] &&
        mid[1].geometry.coordinates.length === r.coords.length - 1);
  const end = lineFeatures({ ways: [r], pick: 0, at: r.coords.length - 1 });
  check("at the end it is all done", kinds(end) === "done", kinds(end));
  check("a position past the end is the end", kinds(lineFeatures({ ways: [r], pick: 0, at: 99 })) === "done");
  check("a position before the start is the start", kinds(lineFeatures({ ways: [r], pick: 0, at: -3 })) === "sel");
}

section("a trip with a ride: walk · ride · walk");
{
  const [r] = readRoutes(routeReply(q({ profile: "multimodal", depart: "now" })), "multimodal");
  const segs = segments(r);
  check("three runs: foot, vehicle, foot", segs.map(s => s.mode).join() === "pedestrian,transit,pedestrian", segs.map(s => s.mode).join());
  // each leg's shape starts where the last ended, so a joint is two vertices at one point
  check("the runs follow one another and cover the whole shape", segs[0].begin === 0 &&
        segs[1].begin === segs[0].begin + segs[0].coords.length &&
        segs[2].begin === segs[1].begin + segs[1].coords.length &&
        segs[2].begin + segs[2].coords.length === r.coords.length);
  check("and meet at the same point, so no gap shows", segs[0].coords.at(-1).join() === segs[1].coords[0].join() &&
        segs[1].coords.at(-1).join() === segs[2].coords[0].join());
  const fs = lineFeatures({ ways: [r], pick: 0 });
  check("the walks are dotted, the ride is solid", kinds(fs) === "walk,sel,walk", kinds(fs));
  const mid = lineFeatures({ ways: [r], pick: 0, at: segs[1].begin + 1 });
  check("part-way along the ride: the walk is done, the ride is cut where you are", kinds(mid) === "done,sel,walk", kinds(mid));
  check("…and the ride begins where you are", mid[1].geometry.coordinates[0][0] === r.coords[segs[1].begin + 1][0]);
  const [w] = readRoutes(routeReply(q({ profile: "pedestrian" })), "pedestrian");
  check("a plain walk is one chosen line, not dotted", kinds(lineFeatures({ ways: [w], pick: 0 })) === "sel");
}

section("a route with no maneuvers, and none at all");
{
  const bare = { coords: [[0, 0], [1, 1], [2, 2]], mans: [], km: 1, s: 1, units: "kilometers", hasToll: false, hasFerry: false, costing: "auto" };
  check("a shape with no maneuvers is still one run", segments(bare).length === 1 && segments(bare)[0].coords.length === 3);
  check("a single point is no run", segments({ ...bare, coords: [[0, 0]] }).length === 0);
  check("a way with no shape draws nothing", lineFeatures({ ways: [{ ...bare, coords: [] }], pick: 0 }).length === 0);
}

section("the bearing: no way at all");
{
  const fs = lineFeatures({ bearing: [[1, 2], [3, 4]] });
  check("a thread between two points", kinds(fs) === "bearing" && fs[0].geometry.coordinates.length === 2);
  check("it joins the points as given", JSON.stringify(fs[0].geometry.coordinates) === "[[1,2],[3,4]]");
}

done();
