// app/away.ts — days a person is ill, resting or away, declared once and read
// wherever it makes sense to declare it: the onboarding walk, settings, and
// the calendar's day view (project's own placement question — see docs/
// planning/food/reproduction-of-labour-power.md §2c). One component, three homes,
// so the interface is never more than the amount of friction the declaration
// itself already carries: a kind and two dates, a few seconds' work, no
// proof and no cap (the plan wants people to declare early) — not a single
// reflex tap, and not buried three menus deep either.
//
// The draft (kind + the two dates being typed) is this component's own
// signal, not a global: mounting it twice — settings AND the calendar, say —
// gives each mount its own in-progress draft, and neither clobbers the
// other's "add" button mid-type.
import { html } from './template.js';
import { signal } from './reactive.js';
import { profile, setProfile } from './profile.js';
import { AWAY_KINDS, isAway } from './rest.js';
import { chip } from './chips.js';
const dayNow = () => new Date().toISOString().slice(0, 10);
/** Every day PROFILE has declared away that touches DATE (an ISO "YYYY-MM-DD", today's by default) — the calendar grid's own reading of whether today carries a marker. */
export function awayOn(date = dayNow(), p = profile()) {
    return (p.away ?? []).find(a => a.from <= date && date <= a.to);
}
/**
 * Days away: kind chips, a date range, the running list. A FACTORY, called
 * ONCE per mount site (module scope of whichever screen embeds it) to bind
 * one draft signal — `const awayBlock = createAwayBlock();` — then embedded
 * in a template as `${awayBlock()}` on every render, the same as any other
 * Fragment-producing function here. Two mount sites showing at once (settings
 * open beside the calendar, say) each get their own draft: neither clobbers
 * the other's in-progress "add" mid-type.
 */
export function createAwayBlock() {
    const draft = signal({ kind: "sick", from: "", to: "" });
    return () => {
        const p = profile();
        const list = p.away ?? [];
        const d = draft();
        const add = () => {
            const a = { ...d, from: d.from || dayNow(), to: d.to || d.from || dayNow() };
            if (!isAway(a))
                return;
            setProfile({ away: [...list, a] });
            draft.set({ kind: d.kind, from: "", to: "" });
        };
        return html `
      <label class="ob-field"><span>days away <em class="ob-opt">optional</em></span>
        <div class="ob-opts">${AWAY_KINDS.map(k => chip(d.kind === k.id, k.label, () => draft.set({ ...d, kind: k.id })))}</div>
        <div class="ob-pair">
          <input type="date" aria-label="from" value="${d.from}" onchange=${(e) => draft.set({ ...d, from: e.target.value })}>
          <input type="date" aria-label="until" value="${d.to}" onchange=${(e) => draft.set({ ...d, to: e.target.value })}>
          <button class="ob-chip" onclick=${add}>add</button>
        </div>
        ${list.length ? html `<ul class="ob-skills">${list.map((a, i) => html `
          <li><span class="ob-skname">${AWAY_KINDS.find(k => k.id === a.kind)?.label ?? a.kind} · ${a.from === a.to ? a.from : `${a.from} → ${a.to}`}</span>
            <a class="ob-x" title="remove" onclick=${() => setProfile({ away: list.filter((_, j) => j !== i) })}>×</a></li>`)}</ul>` : ""}
        <small>a day you are ill, resting or away is declared, never explained: the plan finds nobody on it, hands your shifts to others, and your floors stand whatever you contribute</small></label>`;
    };
}
