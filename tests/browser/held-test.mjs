// tests/browser/held-test.mjs — where a good is held, stock by stock
// (browser/app/held.js, from ui/app/held.ts).
//
// What is pinned: the stocks of a good are those that conform to it; each says where it is by its place's path; most held comes
// first; the sum is said in a line, with no sum across units.
//
// Run: node tests/browser/held-test.mjs

const H = await import("../../browser/app/held.js");

import { harness } from './assert.mjs';
const { check, done } = harness();

const places = [
  { id: "site", name: "commons", containedIn: null },
  { id: "canteen", name: "canteen", containedIn: "site" },
  { id: "pantry", name: "pantry", containedIn: "site" },
];
const stock = (id, spec, onhand, unit, location, expected = null) =>
  ({ id, name: id, spec, unit, onhand, location, code: "", expires: "", expiresKind: "", containedIn: "", mode: "", stage: "", state: "", custodian: "", emoji: "", expected });
const range = { low: 36, high: 42, flows: [{ id: "f", action: "consume", quantity: -6, when: "", proc: "cook" }] };
const stocks = [
  stock("greens", "veg", 42, "kg", "canteen", range),
  stock("roots", "veg", 138, "kg", "pantry"),
  stock("loaves", "bakery/loaf", 18, "", "canteen"),
  stock("tea", "tea", 6, "kg", ""),
  stock("", "veg", 9, "kg", "pantry"),
];

console.log("\n── the stocks of a good ──");
{
  const veg = H.heldOf("veg", stocks, places);
  check("the stocks that conform to the good, most held first", veg.map(h => h.id).join() === "roots,greens", veg.map(h => h.id).join());
  check("each says where it is by its place's path", veg[0].where === "commons › pantry" && veg[1].where === "commons › canteen", veg.map(h => h.where).join(" | "));
  check("…what the ledger reads and what the plan expects", veg[1].onhand === 42 && veg[1].expected === range && veg[0].expected === null);
  check("a stock with no id is no stock to count", !veg.some(h => h.id === ""));
  check("a good the books hold none of has none", H.heldOf("salmon", stocks, places).length === 0);
  check("a stock that names no place says none", H.heldOf("tea", stocks, places)[0].where === "");
}

console.log("\n── the sum, in a line ──");
{
  check("several places: the sum and how many", H.heldSummary(H.heldOf("veg", stocks, places)) === "the ledger holds 180 kg in 2 places", H.heldSummary(H.heldOf("veg", stocks, places)));
  check("one place: the sum and the place", H.heldSummary(H.heldOf("bakery/loaf", stocks, places)) === "the ledger holds 18 at canteen");
  check("one stock with no place", H.heldSummary(H.heldOf("tea", stocks, places)) === "the ledger holds 6 kg in one place");
  check("none held says nothing", H.heldSummary([]) === "");
  const mixed = [...H.heldOf("veg", stocks, places), { ...H.heldOf("tea", stocks, places)[0], unit: "box" }];
  check("stocks in different units have no one sum", H.heldSummary(mixed) === "the ledger holds it in 3 places", H.heldSummary(mixed));
}

done();
