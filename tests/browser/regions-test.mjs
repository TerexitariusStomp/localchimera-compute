// tests/browser/regions-test.mjs — deriving containment from geography
// (browser/app/regions.js)
//
// The map's claim is that the region it draws around a scope is the SAME object,
// by id, that the planner reasons about — because containment is DERIVED from a
// published polygon rather than asserted by hand. Two rules carry that:
//
//   · the deepest region wins. A farm sits in an ecoregion which sits in a
//     bioregion, and every one of them contains the point. Answering the parent
//     would file the farm one tier too coarse, silently and forever.
//   · an asserted parent wins over geography, but ONLY if the forest has it.
//     A location naming a containedIn the snapshot never sent would otherwise
//     root itself and float free of the map.
//
// Both are invisible when they hold. Neither is reachable from the UX suites,
// which need WebGL for the map at all.
//
// Run: node tests/browser/regions-test.mjs

import { installDomStub, harness } from "./dom-stub.mjs";
installDomStub();

const R = await import("../../browser/app/regions.js");

const { check, done } = harness();

/** A square polygon, as a published boundary would carry it. */
const box = (x0, y0, x1, y1) => ({
  type: "Polygon",
  coordinates: [[[x0, y0], [x1, y0], [x1, y1], [x0, y1], [x0, y0]]],
});

// A real nesting: a bioregion, an ecoregion inside it, and a district inside
// that. Every one of the three contains the point (5, 5).
const BIOREGION = { id: "cascadia", name: "Cascadia", parent: null, boundary: box(0, 0, 20, 20) };
const ECOREGION = { id: "willamette", name: "Willamette", parent: "cascadia", boundary: box(0, 0, 10, 10) };
const DISTRICT  = { id: "portland", name: "Portland", parent: "willamette", boundary: box(3, 3, 7, 7) };
const ELSEWHERE = { id: "doon", name: "Doon Valley", parent: null, boundary: box(100, 30, 110, 40) };

// ── the deepest region wins ────────────────────────────────────────────────
{
  const all = [BIOREGION, ECOREGION, DISTRICT, ELSEWHERE];
  check("a point in all three tiers files under the deepest",
        R.deepestRegionAt(5, 5, all) === "portland");
  check("a point in two tiers files under the finer",
        R.deepestRegionAt(9, 9, all) === "willamette");
  check("a point in one files under that one",
        R.deepestRegionAt(15, 15, all) === "cascadia");
  check("a point in none of them files nowhere",
        R.deepestRegionAt(50, 50, all) === null);

  // ORDER MUST NOT MATTER. The layers arrive as separate fetches — the top tier
  // first, then whatever each feature declared — so a rule that depended on the
  // array's order would work until a layer file was renamed.
  const shuffled = [DISTRICT, ELSEWHERE, BIOREGION, ECOREGION];
  check("…and the answer does not depend on the order they loaded in",
        R.deepestRegionAt(5, 5, shuffled) === "portland");

  check("a region with no published boundary is never the answer",
        R.deepestRegionAt(5, 5, [{ id: "hearsay", name: "?", parent: null }, BIOREGION]) === "cascadia");
  check("with no regions at all, nothing is derived",
        R.deepestRegionAt(5, 5, []) === null);
}

// ── regionalize: the forest gains its extents ──────────────────────────────
{
  const regions = [BIOREGION, ECOREGION, DISTRICT];
  const farm = { id: "farm", name: "the farm", parent: null, lat: 5, lng: 5 };
  const nodes = R.regionalize([farm], regions);

  check("every region becomes a node of the forest",
        ["cascadia", "willamette", "portland"].every(id => nodes.some(n => n.id === id)));
  check("…carrying its true published shape",
        nodes.find(n => n.id === "willamette").boundary === ECOREGION.boundary);
  check("…and nested by its own declared containedIn",
        nodes.find(n => n.id === "portland").parent === "willamette" &&
        nodes.find(n => n.id === "willamette").parent === "cascadia" &&
        nodes.find(n => n.id === "cascadia").parent === null);
  check("a placed scope is attached to the deepest region holding it",
        farm.parent === "portland");

  // THE SECOND RULE: an asserted parent wins over geography — a snapshot that
  // says where something belongs is better evidence than a polygon test.
  const asserted = { id: "plot", name: "a plot", parent: "cascadia", lat: 5, lng: 5 };
  R.regionalize([asserted], regions);
  check("an asserted parent the forest HAS is left alone",
        asserted.parent === "cascadia");

  // …but only if the forest has it. A dangling containedIn would float the node
  // out of the map entirely, so geography takes over.
  const dangling = { id: "orphan", name: "an orphan", parent: "atlantis", lat: 5, lng: 5 };
  R.regionalize([dangling], regions);
  check("a parent the forest does NOT have gives way to geography",
        dangling.parent === "portland",
        ` — ${dangling.parent}`);

  // A node with no coordinates cannot be placed, and must not be guessed at.
  const unplaced = { id: "abstract", name: "an idea", parent: null, lat: NaN, lng: NaN };
  R.regionalize([unplaced], regions);
  check("a node with no coordinates is left unattached",
        unplaced.parent === null);

  // A REGION is not re-attached to itself or to a sibling by the point test —
  // its own declaration is the whole truth about where it nests.
  const again = R.regionalize([], regions);
  check("a region keeps its declared parent, never a derived one",
        again.find(n => n.id === "portland").parent === "willamette");

  check("with no regions loaded, the forest passes through untouched",
        R.regionalize([farm], []).length === 1);
}

// ── leafDesire: a thing is not a need ──────────────────────────────────────
{
  check("a place with a recorded shortfall reads it",
        R.leafDesire({ id: "a", desire: 0.4 }) === 0.4);
  check("a place with none recorded reads whole",
        R.leafDesire({ id: "b" }) === 1);
  // THE DISTINCTION THE OVERLAY RESTS ON: null is a THING — a box, a crate. It
  // nests and it draws, and it counts toward nobody's fill. Read it as 0 and a
  // strained place goes green because somebody left a box there; read it as 1
  // and the same happens the other way.
  check("a THING counts toward nobody's fill",
        R.leafDesire({ id: "c", desire: null }) === null);
  check("a work-intent nobody has taken reads strained",
        R.leafDesire({ id: "d", place: { mode: "work", name: "shift", serves: "x" } }) === 0.42);
  check("a commons place reads healthy",
        R.leafDesire({ id: "e", place: { mode: "common", name: "hall", serves: "x" } }) === 0.82);
}

done();
