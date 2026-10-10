// tests/browser/rest-test.mjs — SNIRT as the browser reads it
// (browser/app/rest.js, from ui/app/rest.ts)
//
// rest.ts is a PORT of knowledge/rest-catalogue.scm's base, person layer and
// labour increment, so nothing but a test holds the two to the same figures.
// These pin the claims tests/knowledge/test-rest-catalogue.scm
// pins on the Scheme side.
//
// Run: node tests/browser/rest-test.mjs

const R = await import("../../browser/app/rest.js");

import { harness } from './assert.mjs';
const { check, done } = harness();
const near = (a, b) => Math.abs(a - b) < 1e-9;

console.log("\n── the base and its layers ──");
check("an adult's SNIRT is 8 h of sleep and 2 h of meals and washing: 10 h", near(R.snirtHours({ age: 30 }), 10));
check("sleep follows the age bands: an infant 14, a school child 10.5, a teen 9, an elder 7.5",
  near(R.sleepHours({ age: 0 }), 14) && near(R.sleepHours({ age: 9 }), 10.5) && near(R.sleepHours({ age: 15 }), 9) && near(R.sleepHours({ age: 70 }), 7.5));
check("age 18 reads the adult band, age 65 the elder's", near(R.sleepHours({ age: 18 }), 8) && near(R.sleepHours({ age: 65 }), 7.5));
check("pregnancy adds an hour of sleep", near(R.sleepHours({ age: 30, pregnant: true }), 9));
check("a stated sleep replaces the band, kept inside 4–14 h",
  near(R.sleepHours({ age: 30, sleepHours: 6 }), 6) && near(R.sleepHours({ age: 30, sleepHours: 1 }), 4) && near(R.sleepHours({ age: 30, sleepHours: 20 }), 14));
check("the labour increment rises with hours and effort: 8 h adds 0.8 h, effort 2 adds 1.6 h",
  near(R.snirtHours({ age: 30, labour: 8 }), 10.8) && near(R.snirtHours({ age: 30, labour: 8, effort: 2 }), 11.6));
check("the ratified standard may only raise: 1.25 lifts the base, below 1 reads as 1",
  near(R.snirtHours({ age: 30, restStandard: 1.25 }), 12.5) && near(R.snirtHours({ age: 30, restStandard: 0.5 }), 10));

console.log("\n── a stated sleep span ──");
check("a span states its length, wrapping midnight: 23:00–07:00 is 8 h, 08:00–16:00 is 8 h, 22:30–06:00 is 7.5 h",
  near(R.spanHours("23:00", "07:00"), 8) && near(R.spanHours("08:00", "16:00"), 8) && near(R.spanHours("22:30", "06:00"), 7.5));
check("a span that starts and ends together is nothing", near(R.spanHours("07:00", "07:00"), 0));
check("a stated span is the sleep the base reads: 6 h of sleep and 2 h of meals is 8 h", near(R.snirtHours({ age: 30, sleepHours: R.spanHours("00:00", "06:00") }), 8));

console.log("\n── the tags a person's time becomes ──");
check("a sleep span and away days are written as the schedule's parser reads them",
  R.restTags([{ from: "23:00", to: "07:00" }], [{ from: "2026-09-28", to: "2026-09-30", kind: "sick" }, { from: "2026-10-05", to: "2026-10-05", kind: "rest" }]).join()
    === "sleep:23:00-07:00,away:2026-09-28..2026-09-30:sick,away:2026-10-05..2026-10-05:rest");
check("several sleep spans stack, in order — a night-shift split, each its own weekday list",
  R.restTags([{ from: "23:00", to: "07:00", days: ["monday", "tuesday"] }, { from: "14:00", to: "22:00", days: ["saturday", "sunday"] }]).join()
    === "sleep:23:00-07:00:monday,tuesday,sleep:14:00-22:00:saturday,sunday");
check("a span with one end, a time that is no time, an unknown weekday, or nothing stated writes no sleep tag",
  R.restTags([{ from: "23:00", to: undefined }]).length === 0 && R.restTags([{ from: "25:00", to: "07:00" }]).length === 0
    && R.restTags([{ from: "23:00", to: "07:00", days: ["funday"] }]).length === 0 && R.restTags().length === 0);
check("an away span that runs backwards, is no date, or names another kind writes nothing",
  R.restTags([], [{ from: "2026-09-30", to: "2026-09-28", kind: "sick" }, { from: "soon", to: "later", kind: "sick" }, { from: "2026-09-28", to: "2026-09-29", kind: "holiday" }]).length === 0);
check("the three kinds read alike: ill, resting and away all become away tags",
  R.AWAY_KINDS.map(k => k.id).join() === "sick,rest,leave" && R.AWAY_KINDS.every(k => R.isAway({ from: "2026-09-28", to: "2026-09-28", kind: k.id })));
check("sleepSpansHours sums every stated span — a night-shift split and a biphasic nap both count; undefined when none is stated",
  near(R.sleepSpansHours([{ from: "23:00", to: "05:00" }, { from: "14:00", to: "15:30" }]), 7.5)
    && R.sleepSpansHours([]) === undefined);
check("the seven weekdays, and nothing else, are a valid restriction",
  R.WEEKDAYS.length === 7 && R.isSleepSpan({ from: "23:00", to: "07:00", days: ["monday"] }) && !R.isSleepSpan({ from: "23:00", to: "07:00", days: ["funday"] }));

console.log("\n── disposable time and the offer ──");
check("an adult has 14 h a day, 98 h over seven days", near(R.disposableHours({ age: 30 }), 14) && near(R.disposableHours({ age: 30 }, 7), 98));
check("an offer of 12 h stands; 16 h is kept to 14", near(R.reserveOffer(12, { age: 30 }), 12) && near(R.reserveOffer(16, { age: 30 }), 14));
check("heavy labour shrinks D: ten hours worked leaves 13", near(R.disposableHours({ age: 30, labour: 10 }), 13));

done();
