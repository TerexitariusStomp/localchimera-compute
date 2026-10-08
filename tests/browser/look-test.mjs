// tests/browser/look-test.mjs — a picture, read into rows
// (browser/app/look.js, from ui/app/look.ts).
//
// The model's answer is untrusted text. What is pinned is what is made of it:
//
//   • a row that does not conform is named, in words the model is asked again
//     with, and is left out of what the person sees;
//   • a row is read as a count of a thing held when its spec or its name says
//     so, a near name included, and as a first sighting otherwise;
//   • two rows that are counts of one thing are one row;
//   • a row counted in a unit other than the one its match is held in says so;
//   • a correction changes what it names and leaves the rest;
//   • the model is told the shape, the known specs and what the ledger holds.
//
// Run: node tests/browser/look-test.mjs

const { lookSystem, lookUser, fault, lookCheck, matchOf, rowsOf, corrected, landingOf, sightingNote, meansId } =
  await import("../../browser/app/look.js");

import { harness } from './assert.mjs';
const { check, done } = harness();

const held = [
  { id: "bin/1/jam", name: "plum jam", spec: "jam", unit: "each", onhand: 12 },
  { id: "bin/1/milk", name: "oat milk", spec: "oat-milk", unit: "l", onhand: 6 },
  { id: "rice", name: "basmati rice", spec: "rice", unit: "kg", onhand: 40 },
];
const ctx = { place: "Mill House › Pantry", container: "the jar bin", held };
const specs = ["jam", "oat-milk", "rice", "flour"];

console.log("\n── what the model is told ──");
{
  const sys = lookSystem(specs);
  check("the shape it answers in", sys.includes('{"rows":[') && sys.includes('"qty":<number>'));
  check("the specs the library knows", sys.includes('"flour"') && sys.includes("EXACT names"));
  check("to count what it sees, each thing once", /Count what you can see/.test(sys) && /count each thing once/.test(sys));
  check("what to answer when it recognises nothing", sys.includes('{"rows":[]}'));
  check("with no library, no list of specs", !lookSystem([]).includes("Known specs"));
  const user = lookUser(ctx);
  check("where the picture was taken", user.includes("Mill House › Pantry"));
  check("the container in view", user.includes("the jar bin"));
  check("what the ledger holds there, by name and unit", user.includes("plum jam") && user.includes('"unit":"kg"'));
  check("what is on hand stays with the sheet: the read is blind to the ledger's figures",
        !/"onhand"/.test(user) && !/\b40\b/.test(user) && !/\b12\b/.test(user), user);
  check("a scene the sheet knows nothing of is still asked about",
        lookUser({ place: "", container: "", held: [] }) === "the photographs follow.");
}

console.log("\n── a row that does not conform ──");
{
  check("a row that says what and how much conforms", fault({ name: "jam", qty: 3, unit: "each" }) === null);
  check("a row of nothing left conforms", fault({ name: "jam", qty: 0 }) === null);
  check("a row must say what the thing is", /name/.test(fault({ qty: 3 }) || ""));
  check("…in words, not in space", /name/.test(fault({ name: "  ", qty: 3 }) || ""));
  check("a quantity is a number", /qty/.test(fault({ name: "jam", qty: "some" }) || ""));
  check("…zero or more", /qty/.test(fault({ name: "jam", qty: -1 }) || ""));
  check("a unit is one the sheet counts in", /unit/.test(fault({ name: "jam", qty: 1, unit: "handful" }) || ""));
  check("a date is a date", /expires/.test(fault({ name: "milk", qty: 1, expires: "next week" }) || ""));
  check("a date's kind is one of the two", /expiresKind/.test(fault({ name: "milk", qty: 1, expires: "2026-10-05", expiresKind: "sell-by" }) || ""));
  check("a kind is stated with its date", /no date/.test(fault({ name: "milk", qty: 1, expiresKind: "use-by" }) || ""));

  check("an answer whose rows all conform has no faults",
        lookCheck({ rows: [{ name: "jam", qty: 3, unit: "each" }] }) === null);
  check("an answer of no rows conforms: the picture showed nothing", lookCheck({ rows: [] }) === null);
  check("an answer with no rows field is told so", /"rows" must be an array/.test(lookCheck({}) || ""));
  const two = lookCheck({ rows: [{ name: "jam", qty: 3 }, { qty: 2 }, "jar", { name: "x", qty: -4 }] }) || "";
  check("each fault names its row", /rows\[1\]/.test(two) && /rows\[2\]/.test(two) && /rows\[3\]/.test(two) && !/rows\[0\]/.test(two), two);
  check("more rows than a picture holds kinds of thing is told so",
        /at most 40/.test(lookCheck({ rows: Array.from({ length: 41 }, (_, i) => ({ name: `t${i}`, qty: 1 })) }) || ""));
}

console.log("\n── a row, matched against what is held ──");
{
  check("by its spec", matchOf({ name: "a jar of something", spec: "jam" }, held)?.id === "bin/1/jam");
  check("by its name", matchOf({ name: "Plum Jam", spec: "plum jam" }, held)?.id === "bin/1/jam");
  check("by a near name", matchOf({ name: "basmati ricee", spec: "basmati ricee" }, held)?.id === "rice");
  check("a thing unlike anything held is a first sighting",
        matchOf({ name: "cordless drill", spec: "cordless drill" }, held) === undefined);
  check("with nothing held, everything is a first sighting",
        matchOf({ name: "plum jam", spec: "jam" }, []) === undefined);
}

console.log("\n── the rows of an answer ──");
{
  const rows = rowsOf({ rows: [
    { name: "plum jam", spec: "jam", qty: 11, unit: "each", lot: "L-7", expires: "2027-01-01", expiresKind: "best-before" },
    { name: "oat milk", spec: "oat-milk", qty: 5, unit: "each" },
    { name: "cordless drill", spec: "cordless drill", qty: 1, unit: "each" },
    { name: "", qty: 2 },
    { name: "rice", qty: "lots" },
    "not a row",
  ] }, ctx, specs);
  check("the rows that conform are kept, and only those", rows.length === 3, rows.map(r => r.name).join(", "));
  const jam = rows[0], milk = rows[1], drill = rows[2];
  check("a row of a thing held is a count of it", jam.match?.id === "bin/1/jam" && jam.qty === 11);
  check("…and carries what its label states", jam.lot === "L-7" && jam.expires === "2027-01-01" && jam.expiresKind === "best-before");
  check("a row counted in another unit than its match is held in says so",
        milk.match?.id === "bin/1/milk" && milk.unitDiffers === true);
  check("…and a row in its match's unit does not", jam.unitDiffers === false);
  check("a thing not held is a first sighting", drill.match === undefined && drill.unitDiffers === false);
  check("a spec the library knows is marked known", jam.known === true);
  check("…and one it does not is not", drill.known === false);

  const twice = rowsOf({ rows: [
    { name: "plum jam", spec: "jam", qty: 7, unit: "each" },
    { name: "jam jars", spec: "jam", qty: 4, unit: "each" },
    { name: "plum jam", spec: "jam", qty: 2, unit: "kg" },
  ] }, ctx, specs);
  check("two rows that are counts of one thing are one row", twice.length === 1);
  check("…their quantities summed", twice[0].qty === 11, String(twice[0].qty));
  check("…and a third in another unit left out of the sum", twice[0].unit === "each");

  check("a row with no unit takes its match's", rowsOf({ rows: [{ name: "rice", spec: "rice", qty: 38 }] }, ctx, specs)[0].unit === "kg");
  check("a first sighting with no unit is counted in each", rowsOf({ rows: [{ name: "kettle", qty: 1 }] }, ctx, specs)[0].unit === "each");
  check("a row with no spec is known by its name", rowsOf({ rows: [{ name: "kettle", qty: 1 }] }, ctx, specs)[0].spec === "kettle");
  check("an answer of no rows gives none", rowsOf({ rows: [] }, ctx, specs).length === 0);
  check("no answer gives none", rowsOf(null, ctx, specs).length === 0);
  check("an answer with no rows field gives none", rowsOf({}, ctx, specs).length === 0);
  const many = rowsOf({ rows: Array.from({ length: 60 }, (_, i) => ({ name: `thing number ${i} zz${i}`, qty: 1 })) },
                      { ...ctx, held: [] }, specs);
  check("no more than forty rows reach the person", many.length <= 40, String(many.length));
}

console.log("\n── a correction ──");
{
  const [row] = rowsOf({ rows: [{ name: "plum jam", spec: "jam", qty: 11, unit: "each" }] }, ctx, specs);
  const q = corrected(row, { qty: 12 }, held, specs);
  check("a figure corrected is the figure that stands", q.qty === 12 && q.name === "plum jam" && q.match?.id === "bin/1/jam");
  check("a figure below nothing leaves the row's own", corrected(row, { qty: -2 }, held, specs).qty === 11);
  check("a figure that is no number leaves the row's own", corrected(row, { qty: NaN }, held, specs).qty === 11);
  const renamed = corrected(row, { name: "basmati rice" }, held, specs);
  check("a name corrected is matched again", renamed.match?.id === "rice" && renamed.spec === "rice");
  check("…and says so when the unit is no longer its match's", renamed.unitDiffers === true);
  const fresh = corrected(row, { name: "cordless drill" }, held, specs);
  check("a name corrected to a thing not held is a first sighting", fresh.match === undefined && fresh.spec === "cordless drill" && !fresh.known);
  const unit = corrected(rowsOf({ rows: [{ name: "oat milk", spec: "oat-milk", qty: 5, unit: "each" }] }, ctx, specs)[0],
                         { unit: "l" }, held, specs);
  check("a unit corrected to its match's no longer differs", unit.unitDiffers === false && unit.unit === "l");
  check("a correction of nothing leaves the row as it was",
        JSON.stringify(corrected(row, {}, held, specs)) === JSON.stringify(row));
  check("the row corrected is a new row: the one given is left as it was", row.qty === 11);
}

console.log("\n── where a confirmed row lands ──");
{
  const [jam] = rowsOf({ rows: [{ name: "plum jam", spec: "jam", qty: 9, unit: "each" }] }, ctx, specs);
  const l = landingOf(jam);
  check("a row that matches a thing held is a count of it", l.door === "count" && l.resource === "bin/1/jam");
  check("…of the figure and unit it shows", l.qty === 9 && l.unit === "each");

  const [lamp] = rowsOf({ rows: [{ name: "desk lamp", spec: "lamp", qty: 1, unit: "each", lot: "L7", expires: "2027-01-02", expiresKind: "best-before" }] }, ctx, specs);
  const f = landingOf(lamp);
  check("a row that matches nothing is a first sighting, declared", f.door === "declare" && f.spec === "lamp" && f.name === "desk lamp");
  check("…carrying what a label stated of its lot", /seen in a photo/.test(f.note) && /lot L7/.test(f.note) && /best before 2027-01-02/.test(f.note), f.note);
  check("a sighting with no label states only that a picture showed it", sightingNote({ ...lamp, lot: "", expires: "", expiresKind: "" }) === "seen in a photo");
  check("a person's own stock of a spec has a deterministic id", meansId("EAID", "lamp") === "means:EAID:lamp");
}

console.log("\n── the walk-up count: marks, the far-off rule, the shortfall ──");
{
  const L = await import("../../browser/app/look.js");
  const C = await import("../../browser/app/count.js");   // the rule a figure answers to is count.ts's, for a typed count as for a row
  const flows = [{ id: "bake", action: "consume", quantity: -3, when: "", proc: "bake" }];
  const bread = { id: "b", name: "bread", spec: "bread", unit: "each", onhand: 18, expected: { low: 12, high: 15, flows } };
  const tea = { id: "t", name: "tea", spec: "tea", unit: "kg", onhand: 6 };
  const row = (h, qty, extra = {}) => ({ name: h?.name ?? "oil", spec: h?.spec ?? "oil", qty, unit: h?.unit ?? "each", lot: "", expires: "", expiresKind: "", known: true, match: h, unitDiffers: false, ...extra });
  check("the ledger's own figure agrees", L.markOf(row(tea, 6)) === "agrees" && L.markOf(row(bread, 18)) === "agrees");
  check("a figure inside the plan's range is within", L.markOf(row(bread, 13)) === "within" && L.markOf(row(bread, 12)) === "within");
  check("under and over the plan's range", L.markOf(row(bread, 4)) === "under" && L.markOf(row(bread, 16)) === "over");
  check("with no plan, the ledger's figure is the reference", L.markOf(row(tea, 5)) === "under" && L.markOf(row(tea, 7)) === "over");
  check("a row with no match is a first sighting", L.markOf(row(undefined, 3)) === "new");
  check("a row in another unit has nothing to compare", L.markOf(row(tea, 6, { unitDiffers: true })) === "unsure");
  check("what agrees or is within looks right; the rest waits", L.looksRight(row(tea, 6)) && L.looksRight(row(bread, 13)) && !L.looksRight(row(bread, 4)) && !L.looksRight(row(undefined, 3)) && !L.looksRight(row(tea, 6, { unitDiffers: true })));
  check("far off: 4 where 12–15 were expected", C.farOff(4, bread) === true);
  check("…and 40 where 12–15 were expected", C.farOff(40, bread) === true);
  check("near the range is not far off", C.farOff(11, bread) === false && C.farOff(13, bread) === false && C.farOff(17, bread) === false);
  check("with no plan the ledger is the reference", C.farOff(2, tea) === true && C.farOff(5, tea) === false);
  check("one unit is never far off, however small the stock", C.farOff(0, { ...tea, onhand: 1 }) === false && C.farOff(0, { ...tea, onhand: 3 }) === true);
  check("the shortfall is the plan's low end less the figure", C.shortfall(4, bread) === 8);
  check("…the ledger's figure where no plan bears", C.shortfall(4, tea) === 2);
  check("…and nothing when the figure is no shorter", C.shortfall(20, bread) === 0);
  const z = L.zeroRow(bread, ["bread"]);
  check("a thing held and absent from the picture is a count of nothing", z.qty === 0 && z.match === bread && z.unit === "each" && z.known && L.landingOf(z).door === "count");
}

done();
