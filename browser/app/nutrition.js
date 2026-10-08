// app/nutrition.ts — the REPRODUCTION OF LABOUR-POWER, composed.
//
// A person's nutritional means of subsistence is not one number: it is a stack
// of two-sided fragility profiles (a deficiency floor EAR/RDA, a toxicity
// ceiling UL), and each of the determinants of the value of labour-power is a
// LAYER that transforms the stack. The layers are ordered from the most ESSENTIAL
// (universal, invariant) to the most CONTINGENT (geography, life-stage, the day's
// labour, the historical-moral standard, the measured self). The person's
// profile is the FOLD of the layers over a species base:
//
//     profileFor(ctx) = LAYERS.reduce((p, layer) => layer(p, ctx), {})
//
// The order is the political claim: geography may RAISE the species floor but
// never sink below it; the historical-moral standard may only LIFT; the self
// refines but the public priors remain the default. Everything is computed
// CLIENT-SIDE from the person's own data; only the public catalogue is shared.
//
// ctx = { sex, age, pregnant, lactating, region, labourHours, standard, self, intake }
import { SPECIES_BASE, SEX_SHIFTS, ELDER_AGE, ADULT_SHIFTS, BANDS, GEO_SHIFTS, DIET_SHIFTS, FOLLOWS, REFERENCE_BODY, EER_ROWS, WORK_INTENSITY, ALTITUDE_SHIFTS, WINTER_SUN_LAT, WINTER_SUN_SHIFT, SELF_CONDITIONS, REGION_WORKING_DEGC, REGION_LATITUDES } from './nutrition-catalogue.js';
export { DIET_SHIFTS };
/** The climate region a position implies — latitude alone, by the catalogue's own bands (hot within `hot`° of the equator, cold from `cold`°, high latitude from `high`°). */
export function regionForLat(lat) {
    const a = Math.abs(lat);
    return a >= REGION_LATITUDES.high ? "highLatitude" : a >= REGION_LATITUDES.cold ? "cold" : a <= REGION_LATITUDES.hot ? "hotArid" : "temperate";
}
// ── the layers ──────────────────────────────────────────────────────────────
const shift = (p, spec, k) => {
    const n = p[spec];
    if (!n)
        return;
    n.rda *= (k.rda ?? 1);
    if (n.ul)
        n.ul *= (k.ul ?? 1);
    if (k.w)
        n.w *= k.w;
    if (k.add) {
        n.rda += k.add;
        if (n.ul)
            n.ul += k.add;
    }
};
// ── L0 · SPECIES FLOOR — the physically-indispensable (the "minimum limit").
// Universal adult requirements, sex-neutral base; life-stage (L2) brackets it.
// Values are DRI-style (US IOM), rounded; the FLOOR the whole stack rests on.
// { group, unit, rda (adequate floor), ul (toxicity ceiling|null), w (weight) }
function L0_species() {
    return Object.fromEntries(Object.entries(SPECIES_BASE).map(([spec, n]) => [spec, { ...n }]));
}
// ── L1 · GEOGRAPHY / CLIMATE — "natural wants vary according to climatic and
// physical conditions." Shifts (never lowers below) the species floor by region.
//
// Unlike L0 and L2 this layer has NO DRI-equivalent authority behind it. See
// knowledge/subsistence-catalogue.scm for the full note; in brief:
//   · FAO/WHO/UNU (2004) measures BMR at thermoneutrality and publishes no
//     climate adjustment, so there is no consensus multiplier to cite.
//   · The cold energy figure traces to IOM "Nutritional Needs in Cold and
//     High-Altitude Environments" (1996), where the increase is dominated by
//     CLOTHING (10–16% on the cost of movement) and terrain, not thermoregulation.
//   · Sweat losses in heat run 4.8–6 g sodium per work shift against a 1500 mg/d
//     AI — a fourfold requirement, so ×1.2 badly understates working in heat.
// Both are really climate×ACTIVITY effects, and this stack applies climate (L1)
// and labour (L3) independently. Marked as a gap rather than silently patched.
// [DRAFT] every multiplier below.
// Altitude and the winter sun ride the same layer, both derived from where
// the person is: the highest altitude threshold at or below the elevation,
// and the dark half-year beyond WINTER_SUN_LAT (November–February north,
// May–August south), when skin makes no vitamin D (subsistence-L1-geography).
export const winterSun = (lat, month) => lat != null && month != null && Math.abs(lat) >= WINTER_SUN_LAT
    && (lat >= 0 ? (month >= 11 || month <= 2) : (month >= 5 && month <= 8));
function L1_geography(p, c) {
    applyShifts(p, c.region ? GEO_SHIFTS[c.region] : undefined);
    const alt = ALTITUDE_SHIFTS.find(([m]) => c.altitudeM != null && c.altitudeM >= m);
    if (alt)
        applyShifts(p, alt[1]);
    if (winterSun(c.lat, c.month))
        applyShifts(p, WINTER_SUN_SHIFT);
    return p;
}
// ── L2 · LIFE-STAGE / GENERATIONAL — age × sex, and pregnancy/lactation/growth
// shift the floor hard. This is the generational component: a reproducer carries
// the developing dependent's floor folded into their own.
// SET a nutrient outright — the twin of `shift`, which scales. A life-stage
// bracket is not a nudge but a DIFFERENT TABLE: the DRI publishes absolute values
// per age band, and stating them as ratios would obscure both number and source.
/** Every row of a catalogue table, as a shift — a table a person is not in is no rows. */
const applyShifts = (p, rows) => {
    for (const [spec, k] of Object.entries(rows || {}))
        shift(p, spec, k);
};
const setNut = (p, spec, k) => { const n = p[spec]; if (n) {
    if (k.rda != null)
        n.rda = k.rda;
    if (k.ul != null)
        n.ul = k.ul;
    if (k.w != null)
        n.w = k.w;
} };
// ── CHILDHOOD AND ADOLESCENCE — the brackets the adult base cannot express.
// A growing body is not a small adult: an 11-year-old girl needs 0.44× an adult
// woman's iron and 1.30× her calcium, and no scaling of one adult number gives
// that shape. So each band is its own DRI table, SET rather than scaled, applied
// after the sex shift and overwriting it — DRI publishes no sex split below 9.
// INFANCY is a different regime and is marked as one: almost every infant figure
// is an ADEQUATE INTAKE, not an RDA — "for healthy breast-fed infants, an AI is
// the mean intake", an observation of what nourished infants get rather than a
// requirement derived from need. Only iron and zinc at 7–12 months are RDAs, and
// fibre has no infant value at all (set 0; the menu guard then floors nothing).
// [DATA · VERIFIED 2026-08-08] every rda and every mineral ul below was read back
// from the NASEM/IOM DRI summary tables and matches exactly (NBK545442 App. J for
// mineral RDAs and infant AIs; NBK56068 t2 vitamins, t4 protein/fibre, t7 vitamin
// ULs, t8 mineral ULs). One divergence for a steward: the vit D UL of 63 µg for
// 1–3 is IOM's, where EFSA sets 50 µg for 1–10 — a choice, not a fact.
// [DRAFT] `energy` is an EER — moderate-activity mid-band; L3 then scales it by
// the day's committed labour. Infancy (under 1) is absent, not estimated.
// The table is the catalogue's, generated into nutrition-catalogue.ts (`make nutrition-emit`).
function lifeStageBand(age, sex) {
    const b = BANDS.find((b) => age <= b.maxAge);
    return b ? b[sex] : null;
}
function L2_lifeStage(p, c) {
    const band = lifeStageBand(c.age, c.sex);
    if (band) { // a growing body: its own table, replacing the adult numbers
        Object.entries(band).forEach(([spec, k]) => setNut(p, spec, k));
        return p;
    }
    applyShifts(p, SEX_SHIFTS[c.sex]);
    if (c.age >= ELDER_AGE)
        applyShifts(p, ADULT_SHIFTS.elder[c.sex]);
    if (c.pregnant)
        applyShifts(p, ADULT_SHIFTS.pregnant[c.sex]);
    if (c.lactating)
        applyShifts(p, ADULT_SHIFTS.lactating[c.sex]);
    return p;
}
// ── L3 · ACTIVITY / LABOUR — the day's wear-and-tear (the time face feeding the
// fragility face). Committed labour scales the energy & protein floor.
export function activityFactor(labourHours) {
    return 1 + 0.5 * Math.max(0, Math.min(1.4, ((labourHours || 0) - 4) / 6));
}
// ADD an absolute amount to a floor, and to its ceiling with it. A sweat loss is
// a QUANTITY THE BODY LOST, not a ratio of what it needed — and the ceiling must
// travel with the floor, because a chronic-disease-risk limit derived for a
// sedentary population is not a limit for someone who has just sweated six grams
// out. Raising the floor through a fixed ceiling leaves an empty band.
const addNut = (p, spec, amt) => { const n = p[spec]; if (n) {
    n.rda += amt;
    if (n.ul)
        n.ul += amt;
} };
// ── WHERE CLIMATE AND LABOUR MEET ────────────────────────────────────────────
// Sweat sodium is the one requirement neither layer states alone: it is a product
// of how hot it is AND how hard you worked, and it is the largest single-nutrient
// swing in the catalogue. Every layer gets the full ctx, so L3 reads `region`
// beside `labourHours` and the interaction needs no new machinery.
// The rate is DERIVED, not tabulated, because only one point of it is measured:
//     mg Na per hour = sweat L/h × sweat [Na⁺] mmol/L × 23 mg/mmol
// [DATA] Sweat rate rises ~linearly with ambient temperature, ~0.04 L/h per °C at
//   fixed work intensity (the 60→84 °F step raises it ~47%).
// [DATA] Work in heat costs 4.8–6 g sodium over a shift; acclimation lowers sweat
//   [Na⁺] by ~15–25 mmol/L.
// [DRAFT] [Na⁺] 45 mmol/L unacclimated. The working TEMPERATURE is not a draft:
// each shed states it from its own ERA5 record (bioclim BIO10, the mean of its
// warmest quarter) and the browser is handed that number; the region table below
// is only the fallback for a person standing in no shed.
// The hot case anchors the curve and the slope carries it: 35 °C ⇒ 0.65 L/h ⇒
// 673 mg/h ⇒ 5.4 g over 8 h, inside the measured band. Deriving temperate and
// cold corrected them DOWN (52 and 0 mg/h) from an earlier draft's 150 and 60.
// The constants are the catalogue's; REGION_WORKING_DEGC is generated from it.
const SWEAT_NA_MMOL_L = 45.0, SWEAT_ACCLIM_MMOL_L = 20.0, NA_MG_PER_MMOL = 23.0;
const SWEAT_L_H_PER_DEGC = 0.04, SWEAT_ANCHOR_DEGC = 35.0, SWEAT_ANCHOR_L_H = 0.65;
// [DRAFT] fallback only — used when no shed temperature is known.
// Warmest-quarter means from each shed's own record (data/emit-derived.scm).
// Regenerate alongside *<shed>-derived-warm-quarter-degc*.
export const SHED_WORKING_DEGC = { berlin: 19.9, doon: 26.8, cascadia: 20.2, "bay-area": 16.8 };
// A stated figure wins; then the shed; then the coarse region table.
export function workingDegC(c) {
    return c.workingDegC
        ?? (c.shed ? SHED_WORKING_DEGC[c.shed] : undefined)
        ?? (c.region ? REGION_WORKING_DEGC[c.region] : undefined)
        ?? 20;
}
// A body that has worked this heat a fortnight reabsorbs sodium before it sweats:
// the same litres carry 15–25 mmol/L less. Unacclimated is the DEFAULT, because it
// is the higher floor and the new arrival is the one actually at risk.
const sweatNaMmolL = (acclimated) => acclimated ? SWEAT_NA_MMOL_L - SWEAT_ACCLIM_MMOL_L : SWEAT_NA_MMOL_L;
export function sweatLitresPerHour(degC) {
    // floored at zero: below ~18 °C the linear fit runs negative, which means the
    // curve has left its measured range, not that a body reclaims sodium.
    return Math.max(0, SWEAT_ANCHOR_L_H + SWEAT_L_H_PER_DEGC * (degC - SWEAT_ANCHOR_DEGC));
}
export function sweatSodiumMg(degC, hours, acclimated = false) {
    return sweatLitresPerHour(degC) * sweatNaMmolL(acclimated) * NA_MG_PER_MMOL * Math.max(0, hours || 0);
}
/** The day's committed hours weighted by how hard they are (WORK_INTENSITY; moderate is the unweighted hour). */
export const effectiveLabourHours = (c) => (c.labourHours || 0) * (WORK_INTENSITY[c.labourIntensity || "moderate"] ?? 1);
function L3_activity(p, c) {
    const hours = effectiveLabourHours(c);
    const af = activityFactor(hours);
    shift(p, "energy", { rda: af });
    shift(p, "protein", { rda: af });
    const sweat = sweatSodiumMg(workingDegC(c), hours, c.acclimated);
    if (sweat > 0) {
        addNut(p, "sodium", sweat);
        // the same litres that carried the salt out are litres to drink back
        addNut(p, "drinking-water", sweatLitresPerHour(workingDegC(c)) * Math.max(0, hours));
    }
    return p;
}
// ── L4 · HISTORICAL-MORAL — the ratified standard raises the floor above bare
// physiology to the society's decent life. Governance-set; may only RAISE
// (standard ≥ 1). Bare survival is standard=1.
function L4_cultural(p, c) {
    const s = Math.max(1, c.standard || 1);
    if (s > 1)
        Object.keys(p).forEach(spec => { const n = p[spec]; if (n.ul == null || n.rda * s < n.ul)
            n.rda *= s; });
    return p;
}
// ── L2b · DIET — what a person will not eat raises what the rest must carry:
// non-haem iron is absorbed less well, so a vegetarian's iron floor is 1.8× and
// a vegan's zinc 1.5× (IOM 2001). The rows are the catalogue's DIET_SHIFTS,
// read off the person's diet: tags the way subsistence-L2-diet reads them.
function L2b_diet(p, c) {
    for (const t of c.diet || [])
        if (t.startsWith("diet:"))
            applyShifts(p, DIET_SHIFTS[t.slice(5)]);
    return p;
}
// ── L5 · SELF — measured biomarkers / conditions override the population priors
// (client-side, private). Stub: ctx.self is { spec: {rda|ul multiplier} }.
// A named condition (SELF_CONDITIONS) is a row set the catalogue sources; the
// person states the condition, never the number. This layer may LOWER a floor:
// it is the one place the tables yield to the body (subsistence-L5-self).
function L5_self(p, c) {
    for (const id of c.selfConditions || []) {
        const cond = SELF_CONDITIONS[id];
        if (cond)
            applyShifts(p, cond.rows);
    }
    if (c.self)
        Object.entries(c.self).forEach(([spec, k]) => shift(p, spec, k));
    return p;
}
// ── L2c · BODY — the tables state energy and protein for a REFERENCE body;
// a stated height and weight read them for this one. Energy scales by the
// DRI energy equation's ratio at this body against the reference body of the
// same age and sex, protein by the weight ratio; every other layer composes
// on top unchanged (subsistence-L2c-body is the same rule). Bounded, so a
// mistyped figure cannot move a floor past what a body can be.
function referenceBody(age, sex) {
    const r = REFERENCE_BODY.find(r => r.maxAge != null && age <= r.maxAge) || REFERENCE_BODY[REFERENCE_BODY.length - 1];
    return r[sex];
}
/** The estimated energy requirement of a body, kcal/d: low-active (the floor's reading) or, with `top`, very active — the same equation at its highest published coefficient. */
export function eer(sex, age, kg, m, top = false) {
    const r = EER_ROWS.find(r => r[0] === sex && age >= r[1]);
    return r ? r[2] + r[3] * age + (top ? r[8] : r[4]) * (r[5] * kg + r[6] * m) + r[7] : 89 * kg - 100 + 20;
}
function L2c_body(p, c) {
    const kg = c.weightKg, cm = c.heightCm;
    if (!(kg && cm && kg > 0 && cm > 0))
        return p;
    const ref = referenceBody(c.age, c.sex);
    const clamp = (k) => Math.max(0.6, Math.min(1.8, k));
    shift(p, "energy", { rda: clamp(eer(c.sex, c.age, kg, cm / 100) / eer(c.sex, c.age, ref.kg, ref.m)) });
    shift(p, "protein", { rda: clamp(kg / ref.kg) });
    return p;
}
// ── a nutrient that FOLLOWS another, run last. Lysine has no table of its own:
// the DRI states it as 51 mg per gram of protein required (the protein-quality
// scoring pattern), so its floor is that ratio on the protein floor wherever the
// layers left it. The rows are the catalogue's FOLLOWS; subsistence-profile runs
// the same rule in the same place.
function L6_follows(p, _c) {
    for (const [spec, src, ratio] of FOLLOWS)
        if (p[src] && p[spec])
            p[spec].rda = p[src].rda * ratio;
    return p;
}
// ── the ENERGY CEILING, run last. A body can take only so much: the DRI states
// no UL for energy, and what is eaten past what is burned is stored — a plan
// that fed a body twice its need to reach some other floor has found a way
// round the floor, not fed it. The ceiling is the most this body could burn in
// a day, the EER at its very active coefficient over the low-active one the
// floor stands on, as a ratio on the floor wherever the layers left it. Under
// three the equation has no activity term: the youngest row's ratio stands.
// subsistence-profile's sub-energy-ceiling runs the same rule in the same place.
export function energyCeilingRatio(c) {
    const age = Math.max(3, c.age);
    const body = c.weightKg && c.heightCm && c.weightKg > 0 && c.heightCm > 0
        ? { kg: c.weightKg, m: c.heightCm / 100 } : referenceBody(age, c.sex);
    return eer(c.sex, age, body.kg, body.m, true) / eer(c.sex, age, body.kg, body.m);
}
function L7_energyCeiling(p, c) {
    if (p.energy)
        p.energy.ul = p.energy.rda * energyCeilingRatio(c);
    return p;
}
export const LAYERS = [L0_species, L1_geography, L2_lifeStage, L2b_diet, L2c_body, L3_activity, L4_cultural, L5_self, L6_follows, L7_energyCeiling];
// fold the layers → the person's composed reproduction profile. (L0 seeds the
// species base from {}; each later layer transforms it in place and returns it.)
export function profileFor(ctx) {
    return LAYERS.reduce((p, layer) => layer(p, ctx) || p, {});
}
// the individual wheel: each category's two-sided slack against the COMPOSED
// profile. lowTip = rda (the floor the plan enforces), highTip = ul (toxicity).
// ── the SAFE BAND — the one mapping from a raw quantity x to the barrier's slack
// s, so "not too much, not too little" is expressed once and consumed by the
// untouched −w·log(s) fragility barrier. s = 1 across the adequate PLATEAU
// [softLo, softHi] (φ = 0 — anywhere safely in-band is free), then ramps linearly
// to ~0 at the hard tips [hardLo, hardHi], where the barrier diverges. An ABSENT
// edge (null) means that direction can't be "too much / too little": floor-only
// (skills — more practice is fine), ceiling-only (ecological draws — less is fine)
// and two-sided (nutrients) all fall out of which edges are present. "Unless
// that's ok" = the missing edge.
export function band(x, { hardLo = null, softLo = null, softHi = null, hardHi = null } = {}) {
    let s = 1;
    if (hardLo != null && softLo != null && x < softLo) // approaching a deficiency tip
        s = Math.min(s, (x - hardLo) / (softLo - hardLo));
    if (hardHi != null && softHi != null && x > softHi) // approaching a toxicity / excess tip
        s = Math.min(s, (hardHi - x) / (hardHi - softHi));
    return Math.max(1e-3, Math.min(1, s));
}
export function nutritionWire(person, intake, labourHours) {
    const ctx = { ...person, labourHours, intake };
    const prof = profileFor(ctx);
    const af = activityFactor(labourHours);
    const controls = Object.entries(prof).map(([spec, d]) => {
        const rda = d.rda, ul = d.ul;
        const x = (intake && intake[spec] != null) ? intake[spec] : rda;
        // the WALLS are the solver's walls (planner.scm *band*, one row per nutrient
        // from this same catalogue): the deficiency edge is a hard floor AT the RDA —
        // below it the plan is infeasible — and the toxicity edge a fragility barrier
        // AT the UL. So the slack the wheel draws is the room to the nearest wall the
        // plan actually enforces, and a person fed exactly to their floor reads AT the
        // wall — which is what the plan does when nothing pulls higher: it feeds bodies
        // to the floor and no more (the case the margin floor, `held`, exists for).
        // The ramps are the display's: a quarter of the band inward from each wall is
        // where "at ease" begins; without a UL the floor's ramp is a quarter of the RDA.
        const width = ul ? (ul - rda) : rda;
        const softLo = rda + 0.25 * width;
        const softHi = ul ? ul - 0.25 * width : null;
        const s = band(x, { hardLo: rda, softLo, softHi, hardHi: ul || null });
        const side = x < softLo ? "deficiency" : (softHi && x > softHi ? "toward excess" : "adequate");
        return { kind: "nutrient", spec, control: spec, group: d.group, unit: d.unit, w: d.w, s,
            intake: x, rda: +rda.toFixed(rda < 10 ? 1 : 0), ul, side };
    });
    const life = [person.pregnant && "pregnant", person.lactating && "lactating", person.region && person.region !== "temperate" && person.region].filter(Boolean).join(", ");
    return {
        source: `individual · reproduction of labour-power · ${person.sex === "F" ? "female" : "male"} ${person.age}${life ? " · " + life : ""} · energy/protein ×${af.toFixed(2)} for labour`,
        controls, individual: true,
    };
}
// ── the CAPACITY side of reproduction — the skills the plan requires, DERIVED
// from its recipes (need → recipe → work-of-skill). "As individuals express their
// life, so they are": which skills a person must hold and MAINTAIN is read off
// the plan, not declared — change the recipes and you change the people. Each
// skill is a fragility: competence atrophying toward a floor (disuse), with thin
// redundancy (few willing) the sharper risk. Its maintenance is itself labour —
// the training/formation cost, made a derived demand.
export function capacityWire(planNeeds, recipeById) {
    const skills = {};
    for (const need of (planNeeds || [])) {
        const r = recipeById && need.recipeId ? recipeById[need.recipeId] : undefined;
        if (!r)
            continue;
        for (const step of (r.steps || [])) {
            if (!(step.in || []).some(f => f.action === "work"))
                continue; // a step that spends labour
            const k = step.name;
            if (!k)
                continue; // an unnamed step is nothing a skill row could cite
            const sk = skills[k] || (skills[k] = { emoji: step.emoji, runs: 0, willing: 0, needs: [] });
            sk.runs += need.runs || 0;
            sk.willing = Math.max(sk.willing, need.willing || 0);
            if (!sk.needs.includes(need.label))
                sk.needs.push(need.label);
        }
    }
    return Object.entries(skills).map(([name, sk]) => {
        // two FLOOR-only bands — you can't over-practise or have too many holders, so
        // each has a ceiling-free band: competence plateaus once practised/redundant.
        const practice = band(sk.runs, { hardLo: 0, softLo: 18 }); // runs keep a skill from atrophying
        const redundancy = band(sk.willing, { hardLo: 0, softLo: 2 }); // 2+ willing ≈ not a single point of failure
        const s = Math.max(1e-3, Math.min(1, 0.5 * practice + 0.5 * redundancy));
        return { kind: "skill", spec: "skill:" + name, control: (sk.emoji ? sk.emoji + " " : "") + name,
            group: "capacity · skills", unit: "practice", w: 6, s,
            skill: true, runs: sk.runs, willing: sk.willing, needs: sk.needs.join(", "),
            maintainH: 0.4 }; // keeping the skill sharp — the coupling into the energy floor
    });
}
// the total skill-maintenance labour a person owes to hold their trades — feeds
// back into their nutrition floor (personNutritionWire's maintainH).
export const skillMaintainTotal = (planNeeds, recipeById) => capacityWire(planNeeds, recipeById).reduce((h, sk) => h + (sk.maintainH || 0), 0);
// the whole individual wheel: reproduction of labour-power = the CONSUMPTION side
// (nutrient floors) + the CAPACITY side (skills, derived from the plan). One
// person, two coupled families.
export function reproductionWire(person, intake, labourHours, planNeeds, recipeById) {
    const nut = nutritionWire(person, intake, labourHours);
    const cap = capacityWire(planNeeds, recipeById);
    return { source: nut.source, individual: true, controls: [...nut.controls, ...cap] };
}
// ── per-person nutrition, with the CAPACITY COUPLING: the labour of maintaining
// one's skills (maintainH, derived from the plan) adds to committed labour, so
// production feeds back into the consumption floor — the cook's practice raises
// the cook's own energy need. One reproduction, closed.
export function personNutritionWire(person, maintainH = 0) {
    const labour = (person.labour || 0) + maintainH;
    const w = nutritionWire(person, person.intake || {}, labour);
    return { ...w, source: `${person.name || "a person"} · ${person.sex === "F" ? "female" : "male"} ${person.age}` +
            `${person.region && person.region !== "temperate" ? " · " + person.region : ""}${person.pregnant ? " · pregnant" : ""}${person.lactating ? " · lactating" : ""}` +
            `${(person.diet || []).length ? " · " + person.diet.map(t => t.replace(/^diet:/, "").replace(/^allergy:/, "no ")).join(", ") : ""}` +
            ` · labour ${labour.toFixed(1)}h (${(person.labour || 0)}+${maintainH.toFixed(1)} upkeep)` };
}
// ── the SOCIAL aggregation for per-individual fragilities: the per-category
// GEOMETRIC MEAN of slacks — exp((1/N)·Σ ln s_p), the per-capita form of the
// summed log-barrier Σφ(s_p). Worst-off-leaning (one member near their tip drags
// it toward 0), bounded in (0,1], scale-free. Carries the population `spread`
// [min,max] so the wheel can show whom the mean hides.
// NutritionWire, not Wire: every control it folds is a nutrient, which is what
// lets a reader reach `spread` without narrowing a union that has no skill arm
// in it to begin with.
export function aggregateNutrition(persons, maintainH = 0) {
    const cats = {};
    persons.forEach(p => personNutritionWire(p, maintainH).controls
        .forEach(c => (cats[c.spec] = cats[c.spec] || []).push(c)));
    const controls = Object.values(cats).map(arr => {
        const ss = arr.map(c => c.s);
        const s = Math.exp(ss.reduce((a, b) => a + Math.log(b), 0) / ss.length); // geometric mean
        return { ...arr[0], s, spread: [Math.min(...ss), Math.max(...ss)], count: ss.length, side: undefined };
    });
    return { controls, aggregate: true, source: `social · ${persons.length} people · geometric-mean slack (worst-off-leaning)` };
}
// a demo cohort so the aggregation is real — varied by sex, age, life-stage,
// climate and intake, with one badly-deficient member the geomean must feel.
export const POPULATION = [
    { id: "you", name: "you", sex: "F", age: 34, region: "temperate", labour: 5,
        intake: { energy: 2050, protein: 52, fibre: 17, iron: 11, calcium: 780, zinc: 7.5, iodine: 120, sodium: 3200, "vit C": 62, "vit A": 640, "vit D": 7, folate: 300, "vit B12": 3.1 } },
    { id: "sam", name: "Sam", sex: "M", age: 28, region: "cold", labour: 9,
        intake: { energy: 2600, protein: 70, fibre: 24, iron: 10, calcium: 900, zinc: 11, iodine: 140, sodium: 2600, "vit C": 80, "vit A": 820, "vit D": 9, folate: 380, "vit B12": 4.0 } },
    { id: "ana", name: "Ana", sex: "F", age: 41, region: "temperate", pregnant: true, labour: 3,
        intake: { energy: 2200, protein: 60, fibre: 20, iron: 14, calcium: 950, zinc: 9, iodine: 160, sodium: 2400, "vit C": 78, "vit A": 700, "vit D": 12, folate: 420, "vit B12": 3.4 } },
    { id: "mama", name: "mama", sex: "F", age: 67, region: "temperate", labour: 2,
        intake: { energy: 1700, protein: 48, fibre: 16, iron: 9, calcium: 900, zinc: 8, iodine: 120, sodium: 2800, "vit C": 65, "vit A": 640, "vit D": 9, folate: 340, "vit B12": 2.6 } },
    { id: "priya", name: "Priya", sex: "F", age: 22, region: "inland", labour: 6,
        intake: { energy: 1650, protein: 40, fibre: 12, iron: 8, calcium: 520, zinc: 6, iodine: 60, sodium: 3400, "vit C": 45, "vit A": 500, "vit D": 5, folate: 240, "vit B12": 2.0 } },
    { id: "kai", name: "Kai", sex: "M", age: 30, region: "temperate", labour: 7,
        intake: { energy: 2500, protein: 66, fibre: 30, iron: 11, calcium: 1050, zinc: 12, iodine: 150, sodium: 2200, "vit C": 95, "vit A": 900, "vit D": 16, folate: 410, "vit B12": 3.8 } },
];
// the selected individual (β=0 pole). DEMO_PERSON/DEMO_INTAKE kept as aliases.
export const DEMO_PERSON = POPULATION[0];
export const DEMO_INTAKE = POPULATION[0].intake;
