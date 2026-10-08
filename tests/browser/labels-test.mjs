// tests/browser/labels-test.mjs — a label, and the three prints
// (browser/app/labels.js, from ui/app/labels.ts).
//
// What is pinned:
//
//   • a code is read the way the gateway reads it: upper case, a typed I or L
//     as 1, an O as 0, spaces and dashes dropped;
//   • a label's symbol carries the code and nothing of the thing;
//   • what a camera read is a label when it is a label's own text, a link
//     carrying `label=`, or a bare code, and is nothing otherwise;
//   • each print holds one symbol per thing and writes names as text, so a
//     name with markup in it prints as the name;
//   • a blind checklist leaves what the ledger reads off the page.
//
// Run: node tests/browser/labels-test.mjs

const { normalCode, labelText, codeIn, spoken, labelSheet, nameCards, checklist } =
  await import("../../browser/app/labels.js");
const { LABEL_LENGTH } = await import("../../browser/app/count-catalogue.js");
const { encode } = await import("../../browser/app/qr.js");

import { harness } from './assert.mjs';
const { check, done } = harness();
const count = (s, re) => (s.match(re) || []).length;

console.log("\n── a code, as the books hold it ──");
{
  check("a code is six characters", LABEL_LENGTH === 6);
  check("lower case reads as upper", normalCode("a1b2c3") === "A1B2C3");
  check("a typed I reads as 1", normalCode("AIB2C3") === "A1B2C3");
  check("a typed L reads as 1", normalCode("alb2c3") === "A1B2C3");
  check("a typed O reads as 0", normalCode("A1BOC3") === "A1B0C3");
  check("spaces and a dash drop out", normalCode("A1B - 2C3") === "A1B2C3");
  check("a U, which the alphabet leaves out, drops out", normalCode("AUB") === "AB");
  check("a code is read aloud in two groups", spoken("a1b2c3") === "A1B 2C3");
}

console.log("\n── what a label carries ──");
{
  check("the symbol carries the code under the scheme", labelText("a1b2c3") === "playnet:A1B2C3");
  check("…which is fourteen bytes, a version 1 symbol", encode(labelText("A1B2C3")).version === 1);
}

console.log("\n── what a camera read ──");
{
  check("a label's own text", codeIn("playnet:A1B2C3") === "A1B2C3");
  check("…whatever the case of the scheme", codeIn("PLAYNET:a1b2c3") === "A1B2C3");
  check("a link carrying the label", codeIn("https://example.org/app.html?face=time&label=A1B2C3") === "A1B2C3");
  check("a bare code", codeIn("A1B2C3") === "A1B2C3");
  check("a bare code typed the way it is read aloud", codeIn(" a1b 2c3 ") === "A1B2C3");
  check("a bare code with its look-alikes", codeIn("AIBOCL") === "A1B0C1");
  check("a shop's barcode is no label", codeIn("4006381333931") === null);
  check("a web address is no label", codeIn("https://example.org/") === null);
  check("a code too short is no label", codeIn("playnet:A1B2") === null);
  check("a sentence is no label", codeIn("the jar bin") === null);
  check("nothing is no label", codeIn("") === null);
}

const things = [
  { code: "A1B2C3", name: "the jar bin", emoji: "🫙", where: "pantry · shelf 1" },
  { code: "Z9Y8X7", name: "<b>tins</b> & lids", where: "cellar" },
];

console.log("\n── the label sheet ──");
{
  const page = labelSheet(things);
  check("one symbol per thing", count(page, /<svg /g) === 2);
  check("each code printed as it is read aloud", page.includes("A1B 2C3") && page.includes("Z9Y 8X7"));
  check("a label says nothing of the thing", !page.includes("jar") && !page.includes("pantry") && !page.includes("tins"));
  check("it is a whole page", page.startsWith("<!doctype html>") && page.endsWith("</html>"));
}

console.log("\n── the name cards ──");
{
  const page = nameCards(things);
  check("one symbol per thing", count(page, /<svg /g) === 2);
  check("the name is on the card", page.includes("the jar bin"));
  check("…and where it is held", page.includes("pantry · shelf 1"));
  check("a name with markup in it prints as the name",
        page.includes("&lt;b&gt;tins&lt;/b&gt; &amp; lids") && !page.includes("<b>tins</b>"));
}

console.log("\n── the count checklist ──");
{
  const lines = [
    { code: "J4M001", name: "plum jam", onhand: 12, unit: "each" },
    { code: "M11K00", name: "milk", onhand: 6.5, unit: "l", expires: "2026-10-05T00:00:00Z", expiresKind: "use-by" },
    { code: "B34N00", name: "beans", onhand: 3, unit: "kg", expires: "2027-01-01T00:00:00Z", expiresKind: "best-before" },
  ];
  const page = checklist(things[0], lines, { day: "28 September 2026", commitment: "cmt-count-7" });
  check("the container heads the page, with its symbol", page.includes("the jar bin") && count(page, /<svg /g) === 1);
  check("a line for each thing in it", ["plum jam", "milk", "beans"].every(n => page.includes(n)));
  check("what the ledger reads is beside each", />12</.test(page) && />6\.5</.test(page) && />3</.test(page));
  check("a blank for the figure found on every line, and three spare", count(page, /class="b"/g) === 6);
  check("a use-by date reads as one", page.includes("use by 2026-10-05"));
  check("a best-before date reads as one", page.includes("best before 2027-01-01"));
  check("the commitment and the day are on the page", page.includes("cmt-count-7") && page.includes("28 September 2026"));
  check("whoever counts signs", page.includes("counted by"));

  const blind = checklist(things[0], lines, { blind: true });
  check("a blind count says it is one", blind.includes("blind count"));
  check("…and leaves what the ledger reads off the page",
        !/>12</.test(blind) && !/>6\.5</.test(blind) && !blind.includes(">ledger<"));
  check("…with the blanks still there", count(blind, /class="b"/g) === 6);

  const bare = checklist(things[0], []);
  check("an empty container's sheet asks for what is found", bare.includes("write in what is found"));
}

done();
