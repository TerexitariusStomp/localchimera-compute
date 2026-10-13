// app/earth.ts — the reveal: a leaf need has no finer subdivision in time, so
// its answer is a WHERE.
//
// Click a leaf and the band dilates to fill the dial, the pigment fades, and
// the planet that was rendered beneath the bands ALL ALONG is simply left
// showing. The globe then falls toward your own position — the centre of the
// map is you — and the satellite fabric of places fades in: the resources and
// open slots where this need can actually be met.
//
// That the planet is already there is the whole design of the gesture. Nothing
// here builds a globe; it fades pigment off what was under the bands the entire
// time (app/globe.ts draws it), which is why the reveal reads as an uncovering
// rather than a transition to somewhere else.
//
// ── THE THREE STAGES, AND THEIR MIRRORS ─────────────────────────────────────
//   A  dilate — the leaf's band grows until it is the whole dial
//   B  fade   — the pigment lifts off the planet beneath
//   C  fall   — the globe zooms from whole-earth to where you stand
// and coming back is exactly those three run backwards: C′ rise, B′ the pigment
// returns, A′ the band contracts into its place among its siblings. Both
// directions run on `dilate` (app/bands.ts), the same remap the two zooms use,
// and differ only in which way `u` runs through it.
//
// ── "exiting" IS A THIRD MODE ───────────────────────────────────────────────
// While the dial rises out of the map it is neither on the earth nor back on
// the dial. It reports `exiting` for that stretch so the chrome and the ribbons
// read in τ again on the way up, rather than snapping from bearings to hours at
// the very end.

import { n, clamp01 } from './geom.js';
import { hint } from './core.js';
import { stage } from './stage.js';
import { drawGlobe, landReady, S0, sFinal } from './globe.js';
import { drawChrome } from './chrome.js';
import { drawEvents } from './ribbons.js';
import { drawPriorityBar } from './pribar.js';
import { drawCrumb } from './crumb.js';
import { showPlacesPanel } from './places.js';
import { clearMarkers } from './markers.js';
import { askGeolocation, resetHeading } from './compass.js';
import { endNav } from './route/nav.js';
import { openMap, teardownMap } from './mapview.js';
import { drawBandsRaw, drawBands2, settle } from './wheel.js';
import { L, threads } from './layers.js';
import type { DesireNode } from './desire.js';
import { dilate } from './bands.js';
import type { Sample, BandFrame } from './bands.js';

/** Everything the pigment lives on: it all fades to leave the planet showing. */
const pigment = (): d3.Selection[] => [L.bands, L.seams, L.hand, L.centre, L.spiral];

/**
 * The leaf's own met/pale structure, as a one-band layout inside its own range.
 *
 * Dilating is exactly this: the leaf stops being a slice of the wheel and
 * becomes the wheel, keeping its met/unmet split. So the animation interpolates
 * between two real layouts rather than scaling a picture.
 */
const leafLay = (k: number, cums: Sample[]): BandFrame[] =>
  d3.range(n + 1).map(i =>
    ({ cum: [cums[i].cum[k], cums[i].cum[k + 1]], met: [cums[i].met[k]] }));

/** Redraw the siblings and the leaf at one point along the dilation. */
function paintStage(d: DesireNode, sibs: DesireNode[], oldLay: BandFrame[],
                    lay: BandFrame[], k: number, u: number): void {
  const g = dilate(oldLay, k, u);
  L.bands.selectAll("*").remove();
  L.seams.selectAll("*").remove();
  drawBandsRaw(sibs, oldLay, g, k);
  drawBands2([d], lay, g);
}

/** Open the earth beneath leaf `d`, band `k` of the current focus. */
export function revealEarth(d: DesireNode, k: number): void {
  if (stage.zooming || stage.mode === "earth") return;
  stage.zooming = true;
  stage.mode = "earth"; stage.leaf = d; stage.leafK = k;
  L.prev.selectAll("*").remove(); L.chords.selectAll("*").remove();
  askGeolocation();
  const cums = stage.cums;
  const lay = leafLay(k, cums), oldLay = cums, sibs = stage.focus.children || [];

  // if the land data never arrives (offline, a 404), RELEASE the dial rather
  // than leaving every guard parked behind `busy` forever
  landReady.catch(() => {
    hint(`${d.name} — the earth data did not load; the dial is yours again.`, "warn");
    stage.zooming = false;
    stage.mode = "dial"; stage.leaf = null; stage.leafK = -1;
    settle();
  });

  landReady.then(() => {
    drawGlobe(S0, 1, 0, true);
    d3.transition("earth").duration(800).ease(d3.easeCubicInOut)
      // A: the leaf's band dilates to fill the dial
      .tween("dilate", () => (u: number) => paintStage(d, sibs, oldLay, lay, k, u))
      // B: the pigment fades — the planet has always been there
      .transition().duration(600)
      .tween("fade", () => (u: number) => {
        for (const grp of pigment()) grp.attr("opacity", 1 - u);
      })
      // C: fall to earth — your position is the centre of the map
      .transition().duration(1600).ease(d3.easeCubicInOut)
      .tween("fall", () => (u: number) => {
        const s = S0 * Math.pow(sFinal() / S0, u);
        drawGlobe(s, 1 - u * 1.6, clamp01((u - 0.55) / 0.35));
      })
      .on("end", () => {
        drawGlobe(sFinal(), 0, 1, true);   // the standing frame, fine coastline
        openMap();
        stage.zooming = false;
        drawPriorityBar(0);                // collapse the bar to this leaf
      });
  });

  drawCrumb();
  showPlacesPanel(d);
}

/** Rise back out of the earth, optionally doing something once the dial is back. */
export function exitEarth(after?: () => void): void {
  if (stage.zooming || stage.mode !== "earth") return;
  stage.zooming = true;
  stage.mode = "exiting";        // chrome and ribbons read τ again while we rise
  const d = stage.leaf!, k = stage.leafK;
  const cums = stage.cums;
  const lay = leafLay(k, cums), oldLay = cums, sibs = stage.focus.children || [];

  teardownMap();          // the chips, the panels, and the surfaces riding on them
  endNav();
  clearMarkers();
  L.earth.selectAll("*").remove();
  threads.selectAll("*").remove();
  resetHeading();
  drawChrome();                  // back to τ
  drawEvents();                  // back to the hours of the day

  d3.transition("earth").duration(600)
    // C′: rise from the map back to the whole earth
    .transition().duration(1200).ease(d3.easeCubicInOut)
    .tween("rise", () => (u: number) => {
      const s = S0 * Math.pow(sFinal() / S0, 1 - u);
      drawGlobe(s, clamp01(u * 1.6 - 0.6), clamp01(1 - u * 2));
    })
    // B′: the pigment returns, with the band still fully dilated
    .transition().duration(500)
    .tween("fade", () => (u: number) => {
      paintStage(d, sibs, oldLay, lay, k, 1);
      for (const grp of pigment()) grp.attr("opacity", u);
    })
    // A′: the band contracts back into its place among the others
    .transition().duration(800).ease(d3.easeCubicInOut)
    .tween("contract", () => (u: number) => paintStage(d, sibs, oldLay, lay, k, 1 - u))
    .on("end", () => {
      stage.mode = "dial"; stage.leaf = null; stage.leafK = -1;
      stage.zooming = false;
      L.globe.selectAll("*").remove();
      settle();
      if (after) after();
    });
}

