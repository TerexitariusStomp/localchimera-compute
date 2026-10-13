// tests/browser/route-modes-test.mjs — the ways of travelling (browser/app/route/modes.js, from
// ui/app/route/modes.ts): THE table, looked up by costing, the glyph for how a stretch is travelled, the UI
// words that become costings, and the default.
//
// Run: node tests/browser/route-modes-test.mjs

import { harness } from './assert.mjs';
const { ROUTE_MODES, MODES, modeInfo, costingOf, travelIcon, DEFAULT_COSTING } = await import("../../browser/app/route/modes.js");
const { check, section, done } = harness();

section("the table");
{
  check("four tabs: transit, walk, bicycle, drive, in that order", ROUTE_MODES.join() === "multimodal,pedestrian,bicycle,auto");
  check("each mode has a label and a glyph", MODES.every(m => m.label && m.icon));
  check("a mode is looked up by its costing", modeInfo("bicycle").label === "Bicycle" && modeInfo("auto").icon === "🚗");
  check("a costing with no tab has no info", modeInfo("motor_scooter") === undefined);
  check("how a stretch is travelled, as a glyph — the same ones the tabs wear",
        travelIcon("pedestrian") === modeInfo("pedestrian").icon && travelIcon("drive") === modeInfo("auto").icon &&
        travelIcon("transit") === modeInfo("multimodal").icon && travelIcon("bicycle") === modeInfo("bicycle").icon);
  check("a way we have no glyph for has none", travelIcon("ferry") === "" && travelIcon("") === "");
  check("UI words become costings", costingOf("foot") === "pedestrian" && costingOf("bike") === "bicycle" && costingOf("car") === "auto" && costingOf("transit") === "multimodal");
  check("a costing passes through; no word is a walk", costingOf("bicycle") === "bicycle" && costingOf() === "pedestrian" && costingOf(null) === "pedestrian");
}

section("the default");
{
  check("a walk, and a mode the table knows", DEFAULT_COSTING === "pedestrian" && !!modeInfo(DEFAULT_COSTING));
  check("one of the tabs", ROUTE_MODES.includes(DEFAULT_COSTING));
}

done();
