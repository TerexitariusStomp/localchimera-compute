// tests/browser/route-facts-test.mjs — what a route says, in words (browser/app/route/facts.js, from
// ui/app/route/facts.ts): durations, distances, the headline, the lines a transit route rides, the
// arrival clock, the REPL page's trip, and ⇅.
//
// Run: node tests/browser/route-facts-test.mjs

import { harness } from './assert.mjs';
import { routeReply } from './route-fixture.mjs';
const { readRoutes } = await import("../../browser/app/route/data.js");
const { fmtMinutes, fmtDistance, headline, transitLines, rides, swapEnds, replTrip, arrivalClock } =
  await import("../../browser/app/route/facts.js");
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
  check("ten kilometres and over in whole numbers", fmtDistance(12.34) === "12 km" && fmtDistance(9.44) === "9.4 km");
  check("miles in tenths", fmtDistance(1.44, "miles") === "1.4 mi" && fmtDistance(12.4, "miles") === "12 mi");
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

section("the REPL page's trip");
{
  const [bus] = readRoutes(routeReply(q({ profile: "multimodal", depart: "now" })), "multimodal");
  const t = replTrip(bus, "transit");
  check("the contract the Scheme side takes", t.engine === "valhalla" && t.profile === "transit" &&
        Array.isArray(t.coordinates) && t.coordinates.length === bus.coords.length);
  check("distance in km, time in seconds", t.distance_km === bus.km && t.time_s === bus.s);
  check("one maneuver each, in the page's words", t.maneuvers.length === bus.mans.length &&
        t.maneuvers[0].instruction === bus.mans[0].instr && "travel_mode" in t.maneuvers[0] && "distance_km" in t.maneuvers[0]);
  check("the runs by travel mode, so a ride can be drawn its own way", t.segments.map(s => s.mode).join() === "pedestrian,transit,pedestrian" &&
        t.segments.every(s => s.coordinates.length > 1));
  check("no profile is a walk", replTrip(bus).profile === "foot");
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

section("the arrival clock");
{
  const hh = n => String(n).padStart(2, "0");
  const now = new Date(), later = new Date(now.getTime() + 90 * 60 * 1000);
  const t = arrivalClock(90 * 60);
  check("the wall clock an hour and a half on", t === `${hh(later.getHours())}:${hh(later.getMinutes())}` || t === `${hh(later.getHours())}:${hh((later.getMinutes() + 1) % 60)}`, t);
  check("now is now", /^\d\d:\d\d$/.test(arrivalClock(0)));
}

done();
