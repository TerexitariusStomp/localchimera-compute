// app/disc.ts — the map as a DISC: a circle welded to the dial's centre.
//
// Zooming into a place from the time dial lowers the satellite into a circle
// the size of the dial's own rim, and the dial's angle stops meaning an hour and
// starts meaning a compass bearing. This module is that framing and only that:
// where the circle sits, the ⌃ that rises back out of it, the rim and the
// pointer arcs that read the map as a bearing dial. The map itself — the
// instance, its controls, its markers — is mapview.ts, which takes this as a
// FRAMING; the rectangle that fills the stage on the map face is mapface.ts.

import { S } from './state.js';
import { R, U } from './geom.js';
import { L } from './layers.js';
import { onEarth } from './stage.js';
import { drawChrome } from './chrome.js';
import { drawEvents } from './ribbons.js';
import { drawEarthArcs, drawThreads } from './threads.js';
import { theMap, type Framing } from './mapview.js';

/**
 * The satellite fills the whole circle, as the bands did — so the disc's radius
 * IS the dial's. Exported because the threads clip and measure against it, and
 * two constants that must agree are one constant.
 */
const mapFrac = 1.0;
export const mapR = (): number => R * mapFrac;

/** Set by sizeEarthMap: the live pixels-per-dial-unit, and the disc's radius. */
let pxPerUnit = 1, mapRpx = 1;

/** The disc's radius in pixels — what the route framing pads by. */
export const mapRadiusPx = (): number => mapRpx;
/** Screen pixels per dial unit, for anything measured on the map and drawn on the dial. */
export const pxPerDialUnit = (): number => pxPerUnit;

/**
 * Map pixels → dial viewBox coordinates. The disc's top-left sits at
 * (w∕2 − mapRpx, h∕2 − mapRpx) of the stage, and the dial's origin at its
 * centre — so a marker's screen position becomes a point the annulus can reach.
 */
export const mapToDial = (px: { x: number; y: number }): [number, number] =>
  [(px.x - mapRpx) / pxPerUnit, (px.y - mapRpx) / pxPerUnit];

/** Re-measure and re-place the disc and the chrome that rides its rim. */
export function sizeEarthMap(): void {
  const wrap = document.getElementById("orbwrap");
  const sv = document.getElementById("dial");
  if (!wrap || !sv) return;
  const wr = wrap.getBoundingClientRect();
  const sr = sv.getBoundingClientRect();
  const x0 = sr.left - wr.left, y0 = sr.top - wr.top;   // svg offset in wrap
  const w = sr.width, h = sr.height;
  pxPerUnit = Math.min(w, h) / (2 * S.VE * U);   // track the live viewBox extent
  mapRpx = mapR() * U * pxPerUnit;
  d3.select("#earthmap")
    .style("left", `${x0 + w / 2 - mapRpx}px`).style("top", `${y0 + h / 2 - mapRpx}px`)
    .style("width", `${2 * mapRpx}px`).style("height", `${2 * mapRpx}px`);
  d3.select("#threads")
    .style("left", `${x0}px`).style("top", `${y0}px`)
    .attr("width", w).attr("height", h);
  // back + go ride the disc's lower edge, centred
  d3.select("#backchip").style("bottom", `${wr.height - (y0 + h / 2 + mapRpx) + 12}px`);
  d3.select("#gochip").style("bottom", `${wr.height - (y0 + h / 2 + mapRpx) + 44}px`);
  // the way-up button rides just inside the map's top rim, centred
  d3.select("#mapback")
    .style("left", `${x0 + w / 2}px`)
    .style("top", `${y0 + h / 2 - mapRpx + 12}px`);
  // (the fullscreen toggle and the compass are not here: both live in the
  // native maplibre control stack, which rides the map's own container corner
  // in either framing)
  theMap()?.resize();
}

/** The circle: the one framing with a dial behind it, and so the one with a way up to it. */
export const disc: Framing = {
  element: "earthmap",
  size: sizeEarthMap,
  open: () => { d3.select("#mapback").style("display", "block"); },   // the in-map way up
  offline: () => { d3.select("#backchip").style("display", "none"); },
  ready: m => {
    // the threads are welded to the disc rather than to the world, so they
    // follow every frame of a move
    if (!m._threadsBound) { m.on("move", drawThreads); m._threadsBound = true; }
    d3.select("#backchip").style("display", "none");
    L.rings.transition().duration(600).attr("opacity", 0)
      .on("end", () => { if (onEarth()) L.rings.attr("pointer-events", "none"); });
    drawChrome();
    drawEvents();
    drawEarthArcs();
  },
  close: () => {
    for (const sel of ["#mapback", "#backchip"]) d3.select(sel).style("display", "none");
  },
};
