// app/route/fields.ts — the from/to card: where from, where to, and ⇅.
//
// A card floating at the top of the map with two text fields. The origin is you ("Your location", in blue) until you
// say otherwise; either end is a name typed and a place picked — the commons' places and OpenStreetMap's, nearest first
// (`placesNear`). The card knows nothing of routes: it shows two ends, offers places for each, and says when one changed.

import { theMap } from '../mapview.js';
import { placesNear } from '../tabs/map/atlas.js';
import { youAt } from '../position.js';
import { swapEnds } from './facts.js';
import type { End } from './facts.js';
import type { LatLng } from '../geom.js';
import { esc } from '../template.js';
import { mk } from '../dom.js';

/** An end that is you: it follows the device, and reads "Your location". */
export const youEnd = (): End => ({ at: youAt(), name: "Your location", live: true });

/** A place a field can offer. */
interface Hit { at: LatLng; name: string; note: string; emoji: string; you?: boolean }

/** The commons' places and OpenStreetMap's that a typed name matches, nearest first. */
function matchPlaces(q: string): Hit[] {
  const needle = q.trim().toLowerCase();
  if (!needle) return [];
  return placesNear(youAt(), q, theMap(), r => !!r.name && r.name.toLowerCase().includes(needle), 6)
    .map(r => ({ at: { lat: r.lat, lng: r.lng }, name: r.name!, note: r.provider === "OpenStreetMap" ? r.note || "" : r.provider || "", emoji: r.emoji }));
}

const youHit = (): Hit => ({ at: youAt(), name: "Your location", note: "", emoji: "🔵", you: true });

/** What the card asks of its owner. */
export interface FieldsHost {
  /** The two ends now. */
  ends(): { from: End; to: End };
  /** One end or both changed — a place was picked, or ⇅ was pressed. */
  change(next: { from?: End; to?: End }): void;
}

export interface Fields {
  /** Show the ends as they are now (a field being typed in is left alone). */
  sync(): void;
  /** How tall the card stands, in pixels. */
  height(): number;
  remove(): void;
}

/** Put the card over `container`. */
export function mountFields(container: HTMLElement, h: FieldsHost): Fields {
  const el = mk("div", "routecard");
  el.id = "routecard";
  el.innerHTML =
    `<div class="rc-ends">` +
      `<span class="rc-marks"><i class="rc-from"></i><i class="rc-thread"></i><b class="rc-to">📍</b></span>` +
      `<div class="rc-fields">` +
        `<input class="rc-in rc-in-from" type="text" autocomplete="off" spellcheck="false" aria-label="Start">` +
        `<input class="rc-in rc-in-to" type="text" autocomplete="off" spellcheck="false" aria-label="Destination">` +
      `</div>` +
      `<button type="button" class="rc-swap" title="Swap start and destination">⇅</button>` +
    `</div><div class="rc-hits" hidden></div>`;
  container.appendChild(el);

  const input = (which: "from" | "to"): HTMLInputElement => el.querySelector<HTMLInputElement>(`.rc-in-${which}`)!;
  const hits = el.querySelector<HTMLElement>(".rc-hits")!;
  let side: "from" | "to" | null = null, list: Hit[] = [];

  const sync = (): void => {
    const { from, to } = h.ends();
    for (const [which, e] of [["from", from], ["to", to]] as const) {
      const f = input(which);
      if (document.activeElement !== f) f.value = e.name;
      f.classList.toggle("you", !!e.live);
    }
  };

  const close = (): void => { hits.hidden = true; hits.replaceChildren(); list = []; side = null; };
  const choose = (hit: Hit): void => {
    if (!side) return;
    const e: End = hit.you ? youEnd() : { at: hit.at, name: hit.name };
    const which = side;
    close();
    (document.activeElement as HTMLElement | null)?.blur();
    h.change({ [which]: e });
  };
  const show = (which: "from" | "to", q: string): void => {
    side = which;
    list = matchPlaces(q);
    if (which === "from") list = [youHit(), ...list];
    hits.replaceChildren(...list.map((hit, i) => {
      const b = mk("button", "rc-hit"); b.type = "button";
      b.innerHTML = `<span class="rc-he">${esc(hit.emoji)}</span><span class="rc-hn">${esc(hit.name)}</span>` +
                    (hit.note ? `<span class="rc-hd">${esc(hit.note)}</span>` : "");
      // pointerdown, not click: the field's blur would have closed the list before a click landed
      b.onpointerdown = ev => { ev.preventDefault(); side = which; choose(list[i]); };
      return b;
    }));
    hits.hidden = list.length === 0;
  };

  for (const which of ["from", "to"] as const) {
    const f = input(which);
    f.onfocus = () => { f.select(); show(which, ""); };
    f.oninput = () => show(which, f.value);
    f.onblur = () => { close(); sync(); };
    f.onkeydown = ev => {
      if (ev.key === "Enter" && list[0]) { ev.preventDefault(); side = which; choose(list[0]); }
      else if (ev.key === "Escape" && !hits.hidden) { ev.preventDefault(); ev.stopPropagation(); close(); f.blur(); }
    };
  }
  el.querySelector<HTMLElement>(".rc-swap")!.onclick = () => {
    const { from, to } = h.ends();
    h.change(swapEnds(from, to, youAt()));
  };

  sync();
  return { sync, height: () => el.getBoundingClientRect().height, remove: () => el.remove() };
}
