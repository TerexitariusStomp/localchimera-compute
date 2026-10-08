// app/face-dock.ts — the faces, as one button.
//
// Two views are the ones people live in: the CALENDAR and the MAP. The bar carries one round button
// for the other of the two — on the calendar it shows the map, on the map the calendar, anywhere else
// the map — and a tap goes there. A long press lifts a tray of the rest of the faces to choose from.
// The button presses that face's tab in the (unseen) face strip — the one table, whose `.hid` and `.on`
// it follows, so ⚙ → faces (which faces show) and every other way of changing face reach it unasked.
//
// The scope pill (the crumb) is carried into the bar's chips here as well; it is out of sight for now.

import { mk } from './dom.js';

const strip = (): HTMLElement | null => document.getElementById("facestrip");
const opt = (id: string): HTMLElement | null => document.getElementById(`face-${id}`);
const live = (): HTMLElement | null => strip()?.querySelector<HTMLElement>(".faceopt.on") ?? null;
const HOLD_MS = 420;

let tray: HTMLElement | null = null;
const closeTray = (): void => { tray?.remove(); tray = null; };

/** The tray: every face but the two the button already serves and the one you are on. */
function openTray(): void {
  closeTray();
  const bar = document.getElementById("sharebar");
  const s = strip();
  if (!bar || !s) return;
  const here = live();
  tray = mk("div", "facetray");
  tray.setAttribute("role", "menu");
  tray.setAttribute("aria-label", "more views");
  for (const o of s.querySelectorAll<HTMLElement>(".faceopt")) {          // every face, shown in the strip or not
    if (o === here || o.id === "face-cal" || o.id === "face-map") continue;
    const b = mk("button", "facetray-item");
    b.type = "button"; b.setAttribute("role", "menuitem");
    b.title = o.title.replace(/^([^—]*) — [^—]*— /, "$1 — ");
    b.append(mk("span", "facetray-g", o.textContent || ""), mk("span", "facetray-l", o.dataset.label || o.id));
    b.addEventListener("click", () => { closeTray(); o.click(); });
    tray.append(b);
  }
  bar.append(tray);
}

let wired = false;
export function initFaceDock(): void {
  if (wired) return;
  wired = true;
  const end = document.querySelector<HTMLElement>("#sharebar .share-end");
  const togs = document.querySelector<HTMLElement>("#sharebar .share-togs");
  const crumb = document.getElementById("crumb");
  if (togs && crumb) togs.prepend(crumb);       // the scope stands with the clock and the pin
  const s = strip();
  if (!end || !s) return;

  const btn = mk("button", "facebtn");
  btn.id = "facebtn"; btn.type = "button";
  btn.setAttribute("aria-haspopup", "menu");
  end.prepend(btn);

  // the other primary: the calendar when you are on the map, the map from anywhere else
  const target = (): HTMLElement | null => (live()?.id === "face-map" ? opt("cal") : opt("map"));
  const paint = (): void => {
    const t = target();
    btn.textContent = t?.textContent || "🧭";
    btn.title = `${t?.dataset.label || "map"} — hold for more views`;
    btn.setAttribute("aria-label", `${t?.dataset.label || "map"}; hold for more views`);
  };
  paint();
  new MutationObserver(paint).observe(s, { subtree: true, attributes: true, attributeFilter: ["class"], characterData: true, childList: true });

  // a tap goes; a hold lifts the tray (and the tap that follows a hold is not a tap)
  let timer: ReturnType<typeof setTimeout> | undefined, held = false;
  btn.addEventListener("pointerdown", () => {
    held = false;
    timer = setTimeout(() => { held = true; openTray(); }, HOLD_MS);
  });
  const cancel = (): void => clearTimeout(timer);
  btn.addEventListener("pointerup", cancel);
  btn.addEventListener("pointerleave", cancel);
  btn.addEventListener("pointercancel", cancel);
  btn.addEventListener("contextmenu", e => { e.preventDefault(); cancel(); held = true; openTray(); });
  btn.addEventListener("click", () => {
    if (held) { held = false; return; }
    if (tray) { closeTray(); return; }
    target()?.click();
  });
  document.addEventListener("pointerdown", e => {
    const t = e.target as Element | null;
    if (tray && t && !t.closest(".facetray") && !t.closest("#facebtn")) closeTray();
  });
  document.addEventListener("keydown", e => { if (e.key === "Escape" && tray) { e.preventDefault(); closeTray(); } });
}
