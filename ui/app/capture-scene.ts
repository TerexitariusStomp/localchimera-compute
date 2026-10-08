// app/capture-scene.ts — the scene the camera looks at, and the screen that opens on it.
//
// A photograph is read in a scene: where it is taken, the container in view, the
// planned count it fulfils and what the ledger holds there. The stock screens open
// the camera on a container (a "photograph it" button) and the camera screen opens
// itself on the person's own place, so the scene is made here, beneath both.

import { currentPlace } from "./tabs/social/location.js";
import { placePath } from "./store-tree.js";
import type { Stock } from "./stock.js";
import { knownPlaces, heldStocks } from "./books.js";
import { askReads } from "./allotment.js";
import { HANDLERS } from "./core.js";
import { canScan } from "./scan.js";
import { topOf, push, replaceTop, type Screen, type Scene, type Planned, type LookScreen } from "./sheet.js";

export const lookTop = (): LookScreen | null => topOf("look");

/** The camera screen waiting for a shot: the viewfinder is open, symbols are read, the shutter is live. */

export const aiming = (scr: Screen | null | undefined): scr is LookScreen => scr?.kind === "look" && scr.phase === "idle";

// what the sheet knows of the scene a photograph is taken in

export function sceneOf(container?: Stock, contents: Stock[] = [], plan?: Planned, at?: string): Scene {
  const stocks = heldStocks();
  const here = at || (currentPlace() ?? "");
  const place = container?.location ?? here;
  const near = container ? contents : stocks.filter(t => !here || t.location === here);
  return {
    place: container?.location ?? at ?? "", where: placePath(place, knownPlaces()), container, plan,
    here: !!container || (!!here && near.length > 0),
    held: (near.length ? near : stocks).map(t => ({ id: t.id, name: t.name, spec: t.spec, unit: t.unit, onhand: t.onhand, expected: t.expected })),
  };
}

export const lookScreen = (scene: Scene): LookScreen => ({ kind: "look", scene, phase: "idle", hash: "", lines: [], reads: null, typing: !canScan(), shots: [], queued: "" });

// the week's reads arrive after the screen is up, and fill its line in place

export function wantReads(): void {
  void askReads(HANDLERS.allotment).then(reads => {
    const now = lookTop();
    if (now && now.phase === "idle" && now.reads === null && reads) replaceTop({ ...now, reads });
  });
}

// the camera screen draws its card with the viewfinder following it: made once, then
// pointed at each new video element the card is drawn with

/** The screen of the camera: a scene to look at, its shots none yet. */
export function openLook(scene: Scene): void {
  push(lookScreen(scene));
  wantReads();
}

/** Forget the code being typed. */
