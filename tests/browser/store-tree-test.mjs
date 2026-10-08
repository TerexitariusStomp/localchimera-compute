// tests/browser/store-tree-test.mjs — a store as it is arranged
// (browser/app/store-tree.js, from ui/app/store-tree.ts).
//
// What is pinned:
//
//   • a place's path reads from the outermost place inward;
//   • an id the table does not hold reads as itself;
//   • things are read container first, then what is in it, a level deeper, in
//     the order given among siblings;
//   • every thing given is read exactly once, whatever the list says of what
//     is inside what.
//
// Run: node tests/browser/store-tree-test.mjs

const { placePath, nest } = await import("../../browser/app/store-tree.js");

import { harness } from './assert.mjs';
const { check, done } = harness();

console.log("\n── a place's path ──");
{
  const places = [
    { id: "site", name: "Mill House" },
    { id: "site/pantry", name: "Pantry", containedIn: "site" },
    { id: "site/pantry/shelf-1", name: "Shelf 1", containedIn: "site/pantry" },
    { id: "loop-a", name: "A", containedIn: "loop-b" },
    { id: "loop-b", name: "B", containedIn: "loop-a" },
    { id: "orphan", name: "Shed", containedIn: "gone" },
  ];
  check("three levels read from the outside in",
        placePath("site/pantry/shelf-1", places) === "Mill House › Pantry › Shelf 1",
        placePath("site/pantry/shelf-1", places));
  check("a place inside none is its own name", placePath("site", places) === "Mill House");
  check("an id the table does not hold reads as itself", placePath("elsewhere", places) === "elsewhere");
  check("a place inside one the table does not hold names that one by its id",
        placePath("orphan", places) === "gone › Shed", placePath("orphan", places));
  check("no place reads as nothing", placePath("", places) === "" && placePath(null, places) === "");
  check("two places each inside the other are walked once",
        placePath("loop-a", places) === "B › A", placePath("loop-a", places));
}

console.log("\n── things in a store ──");
{
  const rows = [
    { id: "jam", containedIn: "bin-1" },
    { id: "bin-1" },
    { id: "rice" },
    { id: "lids", containedIn: "box" },
    { id: "box", containedIn: "bin-1" },
    { id: "bin-2" },
    { id: "stray", containedIn: "not-here" },
  ];
  const read = nest(rows);
  const order = read.map(n => `${"·".repeat(n.depth)}${n.row.id}`).join(" ");
  check("a container, then what is in it, a level deeper",
        order === "bin-1 ·jam ·box ··lids rice bin-2 stray", order);
  check("a container says how many things sit in it",
        read.find(n => n.row.id === "bin-1").holds === 2 && read.find(n => n.row.id === "box").holds === 1);
  check("a thing holding nothing says so", read.find(n => n.row.id === "rice").holds === 0);
  check("a thing inside something the list does not hold stands at the top",
        read.find(n => n.row.id === "stray").depth === 0);
  check("every thing is read exactly once",
        read.length === rows.length && new Set(read.map(n => n.row.id)).size === rows.length);

  const ring = nest([{ id: "a", containedIn: "b" }, { id: "b", containedIn: "a" }, { id: "c" }]);
  check("a ring of things each inside the next is still read, once each",
        ring.length === 3 && new Set(ring.map(n => n.row.id)).size === 3,
        ring.map(n => n.row.id).join(" "));
  check("a thing said to be inside itself stands at the top",
        nest([{ id: "x", containedIn: "x" }])[0].depth === 0);
  check("things with no id are read as they come",
        nest([{}, {}]).length === 2);
  check("an empty store reads as empty", nest([]).length === 0);
}

done();
