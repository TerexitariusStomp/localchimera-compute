// app/housing.ts — housing as the plan reads it: the night a person is owed
// and what the dwelling they sleep in delivers of it. nutrition.ts's twin,
// over the housing catalogue's rows — pure, so node runs it (tests/browser/
// housing-test.mjs); what a person STATES and the doors it goes through are
// dwelling.ts's.
//
// The STANDARD (housing-catalogue.ts, generated) states what every person's
// night is owed: three gradients — floor area, warmth, private sleeping places per person — and
// five gates — safety, sanitation, energy, dryness, step-free access — each
// row with the source it was read from. The CLIMATE layer folded here is the
// catalogue's L1: a region without a winter asks no floor of warmth and
// reads the overheating ceiling at the acclimatised 30 °C. The PERSON layer is its L2: the old and the very
// young are owed 20 °C where a winter is, a young child's privacy floor
// halves where the scope keeps that rule, and accessibility, which carries no base floor, rises to 1 for the
// person who needs step-free access; the ratified `standard` (L4) lifts the
// gradients above bare adequacy and may only raise. The layers are ported
// from knowledge/housing-catalogue.scm and pinned to its figures by
// tests/browser/housing-test.mjs, so the walk shows the same night the solve
// defends.
//
// The DWELLING read here is the closure's: a night in a dwelling delivers
// its floor area and sleeping places shared by everyone who sleeps there, the warmth
// it is kept at, and a 1 on every gate the unit attests —
// catalogues/housing-substance.scm's unit-content, so the walk reads a shortfall the
// same way the solve does. The catalogue's type table stays the fallback a
// seeded fixture uses; the walk asks the measurements themselves.
import { HOUSING_STANDARD, ACCLIMATISED_CEILING, WARMTH_RAISED, WARMTH_ELDER_AGE, WARMTH_YOUNG_AGE, CHILD_SHARE_AGE, OUTDOOR_CREDIT, WINTERLESS_REGIONS } from './housing-catalogue.js';
export { ACCLIMATISED_CEILING, WARMTH_RAISED, WARMTH_ELDER_AGE, WARMTH_YOUNG_AGE, CHILD_SHARE_AGE, OUTDOOR_CREDIT };
export const NIGHTS_PER_MONTH = 365 / 12;
/** L1 · the region the geography layer reads that has no winter: within 30° of the equator. */
export const winterless = (region) => region != null && WINTERLESS_REGIONS.includes(region);
/** L1 · which of a dwelling's two warmths a night reads: by the month and the hemisphere. */
export const seasonOf = (month, lat) => {
    const north = lat == null || lat >= 0;
    return (north ? month >= 11 || month <= 3 : month >= 5 && month <= 9) ? "winter" : "summer";
};
/** L1 · a climate without a winter asks no floor of warmth and reads the acclimatised ceiling; elsewhere the standard's stand. */
export function climateLayer(rows, ctx) {
    return winterless(ctx.region) ? rows.map(r => r.id === "hs-warmth" ? { ...r, floor: 0, ceiling: ACCLIMATISED_CEILING } : r) : rows;
}
/** L2 · a young child sleeps beside others where a household keeps to that: the privacy floor halves below CHILD_SHARE_AGE, unless the scope owes a child the whole floor (ctx.childShareAge). */
export const CHILD_PRIVACY = (HOUSING_STANDARD.find(r => r.id === "hs-privacy")?.floor ?? 1 / 3) / 2;
/** L2 · the body housed. */
export function personLayer(rows, ctx) {
    return rows.map(r => {
        if (r.id === "hs-warmth" && !winterless(ctx.region) && (ctx.age >= WARMTH_ELDER_AGE || ctx.age < WARMTH_YOUNG_AGE))
            return { ...r, floor: WARMTH_RAISED };
        if (r.id === "hs-privacy" && ctx.age < (ctx.childShareAge ?? CHILD_SHARE_AGE))
            return { ...r, floor: CHILD_PRIVACY };
        if (r.id === "hs-accessibility" && ctx.stepFree)
            return { ...r, floor: 1 };
        return r;
    });
}
/** L4 · the ratified standard: gradients rise by the factor, never past their own ceiling; a gate is already whole at 1. */
export function standardLayer(rows, ctx) {
    const s = Math.max(1, ctx.standard ?? 1);
    return rows.map(r => {
        const raised = r.floor * s;
        return s > 1 && r.group === "gradient" && (r.ceiling == null || raised < r.ceiling) ? { ...r, floor: raised } : r;
    });
}
/** The night owed to a person: the base, the climate, the body housed, the ratified standard — the catalogue's own fold. */
export function housingProfile(ctx) {
    return standardLayer(personLayer(climateLayer(HOUSING_STANDARD, ctx), ctx), ctx);
}
/** The bands the planner holds: a row asking nothing (floor 0, no ceiling) is dropped, as housing-bands drops it. */
export function housingBands(ctx) {
    return housingProfile(ctx).filter(r => r.floor > 0 || r.ceiling != null);
}
/** Nobody knows their mean indoor temperature; everybody knows which of these they live in. The figures sit inside or outside the standard's 18–26 °C band, one row a season. */
export const WARMTH_WINTER = [
    { id: "cold", label: "cold", degC: 14, hint: "below the 18 °C the WHO guideline names — a coat indoors" },
    { id: "ok", label: "warm enough", degC: 19, hint: "kept above 18 °C through the winter" },
];
export const WARMTH_SUMMER = [
    { id: "ok", label: "fine", degC: 23, hint: "stays where a body used to the climate is comfortable — shade, thick walls, a through-draught count" },
    { id: "hot", label: "too hot", degC: 33, hint: "hotter than a body used to the climate keeps well in, for weeks at a time" },
];
export const winterOf = (id) => WARMTH_WINTER.find(w => w.id === id)?.degC ?? 19;
export const summerOf = (id) => WARMTH_SUMMER.find(w => w.id === id)?.degC ?? 23;
/** The gates a person can attest of their own dwelling, in the words the walk asks them. */
export const GATES = [
    { id: "hs-sanitation", label: "water and a toilet", hint: "safe water on the premises and a toilet not shared with other households" },
    { id: "hs-safety", label: "sound and safe", hint: "stands firm and has a way out in a fire — whatever it is built of: earth, bamboo, timber, brick or stone" },
    { id: "hs-energy", label: "light and power", hint: "light, cooking and a charged phone — from the grid, a solar panel or a shared source" },
    { id: "hs-dry", label: "dry and aired", hint: "no persistent damp or mould, air that moves — however the walls breathe" },
    { id: "hs-quiet", label: "quiet enough to sleep", hint: "no din, traffic or machinery noise loud enough to break sleep through the night" },
    { id: "hs-dark", label: "dark enough to sleep", hint: "can be made dark enough for uninterrupted sleep — shutters, curtains, or their equivalent" },
    { id: "hs-accessibility", label: "step-free entrance", hint: "reached without a step, for whoever needs that" },
];
/** Nearly every dwelling attests these six; the walk starts them on and lets the person untick. */
export const GATES_DEFAULT = ["hs-safety", "hs-sanitation", "hs-energy", "hs-dry", "hs-quiet", "hs-dark"];
/** The floor area a night reads: the indoor area, and the credited share of the outdoor space where the climate lives outdoors. */
export const effectiveArea = (m, region) => m.areaM2 + (winterless(region) ? OUTDOOR_CREDIT * Math.max(0, m.outdoorM2 ?? 0) : 0);
/** What one person-night in a measured dwelling delivers: area and rooms shared by its people, the season's warmth, and a 1 on every gate it attests. */
export function delivers(m, attests, season = "winter", region) {
    const n = Math.max(1, m.people);
    const out = { "hs-area": effectiveArea(m, region) / n, "hs-warmth": season === "summer" ? m.warmthSummerDegC : m.warmthWinterDegC, "hs-privacy": m.rooms / n };
    for (const g of attests)
        out[g] = 1;
    return out;
}
/** The night as this person would spend it there: every row of the profile against what the dwelling delivers. */
export function nightRead(ctx, m, attests) {
    const d = m ? delivers(m, attests, seasonOf(ctx.month ?? new Date().getMonth() + 1, ctx.lat), ctx.region) : null;
    return housingProfile(ctx).map(row => {
        const got = d ? (d[row.id] ?? 0) : null;
        const ok = got == null ? null : got >= row.floor - 1e-9 && (row.ceiling == null || got <= row.ceiling + 1e-9);
        return { row, owed: row.floor, got, ok };
    });
}
/** Rent as the unit's own price: EUR per person-night from a monthly figure shared by everyone who sleeps there. */
export const rentPerNight = (rentMonth, people) => rentMonth > 0 ? rentMonth / (NIGHTS_PER_MONTH * Math.max(1, people)) : 0;
