// app/profile.ts — who you are, as the reproduction floors and the diet read it.
//
// The subsistence catalogue computes a person's floors from ATTRIBUTES — sex,
// age, life stage, climate, committed labour — never from what they ate, and
// the eat recipe builds only the (person, food) pairs the person's diet allows
// (planner/knowledge/catalogues/diets.scm). Both read the same place: typed tags on the
// person's own agent record ("sex:F", "age:34", "pregnant:1", "diet:vegan",
// "allergy:nuts"). This module is the one door those tags come in by: a
// settings section states them, the browser keeps them (the fragility face
// reads "you" from here, offline too), and the commons is told through
// HANDLERS.setProfile whenever they change.
//
// The life-stage picker is a convenience over the same tags: "child" is an
// age band, "pregnant" a flag — the catalogue's own brackets, nothing new.

import { signal } from './reactive.js';
import { readJSON, writeJSON } from './store.js';
import { HANDLERS } from './core.js';
import { registerSettings } from './settings.js';
import type { SettingRow } from './settings.js';
import { html } from './template.js';
import type { Fragment } from './template.js';
import { chip } from './chips.js';
import { nutritionWire } from './nutrition.js';
import type { Person, Sex, NutrientControl } from './nutrition.js';
import { SELF_CONDITIONS } from './nutrition-catalogue.js';
import { positionForFloors } from './tabs/social/location.js';
import { restTags, sleepSpansHours } from './rest.js';
import type { Away, SleepSpan } from './rest.js';
import { K } from "./keys.js";
export type { Away, SleepSpan };

/** The life stages the picker names — each is what the catalogue reads. */
export type Stage = "adult" | "child" | "teen" | "elder" | "pregnant" | "lactating";
export const STAGES: { id: Stage; label: string; note: string }[] = [
  { id: "adult",     label: "adult",           note: "the adult table for your sex" },
  { id: "child",     label: "child (4–8)",     note: "a growing body: its own DRI band, set not scaled" },
  { id: "teen",      label: "adolescent (14–18)", note: "the adolescent band — iron and calcium above the adult's" },
  { id: "elder",     label: "elder (51+)",     note: "calcium and vitamin D up; iron down after menopause" },
  { id: "pregnant",  label: "pregnant",        note: "the developing dependent's floor folded into yours: iron, folate, energy, protein" },
  { id: "lactating", label: "lactating",       note: "energy, vitamins A and C, iodine up" },
];
/** The diets the eat recipe knows (knowledge/diets.scm *diets*, same ids). */
export const DIETS: { id: string; label: string; note: string }[] = [
  { id: "",            label: "everything",  note: "no food refused" },
  { id: "vegetarian",  label: "vegetarian",  note: "no meat, fish or shellfish; the iron floor rises 1.8× (non-haem iron)" },
  { id: "vegan",       label: "vegan",       note: "no animal food at all; iron 1.8×, zinc 1.5×" },
  { id: "pescatarian", label: "pescatarian", note: "no meat; fish stays" },
  { id: "halal",       label: "halal",       note: "no pork, no alcohol, meat only when halal" },
  { id: "kosher",      label: "kosher",      note: "no pork or shellfish, meat only when kosher" },
];
/** Refusals that stack on any diet (each is one tag). */
export const EXTRA: { id: string; label: string }[] = [
  { id: "no-dairy",  label: "no dairy" },
  { id: "no-gluten", label: "no gluten" },
];
/** The allergens a person can name (knowledge/diets.scm *allergens*). */
export const ALLERGENS = ["milk", "eggs", "nuts", "peanuts", "soy", "gluten", "fish", "shellfish", "sesame"];
export const REGIONS: { id: string; label: string }[] = [
  { id: "temperate", label: "temperate" }, { id: "cold", label: "cold" },
  { id: "inland", label: "inland" }, { id: "hotArid", label: "hot and arid" },
];

export interface Profile {
  sex: Sex; stage: Stage; age: number; region: string; labourHours: number;
  diet: string; extra: string[]; allergies: string[];
  /** optional, both or neither: rescale the energy and protein floor to this body (the catalogue's L2c) */
  heightCm?: number; weightKg?: number;
  /** elevation in metres, read off the fix when the device gives one */
  altitudeM?: number;
  /** the spans of the day this person sleeps — several stack (a night-shift split, a main span and a nap). The plan never schedules a shift into any of them, and their summed length is the sleep they state. */
  sleep?: SleepSpan[];
  /** days this person is unavailable — ill, resting or away — each a span of dates and a kind, no reason. The plan reads the three alike and finds nobody on those days. */
  away?: Away[];
  /** this body needs step-free access — the housing catalogue's accessibility gate rises from 0 to 1 for it */
  stepFree?: boolean;
  /** this body cannot use the available transit as it stands (berlin-transit.scm's "transit-access") — an
   *  accommodation fact, like step-free above, not a trained competency: unmarked, the plan may route a trip
   *  through it; marked, it never assigns one. Walking and cycling are the OTHER two ride-mode capabilities —
   *  real, trainable, decaying competencies, so they are declared skills (standing.ts), not a profile flag. */
  cannotUseTransit?: boolean;
  /** the conditions stated about this body (catalogue self-conditions); told to the commons like every other field here */
  self: string[];
  /** days of the week you can give hours on, 0 = Sunday. Kept on this device only — not yet an availability door, so not in profileTags(). */
  days: number[];
  /** set once the person has stated anything — until then the demo cohort's first member stands in */
  stated: boolean;
}
const DEFAULT: Profile = { sex: "F", stage: "adult", age: 30, region: "temperate", labourHours: 5, diet: "", extra: [], allergies: [], self: [], days: [1, 2, 3, 4, 5], stated: false };

/** The conditions a person may state about their own body, as the catalogue names them; the rows live there. */
export const SELF: { id: string; label: string }[] = Object.entries(SELF_CONDITIONS).map(([id, c]) => ({ id, label: c.label }));
export const monthNow = (): number => new Date().getMonth() + 1;
const KEY = K.profile;

export const profile = signal<Profile>({ ...DEFAULT, ...readJSON<Partial<Profile>>(KEY, {}) });
export const profileNote = signal("");

/** The age the stage implies when the person has not stated one. */
function ageFor(p: Profile): number {
  if (p.stage === "child") return 6;
  if (p.stage === "teen") return 16;
  if (p.stage === "elder") return Math.max(p.age, 67);
  return p.age;
}

/**
 * The derived and private facts the layers read beside the stated ones: where
 * the body stands (the fix, else the registered home) and what it carries. How
 * hard the hours are is not among them: that is the work's own fact — the
 * effort each recipe process states as its "work:<class>" — never the person's.
 */
export function whereAndSelf(p: Profile = profile()): Pick<Person, "altitudeM" | "lat" | "month" | "selfConditions"> {
  const f = positionForFloors();
  return { altitudeM: p.altitudeM, lat: f ? f.lat : undefined, month: monthNow(), selfConditions: p.self };
}

/** Whether both body figures are stated — either alone says little, and the catalogue reads neither. */
export const bodyStated = (p: Profile = profile()): boolean => !!(p.heightCm && p.weightKg && p.heightCm > 0 && p.weightKg > 0);

/** The typed tags the commons reads: agent->subsistence-ctx and diets.scm parse most of these; transit-access is the skill the transit modes ask, which engine.scm's mobility-skills reads off the same classifiedAs (walk and cycle are declared skills). */
export function profileTags(p: Profile = profile()): string[] {
  const tags = [`sex:${p.sex}`, `age:${ageFor(p)}`, `region:${p.region}`, `labour-hours:${p.labourHours}`];
  if (p.altitudeM != null) tags.push(`altitude-m:${Math.round(p.altitudeM)}`);
  // a whole-degree latitude is the coarse fact the winter-sun row needs, and no finer than the region tag already tells
  const f = positionForFloors(); if (f) tags.push(`lat:${Math.round(f.lat)}`);
  for (const id of p.self) tags.push(`self:${id}`);
  if (p.stage === "pregnant") tags.push("pregnant:1");
  if (p.stepFree) tags.push("step-free");
  if (!p.cannotUseTransit) tags.push("transit-access");
  tags.push(...restTags(p.sleep, p.away));
  if (p.stage === "lactating") tags.push("lactating:1");
  if (bodyStated(p)) tags.push(`height-cm:${p.heightCm}`, `weight-kg:${p.weightKg}`);
  if (p.diet) tags.push(`diet:${p.diet}`);
  for (const x of p.extra) tags.push(`diet:${x}`);
  for (const a of p.allergies) tags.push(`allergy:${a}`);
  return tags;
}

/**
 * The person a profile states, as every catalogue reads them — nutrition, the
 * housing standard and the rest floor take this one object, the way the
 * commons reads one context off the agent's tags (agent->subsistence-ctx). The
 * age is the stage's own when none is stated (ageFor), the same age the tags carry.
 */
export function personOf(p: Profile = profile()): Person {
  const span = p.sleep ? sleepSpansHours(p.sleep) : undefined;
  return { id: "you", name: "you", sex: p.sex, age: ageFor(p), region: p.region, labour: p.labourHours,
           pregnant: p.stage === "pregnant", lactating: p.stage === "lactating",
           diet: profileTags(p).filter(t => t.startsWith("diet:") || t.startsWith("allergy:")),
           ...(p.stepFree ? { stepFree: true } : {}), ...(span != null && span > 0 ? { sleepHours: span } : {}),
           ...(bodyStated(p) ? { heightCm: p.heightCm, weightKg: p.weightKg } : {}), ...whereAndSelf(p) };
}

/** The person the fragility face draws as "you", when a profile is stated. */
export function profileOverlay(): Partial<Person> {
  const p = profile();
  if (!p.stated) return {};
  const { id: _id, name: _name, ...you } = personOf(p);
  return you;
}

let pushTimer: ReturnType<typeof setTimeout> | null = null;
/** Tell the commons, a beat after the last change, so a run of edits is one write. */
function push(): void {
  if (pushTimer) clearTimeout(pushTimer);
  pushTimer = setTimeout(() => {
    pushTimer = null;
    if (!HANDLERS.setProfile) { profileNote.set("kept on this device — sign in to tell the commons"); return; }
    HANDLERS.setProfile(JSON.stringify(profileTags()), (r: unknown) => {
      profileNote.set(typeof r === "string" && r.startsWith("err:") ? r.slice(4) : "the commons has it — your floors and your menu follow");
    });
  }, 400);
}

export function setProfile(patch: Partial<Profile>): void {
  const next = { ...profile(), ...patch, stated: true };
  profile.set(next);
  writeJSON(KEY, next);
  push();
}

/** The catalogue's age band, as the age alone places you — what the DRI tables split on. */
const bandFor = (age: number): string =>
  age < 4 ? "infant and toddler band" : age < 9 ? "child band (4–8): set, not scaled" : age < 14 ? "child band (9–13)"
  : age < 19 ? "adolescent band (14–18): iron and calcium above the adult's" : age < 51 ? "adult table" : "elder table (51+): calcium and vitamin D up, iron down after menopause";

/** The ages at which pregnancy or lactation is a question worth raising — the catalogue's own bracket. */
export const canCarry = (age: number): boolean => age >= 12 && age <= 55;

/** The two SELF_CONDITIONS the catalogue's own fields already gate elsewhere (heavy-menses behind bodyFields' own mayCarry check, partial-feeding behind its own lactating stage) — named once so a condition is never asked of a body it cannot describe. Every id absent here applies to anyone. */
const SELF_GATES: Record<string, (p: Profile) => boolean> = {
  "heavy-menses": p => p.sex === "F" && canCarry(p.age),
  "partial-feeding": p => p.stage === "lactating",
};
const selfGate = (id: string): ((p: Profile) => boolean) => SELF_GATES[id] ?? (() => true);

export const regionLabel = (id: string): string => id === "highLatitude" ? "high latitude" : (REGIONS.find(r => r.id === id) || REGIONS[0]).label;

/**
 * The floors the answers so far derive: every nutrient's adequate floor,
 * beside a plain reference adult (temperate, no diet, no labour) so each shift
 * your own facts make is visible as the arrow it is.
 */
export const floorsBlock = (): Fragment => {
  const p = profile();
  const me = nutritionWire(personOf(p), undefined, p.labourHours).controls;
  const ref = nutritionWire({ id: "ref", name: "ref", sex: p.sex, age: 30, region: "temperate" }, undefined, 0).controls;
  const refBy: Record<string, NutrientControl> = {};
  for (const c of ref) refBy[c.spec] = c;
  const groups = [...new Set(me.map(c => c.group))];
  const fmt = (x: number): string => x >= 100 ? String(Math.round(x)) : x >= 10 ? x.toFixed(1) : x.toFixed(x >= 1 ? 1 : 2);
  const shifted = me.filter(c => refBy[c.spec] && Math.abs(c.rda / refBy[c.spec].rda - 1) > 0.02).length;
  return html`
    <div class="ob-floors">
      <div class="ob-floors-head"><span class="ob-lbl">your floors, so far</span><small>${shifted === 0 ? "the reference adult's — nothing stated shifts them yet" : `${shifted} of ${me.length} shifted by what you said`}</small></div>
      ${groups.map(g => html`<div class="ob-fgrp"><b>${g}</b><div class="ob-frow">${me.filter(c => c.group === g).map(c => {
        const r = refBy[c.spec];
        const k = r ? c.rda / r.rda : 1;
        const dir = k > 1.02 ? "up" : k < 0.98 ? "down" : "";
        return html`<span class="ob-fl ${dir}" title="${r ? `reference adult: ${fmt(r.rda)} ${c.unit}` : ""}"><i>${c.spec}</i>${fmt(c.rda)} <u>${c.unit}</u>${dir === "up" ? html`<em>↑${Math.round((k - 1) * 100)}%</em>` : dir === "down" ? html`<em>↓${Math.round((1 - k) * 100)}%</em>` : ""}</span>`; })}</div></div>`)}
      <small class="ob-hint">a floor is what the plan guarantees is there for you each day; the toxicity ceiling above each is the same catalogue's. Nobody weighs your plate against it.</small>
    </div>`;
};

/** This body's step-free need, asked wherever it is relevant — the housing walk ("getting in") and the drawer's Attributes tab (share.ts) both show this one fragment rather than their own copy of it. */
export const stepFreeField = (): Fragment => html`
    <div class="ob-field"><span>step-free access</span>
      <div class="ob-opts">
        ${chip(!profile().stepFree, "steps are fine", () => setProfile({ stepFree: false }))}
        ${chip(!!profile().stepFree, "I need step-free access", () => setProfile({ stepFree: true }), "a dwelling reached without a step")}
      </div>
      <small>${profile().stepFree ? "step-free access is owed to you: the housing standard's accessibility gate rises from 0 to 1 for your night" : "the housing standard owes step-free access to whoever needs it, and asks nothing of anyone else"}</small></div>`;

/** Whether this body can use the U-/S-Bahn, tram or bus as they stand (engine.scm's "transit-access") — an
 *  accommodation fact, the same shape as step-free above. Walking and cycling moved to the skills door (your
 *  profile → skills): they're real, trainable, decaying competencies, not a settled fact about the network. */
export const mobilityField = (): Fragment => html`
    <div class="ob-field"><span>getting around</span>
      <div class="ob-opts">
        ${chip(!profile().cannotUseTransit, "transit is fine", () => setProfile({ cannotUseTransit: false }))}
        ${chip(!!profile().cannotUseTransit, "I can't use transit as it stands", () => setProfile({ cannotUseTransit: true }), "the U-/S-Bahn, tram or bus, as the network stands today")}
      </div>
      <small>${profile().cannotUseTransit ? "the plan never routes a transit trip to you — it finds another way instead of assuming you able" : "the plan may route a trip by U-/S-Bahn, tram or bus; marking this keeps it from ever assigning one"}</small></div>`;

/** The body fields alone — sex, age, pregnancy/lactation, height and weight; no floors block, so a caller showing several such groups at once (the drawer's Attributes tab) states it only the once. */
export const bodyFields = (): Fragment => {
  const p = profile();
  const female = p.sex === "F";
  // the question is asked only of someone it can apply to: female, and of an age that can carry — outside that band it is not raised
  const mayCarry = female && canCarry(p.age);
  const repro = p.stage === "pregnant" ? "pregnant" : p.stage === "lactating" ? "lactating" : "neither";
  const setRepro = (r: "pregnant" | "lactating" | "neither"): void => setProfile({ stage: r === "neither" ? "adult" : r });
  return html`
    <div class="ob-field"><span>sex</span>
      <div class="ob-opts">
        ${chip(female, "female", () => setProfile({ sex: "F" }))}
        ${chip(!female, "male", () => setProfile({ sex: "M", stage: p.stage === "pregnant" || p.stage === "lactating" ? "adult" : p.stage }))}
      </div>
      <small>the reference intake tables split by sex from age nine</small></div>
    <label class="ob-field"><span>age</span>
      <input type="number" inputmode="numeric" min="0" max="120" value="${p.age}"
             onchange=${(e: Event) => { const n = parseInt((e.target as HTMLInputElement).value, 10); if (isFinite(n) && n >= 0) setProfile({ age: n, stage: (p.stage === "pregnant" || p.stage === "lactating") && canCarry(n) ? p.stage : "adult" }); }}>
      <small>${bandFor(p.age)} — the band follows the age</small></label>
    ${mayCarry ? html`<div class="ob-field"><span>carrying or feeding a child</span>
      <div class="ob-opts">
        ${chip(repro === "neither", "neither", () => setRepro("neither"))}
        ${chip(repro === "pregnant", "pregnant", () => setRepro("pregnant"), "the developing dependent's floor folded into yours: iron, folate, energy, protein")}
        ${chip(repro === "lactating", "lactating", () => setRepro("lactating"), "energy, vitamins A and C, iodine up")}
      </div>
      <small>${repro === "pregnant" ? "the dependent's floor is folded into yours: iron, folate, energy, protein" : repro === "lactating" ? "energy, vitamins A and C and iodine rise" : "either one raises your floors for as long as it lasts"}</small></div>` : ""}
    <div class="ob-field"><span>height and weight <em class="ob-opt">optional</em></span>
      <div class="ob-pair">
        <input type="number" inputmode="decimal" min="40" max="250" placeholder="cm" value="${p.heightCm || ""}"
               onchange=${(e: Event) => { const n = parseFloat((e.target as HTMLInputElement).value); setProfile({ heightCm: isFinite(n) && n > 0 ? n : undefined }); }}>
        <input type="number" inputmode="decimal" min="2" max="300" placeholder="kg" value="${p.weightKg || ""}"
               onchange=${(e: Event) => { const n = parseFloat((e.target as HTMLInputElement).value); setProfile({ weightKg: isFinite(n) && n > 0 ? n : undefined }); }}>
      </div>
      <small>${bodyStated(p)
        ? "the energy floor is read for your body by the reference intake's energy equation, and protein at its grams per kilogram — the two floors a body's size moves"
        : "without them the tables' reference body of your age and sex stands in; both are needed, either alone says little. Stated, they stay on this device until you sign in."}</small></div>`;
};

/** This body's own conditions (SELF_CONDITIONS, each a floor the catalogue yields on, never a number stated) — gated so a condition this body cannot have is never asked. Told to the commons the same as every other field in this drawer, so the plan provisions for it too. */
export const selfFields = (): Fragment => {
  const p = profile();
  const toggle = (xs: string[], id: string): string[] => xs.includes(id) ? xs.filter(x => x !== id) : [...xs, id];
  const visible = SELF.filter(c => selfGate(c.id)(p));
  return html`
    <div class="ob-field"><span>stated about this body</span>
      <div class="ob-opts">${visible.map(c => chip(p.self.includes(c.id), c.label, () => setProfile({ self: toggle(p.self, c.id) })))}</div>
      <small>each is a condition only you state, never a number; the catalogue yields a floor where a floor would harm</small></div>`;
};

/** The diet fields alone — diet, extras, allergies; no floors block, for the same reason bodyFields has none. */
export const dietFields = (): Fragment => {
  const p = profile();
  const toggle = (xs: string[], id: string): string[] => xs.includes(id) ? xs.filter(x => x !== id) : [...xs, id];
  return html`
    <div class="ob-opts">${DIETS.map(d => chip(p.diet === d.id, d.label, () => setProfile({ diet: d.id }), d.note))}</div>
    <small class="ob-hint">${(DIETS.find(d => d.id === p.diet) || DIETS[0]).note}</small>
    <div class="ob-field"><span>also</span>
      <div class="ob-opts">${EXTRA.map(x => chip(p.extra.includes(x.id), x.label, () => setProfile({ extra: toggle(p.extra, x.id) })))}</div></div>
    <div class="ob-field"><span>allergies</span>
      <div class="ob-opts">${ALLERGENS.map(a => chip(p.allergies.includes(a), a, () => setProfile({ allergies: toggle(p.allergies, a) })))}</div>
      <small>an allergen is left out of the menu the plan builds, whatever the diet. That is planning, not allergen safety: it does not check labels or cross-contact, so read the label and ask whoever cooked.</small></div>`;
};

/** The panels the profile's three sections show: its own chip editors, mounted by app/attributes.ts — the
 *  single rendering of each, whether read from settings or embedded in the onboarding walk (tabs/onboard.ts). */
export interface ProfilePanels { diet(): HTMLElement; body(): HTMLElement; health(): HTMLElement }

export function registerProfileSettings(panels: ProfilePanels): void {
  registerSettings({
    id: "body", title: "diet, body and health", order: 32,
    sections: [
      { id: "diet", title: "diet",
        note: "What you will not eat. The floors stay where they are; the plan closes them from the "
            + "foods you accept, and says so when the menu cannot. A preference among allowed foods is a "
            + "want, stated on the ledger, never a rule here.",
        rows: (): SettingRow[] => [ { kind: "custom", build: panels.diet } ] },
      { id: "body", title: "body",
        note: "What your reproduction floors are computed FROM — never from what you ate. "
            + "Provision to the floor, do not verify the plate: nobody counts your plate, and "
            + "the plan still guarantees the food is there for a person of this description.",
        rows: (): SettingRow[] => [
          { kind: "custom", build: panels.body },
          { kind: "select", label: "climate", note: "the geography layer: a cold or hot region shifts energy and sodium",
            options: () => REGIONS.map(r => ({ value: r.id, label: r.label })),
            get: () => profile().region, set: v => setProfile({ region: v }) },
          { kind: "note", text: "hours a day of real work is asked under \"your time\" — it raises the energy and protein floor the same way, read against the week you give." },
          { kind: "note", text: `derived, never asked: climate ${profile().region}${profile().altitudeM != null ? `, ${Math.round(profile().altitudeM as number)} m` : ""}${positionForFloors() ? `, ${Math.abs(positionForFloors()!.lat).toFixed(0)}° ${positionForFloors()!.lat < 0 ? "S" : "N"} in month ${monthNow()}` : ""} — a high elevation raises energy and iron, a dark winter beyond 35° raises vitamin D` },
          { kind: "note", text: profileNote() || "kept on this device; told to the commons when you are signed in" },
        ] },
      { id: "self", title: "health",
        note: "What only you know about this body. Each is a condition the catalogue sources — you state it, "
            + "never a number — and it is the one place the tables yield to the body, lowering a floor where a floor would harm. "
            + "Told to the commons like everything else you state here, so the plan provisions for it too. "
            + "The values come from published reference tables and may not fit you.",
        rows: (): SettingRow[] => [
          { kind: "note", text: "Health information is optional, and your explicit consent is what lets the plan use it: tell it only what you accept the people your settings let see it to know. "
              + "These are reference values for provisioning a commune's food, not a diagnosis or a diet prescription, and the service is not a medical device. "
              + "For a condition such as kidney disease, malabsorption or pregnancy, follow your clinician, not the plan; never change a medicine or a treatment because of it. In an emergency call your local emergency number." },
          { kind: "custom", build: panels.health } ] },
    ],
  });
}
