// tests/browser/containment-fold-test.mjs — the containment forest and its fold
// (browser/app/tabs/map/containers.js)
//
// The map's region overlay nests PLACES and tints them by an aggregate over
// what is in them. Since containers — things standing in a place: a box, a
// crate, a van — now nest in that same forest, the fold has to hold a line:
//
//   a THING is not one of the things being aggregated.
//
// Get that wrong and the damage is silent and total: give a place a child that
// carries no value and the place stops being a leaf, so its OWN reading is
// never read and it renders as whole. A strained place goes green because
// somebody left a box there. That is the regression this pins, and it is the
// bug the first implementation actually had.
//
// Alongside it: how the forest ROOTS (a parent pointing outside the set, or at
// itself), the AM–GM claim the geometric mean is chosen for, and point-in-
// polygon — which decides which real ecoregion a farm sits in, and so which
// published boundary a leaf's contained-in is DERIVED from rather than guessed.
//
// The rest of the geometry (hulls, discs, the maplibre layers) needs a GL
// context and is not exercised here; everything below is pure, so node runs the
// real code rather than a reimplementation of it.
//
// Run: node tests/browser/containment-fold-test.mjs

globalThis.window = { d3: {} };     // containers.js reads window.d3 at import time
const C = await import("../../browser/app/tabs/map/containers.js");

import { harness } from './assert.mjs';
const { check, done } = harness();

// main.js's leafDesire in miniature: null for a thing, a number for a place.
const valueOf = n => n.desire === null ? null : (n.desire != null ? n.desire : 1);
const build = nodes => {
  const roots = C.forest(nodes);
  roots.forEach(r => C.fold(r, valueOf));
  const by = new Map();
  roots.forEach(function walk(n) { by.set(n.id, n); n.children.forEach(walk); });
  return by;
};

// ── a place holding things keeps its own reading ───────────────────────────
{
  const by = build([
    { id: "block",  parent: null },
    { id: "bridge", parent: "block", desire: 0.4 },
    { id: "square", parent: "block", desire: 0.9 },
    { id: "box",    parent: "bridge", desire: null },   // a thing at the bridge
    { id: "crate",  parent: "box",    desire: null },   // and a thing inside it
  ]);
  const geomean = Math.exp((Math.log(0.4) + Math.log(0.9)) / 2);
  check("a thing nests inside the place holding it",
        by.get("bridge").children.map(c => c.id).join() === "box");
  check("…one level deeper", by.get("box").depth === by.get("bridge").depth + 1);
  check("a place holding things keeps ITS OWN reading",
        Math.abs(by.get("bridge").slack - 0.4) < 1e-12,
        ` (${by.get("bridge").slack.toFixed(3)}, not 1.000)`);
  check("an aggregate is over its places, not their contents",
        Math.abs(by.get("block").slack - geomean) < 1e-12 && by.get("block").n === 2,
        ` (${by.get("block").slack.toFixed(4)}, n=${by.get("block").n})`);
  check("a thing carries no reading of its own to drag on anything",
        valueOf(by.get("box")) === null);
}

// ── and with no things in the tree, nothing whatsoever changed ─────────────
// The overlay predates containers on the map; this is the fold it has always
// been, checked against a copy of it, degenerate leaves included.
{
  const before = (n, v) => {
    const leaves = [];
    (function walk(x) { x.children.length ? x.children.forEach(walk) : leaves.push(x); })(n);
    const ss = leaves.map(v).filter(s => isFinite(s) && s > 0);
    n.slack = ss.length ? Math.exp(ss.reduce((a, s) => a + Math.log(s), 0) / ss.length) : 1;
    n.n = leaves.length;
    n.children.forEach(c => before(c, v));
    return n;
  };
  const places = () => ([
    { id: "root", parent: null },
    { id: "a",  parent: "root", desire: 0.3 },
    { id: "b",  parent: "root" },
    { id: "b1", parent: "b", desire: 0.8 },
    { id: "b2", parent: "b", desire: 0 },        // a leaf whose value is not > 0
    { id: "c",  parent: "root", desire: NaN },   // …and one that is not finite
  ]);
  const dump = roots => {
    const out = [];
    roots.forEach(function w(n) { out.push(`${n.id}:${n.slack.toFixed(6)}/${n.n}`); n.children.forEach(w); });
    return out.join(" ");
  };
  const now = C.forest(places()); now.forEach(r => C.fold(r, valueOf));
  const old = C.forest(places()); old.forEach(r => before(r, valueOf));
  check("a places-only tree folds exactly as it always did", dump(now) === dump(old));
  if (dump(now) !== dump(old)) console.log(`      now: ${dump(now)}\n      was: ${dump(old)}`);
}

// ── the forest roots wherever containment stops ────────────────────────────
{
  const roots = C.forest([
    { id: "commune" },
    { id: "venue", parent: "commune" },
    { id: "room",  parent: "venue" },
    { id: "orphan", parent: "nowhere" },   // a parent outside the set
    { id: "self",   parent: "self" },      // never its own child
  ]);
  const ids = roots.map(r => r.id).sort().join();
  check("a node with no parent roots, as does one whose parent is outside the",
        ids === "commune,orphan,self", `\n      set, as does a self-parent — three roots (${ids})`);
  const by = new Map();
  roots.forEach(function walk(n) { by.set(n.id, n); n.children.forEach(walk); });
  check("depth counts containment from the root",
        by.get("commune").depth === 0 && by.get("venue").depth === 1 && by.get("room").depth === 2);
}

// ── the fold is GEOMETRIC, which is the whole reason for choosing it ───────
// An arithmetic mean would let a comfortable majority hide a member near their
// tip. AM–GM says the geometric one sits at or below it, and strictly below
// wherever the members disagree — so one strained place is visible on the map.
{
  const by = build([
    { id: "block" },
    { id: "a", parent: "block", desire: 0.25 },
    { id: "b", parent: "block", desire: 1 },
  ]);
  check("two leaves fold to their geometric mean",
        Math.abs(by.get("block").slack - 0.5) < 1e-12, ` (${by.get("block").slack})`);
  check("…which is strictly BELOW their arithmetic mean of 0.625",
        by.get("block").slack < 0.625);

  const hurt = build([
    { id: "r" }, { id: "x", parent: "r", desire: 1 }, { id: "y", parent: "r", desire: 1 },
    { id: "z", parent: "r", desire: 0.01 },
  ]).get("r").slack;
  check("so one member near zero drags the whole container down",
        hurt < 0.25, ` (two whole, one at 0.01 → ${hurt.toFixed(3)})`);
}

// ── a container that is ITSELF outside the aggregate takes its subtree out ──
// The same rule as the crate, read from the top rather than from a leaf: the
// walk starts AT the node, so a van's contents are not a place's members.
{
  const by = build([
    { id: "van", desire: null }, { id: "inside", parent: "van", desire: 0.01 },
  ]);
  check("a node that reads null takes everything under it out of the aggregate",
        by.get("van").slack === 1 && by.get("van").n === 0);
}

// ── degenerate readings do not poison the mean ─────────────────────────────
{
  const by = build([
    { id: "c" }, { id: "ok", parent: "c", desire: 0.5 }, { id: "zero", parent: "c", desire: 0 },
  ]);
  check("a zero reading is dropped rather than sending log to −∞", isFinite(by.get("c").slack));
  check("…and the container still counts it as a member", by.get("c").n === 2);
}

// ── point-in-polygon: which published boundary HOLDS a coordinate ──────────
{
  // a 10×10 square with a 2×2 hole at its centre
  const square = {
    type: "Polygon",
    coordinates: [
      [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]],
      [[4, 4], [6, 4], [6, 6], [4, 6], [4, 4]],
    ],
  };
  check("inside the outer ring holds", C.inGeometry(2, 2, square));
  check("outside does not", C.inGeometry(-1, 5, square) === false);
  check("a HOLE excludes — the ring that holds is not the only one that counts",
        C.inGeometry(5, 5, square) === false);
  check("a missing geometry holds nothing", C.inGeometry(5, 5, null) === false);

  const multi = {
    type: "MultiPolygon",
    coordinates: [
      [[[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]]],
      [[[20, 20], [21, 20], [21, 21], [20, 21], [20, 20]]],
    ],
  };
  check("a MultiPolygon holds in either of its parts, and not between them",
        C.inGeometry(0.5, 0.5, multi) && C.inGeometry(20.5, 20.5, multi) &&
        C.inGeometry(10, 10, multi) === false);

  const regions = [{ id: "shed-a", boundary: square }, { id: "shed-b", boundary: multi }];
  check("regionAt names the shed a farm sits in", C.regionAt(2, 2, regions) === "shed-a");
  check("…and null where no published boundary holds it", C.regionAt(50, 50, regions) === null);
  check("a region with no boundary is never the answer",
        C.regionAt(2, 2, [{ id: "hull-only" }, ...regions]) === "shed-a");
}


done();
