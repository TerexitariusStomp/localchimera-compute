// tests/browser/route-steps-test.mjs — the way turn by turn (browser/app/route/steps.js, from
// ui/app/route/steps.ts): which rows are left from where you are, what each says, the chips for what
// a stretch passes through, the distance between rows, the destination and its side of the street.
//
// Run: node tests/browser/route-steps-test.mjs

import { installDomStub } from './dom-stub.mjs';
import { harness } from './assert.mjs';
import { routeReply } from './route-fixture.mjs';
const { check, section, done } = harness();
installDomStub();

const { readRoutes } = await import("../../browser/app/route/data.js");
const { snapToRoute, progress } = await import("../../browser/app/route/shape.js");
const { stepRows } = await import("../../browser/app/route/steps.js");

const A = { lat: 37.7749, lng: -122.4194 }, B = { lat: 37.7849, lng: -122.4094 };
const q = o => new URLSearchParams({ from: `${A.lat},${A.lng}`, to: `${B.lat},${B.lng}`, ...o });
const route = (profile, o = {}) => readRoutes(routeReply(q({ profile, ...o })), profile)[0];
const rowsAt = (r, at, place = "Oak Cafe") => stepRows(r, progress(r, snapToRoute(r, at)), place);

section("from the start");
{
  const walk = route("pedestrian");
  const rows = rowsAt(walk, A);
  check("the turn ahead, then the door: the departure is not listed", rows.length === 2 && rows[0].kind === "next" && rows[1].kind === "destination", rows.map(r => r.kind).join());
  check("the turn ahead is the engine's own sentence", rows[0].text === "Turn right onto Oak Avenue.");
  check("with its arrow", rows[0].glyph === "→");
  check("and how far off it is", /^In \d(\.\d)? km$|^In \d+ m$/.test(rows[0].lead), rows[0].lead);
  check("the stretch after it passes a gate: a chip", rows[0].warns.join() === "Gate");
  check("the distance to the next row follows it", /^\d+ m$|^\d\.\d km$/.test(rows[0].after || ""), String(rows[0].after));
  check("the door is the place, under a flag", rows[1].text === "Oak Cafe" && rows[1].glyph === "🏁");
  check("with the side of the street it is on", rows[1].note === "Destination will be on the right");
  check("nothing follows the door", rows[1].after === null && rows[1].lead === "" && rows[1].warns.length === 0);
}

section("along the way");
{
  const walk = route("pedestrian");
  const late = rowsAt(walk, { lat: B.lat, lng: (A.lng + B.lng) / 2 });
  check("past the last turn only the door is left", late.length === 1 && late[0].kind === "destination");
  check("and it says how far", /^In /.test(late[0].lead), late[0].lead);
  const there = rowsAt(walk, B);
  check("at the door it is still the door", there.length === 1 && there[0].kind === "destination");
}

section("what a stretch passes through");
{
  const drive = route("auto");
  check("a toll on the first stretch is not listed once you are past it", rowsAt(drive, A).every(r => !r.warns.includes("Toll")));
  const toll = { ...drive, mans: drive.mans.map((m, i) => i === 1 ? { ...m, toll: true, rough: true, ferry: true, gate: true } : m) };
  const rows = rowsAt(toll, A);
  check("every chip, in a fixed order", rows[0].warns.join() === "Toll,Gate,Rough ground,Ferry", rows[0].warns.join());
}

section("a ride");
{
  const bus = route("multimodal", { depart: "now" });
  const rows = rowsAt(bus, A);
  const board = rows.find(r => /Take the 48/.test(r.text));
  check("the walk to the stop comes first, then the board, with its glyph and sentence", !!board && board.glyph === "🚌" && rows.indexOf(board) > 0, rows.map(r => r.text).join(" | "));
  check("the list ends at the door", rows[rows.length - 1].kind === "destination");
  check("every row but the door has a distance after it", rows.slice(0, -1).every(r => r.after !== null));
}

section("no way to list");
{
  const walk = route("pedestrian");
  check("a route with no maneuvers has no rows", stepRows({ ...walk, mans: [] }, progress(walk, snapToRoute(walk, A)), "x").length === 0);
  const nodest = { ...walk, destSide: "" };
  check("an unsaid side adds no note", rowsAt(nodest, A)[1].note === "");
  check("the other side is said too", rowsAt({ ...walk, destSide: "left" }, A)[1].note === "Destination will be on the left");
}

done();
