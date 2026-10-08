// app/tabs/map/held-here.ts — what is held at a place on the map.
//
// A place on the map is a place the ledger holds stock at (the venue names its
// place, core.ts Place.place). Its panel lists the stocks held there, and at the
// places inside it, each a row a person counts from (held-view.ts): standing at
// the pantry, a tap on its pin shows what the books say is on its shelves.
import { heldStocks, knownPlaces } from "../../books.js";
import { heldAt } from "../../held.js";
import { heldRows, wireHeld } from "../../held-view.js";
/** The section of a place's panel that lists what is held there; empty for a row that is no place, or a place that holds nothing. */
export function heldHere(row) {
    const place = row.kind === "place" ? row.p?.place : undefined;
    if (!place)
        return "";
    const held = heldAt(place, heldStocks(), knownPlaces());
    if (!held.length)
        return "";
    return `<div class="ms-sec ms-held"><div class="ms-held-h">held here</div><div class="sg-held">${heldRows(held, h => h.name)}</div></div>`;
}
export { wireHeld as wireHeldHere };
