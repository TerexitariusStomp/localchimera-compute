// app/route/sheet.ts — the journey's sheet: the ETA row, and the drawer that rises from it.
//
// While a journey is under way the share bar steps aside and the sheet is the journey's: one view
// (owner "journey", sticky, stepped) with three rests —
//
//   peek   the row alone: ✕ to end, the minutes left in large type, `2.2 km · 17:05` beneath;
//          at the end, You have arrived and Done
//   mid    the row and a menu: Directions ›, Travel by ›, Show the whole way, End navigation
//   full   the row and the way turn by turn (app/route/steps.ts) — tall as the screen below the banner
//
// A swipe up or down on the grip, or a tap, steps through them (the sheet carries the gesture,
// `Stepped` in app/tabs/social/share.ts; this view moves itself); Esc steps down. The menu's rows
// and the ← of a page are the account sheet's own builders (app/sheet-rows.ts).

import { openSheetView, closeSheetView, riseSheet } from '../tabs/social/share.js';
import { row, group, backButton } from '../sheet-rows.js';
import { mk } from '../dom.js';
import { MODES, modeInfo, DEFAULT_COSTING } from './modes.js';
import { renderSteps } from './steps.js';
import type { StepRow } from './steps.js';

const OWNER = "journey";

export type Rest = "peek" | "mid" | "full";
type Page = "menu" | "steps" | "modes";

/** What the sheet says. */
export interface SheetView {
  /** The minutes left, as said: "7 min". */
  big: string;
  /** Beneath it: "2.2 km · 17:05". */
  sub: string;
  arrived: boolean;
  /** The way turn by turn; none when there is no way (the compass). */
  steps: StepRow[];
  /** The costing the journey is travelling by. */
  mode: string;
}

/** What the sheet asks of the journey. */
export interface SheetHost {
  /** ✕, or End navigation: end the journey. */
  exit(): void;
  /** Done, once arrived: end it as completed. */
  done(): void;
  /** The view left the sheet by some other road. */
  gone(): void;
  /** Frame what is left of the way. */
  overview(): void;
  /** Travel the rest of the way by another mode. */
  travelBy(costing: string): void;
  /** The maneuver banner's height, so the sheet at its full height keeps clear of it. */
  bannerHeight(): number;
}

export interface JourneySheet {
  update(v: SheetView): void;
  close(): void;
  rest(): Rest;
}

/** Put the journey's sheet up. */
export function openJourneySheet(h: SheetHost): JourneySheet {
  let rest: Rest = "peek", page: Page = "menu", view: SheetView | null = null, sig = "";
  const el = mk("div", "jv");
  el.dataset.rest = rest;
  const head = mk("div", "jv-head");
  head.innerHTML =
    `<button type="button" class="jv-x" title="End navigation" aria-label="End navigation">✕</button>` +
    `<div class="jv-mid"><div class="jv-big"></div><div class="jv-sub"></div></div>` +
    `<button type="button" class="jv-done" hidden>Done</button>`;
  const body = mk("div", "jv-body");
  el.append(head, body);
  head.querySelector<HTMLElement>(".jv-x")!.onclick = h.exit;
  head.querySelector<HTMLElement>(".jv-done")!.onclick = h.done;

  const hasSteps = (): boolean => !!view && view.steps.length > 0;

  const pageHead = (title: string, back: () => void): HTMLElement => {
    const ph = mk("div", "jv-pagehead");
    ph.append(backButton(back), mk("span", "acct-title", title));
    return ph;
  };

  const menu = (): HTMLElement => {
    const none = (): void => {};
    const rows: HTMLElement[] = [];
    if (hasSteps()) rows.push(row({ icon: "↱", label: "Directions", sub: "the way, turn by turn", go: none }, none, false,
                                  () => setRest("full", "steps")));
    rows.push(row({ icon: modeInfo(view?.mode ?? DEFAULT_COSTING)?.icon ?? "", label: "Travel by", sub: modeInfo(view?.mode ?? "")?.label ?? "", go: none }, none, false,
                  () => setRest("mid", "modes")));
    if (hasSteps()) rows.push(row({ icon: "🗺️", label: "Show the whole way", sub: "what is left of it", go: () => { setRest("peek", "menu"); h.overview(); } }, none));
    rows.push(row({ icon: "⏹", label: "End navigation", go: h.exit, tone: "arm" }, none));
    const pg = mk("div", "jv-pg");
    pg.append(group(...rows));
    return pg;
  };

  const modes = (): HTMLElement => {
    const pg = mk("div", "jv-pg");
    pg.append(pageHead("Travel by", () => setRest("mid", "menu")));
    pg.append(group(...MODES.map(m => row({
      icon: m.icon, label: m.label, sub: m.costing === view?.mode ? "this way" : "", tone: m.costing === view?.mode ? "here" : undefined,
      go: () => h.travelBy(m.costing),
    }, () => {}))));
    return pg;
  };

  const steps = (): HTMLElement => {
    const pg = mk("div", "jv-pg");
    pg.append(pageHead("Directions", () => setRest("mid", "menu")));
    const list = mk("div", "jv-list");
    list.append(renderSteps(view?.steps ?? []));
    sig = signature(view);
    pg.append(list);
    return pg;
  };

  const draw = (): void => {
    body.replaceChildren();
    if (rest === "peek") return;
    body.append(page === "steps" ? steps() : page === "modes" ? modes() : menu());
  };

  function setRest(r: Rest, p: Page = "menu"): void {
    rest = r; page = p;
    el.dataset.rest = r;
    document.documentElement.style.setProperty("--nb-h", `${h.bannerHeight()}px`);   // the whole height starts below the banner
    riseSheet(r === "full");
    draw();
  }

  const up = (): void => { if (rest === "peek") setRest("mid", "menu"); else if (rest === "mid" && hasSteps()) setRest("full", "steps"); };
  const down = (): void => { if (rest === "full") setRest("mid", "menu"); else if (rest === "mid") setRest("peek", "menu"); };
  const tap = (): void => { if (rest === "peek") up(); else down(); };

  openSheetView(OWNER, el, h.gone, {
    fit: true, sticky: true, stepped: { up, down, tap },
    esc: () => { if (rest === "peek") return false; down(); return true; },       // Esc steps down, to the row
  });

  return {
    update(v) {
      view = v;
      head.querySelector(".jv-big")!.textContent = v.big;
      head.querySelector(".jv-sub")!.textContent = v.sub;
      el.classList.toggle("arrived", v.arrived);
      head.querySelector<HTMLElement>(".jv-done")!.hidden = !v.arrived;
      if (v.arrived && rest !== "peek") { setRest("peek"); return; }       // the end is read at a glance
      // the list follows you: redrawn when its rows change, else only how far off the next turn is
      if (rest === "full" && page === "steps") {
        if (signature(v) !== sig) draw();
        else { const lead = body.querySelector(".jv-step.next .jv-lead"); if (lead && v.steps[0]) lead.textContent = v.steps[0].lead; }
      }
    },
    close() {
      document.documentElement.style.removeProperty("--nb-h");
      riseSheet(false);
      closeSheetView(OWNER);
    },
    rest: () => rest,
  };
}

/** What identifies the list apart from how far the first turn is: the rows' words. */
const signature = (v: SheetView | null): string => v ? v.steps.map(s => `${s.kind}|${s.text}|${s.after}`).join("\n") : "";
