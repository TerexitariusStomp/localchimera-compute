// tests/browser/housing-test.mjs — the night a person is owed, as the browser
// folds it (browser/app/housing.js, from ui/app/housing.ts)
//
// The person layer is a PORT of knowledge/housing-catalogue.scm's L2 and L4 —
// code in both places, a table in neither — so nothing but a test holds the
// two to the same figures. These pin the catalogue's own claims, the ones
// tests/solve/test-housing-substance.scm pins on the Scheme
// side: an adult's night is owed 9 m², 18–26 °C, half a room, safety and
// sanitation, energy, dryness; accessibility carries no base floor; a climate
// without a winter asks no warmth floor; the old and the very young are owed 20 °C; a young child's privacy floor halves; step-free raises the
// gate to 1; the ratified standard lifts gradients only, never past a ceiling.
// And the closure's reading: what a night in a measured dwelling delivers —
// area and rooms shared by its people, its warmth — and where it falls short.
//
// Pure functions, no DOM: node runs the real module.
//
// Run: node tests/browser/housing-test.mjs

const H = await import("../../browser/app/housing.js");
const C = await import("../../browser/app/housing-catalogue.js");

import { harness } from './assert.mjs';
const { check, done } = harness();
const floorOf = (rows, id) => rows.find(r => r.id === id)?.floor;

console.log("\n── the standard: a base, the climate, the body housed, the ratified factor ──");
{
  const adult = H.housingBands({ age: 30 });
  const near = (a, b) => Math.abs(a - b) < 1e-9;
  check("an adult's night is owed 9 m2, 18–26 degC, a third of a room, safety, sanitation, energy, dryness, quiet and dark",
    floorOf(adult, "hs-area") === 9 && floorOf(adult, "hs-warmth") === 18 && adult.find(r => r.id === "hs-warmth").ceiling === 26
    && near(floorOf(adult, "hs-privacy"), 1 / 3) && floorOf(adult, "hs-safety") === 1 && floorOf(adult, "hs-sanitation") === 1
    && floorOf(adult, "hs-energy") === 1 && floorOf(adult, "hs-dry") === 1
    && floorOf(adult, "hs-quiet") === 1 && floorOf(adult, "hs-dark") === 1);
  check("accessibility carries no base floor — no band stands for someone who does not need it",
    !adult.some(r => r.id === "hs-accessibility"));
  check("the old are owed 20 degC", floorOf(H.housingBands({ age: 70 }), "hs-warmth") === 20);
  check("the very young are owed 20 degC too", floorOf(H.housingBands({ age: 4 }), "hs-warmth") === 20);
  check("a young child's privacy floor halves", near(floorOf(H.housingBands({ age: 4 }), "hs-privacy"), 1 / 6));
  check("step-free raises the accessibility gate to 1", floorOf(H.housingBands({ age: 30, stepFree: true }), "hs-accessibility") === 1);
  const tropics = H.housingBands({ age: 70, region: "hotArid" });
  check("L1: a climate without a winter asks no floor of warmth, even of the old — the ceiling stands",
    floorOf(tropics, "hs-warmth") === 0 && tropics.find(r => r.id === "hs-warmth").ceiling === 30);
  check("…and its overheating ceiling is the acclimatised 30 degC, where the temperate 26 stands elsewhere",
    H.ACCLIMATISED_CEILING === 30 && H.housingBands({ age: 30 }).find(r => r.id === "hs-warmth").ceiling === 26);
  check("the outdoor credit and the winterless regions come from the catalogue: half, and hotArid alone",
    C.OUTDOOR_CREDIT === 0.5 && C.WINTERLESS_REGIONS.join() === "hotArid" && H.winterless("hotArid") && !H.winterless("temperate") && !H.winterless(undefined));
  check("a scope may owe a child the full privacy floor (childShareAge 0); the halving is the default",
    near(floorOf(H.housingBands({ age: 4, childShareAge: 0 }), "hs-privacy"), 1 / 3) && near(floorOf(H.housingBands({ age: 4 }), "hs-privacy"), 1 / 6));
  check("the season a night reads: January is winter in Berlin and summer in Cape Town; July the reverse; no latitude reads north",
    H.seasonOf(1, 52.5) === "winter" && H.seasonOf(1, -33.9) === "summer" && H.seasonOf(7, 52.5) === "summer" && H.seasonOf(7, -33.9) === "winter" && H.seasonOf(12) === "winter");
  const decent = H.housingBands({ age: 30, standard: 1.5 });
  check("the ratified standard lifts the gradients (9 → 13.5 m2, a third → a half room)", floorOf(decent, "hs-area") === 13.5 && near(floorOf(decent, "hs-privacy"), 0.5));
  check("…never past a ceiling (18 × 1.5 = 27 > 26 stays 18)", floorOf(decent, "hs-warmth") === 18);
  check("…and a gate is already whole at 1", floorOf(decent, "hs-safety") === 1);
  check("a standard below 1 does not lower anything", floorOf(H.housingBands({ age: 30, standard: 0.5 }), "hs-area") === 9);
  check("every row names what it does for rest: a gradient is an outcome or a proxy, a gate an outcome, a service or access",
    C.HOUSING_STANDARD.every(r => (r.group === "gate" ? ["outcome", "service", "access"] : ["outcome", "proxy"]).includes(r.fn)));
  check("the named figures come from the catalogue: 30 degC acclimatised ceiling, 20 degC raised warmth at 65 and under 5, halving under 10",
    C.ACCLIMATISED_CEILING === 30 && C.WARMTH_RAISED === 20 && C.WARMTH_ELDER_AGE === 65 && C.WARMTH_YOUNG_AGE === 5 && C.CHILD_SHARE_AGE === 10);
  check("the rows come in the catalogue's order", H.housingProfile({ age: 30 }).map(r => r.id).join() === C.HOUSING_STANDARD.map(r => r.id).join());
}

console.log("\n── the closure: what a night in this dwelling delivers ──");
{
  const flat = { areaM2: 60, rooms: 3, warmthWinterDegC: 20, warmthSummerDegC: 24, people: 4 };
  const d = H.delivers(flat, ["hs-sanitation"]);
  check("a 60 m² flat with three rooms housing four gives each night 15 m², 0.75 rooms and its winter warmth",
    d["hs-area"] === 15 && d["hs-privacy"] === 0.75 && d["hs-warmth"] === 20);
  check("…the summer's in summer", H.delivers(flat, [], "summer")["hs-warmth"] === 24);
  check("…and a 1 on every gate it attests, nothing on the rest", d["hs-sanitation"] === 1 && d["hs-safety"] === undefined);
  const jan = { month: 1, lat: 52.5 };
  const room = H.nightRead({ age: 30, ...jan }, { areaM2: 12, rooms: 1, warmthWinterDegC: H.winterOf("cold"), warmthSummerDegC: H.summerOf("ok"), people: 4 }, []);
  const by = Object.fromEntries(room.map(r => [r.row.id, r]));
  check("a cold room shared by four falls short on area, warmth and privacy for an adult in January",
    by["hs-area"].ok === false && by["hs-warmth"].ok === false && by["hs-privacy"].ok === false);
  check("…and on the gates it does not attest", by["hs-safety"].ok === false && by["hs-sanitation"].ok === false && by["hs-energy"].ok === false && by["hs-dry"].ok === false && by["hs-quiet"].ok === false && by["hs-dark"].ok === false);
  check("accessibility, owed to nobody here, reads as met at 0", by["hs-accessibility"].ok === true);
  const yard = { areaM2: 20, rooms: 1, outdoorM2: 16, warmthWinterDegC: 23, warmthSummerDegC: 23, people: 2 };
  check("covered outdoor space counts half toward area where there is no winter: 20 m² + 16 m² veranda shared by two is 14 m² each in Lagos, 10 in Berlin",
    H.delivers(yard, [], "winter", "hotArid")["hs-area"] === 14 && H.delivers(yard, [], "winter", "temperate")["hs-area"] === 10 && H.effectiveArea(yard, "hotArid") === 28);
  check("a curtained sleeping place counts as a place: one hall of four places for four is a whole place each",
    H.delivers({ areaM2: 36, rooms: 4, warmthWinterDegC: 23, warmthSummerDegC: 23, people: 4 }, [])["hs-privacy"] === 1);
  const hot = { areaM2: 40, rooms: 2, warmthWinterDegC: H.winterOf("ok"), warmthSummerDegC: H.summerOf("hot"), people: 1 };
  check("too hot in summer breaks the warmth ceiling in July, and nothing else",
    H.nightRead({ age: 30, month: 7, lat: 52.5 }, hot, H.GATES_DEFAULT).filter(r => r.ok === false).map(r => r.row.id).join() === "hs-warmth");
  check("…and in January the same flat is fine", H.nightRead({ age: 30, ...jan }, hot, H.GATES_DEFAULT).every(r => r.ok === true));
  const lagos = H.nightRead({ age: 70, region: "hotArid", month: 1, lat: 6.5 }, { areaM2: 30, rooms: 2, warmthWinterDegC: 23, warmthSummerDegC: 23, people: 1 }, H.GATES_DEFAULT);
  check("in Lagos an elder's night asks no warmth floor: a 23 °C flat meets it", lagos.every(r => r.ok === true));
  const elder = H.nightRead({ age: 70, stepFree: true, ...jan }, { areaM2: 45, rooms: 2, warmthWinterDegC: 21, warmthSummerDegC: 24, people: 2 }, [...H.GATES_DEFAULT, "hs-accessibility"]);
  check("a warm, certified, step-free flat meets an elder's whole night", elder.every(r => r.ok === true));
  check("warm enough is 19 °C in winter and 23 in summer, inside the 18–26 band; an unknown chip reads as that", H.winterOf("ok") === 19 && H.summerOf("?") === 23);
  check("safety, sanitation, energy, dryness, quiet and dark are the default attestation, accessibility is not", H.GATES_DEFAULT.join() === "hs-safety,hs-sanitation,hs-energy,hs-dry,hs-quiet,hs-dark");
  check("no dwelling reads as nothing delivered, not as a shortfall", H.nightRead({ age: 30 }, null, []).every(r => r.got === null && r.ok === null));
}

console.log("\n── rent is the unit's own price, never a need ──");
{
  check("€600 a month shared by two is €9.86 a person-night", Math.abs(H.rentPerNight(600, 2) - 600 / (365 / 12 * 2)) < 1e-9);
  check("no rent prices nothing", H.rentPerNight(0, 3) === 0);
  check("the catalogue still carries the rent recipe's price for a bought night", C.RENT_EUR_PER_NIGHT === 25);
}

done();
