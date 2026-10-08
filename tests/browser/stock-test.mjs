// tests/browser/stock-test.mjs — a thing on the books, read off the wire once
// (browser/app/stock.js, from ui/app/stock.ts).
//
// The inventory face, the capture sheet and the photo read take their fields
// of a stock from this one module. What is pinned here:
//
//   • a row's kebab-cased keys read into one typed shape, with an empty string
//     or zero where the wire left a field out;
//   • the name falls back to the spec, then the id;
//   • a list of rows keeps those that name themselves;
//   • the places table reads into the rows a path walks;
//   • a lot's date says which date it is, and a use-by lot perishes;
//   • the things inside a container are found at any depth, and a ring of
//     things each inside the next is walked once.
//
// Run: node tests/browser/stock-test.mjs

const { stockOf, stocksOf, placesOf, lotDate, perishes, within } = await import("../../browser/app/stock.js");

import { harness } from './assert.mjs';
const { check, done } = harness();

console.log("\n── a row ──");
{
  const s = stockOf({
    id: "bin/1/jam", name: "plum jam", "conforms-to": "jam", onhand: "12", unit: "each",
    location: "place:shelf", code: "K3M9QZ", expires: "2026-10-04T00:00:00Z", "expires-kind": "use-by",
    "contained-in": "bin/1", "distribution-mode": "communal", stage: "stored", state: "fresh", "custodian-name": "the commune",
  });
  check("the id and the name", s.id === "bin/1/jam" && s.name === "plum jam");
  check("the spec comes from conforms-to", s.spec === "jam");
  check("a quantity that rode as text reads as a number", s.onhand === 12);
  check("the place, the code and what it sits in", s.location === "place:shelf" && s.code === "K3M9QZ" && s.containedIn === "bin/1");
  check("the lot's date and which date", s.expires.startsWith("2026-10-04") && s.expiresKind === "use-by");
  check("the mode, stage, state and custodian", s.mode === "communal" && s.stage === "stored" && s.state === "fresh" && s.custodian === "the commune");

  const bare = stockOf({ id: "x" });
  check("a field the wire left out reads as empty", bare.unit === "" && bare.code === "" && bare.containedIn === "" && bare.location === "");
  check("…and a quantity as zero", bare.onhand === 0);
  check("a name falls back to the id", bare.name === "x");
  check("…after the spec", stockOf({ id: "x", spec: "rice" }).name === "rice");
  check("a quantity that is no number reads as zero", stockOf({ id: "x", onhand: "lots" }).onhand === 0);
  check("a null distribution mode reads as empty", stockOf({ id: "x", "distribution-mode": null }).mode === "");
  check("a row that is no object reads as none", stockOf(null) === null && stockOf("rice") === null);
}

console.log("\n── a list ──");
{
  const rows = stocksOf([{ id: "a", name: "A" }, { name: "no id" }, null, { id: "b" }]);
  check("the rows that name themselves are kept", rows.map(r => r.id).join() === "a,b");
  check("a reply that is no list holds none", stocksOf(undefined).length === 0 && stocksOf({}).length === 0);
}

console.log("\n── the places ──");
{
  const ps = placesOf([{ id: "p1", name: "Pantry", containedIn: "h1" }, { id: "h1", name: "House", containedIn: null }, { id: "p2" }]);
  check("each place reads with what it is inside", ps[0].containedIn === "h1" && ps[1].containedIn === null);
  check("a place with no name reads without one", ps[2].name === undefined);
  check("no table holds no places", placesOf(undefined).length === 0 && placesOf(null).length === 0);
}

console.log("\n── a lot's date ──");
{
  check("a use-by date", lotDate("2026-10-04T00:00:00Z", "use-by") === "use by 2026-10-04");
  check("a best-before date", lotDate("2026-10-04", "best-before") === "best before 2026-10-04");
  check("a date that says not which", lotDate("2026-10-04", "") === "date 2026-10-04");
  check("no date says nothing", lotDate("", "use-by") === "" && lotDate(undefined, undefined) === "");
  check("a use-by lot perishes", perishes({ expiresKind: "use-by" }));
  check("a best-before lot keeps", !perishes({ expiresKind: "best-before" }) && !perishes({ expiresKind: "" }));
}

console.log("\n── inside a container ──");
{
  const all = stocksOf([
    { id: "bin" }, { id: "jam", "contained-in": "bin" }, { id: "box", "contained-in": "bin" },
    { id: "lids", "contained-in": "box" }, { id: "rice" }, { id: "stray", "contained-in": "elsewhere" },
  ]);
  check("what is in a container at any depth", within("bin", all).map(s => s.id).sort().join() === "box,jam,lids");
  check("a container holds nothing of what is beside it", within("rice", all).length === 0);
  const ring = stocksOf([{ id: "a", "contained-in": "b" }, { id: "b", "contained-in": "a" }, { id: "c" }]);
  check("a ring of things is walked once", within("c", ring).length === 0 && within("a", ring).length === 1);
}

done();
