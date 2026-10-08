// app/places.ts — where a classification is met, listed and described.
//
// Drill a desire band and the earth opens on the places that can meet it. This
// is the sidebar list — nearest first — and the card that speaks for whichever
// one you select. The map draws the same places as markers; both read PLACES
// under the lens, so the list and the dots are two views of one set and the
// selection is shared.
//
// ── WHAT A PLACE AFFORDS DEPENDS ON ITS RAIL ────────────────────────────────
// A claimable, communal or own resource affords DIRECTIONS — ↦ go, and the
// wayfinder takes it from there. A work-intent affords WILLINGNESS, the skill
// rail's act. One card, and the difference is the rail, which is exactly the
// doc's "priority weights span both rails" showing up as two verbs.
//
// The card also answers the question a list cannot: not just "is it open" but
// "will it still be open when I get there" — the walk is a real duration and a
// place that shuts during it is not somewhere you can go now.

import { PLACES, USER, MODES, pcoord } from './core.js';
import { havKm } from './geom.js';
import { isWilling, offerWillingness, tagHtml } from './willingness.js';
import { navKm, ARROW8 } from './nav.js';
import { stage } from './stage.js';
import type { Place } from './core.js';
import { STATUS } from './palette.js';

/** The map's radial unit: how far you get on foot, read back in τ. */
export const WALK_KMH = 4.8;

/** Is the place open at this hour of the turn? Unlisted hours mean always. */
export const isOpenAt = (p: Place, t: number): boolean =>
  (p.open || [[0, 24]])
    .some(([a, b]) => ((t % 24) + 24) % 24 >= a && ((t % 24) + 24) % 24 < b);

/** What the panel needs from the dial around it. */
export interface PlacesHost {
  /** The compass bearing from you to a place, in the dial's own frame. */
  bearingTo(p: Place): number;
  /** A place was selected or deselected: re-render the map's markers. */
  markersChanged(): void;
  /** Repaint the bearing arcs, which highlight the selected place's thread. */
  arcsChanged(): void;
  /** Fly the camera to a place, or frame everything again on deselect. */
  frame(p: Place | null): void;
  /** The card reshapes the stage — re-weld the map disc to the dial. */
  restage(): void;
  /** Nothing is selected: the card falls back to the day's own view. */
  quietCard(): void;
  /** A new destination ends the journey in progress. */
  endJourney(): void;
}

let host: PlacesHost;
let selected = -1;

export function initPlaces(h: PlacesHost): void {
  host = h;
}

/** Which place is selected, by index into the lens's list, or -1. */
export const selectedPlace = (): number => selected;

/** The selected place itself, or null. */
export function selectedPlaceOf(): Place | null {
  const leaf = stage.leaf;
  if (selected < 0 || !leaf) return null;
  return (PLACES[leaf.id] || [])[selected] || null;
}

/** Open the panel on a classification's places, nearest first. */
export function showPlacesPanel(d: { id: string; name: string; col?: string }): void {
  selected = -1;
  d3.select("#gochip").style("display", "none");
  host.endJourney();
  const ps = (PLACES[d.id] || [])
    .map((p, i) => ({ p, i, km: havKm(USER, pcoord(p)) }))
    .sort((a, b) => a.km - b.km);
  d3.select("#placesSec").style("display", "block");
  d3.select("#placesName").html(`<b style="color:${d.col}">${d.name}</b>
    <span style="color:#999">— sorted by distance from you</span>`);
  const t = stage.hand;
  d3.select("#places").selectAll("li").data(ps, x => String(x.i)).join("li")
    .attr("class", x => (x.i === selected ? "sel" : "") +
                        (x.p.mode === "work" ? " work" : ""))
    .on("click", (_e, x) => selectPlace(x.i))
    .html(x => `<span class="pemoji">${x.p.emoji}</span>
      <span class="pname">${x.p.name}
        <span style="color:${isOpenAt(x.p, t) ? STATUS.sound : STATUS.unmet}; font-size:9px"> ●</span>
        <span style="color:#999; font-size:10.5px"> ${x.p.when}</span>
        <span class="ptag">${tagHtml(x.p)}</span></span>
      <span class="pdist">${x.km < 1 ? `${Math.round(x.km * 1000)} m` : `${x.km.toFixed(1)} km`}
        <span style="color:#bbb">· ${Math.round(x.km / WALK_KMH * 60)} min walk</span></span>`);
}

/** Select a place, or deselect it by choosing it again. */
export function selectPlace(i: number): void {
  host.endJourney();   // a new destination ends the old journey
  selected = selected === i ? -1 : i;
  d3.select("#places").selectAll("li").attr("class", x =>
    ((x as { i: number; p: Place }).i === selected ? "sel" : "") +
    ((x as { i: number; p: Place }).p.mode === "work" ? " work" : ""));
  host.markersChanged();
  d3.select("#gochip").style("display", selected >= 0 ? "block" : "none");
  host.arcsChanged();
  host.frame(selectedPlaceOf());
  renderPlaceCard();
  host.restage();
}

/** Re-render just the willingness tags in the list, in place. */
export function refreshTags(): void {
  d3.select("#places").selectAll("li.work").each(function (this: Element, d) {
    d3.select(this).select(".ptag").html(tagHtml((d as { p: Place }).p));
  });
}

/**
 * The resource speaks where events do: the detail card under the dial.
 *
 * With nothing selected the card goes quiet and the day's own view returns —
 * the card is one surface shared with the calendar, not a panel of its own.
 */
export function renderPlaceCard(): void {
  const p = selectedPlaceOf();
  const leaf = stage.leaf;
  if (!p || !leaf) { host.quietCard(); return; }
  const m = MODES[p.mode] || MODES.own, isWork = p.mode === "work";
  const km = havKm(USER, pcoord(p));
  const brg = host.bearingTo(p);
  const wind = ARROW8[Math.round(brg / 45) % 8];
  const t = stage.hand;
  const open = isOpenAt(p, t);
  const walkH = km / WALK_KMH;
  // NOT just "is it open": will it still be open when you arrive? The walk is a
  // real duration, and a place that shuts during it is not somewhere you can go.
  const reach = isOpenAt(p, t + walkH);
  const onFoot = walkH >= 1 ? `${Math.floor(walkH)} h ${Math.round((walkH % 1) * 60)} m`
                            : `${Math.round(walkH * 60)} m`;
  const ok = isWork && isWilling(p);
  const footer = isWork
    ? `VF: work-intent @ SpatialThing — a skill slot; ${ok ? "willingness offered" : "offer willingness to be matched"}`
    : `VF: EconomicResource @ SpatialThing · ↦ go for directions`;
  const card = d3.select("#evdetail")
    .style("border-left-color", isWork ? m.col : leaf.col)
    .html(`
      ${p.emoji} <b>${p.name}</b> <span style="color:#999">· ${leaf.name}</span>
        <span style="color:${m.col}; font-size:10.5px"> · ${m.label}</span><br>
      ${p.when} · <span style="color:${open ? STATUS.sound : STATUS.unmet}">${open ? "open now" : "shut now"}</span><br>
      ${navKm(km)} ${wind} (${Math.round(brg)}° from N) · ~${onFoot} on foot
      ${reach ? "" : ` · <span style="color:${STATUS.unmet}">shut by the time you arrive</span>`}<br>
      <span style="color:#999">${footer}</span>
      ${isWork ? `<div style="margin-top:6px"><button id="willbtn" class="${ok ? "on" : ""}">${ok ? "✓ willing — withdraw" : "offer willingness"}</button></div>` : ""}`);
  if (isWork) card.select("#willbtn").on("click", () => offerWillingness(p));
}
