// tests/browser/nutrition-test.mjs — the reproduction of labour-power, composed
// (browser/app/nutrition.js, from ui/app/nutrition.ts)
//
// The module states several NUMBERS in prose and derives others from anchors,
// and nothing held them. A comment that says "35 °C ⇒ 0.65 L/h ⇒ 673 mg/h ⇒
// 5.4 g over 8 h, inside the measured band" is a claim about the code, and the
// code is free to drift away from it silently. These pin the ones that would be
// wrong in a way no screenshot could show.
//
// Two of them are not arithmetic but POLITICAL claims the layer order encodes,
// stated at the top of the module:
//
//   geography may RAISE the species floor but never sink below it
//   the historical-moral standard may only LIFT (L4, standard >= 1)
//
// Both are properties of the FOLD, so they are testable exactly the way the
// module composes: profileFor over a ctx.
//
// Pure functions, no DOM: node runs the real module.
//
// Run: node tests/browser/nutrition-test.mjs

const N = await import("../../browser/app/nutrition.js");

import { harness } from './assert.mjs';
const { check, done } = harness();
const near = (a, b, eps = 0.5) => Math.abs(a - b) <= eps;

console.log("\n── the SAFE BAND: not too much, not too little ──");
{
  // s = 1 across the plateau, ramping to ~0 at the hard tips.
  check("anywhere on the plateau is free", N.band(100, { hardLo: 40, softLo: 80, softHi: 120, hardHi: 200 }) === 1);
  check("halfway down the deficiency ramp is 0.5",
    near(N.band(60, { hardLo: 40, softLo: 80 }), 0.5, 1e-9));
  check("at the deficiency tip it floors, never zero",
    N.band(40, { hardLo: 40, softLo: 80 }) === 1e-3);
  check("halfway up the excess ramp is 0.5",
    near(N.band(160, { softHi: 120, hardHi: 200 }), 0.5, 1e-9));
  check("at the toxicity tip it floors", N.band(200, { softHi: 120, hardHi: 200 }) === 1e-3);

  // "Unless that's ok" = the missing edge.
  check("FLOOR-only: you cannot over-practise a skill",
    N.band(1e6, { hardLo: 0, softLo: 18 }) === 1);
  check("CEILING-only: less of an ecological draw is fine",
    N.band(0, { softHi: 120, hardHi: 200 }) === 1);
  check("no edges at all is always free", N.band(-1e6, {}) === 1);
}

console.log("\n── ACTIVITY: the day's wear-and-tear ──");
{
  check("four hours is the hinge — no scaling below it", N.activityFactor(4) === 1);
  check("an absent day does not scale", N.activityFactor(undefined) === 1);
  check("ten hours is the full half-step up", near(N.activityFactor(10), 1.5, 1e-9));
  check("it caps rather than running away", near(N.activityFactor(1000), 1.7, 1e-9));
  check("…and the cap is reached at 12.4 h", near(N.activityFactor(12.4), 1.7, 1e-9));
}

console.log("\n── SWEAT: where climate and labour meet ──");
{
  // the anchor the module derives the whole curve from
  check("35 °C anchors at 0.65 L/h", near(N.sweatLitresPerHour(35), 0.65, 1e-9));
  check("35 °C ⇒ ~673 mg Na per hour", near(N.sweatSodiumMg(35, 1), 673, 1));
  check("…⇒ ~5.4 g over an 8 h shift, inside the measured 4.8–6 g band",
    near(N.sweatSodiumMg(35, 8), 5382, 5));

  // deriving the other regions corrected them DOWN from an earlier draft
  check("temperate (20 °C) derives to ~52 mg/h, not the old 150", near(N.sweatSodiumMg(20, 1), 52, 1));
  check("cold (5 °C) derives to 0 — the fit has left its range, not reclaimed salt",
    N.sweatSodiumMg(5, 1) === 0);
  check("the litre curve floors at zero rather than going negative",
    N.sweatLitresPerHour(-40) === 0);

  check("acclimation lowers the load (25 vs 45 mmol/L)",
    near(N.sweatSodiumMg(35, 8, true) / N.sweatSodiumMg(35, 8, false), 25 / 45, 1e-9));
  check("no hours worked is no sweat loss", N.sweatSodiumMg(35, 0) === 0);

  // a shed's own ERA5 warmest-quarter mean beats the coarse region table
  check("a stated temperature wins over both", N.workingDegC({ workingDegC: 30, shed: "doon", region: "cold" }) === 30);
  check("then the shed's own record", N.workingDegC({ shed: "doon", region: "cold" }) === 26.8);
  check("then the region fallback", N.workingDegC({ region: "cold" }) === 5);
  check("then 20", N.workingDegC({}) === 20);
}

console.log("\n── the FOLD, and the claims its order makes ──");
{
  const base = N.profileFor({ sex: "F", age: 30 });
  check("the species floor seeds the stack", base.energy && base.energy.rda > 0);

  // L1 · geography may RAISE, never sink below the species floor
  const cold = N.profileFor({ sex: "F", age: 30, region: "cold" });
  check("cold raises the energy floor", cold.energy.rda > base.energy.rda);
  const everyRegionRaises = ["cold", "hotArid", "inland", "highLatitude", "temperate"]
    .every(region => {
      const p = N.profileFor({ sex: "F", age: 30, region });
      return Object.keys(base).every(k => p[k].rda >= base[k].rda - 1e-9);
    });
  check("NO region sinks ANY nutrient below the species floor", everyRegionRaises);

  // L3 · labour scales energy and protein, and only those
  const worked = N.profileFor({ sex: "F", age: 30, labourHours: 10 });
  check("a worked day raises energy", worked.energy.rda > base.energy.rda);
  check("…and protein", worked.protein.rda > base.protein.rda);
  check("…and leaves calcium alone", worked.calcium.rda === base.calcium.rda);

  // L4 · the historical-moral standard may only LIFT
  const decent = N.profileFor({ sex: "F", age: 30, standard: 1.3 });
  check("a ratified standard lifts the floor", decent.energy.rda > base.energy.rda);
  const belowOneIgnored = N.profileFor({ sex: "F", age: 30, standard: 0.5 });
  check("a standard BELOW bare survival cannot lower it",
    belowOneIgnored.energy.rda === base.energy.rda);
  const noneThroughCeiling = Object.keys(decent)
    .every(k => decent[k].ul == null || decent[k].rda <= decent[k].ul);
  check("and no lift pushes a floor through its own toxicity ceiling", noneThroughCeiling);

  // L2 · a growing body is not a small adult
  const child = N.profileFor({ sex: "F", age: 11 });
  check("an 11-year-old's iron is its own table, not a scaled adult's",
    child.iron.rda === 8 && child.iron.rda !== base.iron.rda);
  check("…and her calcium floor is HIGHER than an adult woman's",
    child.calcium.rda > base.calcium.rda);
}

console.log("\n── the wheel the faces read ──");
{
  const w = N.nutritionWire(N.DEMO_PERSON, N.DEMO_INTAKE, 5);
  check("every control carries a slack in (0, 1]",
    w.controls.length > 0 && w.controls.every(c => c.s > 0 && c.s <= 1));
  check("every control names its side",
    w.controls.every(c => ["deficiency", "toward excess", "adequate"].includes(c.side)));
  // the walls are the solver's: a person fed EXACTLY to their floor sits AT the
  // deficiency wall (the plan's floor is a hard bar at the RDA), a person a
  // quarter-band above it is at ease, one at the UL sits at the toxicity wall
  {
    // the profile the wire reads is the demo person's own: the energy ceiling
    // is the EER equation's, so it moves with age, and a 30-year-old's band is
    // not a 34-year-old's
    const prof = N.profileFor({ ...N.DEMO_PERSON, labourHours: 5 });
    const atFloor = Object.fromEntries(Object.entries(prof).map(([k, d]) => [k, d.rda]));
    const wf = N.nutritionWire(N.DEMO_PERSON, atFloor, 5);
    check("fed exactly to the floor reads AT the wall (s = 1e-3), every nutrient",
      wf.controls.every(c => c.s === 1e-3));
    const eased = Object.fromEntries(Object.entries(prof).map(([k, d]) => [k, d.rda + 0.3 * (d.ul ? d.ul - d.rda : d.rda)]));
    const we = N.nutritionWire(N.DEMO_PERSON, eased, 5);
    check("a quarter-band above the floor is at ease (s = 1)", we.controls.every(c => c.s === 1 && c.side === "adequate"));
    const atUl = Object.fromEntries(Object.entries(prof).map(([k, d]) => [k, d.ul ?? d.rda + d.rda]));
    const wu = N.nutritionWire(N.DEMO_PERSON, atUl, 5);
    check("at the UL reads AT the toxicity wall; a ceiling-free nutrient is free above",
      wu.controls.every(c => (prof[c.spec].ul ? c.s === 1e-3 : c.s === 1)));
  }

  const agg = N.aggregateNutrition(N.POPULATION);
  check("the social aggregate spans the whole cohort",
    agg.controls.every(c => c.count === N.POPULATION.length));
  check("…and carries the spread the mean hides",
    agg.controls.every(c => Array.isArray(c.spread) && c.spread[0] <= c.spread[1]));
  check("the aggregate lies inside its own spread",
    agg.controls.every(c => c.s >= c.spread[0] - 1e-9 && c.s <= c.spread[1] + 1e-9));

  // "worst-off-leaning" is not a mood, it is AM–GM: the geometric mean sits at
  // or below the arithmetic one, and strictly below it wherever the cohort
  // actually disagrees. That is the whole reason for choosing it — an average
  // would let a comfortable majority hide a member near their tip.
  const perPerson = N.POPULATION.map(p => N.personNutritionWire(p).controls);
  const slacksFor = spec => perPerson.map(cs => cs.find(c => c.spec === spec).s);
  const amgm = agg.controls.every(c => {
    const ss = slacksFor(c.spec);
    return c.s <= ss.reduce((a, b) => a + b, 0) / ss.length + 1e-9;
  });
  check("the geometric mean sits at or below the arithmetic one (AM–GM)", amgm);

  const iron = agg.controls.find(c => c.spec === "iron");
  const ironSlacks = slacksFor("iron");
  const ironMean = ironSlacks.reduce((a, b) => a + b, 0) / ironSlacks.length;
  check("…and strictly below it where the cohort disagrees, so one member near",
    iron.s < ironMean - 1e-9, `\n      their tip drags it down  (geo ${iron.s.toFixed(3)} < mean ${ironMean.toFixed(3)})`);
}

console.log("\n── L2b · DIET: what a person will not eat raises what the rest must carry ──");
{
  // mirrors subsistence-L2-diet (knowledge/diets.scm diet-shifts): a vegetarian's
  // iron floor is 1.8× the omnivore's, a vegan's zinc 1.5×, and nothing else moves
  const base = N.profileFor({ sex: "F", age: 30 });
  const veg  = N.profileFor({ sex: "F", age: 30, diet: ["diet:vegetarian"] });
  const vgn  = N.profileFor({ sex: "F", age: 30, diet: ["diet:vegan", "allergy:nuts"] });
  check("a vegetarian's iron floor is 1.8× the omnivore's", near(veg.iron.rda / base.iron.rda, 1.8, 1e-9), `${veg.iron.rda}/${base.iron.rda}`);
  check("…and her zinc floor is unchanged", near(veg.zinc.rda, base.zinc.rda, 1e-9));
  check("a vegan's zinc floor is 1.5× and iron 1.8×", near(vgn.zinc.rda / base.zinc.rda, 1.5, 1e-9) && near(vgn.iron.rda / base.iron.rda, 1.8, 1e-9));
  check("an allergy moves no floor: it is a menu rule, not a body", Object.keys(base).every(k => k === "iron" || k === "zinc" || near(vgn[k].rda, base[k].rda, 1e-9)));
  check("a diet only raises", Object.keys(base).every(k => vgn[k].rda >= base[k].rda - 1e-9));
}

console.log("\n── the region a latitude implies ──");
{
  const { REGION_LATITUDES: L } = await import("../../browser/app/nutrition-catalogue.js");
  check("the three latitudes come from the catalogue: hot within 30°, cold from 50°, high latitude from 60°", L.hot === 30 && L.cold === 50 && L.high === 60);
  // the same places tests/planner/test-housing-substance.scm reads through region-for-lat
  check("a latitude implies its region by the Scheme rule: Lagos, Berlin, Oslo, Tromsø, and the edges at ±30° and ±50°",
    N.regionForLat(6.5) === "hotArid" && N.regionForLat(45) === "temperate" && N.regionForLat(52.5) === "cold" && N.regionForLat(69.6) === "highLatitude"
    && N.regionForLat(-30) === "hotArid" && N.regionForLat(-50) === "cold");
}

done();
