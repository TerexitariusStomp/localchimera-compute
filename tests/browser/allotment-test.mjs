// tests/browser/allotment-test.mjs — the week's photo reads, as a face says them
// (browser/app/allotment.js, from ui/app/allotment.ts).
//
// What is pinned: the allotment door's reply reads into figures (a refusal or an
// unreadable answer is none); a photograph can be read when a model reads and a
// read is left; the line says what is left of the week, when it opens again, and
// why no read is to be had when none is.
//
// Run: node tests/browser/allotment-test.mjs

const A = await import("../../browser/app/allotment.js");

import { harness } from './assert.mjs';
const { check, done } = harness();

const reply = (o) => JSON.stringify({ remaining: 5, perWeek: 21, opens: "2026-10-05T00:00:00Z", sees: true, ...o });

console.log("\n── reading the reply ──");
{
  const a = A.readsOf(reply({}));
  check("a reply reads into figures", a.remaining === 5 && a.perWeek === 21 && a.opens.startsWith("2026-10-05") && a.sees === true);
  check("a reply that says no model reads says so", A.readsOf(reply({ sees: false })).sees === false);
  check("a refusal is none", A.readsOf("err:sign in first") === null);
  check("an unreadable answer is none", A.readsOf("{oops") === null && A.readsOf(undefined) === null);
  check("a figure the reply leaves out is zero", A.readsOf(JSON.stringify({ sees: true })).remaining === 0);
}

console.log("\n── asking ──");
{
  check("no door is none", await A.askReads(undefined) === null);
  check("a door that answers is read", (await A.askReads(() => Promise.resolve(reply({ remaining: 2 })))).remaining === 2);
  check("a door that throws is none", await A.askReads(() => Promise.reject(new Error("x"))) === null);
}

console.log("\n── what it says ──");
{
  check("a read can be had when a model reads and one is left", A.canRead(A.readsOf(reply({}))));
  check("…not when none is left", !A.canRead(A.readsOf(reply({ remaining: 0 }))));
  check("…nor when no model reads", !A.canRead(A.readsOf(reply({ sees: false }))));
  check("…nor when nothing is known", !A.canRead(null));
  const line = A.readsLine(A.readsOf(reply({})));
  check("the line says what is left, of how many, and when the week opens", /5 of 21 photo reads left this week/.test(line) && /new reads 2026-10-05/.test(line), line);
  check("with no model the line says a photograph is kept as evidence", /no vision model/.test(A.readsLine(A.readsOf(reply({ sees: false })))) && /evidence/.test(A.readsLine(A.readsOf(reply({ sees: false })))));
  check("with nothing known it says nothing", A.readsLine(null) === "");
  check("a week with none left still says how it stands", /0 of 21/.test(A.readsLine(A.readsOf(reply({ remaining: 0 })))));
}

check("a read can go when a model reads and a read is left", A.whyNotRead({ remaining: 3, perWeek: 21, opens: "", sees: true }) === "");
check("signed out, a read says to sign in", /sign in/.test(A.whyNotRead(null)));
check("with no model it says so", /no vision model/.test(A.whyNotRead({ remaining: 3, perWeek: 21, opens: "", sees: false })));
check("with the week spent it says when the reads return", /spent · new reads 2026-10-05/.test(A.whyNotRead({ remaining: 0, perWeek: 21, opens: "2026-10-05T00:00:00Z", sees: true })));
check("a planned count's read is not stopped by the week being spent", A.whyNotRead({ remaining: 0, perWeek: 21, opens: "", sees: true }, true) === "");

done();
