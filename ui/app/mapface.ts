// app/mapface.ts — the map as a FACE: a rectangle that fills the stage.
//
// The map tab owns the stage outright. There is no dial behind it to rise
// back to — the tab bar is the way out — and no disc geometry, so the bearing
// chrome (threads, isochrones, the rim's compass marks) has nothing to say here
// and is never drawn. The face leaves `stage.mode` on "dial": the dial is simply
// a face that is not showing, as it is under every other face.
//
// This module is that framing and the face's own comings and goings. The map
// itself is mapview.ts, which takes this as a FRAMING; the circle the same map
// takes when you zoom into a place from the dial is disc.ts.

import { stage, onMapFace } from './stage.js';
import { settle } from './wheel.js';
import { MAP_ALL } from './offers.js';
import { drawChrome } from './chrome.js';
import { drawEvents } from './ribbons.js';
import { clearMarkers, renderMarkers } from './markers.js';
import { askGeolocation, resetHeading } from './compass.js';
import { endNav } from './route/nav.js';
import { L, threads } from './layers.js';
import { openMap, teardownMap, showMapSurface, theMap, type Framing } from './mapview.js';
import { leaveSelectArea } from './tabs/map/select-area.js';
import * as dropoff from './tabs/map/dropoff.js';
import * as pool from './tabs/map/pool.js';
import * as mapsearch from './tabs/map/mapsearch.js';
import { placeAt } from './tabs/map/osm-places.js';
import * as containers from './tabs/map/containers.js';

/** The instances whose face gestures are bound — a rebuilt map starts clean. */
const bound = new WeakSet<maplibregl.Map>();

/** Re-measure and re-place the map: the whole stage, from its corner. */
function sizeMapFace(): void {
  const wrap = document.getElementById("orbwrap");
  if (!wrap) return;
  const wr = wrap.getBoundingClientRect();
  d3.select("#maptab")
    .style("left", "0px").style("top", "0px")
    .style("width", `${wr.width}px`).style("height", `${wr.height}px`);
  d3.select("#threads").style("left", "0px").style("top", "0px")
    .attr("width", wr.width).attr("height", wr.height);
  d3.select("#gochip").style("left", "16px").style("transform", "none").style("bottom", "16px");
  theMap()?.resize();
}

/** The rectangle: the framing with the search panel, the drop points and the pool in it. */
const mapFace: Framing = {
  element: "maptab",
  size: sizeMapFace,
  // the search panel and its filter are about DATA, not tiles: they mount
  // before the no-WebGL bail, so a browser without it still gets its search
  open: () => {
    mapsearch.mountMapSearch();
    mapsearch.bindFilter(() => { if (theMap()) renderMarkers(); });
  },
  offline: showMapSurface,      // the dark map surface, not a void
  ready: m => {
    // the drop points ride the same markers, so their card hands back a restyle
    dropoff.mountDrops({ map: m, refresh: renderMarkers, select: containers.setSelected });
    pool.mountPool({ refresh: renderMarkers });
    if (bound.has(m)) return;
    bound.add(m);
    // a tap on one of OpenStreetMap's places (the basemap's own labels) opens
    // it in the panel as a row of the map's own — the dial's markers stop their
    // click before the map sees it, so this fires only on the ground
    m.on("click", e => { if (!onMapFace()) return; const r = placeAt(m, e.point); if (r) mapsearch.showOnPanel(r); });
    // a dropped pin: right-click, or press-and-hold on touch (maplibre raises
    // contextmenu for both) — a bare spot opens in the panel, ready to save
    m.on("contextmenu", e => { if (onMapFace()) mapsearch.showSpot(e.lngLat.lat, e.lngLat.lng); });
  },
  close: () => {
    dropoff.unmountDrops();
    pool.unmountPool();
    mapsearch.unmountMapSearch();
  },
};

/**
 * Enter the map: the unlensed leaf, so every place shows.
 *
 * The caller establishes the time stage first, because the map sizes itself
 * against the stage the dial left. A disc still open from a drill-down is put
 * away first — the face and the disc are two framings of one map and never
 * stand together.
 */
export function enterMapFace(): void {
  if (stage.mode !== "dial") {
    teardownMap(); endNav(); clearMarkers();
    L.earth.selectAll("*").remove();
    threads.selectAll("*").remove();
    stage.mode = "dial";
  }
  stage.leaf = MAP_ALL; stage.leafK = 0;
  askGeolocation();
  openMap(mapFace);
}

/** Leave the map instantly — no rise animation, because a tab is not a journey. */
export function exitMapFace(): void {
  leaveSelectArea();      // the area frame, if it was up, goes with the map
  teardownMap();          // the same put-away the dial uses rising out of earth
  endNav();
  clearMarkers();
  L.earth.selectAll("*").remove();
  threads.selectAll("*").remove();
  resetHeading();
  stage.leaf = null; stage.leafK = -1;
  drawChrome(); drawEvents(); settle();
}
