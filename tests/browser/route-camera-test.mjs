// tests/browser/route-camera-test.mjs — framing a box exactly (browser/app/route/camera.js, from
// ui/app/route/camera.ts): the camera's standing padding is cleared first, then the box is framed with the
// asked-for padding and nothing else.
//
// Run: node tests/browser/route-camera-test.mjs

import { harness } from './assert.mjs';
const { fitClear, NO_PADDING } = await import("../../browser/app/route/camera.js");
const { check, section, done } = harness();

section("clearing, then framing");
{
  const calls = [];
  const map = { setPadding: p => calls.push(["setPadding", p]), fitBounds: (b, o) => calls.push(["fitBounds", b, o]) };
  const box = [[1, 2], [3, 4]], o = { padding: { top: 120, bottom: 300, left: 28, right: 28 }, duration: 600, maxZoom: 17 };
  fitClear(map, box, o);
  check("the standing padding goes first, then the box", calls.map(c => c[0]).join() === "setPadding,fitBounds");
  check("it is cleared to nothing", JSON.stringify(calls[0][1]) === JSON.stringify({ top: 0, bottom: 0, left: 0, right: 0 }));
  check("the box and the asked-for options reach fitBounds as they were", calls[1][1] === box && calls[1][2] === o);
  check("no padding is nothing at all", Object.values(NO_PADDING).every(v => v === 0));
}

done();
