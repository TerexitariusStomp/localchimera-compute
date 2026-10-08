// app/shop-count.ts — counting from the Resources face.
//
// A good's card gains a third reading beside "want this" and "I have this":
// "count it", the stocks of the good place by place (held.ts), each a row a
// person counts from (held-view.ts). The Resources face draws with strings and
// wires by selector, so this module hands it strings and one wiring call.
import { signal } from "./reactive.js";
import { esc } from "./template.js";
import { heldStocks, knownPlaces } from "./books.js";
import { heldOf, heldSummary } from "./held.js";
import { heldRows, signsOf, signHtml, wireHeld } from "./held-view.js";
export { wireHeld };
/** The open card reads "count it". */
export const countMode = signal(false);
/** The stocks of the good SPEC the books hold. */
export const heldFor = (spec) => heldOf(spec, heldStocks(), knownPlaces());
/** The signs a good's tile wears: what asks for attention on any stock of it. */
export function heldGlyphs(spec) {
    const seen = new Map();
    for (const h of heldFor(spec))
        for (const g of signsOf(h))
            seen.set(g.word, signHtml(g));
    return seen.size ? `<span class="sg-held-glyphs">${[...seen.values()].join("")}</span>` : "";
}
/** The third tab of a good's card, where the books hold a stock of it. */
export const countTab = (spec) => heldFor(spec).length ? `<a class="sg-mode-tab${countMode() ? " on" : ""}" data-mode="count">count it</a>` : "";
/** The body of "count it": each stock of the good at its place, and the two ways to count it. */
export function heldCard(spec) {
    const held = heldFor(spec);
    return `<div class="sg-held">
    <div class="sg-held-sum">${esc(heldSummary(held))}</div>
    ${heldRows(held, h => h.where.split(" › ").pop() || h.name)}
  </div>`;
}
