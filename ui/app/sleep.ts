// app/sleep.ts — the sleep span, in two weights.
//
// `sleepBlock` is the simple case the onboarding walk shows: one uniform
// "asleep from … until …" pair, writing directly into `profile().sleep`'s
// FIRST entry on every change — no draft, no "add" button, the way a plain
// field commits as you type it. Most people never need more than this.
//
// `createSleepSpansBlock` is settings' own, fuller editor: the SAME list
// several sleep: tags stack (agent-time.scm) made editable — each span its
// own hours and, optionally, the weekdays it is restricted to — for a
// night-shift split (one span for the work days, another for the rest) or a
// biphasic sleeper (a main span and a nap, both left at every day). Draft-
// then-add, the way days-away already works (app/away.ts): a span is
// composed, then added to the list; editing an existing one is removing it
// and adding it again, the same convention away.ts's own list already uses.
// Both write ui/app/rest.ts's SleepSpan[]; window-net-of-span (matching/
// availability.scm) reads whichever shape a person actually states.

import { html } from './template.js';
import type { Fragment } from './template.js';
import { signal } from './reactive.js';
import { profile, setProfile } from './profile.js';
import { snirtHours, disposableHours, isSleepSpan, WEEKDAYS } from './rest.js';
import type { SleepSpan } from './rest.js';
import { personOf } from './profile.js';
import { chip } from './chips.js';

const shortDay = (d: string): string => d.slice(0, 3);

/** The uniform "asleep from … until …" pair, and what it costs the day — restLine's own text, the shared reading onboarding and settings both show. */
export function sleepBlock(): Fragment {
  const p = profile();
  const you = personOf(p);
  const own = snirtHours(you), free = disposableHours(you);
  const span = you.sleepHours ?? 0;
  const main = p.sleep?.[0] ?? { from: "", to: "" };
  const rest = (p.sleep ?? []).slice(1);
  const setSpan = (key: "from" | "to") => (e: Event): void => {
    const next = { ...main, [key]: (e.target as HTMLInputElement).value || "" };
    setProfile({ sleep: next.from || next.to ? [next, ...rest] : rest });
  };
  const time = (key: "from" | "to", label: string): Fragment =>
    html`<input type="time" aria-label="${label}" value="${main[key] || ""}" onchange=${setSpan(key)}>`;
  return html`<div class="ob-pair"><span class="ob-lbl">asleep</span>${time("from", "asleep from")}${time("to", "asleep until")}</div>
    <small class="ob-hint">${span > 0 ? `${span.toFixed(1)} h of sleep, and the plan never schedules a shift into it — settings' own editor states a fuller pattern: different hours on different days, or a second span for a nap` : "optional: the span of the day you sleep. State it and the plan keeps it clear of every shift; leave it and your age's usual sleep is reserved"}</small>
    <small class="ob-hint">${p.labourHours > free
    ? `${p.labourHours} h is more than the day leaves: your body's own time — sleep, meals, washing — takes about ${own.toFixed(1)} h, so ${free.toFixed(1)} h at most can be offered`
    : `your body's own time — sleep, meals, washing, recovery — is reserved first, about ${own.toFixed(1)} h of the day; up to ${free.toFixed(1)} h can be offered, and the plan never schedules a shift into your sleep`}</small>`;
}

/** A draft span being composed — DAYS empty means every day, the common case. */
interface SpanDraft { from: string; to: string; days: string[]; }

/**
 * Every sleep span, editable: a list of what is stated, each removable, and
 * one draft — hours, then optionally the weekdays it is restricted to —
 * added to the list. FACTORY, called once per mount site, the same
 * convention as createAwayBlock.
 */
export function createSleepSpansBlock(): () => Fragment {
  const draft = signal<SpanDraft>({ from: "", to: "", days: [] });
  return (): Fragment => {
    const p = profile();
    const spans = p.sleep ?? [];
    const you = personOf(p);
    const d = draft();
    const toggleDay = (day: string): void =>
      draft.set({ ...d, days: d.days.includes(day) ? d.days.filter(x => x !== day) : [...d.days, day] });
    const add = (): void => {
      const s: SleepSpan = { from: d.from, to: d.to, ...(d.days.length ? { days: d.days } : {}) };
      if (!isSleepSpan(s) || !s.from || !s.to) return;
      setProfile({ sleep: [...spans, s] });
      draft.set({ from: "", to: "", days: [] });
    };
    const daysLabel = (days?: string[]): string => !days || days.length === 0 ? "every day" : days.map(shortDay).join(", ");
    return html`
      <label class="ob-field"><span>sleep spans</span>
        ${spans.length ? html`<ul class="ob-skills">${spans.map((s, i) => html`
          <li><span class="ob-skname">${s.from}–${s.to} · ${daysLabel(s.days)}</span>
            <a class="ob-x" title="remove" onclick=${() => setProfile({ sleep: spans.filter((_, j) => j !== i) })}>×</a></li>`)}</ul>` : ""}
        <div class="ob-pair">
          <input type="time" aria-label="from" value="${d.from}" onchange=${(e: Event) => draft.set({ ...d, from: (e.target as HTMLInputElement).value })}>
          <input type="time" aria-label="until" value="${d.to}" onchange=${(e: Event) => draft.set({ ...d, to: (e.target as HTMLInputElement).value })}>
          <button class="ob-chip" onclick=${add}>add</button>
        </div>
        <div class="ob-opts">${WEEKDAYS.map(day => chip(d.days.includes(day), shortDay(day), () => toggleDay(day), day))}</div>
        <small>${d.days.length ? `this span applies ${daysLabel(d.days)} only` : "no day ticked: this span applies every day. Tick days for a night-shift split (one span for the work days, another for the rest) — leave every span at every day for a biphasic pattern (a main span and a nap)"}</small>
        <small class="ob-hint">${spans.length ? `${(you.sleepHours ?? 0).toFixed(1)} h of sleep stated, summed across every span, and the plan never schedules a shift into any of them` : "several spans stack, in the order added — nothing stated yet reads as your age's usual sleep"}</small>
      </label>`;
  };
}
