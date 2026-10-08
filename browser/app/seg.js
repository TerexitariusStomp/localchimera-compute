// app/seg.ts — a segmented control: one row of options, exactly one of them on.
//
// The switch a face uses to pick ONE of a few readings of the same thing — an
// activity, a lens, a tab. Options are [key, label, count?]; the count rides the
// label as a small figure. The markup is one `.seg-rail` (styled in app.html), so
// a face that wants a variant adds its own class beside it and no second control.
import { html } from './template.js';
export function segRail(options, current, pick, cls = "") {
    return html `<div class="seg-rail ${cls}">${options.map(([key, label, n]) => html `
    <a class="${key === current ? "on" : ""}" onclick=${() => pick(key)}>${label}${n != null && n !== "" ? html `<span class="n">${n}</span>` : null}</a>`)}</div>`;
}
