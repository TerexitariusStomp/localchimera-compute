// tests/browser/route-nav-test.mjs — a journey under way, stated without a map or a device:
// the camera's math (app/route/follow.ts), the words on the card (app/route/banner.ts) and a
// rehearsed drive along a route (app/route/drive-sim.ts).
//
// Run: node tests/browser/route-nav-test.mjs

import { installDomStub } from './dom-stub.mjs';
import { harness } from './assert.mjs';
import { routeReply } from './route-fixture.mjs';
const { check, section, done } = harness();
installDomStub();
Object.defineProperty(globalThis, "navigator", { configurable: true, value: { geolocation: undefined } });
globalThis.window.setInterval = setInterval;     // the drive's timer is the page's

const { readRoutes } = await import("../../browser/app/route/data.js");
const F = await import("../../browser/app/route/shape.js");
const { followZoom, followPadding, turnTo, chooseHeading, FOLLOW_PITCH, SEAT } = await import("../../browser/app/route/follow.js");
const { routeBanner, bearingBanner, reroutingBanner, glyphOf, THEN_M } = await import("../../browser/app/route/banner.js");
const { startDrive, pace } = await import("../../browser/app/route/drive-sim.js");
const P = await import("../../browser/app/position.js");
const { USER } = await import("../../browser/app/core.js");

const A = { lat: 37.7749, lng: -122.4194 }, B = { lat: 37.7849, lng: -122.4094 };
const q = o => new URLSearchParams({ from: `${A.lat},${A.lng}`, to: `${B.lat},${B.lng}`, ...o });
const [walk] = readRoutes(routeReply(q({ profile: "pedestrian" })), "pedestrian");

section("the camera: zoom");
{
  check("a walker is close", followZoom(1.4, "pedestrian") > 17.4 && followZoom(null, "pedestrian") === 18);
  check("a rider is a little back", followZoom(null, "bicycle") === 17.5);
  check("a driver pulls back as the speed rises", followZoom(5, "auto") > followZoom(15, "auto") && followZoom(40, "auto") === 17 - 1.6);
  check("the zoom never leaves its band", followZoom(1000, "pedestrian") >= 17.4 && followZoom(-5, "auto") === 17);
}

section("the camera: where you sit");
{
  const pad = followPadding(800, 90, 110);
  check("more room above than below, none at the sides", pad.top > pad.bottom && pad.left === 0 && pad.right === 0);
  check("the sheet's height is kept free at the foot", pad.bottom === 90);
  const seat = pad.top + (800 - pad.top - pad.bottom) / 2;
  check("the centre of what is left is where you sit: low in the frame", Math.abs(seat / 800 - SEAT) < 0.01, String(seat / 800));
  check("the banner is always cleared", followPadding(800, 90, 300).top >= 316);
  check("a short frame still leaves room to see", (p => 800 - p.top - p.bottom >= 120 || p.top + 120 + p.bottom <= 800)(followPadding(800, 400, 60)));
  check("no negative padding", followPadding(300, 0, 0).top >= 0 && followPadding(300, -5, 0).bottom === 0);
}

section("the camera: which way is up");
{
  check("turning by the short way: 350° → 10° is +20", turnTo(350, 10) === 370);
  check("10° → 350° is −20", turnTo(10, 350) === -10);
  check("it counts on past a full turn, never back", turnTo(720, 30) === 750);
  check("already there is no turn", turnTo(123, 123) === 123);
  check("a half turn goes one way or the other, never spins", Math.abs(turnTo(0, 180)) === 180);
  check("moving: the course the device is on", chooseHeading({ heading: 80, speed: 3 }, 200, 10) === 80);
  check("still: the compass, when the phone gives one", chooseHeading({ heading: 80, speed: 0.2 }, 200, 10) === 200);
  check("still and no compass: the way the route is heading", chooseHeading({ heading: null, speed: null }, null, 10) === 10);
  check("moving with no course reading falls back too", chooseHeading({ heading: null, speed: 5 }, null, 33) === 33);
  check("the tilt is toward the horizon", FOLLOW_PITCH > 30 && FOLLOW_PITCH < 75);
}

section("the card: words for the turn");
{
  const s = F.snapToRoute(walk, A), p = F.progress(walk, s);
  const v = routeBanner(walk, p, { place: "Oak Cafe", arrive: "17:05", arrived: false });
  check("the glyph is the next turn's", v.glyph === glyphOf(walk.mans[1].type) && v.glyph === "→");
  check("the distance to the turn, in large type", /^\d+(\.\d)? ?(m|km)$|^\d+ m$|^\d\.\d km$/.test(v.dist) || v.dist.endsWith("m"), v.dist);
  check("the street is the one to turn onto", v.street === "Oak Avenue");
  check("the disc's line carries distance, minutes and arrival", v.meta.includes(v.dist) && /min/.test(v.meta) && v.meta.endsWith("arrive 17:05"), v.meta);
  check("the turn after is shown only when close behind", v.then === null || p.nextToThenM < THEN_M);
  const near = routeBanner(walk, { ...p, nextToThenM: 90 }, { place: "x", arrive: "1", arrived: false });
  check("close behind: a Then chip with the glyph of the arrival… none, since arrival is no turn", near.then === null);
  const bus = readRoutes(routeReply(q({ profile: "multimodal", depart: "now" })), "multimodal")[0];
  const pb = F.progress(bus, F.snapToRoute(bus, A));
  check("a ride's board is a bus glyph", routeBanner(bus, pb, { place: "x", arrive: "1", arrived: false }).glyph === glyphOf(bus.mans[pb.next].type));
  const board = pb.next >= 0 ? bus.mans.findIndex(m => m.transit) : -1;
  const atBoard = routeBanner(bus, { ...pb, next: board, then: -1, nextToThenM: Infinity, toNextKm: 0.2 }, { place: "x", arrive: "1", arrived: false });
  check("a ride ahead is named by its line and where it heads", atBoard.street === "48 toward Downtown" && atBoard.glyph === "🚌", `${atBoard.glyph} ${atBoard.street}`);
  const nohead = { ...bus, mans: bus.mans.map(m => m.transit ? { ...m, transit: { ...m.transit, headsign: "" } } : m) };
  check("a line that says no headsign is named by itself", routeBanner(nohead, { ...pb, next: board, then: -1, nextToThenM: Infinity, toNextKm: 0.2 }, { place: "x", arrive: "1", arrived: false }).street === "48");
  const rr = reroutingBanner();
  check("while a new way is found the card says so", rr.state === "rerouting" && rr.dist === "Rerouting…" && rr.street === "" && rr.then === null);
  const last = routeBanner(walk, F.progress(walk, F.snapToRoute(walk, { lat: B.lat, lng: (A.lng + B.lng) / 2 })), { place: "Oak Cafe", arrive: "17:05", arrived: false });
  check("the last stretch names the place, under a flag", last.glyph === "🏁" && last.street === "Oak Cafe");
  const arr = routeBanner(walk, p, { place: "Oak Cafe", arrive: "17:05", arrived: true });
  check("arrived says so, and where", arr.state === "arrived" && arr.dist === "Arrived" && arr.street === "Oak Cafe" && arr.then === null);
  const two = { ...walk, mans: [walk.mans[0], { ...walk.mans[1], type: 10, streets: ["B St"] },
                                  { ...walk.mans[1], type: 15, streets: ["C St"] }, walk.mans[2]] };   // turns at vertex 1, arrival at 2
  const p2 = F.progress(two, F.snapToRoute(two, A));
  const chip = routeBanner(two, { ...p2, nextToThenM: 100 }, { place: "x", arrive: "1", arrived: false });
  check("two turns close together: the second rides as a Then chip", chip.then === glyphOf(15) && chip.then === "←");
  const far = routeBanner(two, { ...p2, nextToThenM: 400 }, { place: "x", arrive: "1", arrived: false });
  check("far apart: no chip", far.then === null);
  const b = bearingBanner({ bearing: 90, heading: 0, km: 1.4, place: "Oak Cafe" });
  check("with no way: an arrow toward the place and the crow's distance", b.state === "bearing" && b.glyph === "→" && /1\.4 km as the crow flies/.test(b.meta));
  check("held with the phone's heading, the arrow turns with you", bearingBanner({ bearing: 90, heading: 90, km: 1, place: "x" }).glyph === "↑");
  check("an unknown maneuver type reads straight on", glyphOf(9999) === "↑");
}

section("a rehearsed drive");
{
  check("a walker's pace is under a driver's", pace("pedestrian") < pace("bicycle") && pace("bicycle") < pace("auto"));
  const heard = []; const stop = P.observeFixes(f => heard.push(f));
  const d = startDrive(walk, { factor: 400, tickMs: 5 });
  check("the first fix is the start", heard.length === 1 && Math.abs(heard[0].lat - A.lat) < 1e-6 && Math.abs(USER.lat - A.lat) < 1e-6);
  check("it carries a heading and a speed", heard[0].heading !== null && heard[0].speed !== null && heard[0].speed > 100);
  await d.done;
  stop();
  const end = heard[heard.length - 1];
  check("it runs to the end of the shape", Math.abs(end.lat - B.lat) < 1e-5 && Math.abs(end.lng - B.lng) < 1e-5);
  check("by steps along the way, each further on than the last",
        heard.every((f, i) => i === 0 || F.snapToRoute(walk, f).at * 10 + F.snapToRoute(walk, f).t >= F.snapToRoute(walk, heard[i - 1]).at * 10 + F.snapToRoute(walk, heard[i - 1]).t - 1e-9));
  check("every fix is on the way", heard.every(f => F.snapToRoute(walk, f).offKm < 0.005));
  check("USER ends where the drive does", Math.abs(USER.lat - B.lat) < 1e-5);
  const d2 = startDrive(walk, { factor: 1, tickMs: 5 });
  d2.stop();
  await d2.done;
  check("a stopped drive gives the device back and resolves", true);
}

done();
