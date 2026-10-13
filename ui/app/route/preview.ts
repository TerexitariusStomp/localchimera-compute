// app/route/preview.ts — the ways to a place, before you set out.
//
// ↦ directions opens this rather than starting a journey. Three things appear
// together and are one state:
//
//   the from/to card   floats at the top of the map: where from (you, until you
//                      say otherwise), where to, and ⇅. Either end is a field —
//                      type a name, pick a place.
//   the sheet          owner "route" in the share bar's pull-up: the mode tabs
//                      with a time each, the chosen way's summary, Start.
//   the map            the chosen route heavy, its alternatives pale, a time on
//                      each, framed so the whole of it shows between card and sheet.
//
// Every mode is asked at once (app/route/data.ts) and each tab fills as its
// answer lands. Start hands the chosen way to the wayfinder (app/route/nav.ts
// startNavTo) and the preview steps away; ✕ steps back to the place it came from.
//
// The view is `sticky` in the sheet: the page works WITH a route being chosen —
// a tap on the map to pick an alternative must not put it away.

import { USER } from '../core.js';
import { theMap, MAP_EL } from '../mapview.js';
import { openSheetView, closeSheetView, sheetViewIs, sheetHeight } from '../tabs/social/share.js';
import { placesNear } from '../tabs/map/atlas.js';
import { startNavTo } from './nav.js';
import { fetchRoutes, ROUTE_MODES, modeInfo } from './data.js';
import type { Route } from './data.js';
import { paintLines, clearLines } from './lines.js';
import { lineBadge } from './badge.js';
import { fmtMinutes, headline, swapEnds, transitLines, arrivalClock } from './facts.js';
import { boundsOf, pillAnchor } from './shape.js';
import type { End } from './facts.js';
import { havKm } from '../geom.js';
import type { LatLng } from '../geom.js';
import { readStr, writeStr } from '../store.js';
import { K } from '../keys.js';
import { esc } from '../template.js';
import { mk } from '../dom.js';

const OWNER = "route";
/** The destination pin's height in pixels — the camera leaves it room above the point. */
const PIN_H = 34;

const DEFAULT_MODE = "pedestrian";
/** How many ways besides the best to ask for, where the engine offers them. */
const ALTERNATES = 2;

/** A place the from/to fields can offer. */
interface Hit { at: LatLng; name: string; note: string; emoji: string; you?: boolean }

interface Preview {
  from: End;
  to: End;
  mode: string;
  /** Each mode's routes; absent until that mode's answer lands, [] when it has none. */
  ways: Record<string, Route[] | undefined>;
  /** Which of the mode's routes is chosen. */
  pick: number;
  /** Which round of asks is current — a late answer to an old one is let go. */
  seq: number;
  /** Where ✕ goes back to — the place card the journey began from. */
  back: (() => void) | null;
  /** The sheet's view, and the card's pieces. */
  body: HTMLElement;
}

let pv: Preview | null = null;
let card: HTMLElement | null = null;
let markers: maplibregl.Marker[] = [];

// ── the places the fields offer ─────────────────────────────────────────────

/** The commons' places and OpenStreetMap's that a typed name matches, nearest first. */
function matchPlaces(q: string): Hit[] {
  const needle = q.trim().toLowerCase();
  if (!needle) return [];
  return placesNear(USER, q, theMap(), r => !!r.name && r.name.toLowerCase().includes(needle), 6)
    .map(r => ({ at: { lat: r.lat, lng: r.lng }, name: r.name!, note: r.provider === "OpenStreetMap" ? r.note || "" : r.provider || "", emoji: r.emoji }));
}

const YOU: Hit = { at: USER, name: "Your location", note: "", emoji: "🔵", you: true };

// ── the asks ────────────────────────────────────────────────────────────────

const atOf = (e: End): LatLng => e.live ? { lat: USER.lat, lng: USER.lng } : e.at;
const here = (): End => ({ at: { lat: USER.lat, lng: USER.lng }, name: "Your location", live: true });

/** Ask every mode, and let each tab fill as its answer lands. */
function ask(): void {
  const p = pv; if (!p) return;
  const seq = ++p.seq;
  p.ways = {}; p.pick = 0;
  draw();
  const a = atOf(p.from), b = atOf(p.to);
  let framed = false;
  for (const m of ROUTE_MODES) {
    fetchRoutes(a, b, m, { alternates: ALTERNATES }).then(rs => {
      if (pv !== p || p.seq !== seq) return;
      p.ways[m] = rs;
      draw();
      // the camera frames once, when the chosen mode answers — or, if nothing answers it, when all have
      const done = ROUTE_MODES.every(x => p.ways[x] !== undefined);
      if (!framed && (m === p.mode || done)) { framed = true; frame(); }
    });
  }
}

const routes = (): Route[] => (pv && pv.ways[pv.mode]) || [];
const settled = (): boolean => !!pv && ROUTE_MODES.every(m => pv!.ways[m] !== undefined);
const nowhere = (): boolean => settled() && ROUTE_MODES.every(m => (pv!.ways[m] || []).length === 0);

// ── the map ─────────────────────────────────────────────────────────────────

function clearMarkers(): void { markers.forEach(m => m.remove()); markers = []; }

function pin(map: maplibregl.Map, cls: string, text: string, at: LatLng, anchor: string, onClick?: () => void): void {
  const el = mk(onClick ? "button" : "div", cls, text);
  if (onClick) { (el as HTMLButtonElement).type = "button"; el.onclick = e => { e.stopPropagation(); onClick(); }; }
  markers.push(new maplibregl.Marker({ element: el, anchor }).setLngLat([at.lng, at.lat]).addTo(map));
}

/** The routes, their times and the two ends, drawn from the state. */
function paint(): void {
  const p = pv, map = theMap();
  if (!p || !map) return;
  const rs = routes();
  const a = atOf(p.from), b = atOf(p.to);
  paintLines(map, { ways: rs, pick: p.pick, bearing: nowhere() ? [[a.lng, a.lat], [b.lng, b.lat]] : undefined });

  clearMarkers();
  if (!p.from.live) pin(map, "rv-dot", "", p.from.at, "center");
  pin(map, "rv-pin", "📍", atOf(p.to), "bottom");
  rs.forEach((r, i) => {
    const at = pillAnchor(rs, i);
    if (!at) return;
    const best = i === 0 && rs.length > 1 && p.pick === 0;
    pin(map, "rv-pill" + (i === p.pick ? " sel" : ""), fmtMinutes(r.s) + (i === p.pick && best ? " · Best route" : ""),
        { lat: at[1], lng: at[0] }, "center", () => { p.pick = i; draw(); });
  });
}

/** Frame every way of the chosen mode (or the two ends) between the card and the sheet. */
function frame(): void {
  const p = pv, map = theMap();
  if (!p || !map) return;
  const go = (): void => {
    if (pv !== p) return;
    const ends: [number, number][] = [[atOf(p.from).lng, atOf(p.from).lat], [atOf(p.to).lng, atOf(p.to).lat]];
    const b = boundsOf(routes()) || boundsOf([{ coords: ends }]);
    if (!b) return;
    // a flyTo's padding stays on the camera, and fitBounds adds its own to it: clear it, so the padding below is the whole of it
    map.setPadding({ top: 0, bottom: 0, left: 0, right: 0 });
    map.fitBounds(b, { duration: 600, maxZoom: 17,
      // the top clears the card AND the destination pin, which stands a pin's height above its point
      padding: { top: (card?.getBoundingClientRect().height || 0) + 28 + PIN_H, bottom: sheetHeight() + 24, left: 28, right: 28 } });
  };
  // the sheet takes its height a frame or two after it draws; the camera pads by what it really has
  requestAnimationFrame(() => requestAnimationFrame(go));
}

// ── the sheet ───────────────────────────────────────────────────────────────

function drawSheet(): void {
  const p = pv; if (!p) return;
  const rs = routes(), r = rs[p.pick] || null;
  const m = modeInfo(p.mode)!;
  const pending = p.ways[p.mode] === undefined;
  const tab = (id: string): string => {
    const w = p.ways[id];
    const t = w === undefined ? "…" : w.length ? fmtMinutes(w[0].s) : "–";
    return `<button type="button" class="rv-tab${id === p.mode ? " on" : ""}" role="tab" aria-selected="${id === p.mode}" data-mode="${id}">` +
           `<span class="rv-ti">${modeInfo(id)!.icon}</span><b>${esc(t)}</b></button>`;
  };
  let sum: string, acts: string;
  if (pending) {
    sum = `<div class="rv-big">Finding the way…</div>`;
    acts = `<button type="button" class="rv-start" disabled>▲ Start</button>`;
  } else if (r) {
    const arrive = arrivalClock(r.s);
    const lines = transitLines(r).map(l => lineBadge(l).outerHTML).join("");
    sum = `<div class="rv-big">${esc(headline(r))}</div>` +
          `<div class="rv-sub">${lines ? lines + " · " : ""}arrive ${esc(arrive)}${r.hasToll ? " · tolls" : ""}${r.hasFerry ? " · ferry" : ""}</div>`;
    acts = p.from.live
      ? `<button type="button" class="rv-start">▲ Start</button>`
      : `<button type="button" class="rv-start rv-fromhere">▲ Start from my location</button>`;
  } else if (nowhere()) {
    const km = havKm(atOf(p.from), atOf(p.to));
    sum = `<div class="rv-big">Routing is unavailable here</div>` +
          `<div class="rv-sub">${km < 1 ? `${Math.round(km * 1000)} m` : `${km.toFixed(1)} km`} as the crow flies</div>`;
    acts = `<button type="button" class="rv-start rv-go">↦ Go by compass</button>`;
  } else {
    sum = `<div class="rv-big">No route to here by ${esc(m.label.toLowerCase())}</div>`;
    acts = `<button type="button" class="rv-start" disabled>▲ Start</button>`;
  }
  p.body.innerHTML =
    `<div class="rv-head"><h2 class="rv-title">${esc(m.label)}</h2><button type="button" class="rv-x" title="Close directions">✕</button></div>` +
    `<div class="rv-tabs" role="tablist">${ROUTE_MODES.map(tab).join("")}</div>` +
    `<div class="rv-sum">${sum}</div><div class="rv-acts">${acts}</div>`;

  p.body.querySelector<HTMLElement>(".rv-x")!.onclick = () => end(true);
  p.body.querySelectorAll<HTMLElement>(".rv-tab").forEach(b => b.onclick = () => {
    p.mode = b.dataset.mode!; p.pick = 0;
    writeStr(K.routeMode, p.mode);
    draw();
    if (p.ways[p.mode] !== undefined) frame();
  });
  const start = p.body.querySelector<HTMLButtonElement>(".rv-start");
  if (start && !start.disabled) start.onclick = () => {
    if (start.classList.contains("rv-fromhere")) { p.from = here(); ask(); return; }   // a journey sets out from where you are
    go(r);
  };
}

/** Set out: the chosen way (or none — the compass) goes to the wayfinder and the preview steps away. */
function go(r: Route | null): void {
  const p = pv; if (!p) return;
  const dest = atOf(p.to), name = p.to.name, costing = p.mode;
  end(false);
  void startNavTo(dest, name, { route: r, costing });
}

// ── the card ────────────────────────────────────────────────────────────────

function buildCard(): HTMLElement {
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
  return el;
}

function syncCard(): void {
  const p = pv; if (!card || !p) return;
  const f = card.querySelector<HTMLInputElement>(".rc-in-from")!, t = card.querySelector<HTMLInputElement>(".rc-in-to")!;
  if (document.activeElement !== f) f.value = p.from.name;
  if (document.activeElement !== t) t.value = p.to.name;
  f.classList.toggle("you", !!p.from.live);
  t.classList.toggle("you", !!p.to.live);
}

function wireCard(el: HTMLElement): void {
  const hits = el.querySelector<HTMLElement>(".rc-hits")!;
  const swap = el.querySelector<HTMLElement>(".rc-swap")!;
  let side: "from" | "to" | null = null, list: Hit[] = [];

  const close = (): void => { hits.hidden = true; hits.replaceChildren(); list = []; side = null; };
  const choose = (h: Hit): void => {
    const p = pv; if (!p || !side) return;
    const e: End = h.you ? here() : { at: h.at, name: h.name };
    p[side] = e;
    close();
    (document.activeElement as HTMLElement | null)?.blur();
    ask(); syncCard(); frame();
  };
  const show = (which: "from" | "to", q: string): void => {
    side = which;
    list = matchPlaces(q);
    if (which === "from") list = [YOU, ...list];
    hits.replaceChildren(...list.map((h, i) => {
      const b = mk("button", "rc-hit"); b.type = "button";
      b.innerHTML = `<span class="rc-he">${esc(h.emoji)}</span><span class="rc-hn">${esc(h.name)}</span>` +
                    (h.note ? `<span class="rc-hd">${esc(h.note)}</span>` : "");
      // pointerdown, not click: the field's blur would have closed the list before a click landed
      b.onpointerdown = ev => { ev.preventDefault(); side = which; choose(list[i]); };
      return b;
    }));
    hits.hidden = list.length === 0;
  };

  for (const which of ["from", "to"] as const) {
    const input = el.querySelector<HTMLInputElement>(`.rc-in-${which}`)!;
    input.onfocus = () => { input.select(); show(which, ""); };
    input.oninput = () => show(which, input.value);
    input.onblur = () => { close(); syncCard(); };
    input.onkeydown = ev => {
      if (ev.key === "Enter" && list[0]) { ev.preventDefault(); side = which; choose(list[0]); }
      else if (ev.key === "Escape" && !hits.hidden) { ev.preventDefault(); ev.stopPropagation(); close(); input.blur(); }
    };
  }
  swap.onclick = () => {
    const p = pv; if (!p) return;
    const s = swapEnds(p.from, p.to, { lat: USER.lat, lng: USER.lng });
    p.from = s.from; p.to = s.to;
    ask(); syncCard(); frame();
  };
}

// ── opening and closing ─────────────────────────────────────────────────────

function draw(): void { drawSheet(); paint(); }

const onKey = (e: KeyboardEvent): void => {
  if (e.key === "Escape" && pv && sheetViewIs(OWNER)) { e.preventDefault(); end(true); }
};

/** Whether the preview is up. */
export const routePreviewOpen = (): boolean => pv !== null;

/**
 * Show the ways to `dest`. `back`, when given, is where ✕ returns to — the
 * place card the person came from; setting out does not call it.
 */
export function openRoutePreview(dest: LatLng, name: string, back?: () => void): void {
  const map = theMap();
  if (!map) return;
  if (pv) end(false);
  const saved = readStr(K.routeMode);
  const body = mk("div", "rv");
  pv = { from: here(), to: { at: dest, name }, mode: saved && modeInfo(saved) ? saved : DEFAULT_MODE,
         ways: {}, pick: 0, seq: 0, back: back || null, body };

  const host = document.getElementById(MAP_EL());
  if (host) {
    card = buildCard();
    host.appendChild(card);
    wireCard(card);
    syncCard();
  }
  document.addEventListener("keydown", onKey);
  // sticky: a tap on the map picks a way, it does not put the sheet away
  openSheetView(OWNER, body, teardown, { fit: true, sticky: true });
  ask();
}

/** The view left the sheet, whichever way: take down the card, the lines and the markers. */
function teardown(): void {
  document.removeEventListener("keydown", onKey);
  card?.remove(); card = null;
  clearMarkers();
  clearLines(theMap());
  pv = null;
}

/** Close the preview. With `back`, return to the place card it began from. */
function end(back: boolean): void {
  const p = pv; if (!p) return;
  const b = back ? p.back : null;
  closeSheetView(OWNER);      // → teardown
  if (pv) teardown();         // a sheet that was already gone leaves nothing to call it
  b?.();
}
