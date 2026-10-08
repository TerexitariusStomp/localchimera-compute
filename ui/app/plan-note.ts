// app/plan-note.ts — the plan's word on a stock, as one quiet line that opens.
//
// A stock the plan bears on has a range the plan expects (count.ts Expected). The
// capture sheet shows it beside the figure and the store face shows it on the desk;
// both draw it here, so the two say it alike: a line that gives the range or the
// plan's verdict on a figure, and, opened, the flows behind it.

import { html, type Fragment } from "./template.js";
import { flowLine, type Expected } from "./count.js";

/** LEAD is the line; BEYOND marks a figure the range does not hold. */
export function planNote(e: Expected, unit: string, lead: string, beyond = false): Fragment {
  return html`
    <details class="cap-plan${beyond ? " beyond" : ""}">
      <summary>${lead}</summary>
      <ul class="cap-flows">${e.flows.map(f => html`<li title="${f.proc}">${flowLine(f, unit)}</li>`)}</ul>
    </details>`;
}
