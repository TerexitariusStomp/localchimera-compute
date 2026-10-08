// app/globe.ts — the planet rendered beneath the bands.
//
// It is drawn ALL ALONG, under the desire bands, and revealing the earth does
// not build it — it fades the pigment off what was already there. That is why
// the reveal reads as an uncovering rather than a transition: the thing you end
// up looking at was never absent.
//
// The projection is ORTHOGRAPHIC and rotated so that YOU are at the centre.
// Zooming in is a scale, not a re-projection, so the globe grows continuously
// into the satellite's frame and hands over at ≈ maplibre z13 with nothing
// jumping.
//
// ── TWO RESOLUTIONS, AND WHY BOTH ───────────────────────────────────────────
// 110m for the frames that MOVE and 50m for the ones that stand still. A
// coarse coastline is invisible at animation speed and a fine one costs enough
// per frame to be felt; the fine file is also allowed to fail, because a
// slightly blockier coast is a far better outcome than no earth at all.
import { R, U, PT, TAU } from './geom.js';
import { USER, PLACES, MODES, cDeep, cYea, pcoord } from './core.js';
import { stage } from './stage.js';
/**
 * d3-geo winds polygons on the sphere, where a ring enclosing MORE than half
 * the earth is "inside out". Rewind those, or the ocean wears the land.
 */
const rewind = (geo) => {
    const fix = (poly) => poly.forEach(ring => {
        if (d3.geoArea({ type: "Polygon", coordinates: [ring] }) > TAU)
            ring.reverse();
    });
    for (const f of geo.features) {
        const g = f.geometry;
        if (g.type === "Polygon")
            fix(g.coordinates);
        else if (g.type === "MultiPolygon")
            g.coordinates.forEach(fix);
    }
    return geo;
};
/** Coarse land, for the frames that move. */
let land = null;
/** Fine land, for the frames that stand still. Allowed to be absent. */
let landFine = null;
/**
 * Both coastlines, loaded once. Resolves when they have settled either way —
 * the caller waits on it to draw, and a failed fetch must not leave it waiting
 * forever, so every arm swallows its own error.
 */
export const landReady = Promise.all([
    fetch("data/geo/land-110m.json").then(r => r.json())
        .then(t => { land = rewind(topojson.feature(t, t.objects.land)); }),
    fetch("data/geo/land-50m.json").then(r => r.json())
        .then(t => { landFine = rewind(topojson.feature(t, t.objects.land)); })
        .catch(() => { }),
]).catch(() => { });
/** The scale at which the whole earth fills the dial. */
export const S0 = R * U;
/**
 * The scale to hand over to the satellite at — ≈ maplibre z13 at YOUR latitude,
 * which is why it is a function: the Mercator scale a zoom level means depends
 * on where you are standing.
 */
export const sFinal = () => (256 * Math.pow(2, 13)) / TAU * Math.cos(USER.lat * Math.PI / 180);
/** The <g> the globe is drawn into, and the clip that keeps it in the disc. */
export function mountGlobe(g, defs) {
    layer = g;
    defs.html(`
  <clipPath id="dialClip"><circle r="${R * U}"/></clipPath>
  <radialGradient id="oceanGrad" cx="38%" cy="34%" r="80%">
    <stop offset="0%" stop-color="#cfe2ee"/>
    <stop offset="78%" stop-color="#9dbdd4"/>
    <stop offset="100%" stop-color="#7fa3bd"/>
  </radialGradient>`);
    g.attr("clip-path", "url(#dialClip)");
}
let layer;
/**
 * Draw the globe at a scale.
 *
 * `gratAlpha` fades the graticule and `placesAlpha` the lens's places, both
 * separately from the land — because the reveal brings them in at different
 * moments, and a single opacity would make the whole thing arrive at once.
 */
export function drawGlobe(scale, gratAlpha, placesAlpha, fine) {
    layer.selectAll("*").remove();
    const shape = (fine && landFine) || land;
    if (!shape)
        return;
    const proj = d3.geoOrthographic().translate([0, 0]).scale(scale)
        .rotate([-USER.lng, -USER.lat]).precision(fine ? 0.5 : 1.5);
    const path = d3.geoPath(proj);
    layer.append("path").attr("d", path({ type: "Sphere" }))
        .attr("fill", "url(#oceanGrad)");
    if (gratAlpha > 0.01)
        layer.append("path").attr("d", path(d3.geoGraticule10()))
            .attr("fill", "none").attr("stroke", "#fff")
            .attr("stroke-width", 0.5).attr("opacity", 0.45 * gratAlpha);
    layer.append("path").attr("d", path(shape))
        .attr("fill", "#a8bf9b").attr("stroke", "#86a07a").attr("stroke-width", 0.6);
    layer.append("circle").attr("r", R * U) // the limb
        .attr("fill", "none").attr("stroke", cDeep).attr("stroke-width", 0.7 * PT);
    const leaf = stage.leaf;
    if (placesAlpha > 0.01 && leaf) {
        const pg = layer.append("g").attr("opacity", placesAlpha);
        for (const p of PLACES[leaf.id] || []) {
            const q = pcoord(p), pt = proj([q.lng, q.lat]);
            // Beyond 1.4 radians the point is round the back of the sphere, where an
            // orthographic projection still answers — with the wrong side's mirror.
            if (!pt || d3.geoDistance([q.lng, q.lat], [USER.lng, USER.lat]) > 1.4)
                continue;
            // A ring in the RAIL's colour — credit, commons, yours, work-intent — so
            // the three rails read straight off the map. Work-intents wear a thicker
            // ring: a slot to fill rather than a place to go.
            const pm = MODES[p.mode] || MODES.own;
            pg.append("circle").attr("cx", pt[0]).attr("cy", pt[1]).attr("r", 11)
                .attr("fill", "rgba(255,255,255,0.92)")
                .attr("stroke", pm.col).attr("stroke-width", p.mode === "work" ? 2.2 : 1.4);
            pg.append("text").attr("x", pt[0]).attr("y", pt[1])
                .attr("text-anchor", "middle").attr("dominant-baseline", "central")
                .attr("font-size", 12).text(p.emoji);
        }
        pg.append("circle").attr("r", 6).attr("fill", cYea)
            .attr("stroke", "#fff").attr("stroke-width", 2); // you, at the centre
    }
}
