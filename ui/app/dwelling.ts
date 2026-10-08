// app/dwelling.ts — what a person states about where they sleep, and the
// doors it goes through. housing.ts is the pure reading (the night owed,
// what a dwelling delivers); this is the state beside it, kept on the device
// like the profile and pushed to the commons a beat after the last edit.
//
// Three doors, one per answer. A DWELLING is one owned resource in the
// commons, measured by its tags exactly as the closure reads a unit
// (catalogues/housing-substance.scm resource->dwelling-unit): its floor area and rooms
// shared by everyone who sleeps there and the warmth it is kept at are the
// gradients its nights deliver, the gates are what an inspection of it would
// attest. Rent is NOT a need — it is the market recipe for the same night
// (recipes/dwelling.scm's rp-rent-shelter), paid from the purses members
// socialize when no lent bed covers you — so a stated rent rides the unit
// as its own price and nothing else. No fixed dwelling declares a night's
// shelter as a RIGHT at your home, the floor the demo pool matches to a lent
// bed; a spare bed is a bed offered at your home, the means the share
// face lends.

import { signal } from './reactive.js';
import { readJSON, writeJSON } from './store.js';
import { HANDLERS, EXT } from './core.js';
import { registerSettings } from './settings.js';
import type { SettingRow } from './settings.js';
import { html, panel } from './template.js';
import type { Fragment } from './template.js';
import { chip } from './chips.js';
import { home, homeName, setHome, lastFix } from './tabs/social/location.js';
import { locationOptions } from './slots/model.js';
import { rentPerNight, winterOf, summerOf, effectiveArea, GATES_DEFAULT, nightRead, OUTDOOR_CREDIT, GATES, WARMTH_WINTER, WARMTH_SUMMER, winterless } from './housing.js';
import { HOUSING_STANDARD, RENT_EUR_PER_NIGHT, ACCLIMATISED_CEILING } from './housing-catalogue.js';
import { profile, personOf, stepFreeField } from './profile.js';
import type { Measured } from './housing.js';
import { K } from "./keys.js";

// ── what the person states, and where it goes ──────────────────────────────

/** Tenure is custody, never a row of the vector (docs/rights.md); "none" is no fixed dwelling at all. A lodger's or a family member's home is the household's own here: what the plan needs to know is whether a landlord is paid, and whether a bed there is yours to lend. */
export type Tenure = "own" | "rent" | "none";
export const TENURES: { id: Tenure; label: string; hint: string }[] = [
  { id: "own",    label: "our own place",     hint: "yours, your family's, or a friend's — nobody outside it is paid" },
  { id: "rent",   label: "rented",            hint: "a landlord is paid" },
  { id: "none",   label: "no fixed dwelling", hint: "a night's shelter becomes your declared right" },
];

export interface Dwelling {
  tenure: Tenure;
  /** the whole dwelling's floor area, m² — 0 until stated */
  areaM2: number;
  /** private sleeping places — walled rooms, curtained places in a hall or yurt, huts of a compound — 0 until stated */
  rooms: number;
  /** covered outdoor and shared living space (veranda, courtyard), m² — 0 when none */
  outdoorM2: number;
  /** a WARMTH_WINTER chip: cold | ok */
  winter: string;
  /** a WARMTH_SUMMER chip: ok | hot */
  summer: string;
  /** who sleeps there a night, you included */
  people: number;
  /** the gates an inspection would attest — what the dwelling physically has */
  attests: string[];
  /** EUR a month the household pays, 0 when no landlord is */
  rentMonth: number;
  /** beds beyond the household's own — an offer at your home, lent on the share face */
  spareBeds: number;
  /** whether a bed offer was ever pushed, so zero can retire it and never asks the door before */
  bedsOffered?: boolean;
  stated: boolean;
}
const KEY = K.dwelling;
const DEFAULT: Dwelling = { tenure: "rent", areaM2: 0, rooms: 0, outdoorM2: 0, winter: "ok", summer: "ok", people: 1, attests: GATES_DEFAULT, rentMonth: 0, spareBeds: 0, stated: false };
// a record kept before the walk asked measurements (it asked a type) or with the old "lodged" tenure reads forward
const kept: Record<string, unknown> = readJSON<Record<string, unknown>>(KEY, {});
if (kept.tenure === "lodged") kept.tenure = ((kept.rentMonth as number) || 0) > 0 ? "rent" : "own";
delete kept.type; delete kept.warmth;
export const dwelling = signal<Dwelling>({ ...DEFAULT, ...(kept as Partial<Dwelling>) });

/** The measurements as the fold reads them, null until all three are stated. */
export const measured = (d: Dwelling = dwelling()): Measured | null =>
  d.areaM2 > 0 && d.rooms > 0 ? { areaM2: d.areaM2, rooms: d.rooms, outdoorM2: d.outdoorM2, warmthWinterDegC: winterOf(d.winter), warmthSummerDegC: summerOf(d.summer), people: Math.max(1, d.people) + Math.max(0, d.spareBeds) } : null;
export const housingNote = signal("");

const toggle = (xs: string[], id: string): string[] => xs.includes(id) ? xs.filter(x => x !== id) : [...xs, id];
export const toggleGate = (id: string): void => setDwelling({ attests: toggle(dwelling().attests, id) });

const said = (r: unknown, ok: string): string => typeof r === "string" && r.startsWith("err:") ? r.slice(4) : ok;

let pushTimer: ReturnType<typeof setTimeout> | null = null;
/** Tell the commons, a beat after the last change, so a run of edits is one write — each answer through the door that owns it. */
function push(): void {
  if (pushTimer) clearTimeout(pushTimer);
  pushTimer = setTimeout(() => {
    pushTimer = null;
    const d = dwelling();
    const at = home()?.place || "";
    if (!HANDLERS.declareDwelling || !HANDLERS.declareNeed || !HANDLERS.declareMeans || !HANDLERS.retireNeed) {
      housingNote.set("kept on this device — sign in to tell the commons"); return;
    }
    const jobs: Promise<string>[] = [];
    if (d.tenure === "none") {
      // the right: a night's shelter, seven a week, at home — the floor the plan defends before any want
      jobs.push(HANDLERS.declareNeed("spec-shelter", 7, "person-nights", at, "[]", "no fixed dwelling", "🏠", "", "",
                                     "a night's shelter", "[]", "", "floor", 0).then(r => said(r, "your right to a night's shelter is declared")));
    } else {
      if (!at) { housingNote.set("register your home above first — a dwelling stands at a place"); return; }
      const m = measured(d);
      if (!m) { housingNote.set("its floor area and rooms are what the night is read from — state them and the commons has your dwelling"); return; }
      jobs.push(HANDLERS.declareDwelling(at, effectiveArea(m, profile().region), m.rooms, m.warmthWinterDegC, m.warmthSummerDegC, m.people, JSON.stringify(d.attests), d.attests.length > 0,
                                         rentPerNight(d.rentMonth, d.people), d.tenure).then(r => said(r, "the commons has your dwelling")));
      jobs.push(HANDLERS.retireNeed("spec-shelter").then(() => ""));
    }
    // a spare bed is a bed (spec-bed on the wire) on offer at home; zero retires the offer (the means
    // door's own idiom) — asked only once an offer was ever made
    if (d.spareBeds > 0 || d.bedsOffered)
      jobs.push(HANDLERS.declareMeans("spec-bed", Math.max(0, d.spareBeds), "each", at, "[]",
                                      d.spareBeds > 0 ? "a spare bed at home — lend it into the commons on the share face" : "", "🏠",
                                      "a spare bed", "[]", "").then(r => said(r, d.spareBeds > 0 ? `${d.spareBeds} spare ${d.spareBeds === 1 ? "bed" : "beds"} on offer at home` : "")));
    // a door that throws (a spine not yet signed in dies rather than answering) reads as its own words, once
    Promise.all(jobs.map(j => j.catch((e: unknown) => String(e).includes("sign in") ? "sign in first" : `the commons did not answer: ${String(e)}`)))
      .then(words => {
        const unique = [...new Set(words.filter(Boolean))];
        housingNote.set(unique.includes("sign in first") ? "kept on this device — sign in to tell the commons" : unique.join(" · "));
        if (d.spareBeds > 0 && !d.bedsOffered) { const next = { ...dwelling(), bedsOffered: true }; dwelling.set(next); writeJSON(KEY, next); }
      });
  }, 400);
}

export function setDwelling(patch: Partial<Dwelling>): void {
  const next = { ...dwelling(), ...patch, stated: true };
  // no dwelling, no bed to lend: a night's shelter is met FROM lent beds, never by them
  if (next.tenure === "none") next.spareBeds = 0;
  dwelling.set(next);
  writeJSON(KEY, next);
  push();
}

/** The dwelling in a line, for the walk's summary. */
export function dwellingSummary(d: Dwelling = dwelling()): string {
  if (!d.stated) return "not stated";
  if (d.tenure === "none") return "no fixed dwelling — a night's shelter is your declared right";
  const t = TENURES.find(x => x.id === d.tenure)?.label ?? d.tenure;
  const size = d.areaM2 > 0 && d.rooms > 0 ? `${Math.round(d.areaM2)} m², ${d.rooms} sleeping ${d.rooms === 1 ? "place" : "places"}` : "size not stated";
  const w = [d.winter === "cold" ? "cold in winter" : "", d.summer === "hot" ? "too hot in summer" : ""].filter(Boolean).join(", ") || "warm enough";
  return `${size}, ${w}, ${t}, ${d.people} sleeping${d.rentMonth > 0 ? `, €${Math.round(d.rentMonth)} a month` : ""}${d.spareBeds > 0 ? `, ${d.spareBeds} spare` : ""}`;
}

// ── the fields, as one panel — settings and the onboarding walk both embed this ──

// what a typed coordinate pair reads as, for the home; kept out of `dwelling`
// itself, since it is a draft until "set", never a stated fact on its own
let draftLat = "", draftLng = "";
const homeSaid = signal("");
const fmtDeg = (p: { lat: number; lng: number }): string =>
  `${Math.abs(p.lat).toFixed(2)}°${p.lat < 0 ? "S" : "N"} ${Math.abs(p.lng).toFixed(2)}°${p.lng < 0 ? "W" : "E"}`;

/** The home block — a home is where you sleep: what is registered, and the three ways to register one — this fix, a place the scope names, or typed coordinates. */
const homeBlock = (): Fragment => {
  const h = home();
  const f = lastFix();
  const places = locationOptions(EXT);
  const say = (r: { ok: boolean; said: string }): void => homeSaid.set(r.said);
  const fromDraft = (): void => {
    const lat = parseFloat(draftLat), lng = parseFloat(draftLng);
    if (!isFinite(lat) || !isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) { homeSaid.set("a latitude −90…90 and a longitude −180…180"); return; }
    setHome("", lat, lng).then(say);
  };
  return html`
    <div class="ob-field"><span>your home</span>
      <div class="ob-derived"><b>${h ? homeName() : "none registered yet"}</b>
        <small>${h ? (h.lat != null ? `your own place at ${fmtDeg({ lat: h.lat, lng: h.lng! })}` : "a place this commons names") + " — where your dwelling stands, and where the plan routes to whenever no position is shared"
                  : "where your dwelling stands: the plan routes work and food to it when no position is shared, and cannot place you without one"}</small></div>
      <div class="ob-opts">
        ${f ? chip(false, "◉ this fix is my home", () => setHome("", f.lat, f.lng).then(say), "your own place, at the position just taken") : ""}
        ${places.length ? html`<select class="ob-sel" onchange=${(e: Event) => { const v = (e.target as HTMLSelectElement).value; if (v) setHome(v).then(say); }}>
          <option value="">a place this commons names…</option>${places.map(p => html`<option value="${p.id}" ${h && h.place === p.id ? "selected" : ""}>${p.name}</option>`)}</select>` : ""}
      </div>
      <div class="ob-pair">
        <input type="number" inputmode="decimal" step="any" min="-90" max="90" placeholder="latitude" value="${draftLat}" oninput=${(e: Event) => { draftLat = (e.target as HTMLInputElement).value; }}>
        <input type="number" inputmode="decimal" step="any" min="-180" max="180" placeholder="longitude" value="${draftLng}" oninput=${(e: Event) => { draftLng = (e.target as HTMLInputElement).value; }}>
        <button class="ob-chip" onclick=${fromDraft}>set</button>
      </div>
      <small>${homeSaid() || "or type the coordinates — a map app's share sheet gives them; what is kept is your own place, named by your key"}</small></div>`;
};

/**
 * The night you are owed, read against the dwelling you sleep in: every row
 * of the housing standard folded over your body (housing.ts), and what a
 * night in your dwelling delivers of it — the floors block's twin.
 */
const nightBlock = (): Fragment => {
  const p = profile();
  const d = dwelling();
  const housed = d.stated && d.tenure !== "none";
  const rows = nightRead(personOf(p), housed ? measured(d) : null, d.attests);
  const fmt = (x: number, unit: string): string => unit === "cert" ? (x >= 1 ? "held" : "none") : x >= 10 ? String(Math.round(x)) : String(Math.round(x * 100) / 100);
  const short = rows.filter(r => r.ok === false).length;
  return html`
    <div class="ob-floors">
      <div class="ob-floors-head"><span class="ob-lbl">your night</span>
        <small>${!housed || !measured(d) ? "what every night of yours is owed — the standard, folded over your climate and your age" + (p.stepFree ? " and your need for step-free access" : "") + (housed ? "; state the dwelling's size to read it against your night" : "")
                 : short === 0 ? "your dwelling delivers every row of it" : `${short} of ${rows.length} rows fall short in your dwelling — the plan reads the gap, never you`}</small></div>
      <div class="ob-frow">${rows.filter(r => r.owed > 0 || r.row.ceiling != null).map(r => html`<span class="ob-fl ${r.ok === false ? "short" : r.ok ? "ok" : ""}" title="${r.row.fn}: ${r.row.source}"><i>${r.row.name.toLowerCase()}</i>${fmt(r.owed, r.row.unit)}${r.row.ceiling != null ? `–${fmt(r.row.ceiling, r.row.unit)}` : ""} <u>${r.row.unit === "cert" ? "" : r.row.unit === "degC" ? "°C" : r.row.unit === "m2" ? "m²" : r.row.unit}</u>${r.got != null ? html`<em>${r.ok ? "✓" : `got ${fmt(r.got, r.row.unit)}`}</em>` : ""}</span>`)}</div>
      <small class="ob-hint">a night is intensive: two cold nights are not one warm one, so the plan gives you exactly one night a period and reads the mix of dwellings it was spent across. Each row names what it does for rest and its source when tapped.</small>
    </div>`;
};

/** The standard's own warmth row: the figures the copy quotes are its, never typed here. */
const warmth = HOUSING_STANDARD.find(r => r.id === "hs-warmth")!;

/** Every housing field, as one block — settings' "housing" section and the onboarding walk both embed this, not a copy of it. */
export const housingFields = (): Fragment => {
  const d = dwelling();
  const housed = d.tenure !== "none";
  const perNight = rentPerNight(d.rentMonth, d.people);
  const m = measured(d);
  const num = (key: "areaM2" | "rooms" | "people" | "outdoorM2", min: number) => (e: Event): void => {
    const n = parseFloat((e.target as HTMLInputElement).value);
    setDwelling({ [key]: isFinite(n) && n >= min ? n : 0 } as Partial<Dwelling>);
  };
  return html`
    ${homeBlock()}
    <div class="ob-field"><span>where you sleep</span>
      <div class="ob-opts">${TENURES.map(t => chip(d.stated && d.tenure === t.id, t.label, () => setDwelling({ tenure: t.id }), t.hint))}</div>
      <small>${!d.stated ? "who holds the place is custody, never a row of the standard: it says whether a landlord is paid and whether a bed there is yours to lend, not how good a night it gives"
               : d.tenure === "none" ? "a night's shelter is declared as your right, seven a week at your home: the plan meets it from beds people lend first, and pays a landlord from socialized purses when none is free"
               : (TENURES.find(t => t.id === d.tenure) || TENURES[0]).hint}</small></div>
    ${stepFreeField()}
    ${housed ? html`
    <details class="ob-why" open><summary>how big, how many places to sleep, and how many sleep there</summary>
    <div class="ob-pair">
        <input type="number" inputmode="decimal" min="1" step="1" placeholder="m²" value="${d.areaM2 || ""}" onchange=${num("areaM2", 1)}>
        <input type="number" inputmode="numeric" min="1" step="1" placeholder="sleeping places" value="${d.rooms || ""}" onchange=${num("rooms", 1)}>
        <input type="number" inputmode="numeric" min="1" max="30" step="1" placeholder="people" value="${d.people || ""}" onchange=${num("people", 1)}>
      </div>
      <small>floor area in m² — the lease or your own measure states it. A sleeping place is where someone sleeps with privacy, however your household keeps it: a walled room, a curtained or screened place in a hall or yurt, a hut of a compound. People is everyone who sleeps there, you included — grandparents, children and kin sleeping together is a way of living, never a fault of the dwelling. The standard is per person, so the two are shared by the third: ${m ? `${(effectiveArea(m, profile().region) / (Math.max(1, d.people) + d.spareBeds)).toFixed(1)} m² and ${(d.rooms / (Math.max(1, d.people) + d.spareBeds)).toFixed(2)} sleeping places each${d.spareBeds > 0 ? ", a lent bed counted as slept in" : ""}` : "a full dwelling gives each person less of it"}</small>
    ${winterless(profile().region) ? html`<label class="ob-field"><span>covered outdoor and shared space <em class="ob-opt">optional</em></span>
      <input type="number" inputmode="decimal" min="0" step="1" placeholder="m²" value="${d.outdoorM2 || ""}" onchange=${num("outdoorM2", 0)}>
      <small>${d.outdoorM2 > 0 ? `a veranda, roofed yard or shared courtyard: ${Math.round(OUTDOOR_CREDIT * 100)}% of it counts toward your floor area, since in your climate daily life is carried there` : "a veranda, roofed yard or shared courtyard where daily life is carried in your climate — half of it counts toward your floor area"}</small></label>` : ""}
    ${!winterless(profile().region) ? html`<div class="ob-field"><span>in winter it is</span>
      <div class="ob-opts">${WARMTH_WINTER.map(w => chip(d.winter === w.id, w.label, () => setDwelling({ winter: w.id }), w.hint))}</div>
      <small>${(WARMTH_WINTER.find(w => w.id === d.winter) || WARMTH_WINTER[1]).hint} — a winter night is owed ${warmth.floor} °C</small></div>` : ""}
    <div class="ob-field"><span>in summer it is</span>
      <div class="ob-opts">${WARMTH_SUMMER.map(w => chip(d.summer === w.id, w.label, () => setDwelling({ summer: w.id }), w.hint))}</div>
      <small>${(WARMTH_SUMMER.find(w => w.id === d.summer) || WARMTH_SUMMER[0]).hint} — no night is owed more than ${winterless(profile().region) ? ACCLIMATISED_CEILING : warmth.ceiling} °C${winterless(profile().region) ? " — a body used to your climate keeps well higher; and it has no winter, so no floor of warmth is asked" : ""}</small></div>
    <div class="ob-field"><span>it has</span>
      <div class="ob-opts">${GATES.map(g => chip(d.attests.includes(g.id), g.label, () => toggleGate(g.id), g.hint))}</div>
      <small>what an inspection of it would attest; your word stands until the scope's inspector says otherwise. Untick what it lacks — a gate the dwelling lacks is a row of your night that falls short.${d.tenure === "rent" ? " A rented place is held on a landlord's word: the plan reads that as a fragility, the way it reads any lent-in means." : ""}</small></div>
    ${d.tenure === "rent" ? html`<label class="ob-field"><span>rent a month <em class="ob-opt">optional</em></span>
      <input type="number" inputmode="decimal" min="0" step="10" placeholder="€" value="${d.rentMonth || ""}"
             onchange=${(e: Event) => { const n = parseFloat((e.target as HTMLInputElement).value); setDwelling({ rentMonth: isFinite(n) && n > 0 ? n : 0 }); }}>
      <small>${d.rentMonth > 0
        ? `€${perNight.toFixed(2)} a person-night, your dwelling's own price. Rent is never a need — it is the other way to reach a night, paid from the purses members socialize when no lent bed covers you`
        : `rent is not a need but the market recipe for the same night: the commons pays it from socialized purses when no lent bed covers you, at €${RENT_EUR_PER_NIGHT} a night unless your dwelling states its own`}</small></label>` : ""}
    </details>
    <div class="ob-field"><span>spare beds</span>
      <div class="ob-opts">${[0, 1, 2, 3].map(n => chip(d.stated && d.spareBeds === n, n === 0 ? "none" : String(n), () => setDwelling({ spareBeds: n })))}</div>
      <small>${d.spareBeds > 0
        ? `${d.spareBeds === 1 ? "a bed" : `${d.spareBeds} beds`} on offer at your home; lend ${d.spareBeds === 1 ? "it" : "them"} into the commons on the share face and a night can be matched to ${d.spareBeds === 1 ? "it" : "them"} — custody moves for a while, your right stays${d.tenure === "rent" ? ". From a rented place that is a lease question, your landlord's word before the commons'" : ""}`
        : "a bed beyond your household's own is a bed the commons can match a night to — the first thing a night's shelter is met from"}</small></div>` : ""}
    <p class="ob-note">${housingNote() || "kept on this device; told to the commons when you sign in"}</p>
    <details class="ob-why"><summary>your night, so far</summary>${nightBlock()}</details>`;
};

/** The housing panel, one element for the life of the page — settings' "housing" section and the onboarding walk both mount this, not their own copy. */
export const housingPanel = panel(housingFields, "attr");

export function registerDwellingSettings(): void {
  registerSettings({
    id: "housing", title: "housing", order: 33,
    sections: [
      { id: "housing", title: "housing",
        note: "Housing is a right the plan defends like food: a night is owed floor area, warmth, a private "
            + "place to sleep, safety, sanitation. Without a fixed dwelling, a night's shelter is declared as "
            + "your right and met from the beds people lend, or paid to a landlord from socialized purses.",
        rows: (): SettingRow[] => [ { kind: "custom", build: housingPanel } ] },
    ],
  });
}
