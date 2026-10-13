// app/route/eta.ts — the journey's ETA bar: the sheet at its lowest rest.
//
// While a journey is under way the share bar steps aside and the sheet shows one
// row — ✕ to end, the minutes left in large type, and `2.2 km · 17:05` beneath. At the
// end the row says you have arrived and offers Done. It is a sheet view (owner
// "journey", sticky, peek), so the page's other surfaces leave it alone.

import { openSheetView, closeSheetView } from '../tabs/social/share.js';
import { mk } from '../dom.js';

const OWNER = "journey";

/** What the row says. */
export interface EtaView {
  /** The minutes left, as said: "7 min". */
  big: string;
  /** Beneath it: "2.2 km · 17:05". */
  sub: string;
  arrived: boolean;
}

/** The row's two ways out. */
export interface EtaHost {
  /** ✕: end the journey. */
  exit(): void;
  /** Done, once arrived: end it as completed. */
  done(): void;
  /** The view left the sheet by some other road. */
  gone(): void;
}

export interface Eta {
  update(v: EtaView): void;
  close(): void;
}

/** Put the ETA bar in the sheet. */
export function openEta(h: EtaHost): Eta {
  const el = mk("div", "eb");
  el.innerHTML =
    `<button type="button" class="eb-x" title="End navigation" aria-label="End navigation">✕</button>` +
    `<div class="eb-mid"><div class="eb-big"></div><div class="eb-sub"></div></div>` +
    `<button type="button" class="eb-done" hidden>Done</button>`;
  el.querySelector<HTMLElement>(".eb-x")!.onclick = h.exit;
  el.querySelector<HTMLElement>(".eb-done")!.onclick = h.done;
  openSheetView(OWNER, el, h.gone, { fit: true, sticky: true, peek: true });
  return {
    update(v) {
      el.querySelector(".eb-big")!.textContent = v.big;
      el.querySelector(".eb-sub")!.textContent = v.sub;
      el.classList.toggle("arrived", v.arrived);
      el.querySelector<HTMLElement>(".eb-done")!.hidden = !v.arrived;
    },
    close() { closeSheetView(OWNER); },
  };
}
