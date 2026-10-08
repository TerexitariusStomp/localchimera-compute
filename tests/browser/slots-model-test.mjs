// tests/browser/slots-model-test.mjs — the slots model's formatters and mode
// readings, pure (app/slots/model.ts runs the same under node as in the page).
//
//   MODES      an arc's time/day/month/week read back as the table's named
//              entry that matches, "custom" when none does, "all" for an
//              unset tier — the editors' selects and the summaries agree
//   SUMMARIES  fmtArcs reads an arc as one line; the day set as a word when
//              DAY_MODES names it, the days' own letters otherwise
//   CATALOGUE  knownSpecs and knownEmoji are projections of knownSpecRows —
//              every reader of the dial's specs sees the same catalogue
//
// Run: node tests/browser/slots-model-test.mjs
const M = await import("../../browser/app/slots/model.js");

import { harness } from './assert.mjs';
const { check, done } = harness();

console.log("modes");
const biz = { start: "09:00", end: "17:00", days: [...M.WEEKDAYS] };
check("business hours on weekdays read as their named modes",
      M.timeModeOf(biz) === "business" && M.dayModeOf(biz) === "weekdays");
check("an unmatched time is custom", M.timeModeOf({ ...biz, start: "09:30" }) === "custom");
check("days match as a SET, any order", M.dayModeOf({ ...biz, days: [...M.WEEKDAYS].reverse() }) === "weekdays");
check("an unset tier is all", M.monthModeOf(biz) === "all" && M.weekModeOf(biz) === "all");
check("a set tier matches by its numbers", M.monthModeOf({ ...biz, months: [8, 6, 7] }) === "summer"
      && M.weekModeOf({ ...biz, weeks: [3, 1] }) === "1st_3rd");
check("a set tier nothing names is custom", M.monthModeOf({ ...biz, months: [2, 3] }) === "custom");

console.log("summaries");
check("no arcs: anytime", M.fmtArcs([]) === "anytime" && M.fmtArcs(null) === "anytime");
check("weekdays as a word", M.fmtArc(biz) === "weekdays 09:00–17:00", M.fmtArc(biz));
check("every day / weekend as words", /^every day /.test(M.fmtArc({ ...biz, days: [...M.DAYS] }))
      && /^weekend /.test(M.fmtArc({ ...biz, days: [...M.WEEKEND] })));
check("an unnamed set as its letters", M.fmtArc({ ...biz, days: ["monday", "wednesday"] }) === "mon wed 09:00–17:00",
      M.fmtArc({ ...biz, days: ["monday", "wednesday"] }));
check("a month run reads as a span, a scatter as a list",
      /^Jun–Aug · /.test(M.fmtArc({ ...biz, months: [6, 7, 8] })) && /^Jan, Mar · /.test(M.fmtArc({ ...biz, months: [1, 3] })));
check("a week tier names the ordinals", /^1st, 3rd wk · /.test(M.fmtArc({ ...biz, weeks: [1, 3] })));
check("fmtWhere names the place, falls back to the id, reads empty as anywhere",
      M.fmtWhere("p1", [{ id: "p1", name: "the mill" }]) === "the mill" && M.fmtWhere("p9", []) === "p9" && M.fmtWhere("", []) === "anywhere");

console.log("catalogue");
const EXT = { inventory: { specs: [{ id: "spec-flour", name: "flour", emoji: "🌾", categories: ["nourishment"] },
                                   { id: "spec-bike", name: "bike repair", categories: [] }] } };
const PLAN = () => ({ needs: [{ id: "nourishment/meals", label: "meals", emoji: "🍲" }, { id: "spec-flour", label: "FLOUR AGAIN" }] });
const rows = M.knownSpecRows(EXT, PLAN);
check("rows: inventory then plan needs, one row per id (the first wins)",
      rows.map(r => r.id).join(",") === "spec-flour,spec-bike,nourishment/meals" && rows[0].name === "flour");
check("a plan need's classification is its own id", rows[2].cats[0] === "nourishment/meals");
check("knownSpecs is the rows' id → name", [...M.knownSpecs(EXT, PLAN)].map(([k, v]) => `${k}=${v}`).join(",")
      === "spec-flour=flour,spec-bike=bike repair,nourishment/meals=meals");
const em = M.knownEmoji(EXT, PLAN);
check("knownEmoji keys by id and by lowercased name, skipping glyphless rows",
      em.get("spec-flour") === "🌾" && em.get("flour") === "🌾" && em.get("meals") === "🍲" && !em.has("spec-bike") && em.size === 4);

done();
