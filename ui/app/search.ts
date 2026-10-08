// app/search.ts — one search: the query, the time filter, and the pill.
//
// The map's side panel (tabs/mapsearch.js, ported from free-association's
// MapSidePanel) grew the dial's search: a text query over a row's words and a
// time filter — Any Time · Now · Next 24h · a custom range — read through
// atlas's window readers, with the pill (input ✕ | 🕒 select) and its custom
// date rows as the surface. Every face with a pool to sift wants exactly that,
// so it lives here rather than in the map's file: the map filters its markers
// with it, the match ring sifts its slots with it, and a third face gets it by
// importing.
//
// A filter is an INSTANCE (each face keeps its own query and its own clock
// window), and the pill is a view over one — so two faces never share state by
// accident, and neither re-implements "does this row's window cover now?".
//
// Rows are duck-typed the way atlas's readers already are: anything carrying
// from/until/arcs (a slot, an atlas row) can be time-filtered; the text fields
// are named per filter, since a slot's words and a place's words differ.

import { signal, effect } from './reactive.js';
import { windowCovers, windowIntersects, havKm } from './tabs/map/atlas.js';
import type { Windowed } from './tabs/map/atlas.js';
import type { Signal } from './reactive.js';
import { mk } from './dom.js';

/**
 * A filter INSTANCE. Each face keeps its own query and its own clock window,
 * so two faces never share state by accident and neither re-implements "does
 * this row's window cover now?".
 */
export interface SearchFilter {
  query: Signal<string>;
  timeBy: Signal<TimeMode>;
  /** The resting value timeBy was constructed with — "any" unless the
      caller asked for another. Read this rather than assume "any": a
      caller sharing one instance across faces (the express bar's clock and
      the map's pill, say) may give it a real horizon as its rest state, and
      "is anything narrowed" has to compare against THAT, not a hardcoded
      "any" that stops being true the moment a caller does this. */
  readonly defaultTimeBy: TimeMode;
  /** Custom range: start date/time, end date/time. */
  t0d: Signal<string>;
  t0t: Signal<string>;
  t1d: Signal<string>;
  t1t: Signal<string>;
  /** External data changed — re-rank. */
  bump: Signal<number>;
  /** Sort key, one of the caller's `sorts`; "" = the rows' own order. */
  sort: Signal<string>;
  /** Restrict to rows whose who/owner/provider is this; "" = anyone. */
  by: Signal<string>;
  passesTime(r: Windowed): boolean;
  passesText(r: SearchRow): boolean;
  passesBy(r: SearchRow): boolean;
  passes(r: SearchRow & Windowed): boolean;
  /** The rows in the sort's order — stable, ascending by the sort's reader; unsorted when none. */
  sorted<R>(rows: R[], readers: Record<string, (r: R) => number | string>): R[];
  /** The live facets as one value — what a saved view keeps. */
  snapshot(): Facets;
  /** Put a saved view's facets back into the live controls. */
  restore(f: Facets): void;
  /** Does the row pass THESE facets (a saved view's), rather than the live ones? */
  passesWith(r: SearchRow & Windowed & { qty?: unknown }, f: Facets): boolean;
  /** Peek-based, for callers asked mid-render whether anything is in force. */
  active(): boolean;
  reset(): void;
  /** How far from the centre a row may stand, in km; 0 = anywhere. A row with no place passes. */
  radiusKm: Signal<number>;
  /** The centre of the radius; null = the caller's own default (where you are). */
  center: Signal<GeoPt | null>;
  /** Teach the filter where things stand: a row's point, a place id's point, and the default centre. */
  setGeo(g: { ofRow(r: any): GeoPt | null; ofPlace(id: string): GeoPt | null; home(): GeoPt }): void;
  /** Does anything at these places (ids) stand within the radius? Unplaced goods pass. */
  passesPlaces(ids: string[]): boolean;
}

/** A point on the earth. */
export interface GeoPt { lat: number; lng: number }

/** The four time filters. */
export type TimeMode = "any" | "now" | "next24h" | "between";

/**
 * The facets as one value — free-association's SlotFilter (a saved, named
 * view: applies_to, min_quantity, …, OR-combined). A view keeps a snapshot;
 * passesWith reads a row against it without touching the live controls.
 */
export interface Facets {
  query: string;
  timeBy: TimeMode;
  t0d?: string; t0t?: string; t1d?: string; t1t?: string;
  by?: string;
  /** Rows at or above this quantity; 0/absent = any. */
  minQty?: number;
}

/**
 * A row the text filter can read: the fields its readers pull off it, each
 * optional and each `unknown` because a row is free to carry anything there.
 * The default reader takes the first six; the match ring passes its own
 * `fields` and reaches `cats` as well.
 */
export interface SearchRow {
  name?: unknown;
  provider?: unknown;
  who?: unknown;
  owner?: unknown;
  note?: unknown;
  spec?: unknown;
  /** Folksonomy term-ids. Only the match ring's own reader pulls these. */
  cats?: unknown;
}

/** The pill's parts, so a caller can mount it and dispose its effects. */
export interface SearchPill {
  el: HTMLElement;
  input: HTMLInputElement;
  effects: (() => void)[];
}


export const TIME_MODES: [TimeMode, string][] = [["any", "Any Time"], ["now", "Now"],
                           ["next24h", "Next 24h"], ["between", "Custom"]];

// searchFilter({ fields }) — the store and its predicates.
//   fields: (row) => [strings…] — what the query reads. Defaults to the shape
//   atlas rows and slot rows share.
export function searchFilter({ fields, defaultTimeBy = "any" }:
    { fields?: (r: SearchRow) => unknown[]; defaultTimeBy?: TimeMode } = {}): SearchFilter {
  const read = fields || ((r: SearchRow) => [r.name, r.provider, r.who, r.owner, r.note, r.spec]);
  const query = signal("");
  const timeBy = signal<TimeMode>(defaultTimeBy);      // any | now | next24h | between
  const t0d = signal(""), t0t = signal("");  // custom range: start date/time
  const t1d = signal(""), t1t = signal("");  // custom range: end date/time
  const bump = signal(0);                    // external data changed — re-rank
  const sort = signal("");                   // a key of the caller's sort readers
  const by = signal("");                     // a who/owner/provider, or anyone
  const radiusKm = signal(0);                // how far from the centre a row may stand; 0 = anywhere
  const center = signal<GeoPt | null>(null);
  let geo: { ofRow(r: any): GeoPt | null; ofPlace(id: string): GeoPt | null; home(): GeoPt } | null = null;
  const within = (p: GeoPt | null): boolean => {
    const km = radiusKm();
    if (!km || !geo || !p) return true;      // no radius, or nothing to measure: it passes
    const c = center() ?? geo.home();
    return havKm(c, p) <= km;
  };
  const passesRadius = (r: unknown): boolean => within(geo ? geo.ofRow(r) : null);

  // every predicate reads FACETS — the live ones by default, a saved view's
  // when a caller asks — so a view and the controls are one code path
  const live = (): Facets => ({ query: query(), timeBy: timeBy(), t0d: t0d(), t0t: t0t(),
                                t1d: t1d(), t1t: t1t(), by: by() });
  const timeWith = (r: Windowed, f: Facets): boolean => {
    const now = new Date();
    switch (f.timeBy) {
      case "now":     return windowCovers(r, now);
      case "next24h": return windowIntersects(r, now, new Date(now.getTime() + 24 * 3600e3));
      case "between": {
        if (!f.t0d || !f.t1d) return true;   // half-stated range filters nothing
        const a = new Date(`${f.t0d}T${f.t0t || "00:00"}`);
        const b = new Date(`${f.t1d}T${f.t1t || "23:59"}`);
        return isFinite(a.getTime()) && isFinite(b.getTime()) ? windowIntersects(r, a, b) : true;
      }
      default: return true;                  // "any"
    }
  };
  const textWith = (r: SearchRow, f: Facets): boolean => {
    const q = (f.query || "").trim().toLowerCase();
    return !q || read(r).some(v => String(v ?? "").toLowerCase().includes(q));
  };
  const byWith = (r: SearchRow, f: Facets): boolean =>
    !f.by || [r.who, r.owner, r.provider].some(v => String(v ?? "") === f.by);
  const qtyWith = (r: { qty?: unknown }, f: Facets): boolean =>
    !f.minQty || (Number(r.qty) || 0) >= f.minQty;
  const passesTime = (r: Windowed): boolean => timeWith(r, live());
  const passesText = (r: SearchRow): boolean => textWith(r, live());
  const passesBy = (r: SearchRow): boolean => byWith(r, live());
  return {
    query, timeBy, t0d, t0t, t1d, t1t, bump, sort, by,
    passesTime, passesText, passesBy,
    passes: r => passesText(r) && passesTime(r) && passesBy(r) && passesRadius(r),
    radiusKm, center,
    setGeo: g => { geo = g; },
    passesPlaces: ids => {
      if (!radiusKm() || !geo || !ids.length) return true;
      const pts = ids.map(id => geo!.ofPlace(id)).filter((p): p is GeoPt => !!p);
      return !pts.length || pts.some(p => within(p));
    },
    snapshot: live,
    restore: f => { query.set(f.query || ""); timeBy.set(f.timeBy || defaultTimeBy);
                    t0d.set(f.t0d || ""); t0t.set(f.t0t || ""); t1d.set(f.t1d || ""); t1t.set(f.t1t || "");
                    by.set(f.by || ""); },
    passesWith: (r, f) => textWith(r, f) && timeWith(r, f) && byWith(r, f) && qtyWith(r, f),
    sorted: (rows, readers) => {
      const k = sort(); const rd = k && readers[k];
      if (!rd) return rows;
      return rows.map((r, i) => ({ r, i, v: rd(r) }))
        .sort((a, b) => (a.v < b.v ? -1 : a.v > b.v ? 1 : a.i - b.i))
        .map(x => x.r);
    },
    // peek-based, for callers asked mid-render whether anything is in force
    active: () => !!query.peek().trim() || timeBy.peek() !== defaultTimeBy || !!by.peek() || radiusKm.peek() > 0,
    reset: () => { query.set(""); timeBy.set(defaultTimeBy); by.set(""); radiusKm.set(0); },
    defaultTimeBy,
  };
}

// searchPill(filter, opts) → { el, effects }
// The pill, built ONCE: a rebuilt input eats its own focus (calrail's search
// taught this), so the caller mounts this and redraws only the lists beneath.
// opts: { placeholder, onChange (after any control moves — clear a detail
// view), compact (drop the time filter for a face with no clock), text:false
// (drop the query input — another input already drives filter.query, as the
// share bar's name does), sorts (a [key,label][] → a sort select) }.
export function searchPill(filter: SearchFilter,
                           { placeholder = "Search…", onChange, compact = false, text = true, sorts }:
                           { placeholder?: string; onChange?: () => void; compact?: boolean;
                             text?: boolean; sorts?: [string, string][] } = {}): SearchPill {
  const { query, timeBy, t0d, t0t, t1d, t1t, sort } = filter;
  const wrap = mk("div", "ms-pillwrap");
  const inner = mk("div", "ms-pill");
  const input = mk("input", "ms-input");
  input.type = "text"; input.placeholder = placeholder;
  const touched = () => { if (onChange) onChange(); };
  input.oninput = () => { query.set(input.value); touched(); };
  const clear = mk("button", "ms-clear", "✕"); clear.title = "Clear search";
  clear.onclick = () => { query.set(""); input.value = ""; touched(); input.focus(); };
  if (text) inner.append(input, clear);
  if (sorts && sorts.length) {
    const sf = mk("div", "ms-time ms-sort");
    sf.append(mk("span", "ms-tico", "↕"));
    const sel = mk("select", "ms-tsel");
    for (const [v, l] of [["", "as declared"], ...sorts]) { const o = mk("option", null, l); o.value = v; sel.append(o); }
    sel.onchange = () => { sort.set(sel.value); touched(); };
    sf.append(sel);
    inner.append(sf);
  }

  let tsel: HTMLSelectElement | null = null;
  const custom = mk("div", "ms-custom");
  if (!compact) {
    const tf = mk("div", "ms-time");
    tf.append(mk("span", "ms-tico", "🕒"));
    const sel = mk("select", "ms-tsel");
    for (const [v, l] of TIME_MODES) { const o = mk("option", null, l); o.value = v; sel.append(o); }
    tsel = sel;
    // the options were written from TIME_MODES one line up, so the value is one
    sel.onchange = () => { timeBy.set(sel.value as TimeMode); touched(); };
    tf.append(sel);
    inner.append(tf);
    const row = (pair: [Signal<string>, string][]): HTMLElement => { const d = mk("div", "ms-trow");
      pair.forEach(([sig, type]) => { const i = mk("input", "ms-tin");
        i.type = type; i.onchange = () => { sig.set(i.value); touched(); }; d.append(i); });
      return d; };
    custom.append(row([[t0d, "date"], [t0t, "time"]]),
                  row([[t1d, "date"], [t1t, "time"]]));
  }
  wrap.append(inner, custom);
  const effects = [
    effect(() => { custom.style.display = timeBy() === "between" ? "flex" : "none"; }),
    // another hand on the same dial (the bar's clock) turned it: show that here
    effect(() => { const m = timeBy(); if (tsel && tsel.value !== m) tsel.value = m; }),
    effect(() => { clear.style.display = query() && text ? "block" : "none"; }),
    // another handle on the same filter (the share bar's name over the map's
    // pill) moved the query: this input shows it, without stealing focus
    effect(() => { const q = query(); if (input.value !== q && document.activeElement !== input) input.value = q; }),
  ];
  return { el: wrap, input, effects };
}
