// app/markers.ts — one renderer for everything on the map.
//
// Places, offers, drop points and the socialized pool all land here, and the
// point of one renderer is that clustering is a property of the MAP, not of any
// one source: points within CLUSTER_PX of each other on screen fold into one
// bubble whatever they are, so a zoomed-out map shows groups rather than a pile.
// Mirrors module/playnet/ui/map.scm.
//
// ── ONE RULE KEEPS THIS CALM: NOTHING HERE READS THE VIEWPORT ───────────────
// Groups are buckets in WORLD PIXELS at the settled integer zoom. So a pan
// changes nothing at all — maplibre translates the existing markers, which is
// free and perfectly smooth, and this never even re-renders — and a zoom
// regroups exactly once, when the gesture settles. Off-view points are simply
// markers that happen to be off-screen; the places panel already lists what is
// far, so the frame owes no indicator.
//
// Each rendered unit persists in the registry under a STABLE KEY (a point's own
// id; a cluster's zoom-and-cell) and is morphed in place, so the DOM never
// blinks. The flicker was always the rebuild.

import { PLACES, cWarm, cYea } from './core.js';
import { fmtClock } from './timefmt.js';
import { themed } from './theme.js';
import { relevantOffers } from './offers.js';
import * as dropoff from './tabs/map/dropoff.js';
import * as pool from './tabs/map/pool.js';
import * as mapsearch from './tabs/map/mapsearch.js';
import * as pins from './tabs/map/pins.js';
import * as share from './tabs/social/share.js';
import * as atlas from './tabs/map/atlas.js';
import type { MarkerPoint } from './tabs/map/atlas.js';
import { stage, onMapFace } from './stage.js';
import { renderJourneys } from './journeys.js';
import { effect } from './reactive.js';
import type { DayEvent } from './seam.js';

/** How close on screen is close enough to fold into one bubble. */
const CLUSTER_PX = 34;

/** A key for an offer that survives mapOffers re-wrapping it each render. */
export const evKey = (o: DayEvent | null | undefined): string =>
  o ? `${o.label}@${o.t0}` : "";

/** What the renderer needs to know about the dial around it. */
export interface MarkerHost {
  /** The map to place markers on — null before one is built. */
  map(): maplibregl.Map | null;
  /** The disc's selected place index, or -1. */
  selectedPlace(): number;
  /** Select a place on the disc. */
  selectPlace(i: number): void;
  /** The open event's card, as read and written by the disc. */
  selectedEv(): DayEvent | null;
  selectEvent(ev: DayEvent | null): void;
  /** Whether willingness has been offered against this thing. */
  isWilling(x: unknown): boolean;
  /** Re-apply the off-view fades once a render settles. */
  afterRender(): void;
}

let host: MarkerHost;

/**
 * A place's live element, by its index — or absent when it is folded into a
 * cluster. The off-view pointer arcs read it to fade and hide what is beyond
 * the disc, which is why the array is owned HERE, beside the only code that
 * fills it, rather than being a bare `let` somebody else also wrote to.
 */
let placeEl: (HTMLElement | undefined)[] = [];

/** The live element for a place, when it is drawn as itself. */
export const placeElAt = (i: number): HTMLElement | undefined => placeEl[i];

/** Every point the map should show right now. */
function markerPoints(): MarkerPoint[] {
  const leaf = stage.leaf;
  if (!leaf) return [];
  const pts: MarkerPoint[] = [];
  // atlas.MAP_ANCHOR, not live USER: USER drifts continuously (real
  // geolocation jitter, live-location watchers), and reading it straight at
  // render time made every point here jump relative to the viewport the
  // moment anything forced a redraw (a zoom, most visibly) — see MAP_ANCHOR's
  // own comment in atlas.ts.
  (PLACES[leaf.id] || []).forEach((p, i) =>
    pts.push({ lng: atlas.MAP_ANCHOR.lng + p.dLng, lat: atlas.MAP_ANCHOR.lat + p.dLat, kind: "place", p, i }));
  const offs = relevantOffers(leaf.id);
  offs.forEach(o =>
    pts.push({ lng: atlas.MAP_ANCHOR.lng + o.at!.dLng, lat: atlas.MAP_ANCHOR.lat + o.at!.dLat, kind: "offer", o }));
  // The SELECTED event always shows, even when it belongs to another
  // classification (a rim event from elsewhere in your day): "select → see it
  // on the map" must hold, or you fly to an empty spot.
  const selEv = host.selectedEv();
  if (selEv && selEv.at && !offs.some(o => evKey(o) === evKey(selEv)))
    pts.push({ lng: atlas.MAP_ANCHOR.lng + selEv.at.dLng, lat: atlas.MAP_ANCHOR.lat + selEv.at.dLat,
               kind: "offer", o: selEv });
  if (onMapFace()) {
    // Drop points — containers you can leave things in and take them from — and
    // the socialized pool, means the commons holds by live grant. Both on the
    // MAP face only: the disc map reached from a desire band answers "where is
    // this need met", which is a different question.
    pts.push(...dropoff.dropPoints() as unknown as MarkerPoint[]);
    pts.push(...pool.poolPoints());
  }
  // Search-as-map-filter: while the panel holds a query or a time filter, the
  // map shows exactly what the results list names. ONE predicate, two surfaces
  // — and a no-op when the panel is at rest.
  return pts.filter(pt => mapsearch.matchesPt(pt) && matchesShare(pt));
}

// The share drawer's own toolbar is chrome on every face — it never closes
// what it knows, so its search ANDs onto the map's own (both must admit a
// point). A pool point ALSO answers to the need⇄offer rail: whichever side
// is lit is the only side the map shows a slot for, the same switch that
// already picks which column the drawer's own list reads.
function matchesShare(pt: MarkerPoint): boolean {
  if (pt.kind !== "pool") return atlas.passesFilter(pt, share.F);
  // a pool point ALSO answers to the rail (need ⇄ offer — the same switch
  // that already picks which column the drawer's own list reads), the
  // dialled rhythm (overlap, not equality — passesRhythm) and the dialled
  // place (exact match) — the toolbar's other fields, live as it types them.
  if (pt.need !== (share.rail() === "need")) return false;
  if (!atlas.passesFilter(pt, share.F)) return false;
  const row = atlas.rowOfPt(pt);
  if (!row) return true;
  const where = share.draftWhere();
  if (where && row.where !== where) return false;
  return atlas.passesRhythm(row, share.draftWhen());
}

/** The DOM for a single point, wearing its list's face when it is pinned. */
function pointEl(pt: MarkerPoint): HTMLElement {
  const el = bareEl(pt);
  const row = onMapFace() && pins.hasPins() ? atlas.rowOfPt(pt) : null;
  const badge = row ? pins.badgeOf(pins.subjectOf(row)) : null;
  if (badge) {
    el.classList.add("pinned");
    const b = document.createElement("span");
    b.className = "pin-badge"; b.textContent = badge;
    el.append(b);
  }
  return el;
}
function bareEl(pt: MarkerPoint): HTMLElement {
  if (pt.kind === "drop") return dropoff.dropEl(pt as unknown as { c: dropoff.Drop; m: number });
  if (pt.kind === "pool") return pool.poolEl(pt);
  const el = document.createElement("div");
  const onMap = onMapFace();
  if (pt.kind === "place" && pt.p!.mode !== "work") {
    el.className = "map-slot-marker" + (host.selectedPlace() === pt.i ? " sel" : "");
    el.innerHTML = `<div class="marker-icon">${pt.p!.emoji}</div>` +
                   `<div class="marker-label">${pt.p!.name}</div>`;
    el.onclick = e => {
      e.stopPropagation();
      if (onMap) mapsearch.showOnPanel(mapsearch.rowOfPt(pt)!);
      else host.selectPlace(pt.i!);
    };
  } else {
    const o = pt.kind === "offer" ? pt.o! : null;
    // A marker selected from the rim may be a raw event with no tier yet — read
    // it from its status so the dot still styles (day / offered / open).
    const tier = o ? ((o.tier as string) || (o.status === "proposed" ? "offered" : "day")) : "open";
    const target = o || pt.p!;
    const selEv = host.selectedEv();
    const sel = o ? Boolean(selEv && evKey(selEv) === evKey(o))
                  : (host.selectedPlace() === pt.i);
    el.className = `map-offer-marker tier-${tier}` +
                   (host.isWilling(target) ? " willing" : "") + (sel ? " sel" : "");
    el.style.setProperty("--oc", o && o.kind === "free" ? cYea : cWarm);
    const label = o ? `${fmtClock(o.t0)} ${o.label}` : pt.p!.name;
    el.innerHTML = `<span class="odot"></span><span class="olabel">${label}</span>`;
    el.title = o
      ? (tier === "open" ? `eligible — ${o.label} · select to offer willingness`
                         : `${o.from ? o.from + " · " : ""}${o.label}`)
      : pt.p!.name;
    el.onclick = e => {
      e.stopPropagation();
      if (onMap) { mapsearch.showOnPanel(mapsearch.rowOfPt(pt)!); return; }
      // click again → deselect (the disc's own toggle)
      if (o) host.selectEvent(host.selectedEv() === o ? null : o);
      else host.selectPlace(pt.i!);
    };
  }
  return el;
}

/** The face a member shows inside a cluster bubble. Offers carry none. */
const emojiOf = (pt: MarkerPoint): string | null =>
  pt.kind === "place" ? pt.p!.emoji
  : pt.kind === "pool" ? (pt.s!.emoji || (pt.need ? "🌱" : "🤲"))
  : pt.kind === "drop" ? ((pt.c && pt.c.emoji) || "📦")
  : null;

/**
 * A stable identity for every point — the key its marker persists under across
 * re-renders, so panning and zooming morph elements in place instead of
 * rebuilding them.
 */
const ptKey = (pt: MarkerPoint): string =>
  pt.kind === "place" ? `p:${pt.i}`
  : pt.kind === "pool" ? `l:${pt.s!.id}`
  : pt.kind === "drop" ? `d:${pt.c && pt.c.id}`
  : `o:${evKey(pt.o)}`;

/**
 * A cluster bubble shows its MEMBERS — up to four faces huddled in the ring,
 * the way a group of offers reads on a commons map — with a corner badge for
 * what the faces cannot say: the overflow (+N), a faceless count, or, for a
 * group that is entirely pool means, the commons' occupied-of-total.
 */
function clusterEl(group: MarkerPoint[]): HTMLElement {
  const el = document.createElement("div");
  el.className = "map-cluster-marker";
  const anyWork = group.some(g => g.kind === "place" ? g.p!.mode === "work"
                                                     : g.kind === "offer" && g.o!.kind === "work");
  // not a d3 paint, so it is themed by hand
  el.style.setProperty("--cc", themed(anyWork ? cWarm : "#2c4a6e"));
  const faces = group.map(emojiOf).filter(Boolean).slice(0, 4) as string[];
  const more = group.length - faces.length;
  const means = group.filter(g => g.kind === "pool" && !g.need);
  let badge = "", title = "several here — tap to zoom in";
  if (means.length === group.length && means.length) {
    const tot = means.reduce((a, g) => a + (+(g.s!.qty ?? 0) || 0), 0);
    const occ = Math.round(means.reduce((a, g) =>
      a + (+(g.s!.drawn ?? 0) || 0) * (+(g.s!.qty ?? 0) || 0), 0));
    badge = `${occ}/${tot}`;
    title = `the commons here — ${occ} of ${tot} taken by the plan · tap to zoom in`;
  } else if (!faces.length) badge = String(group.length);
  else if (more > 0) badge = `+${more}`;
  el.innerHTML =
    `<span class="cfaces n${Math.min(faces.length, 4)}">${faces.map(f => `<i>${f}</i>`).join("")}</span>`
    + (badge ? `<span class="cbadge">${badge}</span>` : "");
  el.title = title;
  el.onclick = e => {
    e.stopPropagation();
    // MAP face: the bundle answers in the panel — its members as cards, each
    // openable, with "zoom to split" as the header's own act. The disc keeps
    // the plain zoom, having no panel to answer in.
    if (onMapFace()) { mapsearch.showCluster(group.map(g => mapsearch.rowOfPt(g)!)); return; }
    const map = host.map();
    if (!map) return;
    const lats = group.map(g => g.lat), lngs = group.map(g => g.lng);
    map.fitBounds([[Math.min(...lngs), Math.min(...lats)],
                   [Math.max(...lngs), Math.max(...lats)]],
                  { padding: 70, duration: 600, maxZoom: 17, bearing: map.getBearing() });
  };
  return el;
}

/** One rendered unit: the maplibre marker, and the element it carries. */
interface Rendered {
  marker: maplibregl.Marker;
  el: HTMLElement;
}

let markerReg = new Map<string, Rendered>();

/** Take every marker off the map. */
export function clearMarkers(): void {
  markerReg.forEach(r => r.marker.remove());
  markerReg = new Map();
  placeEl = [];
}

/**
 * Update an element in place, touching only what changed.
 *
 * The element BELONGS TO MAPLIBRE while it is a Marker: the library stamps
 * maplibregl-* classes on it and positions it through style.transform. So the
 * morph must clobber neither — classes are compared bare (ours only, maplibre's
 * kept) and styles are copied per custom property, never as cssText.
 */
function morphEl(el: HTMLElement, fresh: HTMLElement): void {
  const keep = [...el.classList].filter(c => c.startsWith("maplibregl-"));
  const bare = [...el.classList].filter(c => !c.startsWith("maplibregl-")).join(" ");
  if (bare !== fresh.className)
    el.className = fresh.className + (keep.length ? " " + keep.join(" ") : "");
  if (el.innerHTML !== fresh.innerHTML) el.innerHTML = fresh.innerHTML;
  if (el.title !== fresh.title) el.title = fresh.title;
  el.onclick = fresh.onclick;
  for (const p of ["--oc", "--cc"]) {
    const v = fresh.style.getPropertyValue(p);
    if (v && el.style.getPropertyValue(p) !== v) el.style.setProperty(p, v);
  }
}

/** Regroup and repaint every marker. Cheap to call; it does nothing on a pan. */
export function renderMarkers(): void {
  const map = host.map();
  if (!map || !stage.leaf) return;
  placeEl = [];
  // bucket in world px at the settled integer zoom — pan-invariant, zoom-stepped
  const zq = Math.max(0, Math.round(map.getZoom()));
  const scale = (512 * Math.pow(2, zq)) / CLUSTER_PX;
  const cells = new Map<string, MarkerPoint[]>();
  for (const pt of markerPoints()) {
    const mc = maplibregl.MercatorCoordinate.fromLngLat([pt.lng, pt.lat]);
    const k = `${Math.floor(mc.x * scale)}:${Math.floor(mc.y * scale)}`;
    if (!cells.has(k)) cells.set(k, []);
    cells.get(k)!.push(pt);
  }
  const seen = new Set<string>();
  for (const [cell, group] of cells) {
    const single = group.length === 1;
    const key = single ? ptKey(group[0]) : `c:${zq}:${cell}`;
    seen.add(key);
    // d3.mean rather than a fold: it SKIPS a point whose coordinate is
    // unreadable, where a fold would drag the whole bubble to NaN and off the map.
    const lng = single ? group[0].lng : d3.mean(group, x => x.lng)!;
    const lat = single ? group[0].lat : d3.mean(group, x => x.lat)!;
    const fresh = single ? pointEl(group[0]) : clusterEl(group);
    const reg = markerReg.get(key);
    if (reg) {
      morphEl(reg.el, fresh);
      // A marker the disc's hider (or any stale writer) switched off comes
      // back: inline display belongs to NOBODY between renders.
      if (reg.el.style.display) reg.el.style.display = "";
      reg.marker.setLngLat([lng, lat]);
    } else {
      const mk = new maplibregl.Marker({ element: fresh, anchor: "center" })
        .setLngLat([lng, lat]).addTo(map);
      markerReg.set(key, { marker: mk, el: fresh });
    }
    if (single && group[0].kind === "place")
      placeEl[group[0].i!] = markerReg.get(key)!.el;
  }
  // whatever this render no longer names, leaves — the ONLY removal path
  for (const [key, reg] of markerReg)
    if (!seen.has(key)) { reg.marker.remove(); markerReg.delete(key); }
  renderJourneys();   // the move arcs re-derive with the pins they connect
  host.afterRender();
}

/** Hand the renderer the map and the dial around it. */
export function initMarkers(h: MarkerHost): void {
  host = h;
  // The map's OWN search re-renders through an IMPERATIVE callback
  // (mapview.ts's bindFilter, fired straight from the search pill's own
  // input handler) — nothing like that exists for the share bar, which is
  // chrome on every face and has no map-specific hook to call. This effect
  // is that hook: it reads every share-bar filter signal UNCONDITIONALLY
  // (never through passesFilter's own peek-based fast path, which is why
  // typing alone never triggered a redraw before this), so it resubscribes
  // on every change and redraws whenever the map is the face actually up.
  effect(() => {
    share.F.query(); share.F.timeBy(); share.F.by();
    share.rail(); share.draftWhen(); share.draftWhere();
    if (onMapFace() && host.map()) renderMarkers();
  });
}
