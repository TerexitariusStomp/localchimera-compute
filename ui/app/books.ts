// app/books.ts — what the books hold and where, as the stock faces read them.
//
// The snapshot on the seam carries the stock and the places it is at and inside:
// a gateway's, or with no gateway the demo's, pushed through the same door
// (demo/seat.ts). The capture sheet, the rail's inventory and the store face each
// ask here, so they see one set of books.
//
// The books are the seat's own once a seat is taken at a gateway, or a gateway's
// snapshot has brought stock. Until then they are the demo's, and the doors the
// demo answers are the demo's too (demo/seat.ts); a seat with empty books reads
// them empty, and nothing of the demo reaches a count, a pairing or the vision
// model's prompt. (The bridge registers its doors whether or not a gateway
// answers them, so a door's presence says nothing of the seat; the spine's
// status and the stock on the seam do.)

import { EXT } from "./core.js";
import { on, emit } from "./bus.js";
import { placesOf, stocksOf, type Stock } from "./stock.js";
import type { InventoryResource } from "./seam.js";
import type { PlaceRow } from "./store-tree.js";

let seated = false;
// the spine reports a seat taken as "ok:<aid>…" (tabs/social/id.ts reads the rest of the vocabulary);
// the books are asked again when it changes, so the demo goes the moment a seat is taken
on("status", (s: string) => {
  const now = typeof s === "string" && s.startsWith("ok:");
  if (now === seated) return;
  seated = now;
  emit("inventory");
});

/** The stock on the seam is the demo's own: the demo marks the books it pushes (demo/seat.ts). */
export const demoBooks = (): boolean => !!(EXT.inventory as { demo?: boolean } | undefined)?.demo;

/** Whether the books are the seat's own: it is seated at a gateway, or a gateway's snapshot has brought stock. */
export const attached = (): boolean => seated || (!demoBooks() && (EXT.inventory?.resources?.length ?? 0) > 0);

/** The places the books name: the snapshot's, a gateway's or the demo's (demo/seat.ts). */
export function knownPlaces(): PlaceRow[] {
  return placesOf(EXT.snapshot?.locations ?? []);
}

/** The stock the books hold: the snapshot's, and none of the demo's once a seat is taken. */
export function knownResources(): InventoryResource[] {
  const wired = EXT.inventory?.resources;
  return Array.isArray(wired) && !(seated && demoBooks()) ? wired : [];
}

/** The stock the books hold, as the faces read it. */
export const heldStocks = (): Stock[] => stocksOf(knownResources());
