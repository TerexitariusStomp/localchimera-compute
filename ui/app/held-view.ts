// app/held-view.ts — stocks as rows a person counts from.
//
// Two faces list stocks outside the store: the Resources face lists the stocks of
// a good, place by place (shop-count.ts), and the map lists the stocks held at a
// place (tabs/map/held-here.ts). Both draw the same row here: what it is called in
// that list, what asks for attention, the ledger's figure with the plan's range,
// and the two ways to count it, the figure screen and the camera, both the
// capture sheet's own. The faces draw with strings and wire by selector, so this
// hands them a string and one wiring call.

import { esc } from "./template.js";
import type { HeldAt } from "./held.js";
import { quantity, planRange } from "./count.js";
import { glyphs, type Glyph } from "./store-view.js";
import { schedule } from "./store-data.js";
import { contested } from "./contests.js";
import { openCaptureStock, openCapturePhotoOf } from "./capture.js";

/** What asks for attention on a stock. */
export const signsOf = (h: HeldAt): Glyph[] => glyphs({ id: h.id, name: h.name }, schedule(), contested());

/** A sign, as a row or a tile wears it. */
export const signHtml = (g: Glyph): string =>
  `<span class="sg-held-glyph${g.warn ? " warn" : ""}" title="${esc(g.word)}" aria-label="${esc(g.word)}">${g.glyph}</span>`;

/** The rows of HELD, each labelled by LABEL (its place among a good's stocks, its name among a place's). */
export function heldRows(held: HeldAt[], label: (h: HeldAt) => string): string {
  return held.map(h => `<div class="sg-held-row">
      <span class="sg-held-place" title="${esc(h.where)}">${esc(label(h))}</span>
      <span class="sg-held-signs">${signsOf(h).map(signHtml).join("")}</span>
      <span class="sg-held-q">${esc(quantity(h.onhand, h.unit))}${h.expected ? `<span class="sg-held-plan"> · the plan expects ${esc(planRange(h.expected, h.unit))}</span>` : ""}</span>
      <button class="sg-held-shoot" data-rid="${esc(h.id)}" title="photograph it: a model proposes the count, you confirm">📷</button>
      <button class="sg-held-count" data-rid="${esc(h.id)}">count</button>
    </div>`).join("");
}

/** Wire the count and camera buttons under ROOT to the capture sheet. */
export function wireHeld(root: ParentNode): void {
  root.querySelectorAll<HTMLElement>(".sg-held-count").forEach(b =>
    b.addEventListener("click", ev => { ev.stopPropagation(); openCaptureStock(b.dataset.rid || ""); }));
  root.querySelectorAll<HTMLElement>(".sg-held-shoot").forEach(b =>
    b.addEventListener("click", ev => { ev.stopPropagation(); openCapturePhotoOf(b.dataset.rid || ""); }));
}
