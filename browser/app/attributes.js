// app/attributes.ts — diet, body, health and time, each its own panel.
//
// What the plan reads your floors and your week from, stated once: here (the
// account sheet → diet, body, health, time) or in the onboarding walk, which
// embeds these same panels (tabs/onboard.ts) rather than its own copy. The
// fields are profile.ts's own — this module composes them with the UI-only
// pieces (sleep, away) profile.ts cannot import without a cycle (both import
// profile.ts themselves) — one editor, one door, so a change made in any of
// the homes shows in the others. Each panel is one element for the life of
// the page, with its own effect redrawing it when the state it reads moves.
import { signal } from './reactive.js';
import { html, panel } from './template.js';
import { profile, setProfile, dietFields, bodyFields, stepFreeField, mobilityField, selfFields, floorsBlock } from './profile.js';
import { createAwayBlock } from './away.js';
import { sleepBlock } from './sleep.js';
import { chip } from './chips.js';
import { EXT } from './core.js';
import { CURRENCIES, currency, setCurrency, currencyInForce, currencyForHere, perHour, fmtMoney } from './money.js';
import { registerSettings } from './settings.js';
// render() replaces a panel's children wholesale, so a plain <details open> would
// lose its state on the next redraw — which a chip click inside it causes at once.
// This signal is "ongoing"'s open state's real home; the markup only reflects it.
const ongoingOpen = signal(true);
/** The closed "ongoing" summary: a private count only, never which conditions — naming them would defeat collapsing. */
const ongoingSummary = () => { const n = profile().self.length; return n === 0 ? "nothing stated" : `${n} stated`; };
const awayBlock = createAwayBlock();
/** What you eat and what you refuse, with the floors it moves. */
export const dietPanel = panel(() => html `${dietFields()}${floorsBlock()}`, "attr");
/** Your body as the tables read it: sex, age, size, and what the dwelling and the network must allow. */
export const bodyPanel = panel(() => html `${bodyFields()}${stepFreeField()}${mobilityField()}${floorsBlock()}`, "attr");
/** What only you know about this body. The days you are away are the health page's own "days away" section, not repeated here. */
export const healthPanel = panel(() => html `
  <details class="ob-why" ${ongoingOpen() ? "open" : ""}
            ontoggle=${(e) => ongoingOpen.set(e.currentTarget.open)}>
    <summary><span class="fm-lbl">ongoing</span><small>${ongoingSummary()}</small></summary>
    ${selfFields()}
  </details>`, "attr");
// ── time: hours a day, which days, what it earns ──────────────────────────
const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const HOURS = [2, 5, 8, 10, 12];
const toggleDay = (d) => { const days = profile().days; setProfile({ days: days.includes(d) ? days.filter(x => x !== d) : [...days, d].sort() }); };
/**
 * What the hours earn. Credit is denominated in hours (playnet.typ §The
 * credit identity): every matched hour accrues to your contribution, and
 * your drawable credit is your consumer voice scaled to the pool. The
 * hour-for-hour reading is the labor certificate the section describes; the
 * live figure is the commons' own, once it has answered (EXT.credit). The
 * currency line is the shop's: a currency is an external asset priced at
 * what the commons spent to acquire it (app/money.ts).
 */
const earningsBlock = () => {
    const p = profile();
    const week = p.days.length * p.labourHours;
    const cr = EXT.credit;
    const live = cr && isFinite(Number(cr.drawable)) ? cr : null;
    const code = currencyInForce();
    const rate = perHour(code);
    const here = currencyForHere();
    const codes = [...new Set([here, "USD", "EUR", "XMR", code].filter((c) => !!c))];
    return html `
    <div class="ob-earn">
      <div class="ob-earn-row"><b>${week} h</b><span>a week of contribution${week ? `, about ${Math.round(week * 52 / 12)} h a month` : ""}</span></div>
      ${live ? html `<div class="ob-earn-row"><b>${Number(live.drawable).toFixed(1)} h</b><span>drawable now, the commons says${isFinite(Number(live.voice)) ? ` — your voice ${(Number(live.voice) * 100).toFixed(1)}% of a ${Math.round(Number(live.pool) || 0)} h pool` : ""}</span></div>` : ""}
      <div class="ob-earn-row">${rate
        ? html `<b>≈ ${fmtMoney(code, week * rate.amount)}</b><span>a week${week ? `, about ${fmtMoney(code, week * 52 / 12 * rate.amount)} a month` : ""}, if drawn as ${code} — ${fmtMoney(code, rate.amount)} an hour, what this commons spent to acquire ${rate.unit}</span>`
        : html `<b>${code}</b><span>this commons holds no ${code} yet; its rate in hours appears once it acquires some</span>`}</div>
      <div class="ob-field"><span>read credit in</span>
        <div class="ob-opts">${codes.map(c => chip(c === code, `${c}${c === here && !currency() ? " · here" : ""}`, () => setCurrency(c === here ? "" : c)))}
          <select class="ob-cur" onchange=${(e) => setCurrency(e.target.value)}>
            <option value="">more…</option>${CURRENCIES.filter(c => !codes.includes(c.code)).map(c => html `<option value="${c.code}">${c.code} · ${c.name}</option>`)}</select></div>
        <small>${currency() ? `your pick, kept on this device` : here ? `following where this device says it is; pick one to fix it` : `the dollar until you pick one`} — credit itself never converts: the shop sells a currency like any other good, and only outward</small></div>
    </div>`;
};
/** Hours a day, which days, what it earns — settings' "time" section and the onboarding walk both embed this. */
export const timePanel = panel(() => {
    const p = profile();
    return html `
    <div class="ob-field"><span>hours a day</span>
      <div class="ob-opts">${HOURS.map(h => chip(p.labourHours === h, `${h} h`, () => setProfile({ labourHours: h })))}</div>
      <small>real work, a day you work: it raises your own energy and protein floor as much as it fills the plan. How hard an hour is comes from the work itself — each recipe states its own effort — never from you</small></div>
    ${sleepBlock()}
    ${awayBlock()}
    <div class="ob-field"><span>which days</span>
      <div class="ob-opts">${DAYS.map((d, i) => chip(p.days.includes(i), d, () => toggleDay(i)))}</div>
      <small>${p.days.length === 0 ? "no day given — the plan will hold no shift for you" : `${p.days.length * p.labourHours} h a week on offer; kept on this device, and the clock face lets you shape each day`}</small></div>
    <details class="ob-why"><summary>what it earns</summary>${earningsBlock()}</details>
    <details class="ob-why"><summary>your floors, so far</summary>${floorsBlock()}</details>`;
}, "attr");
export function registerTimeSettings() {
    registerSettings({
        id: "time", title: "your time", order: 34,
        sections: [
            { id: "time", title: "your time",
                note: "The plan fills needs with hours people give. A day you did not give is a day no shift lands "
                    + "on; every matched hour accrues to your credit, counted in hours, and more hours also raise "
                    + "your own energy floor, because labour has to be reproduced.",
                rows: () => [{ kind: "custom", build: timePanel }] },
        ],
    });
}
