// app/threads.ts — the bearing dial: pointers to what the disc cannot show.
//
// In earth mode the dial's angle stops meaning the HOUR and starts meaning the
// COMPASS BEARING from where you stand. North is the top — unless the compass is
// on, in which case your own heading is, and the dial turns with your hand like
// a real instrument.
//
// ── AN ARC IS AN ABSENCE ────────────────────────────────────────────────────
// A place's arc hugs the inside of the rim ONLY while the place is out of view.
// Pan until its marker enters the disc and the arc DISSOLVES — the thing itself
// has arrived, and a pointer to something you can see is noise. So the arcs are
// redrawn on every map move, and they and the isochrones live in one function
// because they are one answer to one question: what is around you, and how far.
//
// ── LANES ARE A SCARCE RING RESOURCE, NOT A PER-PLACE INDEX ─────────────────
// A lane number that counted places would march inward one ring per place, and
// on the unlensed map tab — every place at once, forty of them — sweep straight
// through the centre and out the mirrored side, arcs spiralling over the
// imagery. Lanes are assigned by BEARING instead: an arc takes the outermost
// ring whose sweep its own does not collide with. A crowded direction stacks a
// few rings deep; an empty one never spends a ring at all.
//
// ── THE MAP TAB HAS NO DISC ─────────────────────────────────────────────────
// All of this is circular-disc geometry, and the map face is a rectangle. It is
// SKIPPED there rather than hidden, and that is a real fix rather than tidiness:
// the computation's side effect — hiding place markers "beyond the disc" — was
// still running against a radius that is stale garbage on a rectangle, blinking
// markers in and out as pan and zoom moved their meaningless projection. A
// rectangle clips markers the honest way, at its own edges.
import { R, U, PT, TAU, xy, bearingDeg } from './geom.js';
import { USER, PLACES, ISO, pcoord } from './core.js';
import { deviceHeading } from './compass.js';
import { theMap, mapToDial, pxPerDialUnit } from './mapview.js';
import { placeElAt } from './markers.js';
import { isOpenAt, WALK_KMH, selectPlace, selectedPlace } from './places.js';
import { stage, onEarth, onMapFace } from './stage.js';
import { L, threads } from './layers.js';
/** How many rings the pointer arcs may use. */
const PLACE_LANES = 4;
/** Lane 0 is outermost, at 2.47; lane 3 innermost, at 1.96. */
const placeLaneR = (i) => R - 0.13 - i * 0.17;
/** The smallest absolute angular distance between two dial angles, radians. */
const angDist = (a, b) => {
    const d = Math.abs((a - b) % TAU);
    return Math.min(d, TAU - d);
};
/**
 * A compass bearing, as an angle on the dial. Twelve o'clock is north, and the
 * device's own heading rotates the whole frame — which is what makes the dial
 * turn under your hand rather than merely showing directions.
 */
export const angDeg = (deg) => (Math.PI / 2) - (deg - deviceHeading()) * Math.PI / 180;
/** The bearing from you to something offset from you. */
export const bearingTo = (thing) => bearingDeg(USER, { lat: USER.lat + thing.dLat, lng: USER.lng + thing.dLng });
let host;
export function initThreads(h) {
    host = h;
}
/**
 * Repaint the bearing chrome. On the map face this is the whole of the work,
 * and the answer is to do none of it.
 */
export function drawEarthArcs() {
    L.earth.selectAll("*").remove();
    if (onMapFace())
        return;
    drawThreads();
}
/** The isochrones inside the disc, and the pointer arcs around it. */
export function drawThreads() {
    threads.select(".dyn").remove();
    if (onMapFace()) {
        threads.select(".arcs").remove();
        return;
    }
    const m = theMap();
    const leaf = stage.leaf;
    if (!onEarth() || !leaf || !m)
        return;
    const discR = host.discR();
    const t = stage.hand;
    const dyn = threads.insert("g", ":first-child").attr("class", "dyn");
    const clip = dyn.append("clipPath").attr("id", "mapClip");
    clip.append("circle").attr("r", discR * U);
    const inside = dyn.append("g").attr("clip-path", "url(#mapClip)");
    // Walking isochrones, centred on YOU wherever the map has been dragged. The
    // radius is measured through the projection rather than assumed, so a ring
    // stays a true twenty minutes' walk at every zoom and latitude.
    const cpx = m.project([USER.lng, USER.lat]);
    const [cx, cy] = mapToDial(cpx);
    for (const [min, label] of ISO) {
        const km = WALK_KMH * min / 60;
        const epx = m.project([USER.lng + km / (111.32 * Math.cos(USER.lat * Math.PI / 180)), USER.lat]);
        const rpx = Math.hypot(epx.x - cpx.x, epx.y - cpx.y) / pxPerDialUnit();
        inside.append("circle").attr("cx", cx).attr("cy", cy).attr("r", rpx)
            .attr("fill", "none").attr("stroke", "#fff")
            .attr("stroke-width", 1).attr("stroke-dasharray", "5,4").attr("opacity", 0.75);
        inside.append("text").attr("x", cx).attr("y", cy - rpx - 4)
            .attr("text-anchor", "middle").attr("font-size", 10).attr("fill", "#fff")
            .attr("opacity", 0.9).style("text-shadow", "0 0 3px #000")
            .text(label);
    }
    threads.select(".arcs").remove();
    const tA = threads.append("g").attr("class", "arcs");
    const ps = PLACES[leaf.id] || [];
    const half = 13 * Math.PI / 180;
    // The pointer means "pan THIS way to reach it", so its bearing is from the
    // disc's CURRENT centre rather than from home — pan, and the arcs swing to
    // keep telling the truth.
    const ctr = m.getCenter();
    const lanes = Array.from({ length: PLACE_LANES }, () => []);
    ps.forEach((p, i) => {
        const open = isOpenAt(p, t);
        const el = placeElAt(i);
        if (el)
            el.style.opacity = open ? "1" : "0.55";
        const q = pcoord(p);
        const ppx = m.project([q.lng, q.lat]);
        const [mx, my] = mapToDial(ppx);
        const rm = Math.hypot(mx, my), rcap = (discR - 0.04) * U;
        // A marker projecting beyond the disc would cling half-clipped to the rim
        // wherever the pan left it. Hide it: the pointer arc at the TRUE bearing —
        // from you, like everything else on this dial — is the off-view indicator.
        if (el)
            el.style.display = rm <= rcap ? "" : "none";
        if (rm <= rcap)
            return; // in view: the marker suffices
        const aM = angDeg(bearingDeg({ lat: ctr.lat, lng: ctr.lng }, q));
        // The outermost ring this bearing is still free on. If every ring is taken
        // here — a genuinely crowded direction — the innermost carries it, so no
        // place ever loses its pointer.
        let lane = lanes.findIndex(taken => taken.every(a => angDist(a, aM) > 2 * half));
        if (lane < 0)
            lane = PLACE_LANES - 1;
        lanes[lane].push(aM);
        const rr = placeLaneR(lane);
        // With the circumference: aM−half to aM+half, the same sweep the events ride.
        const [x0, y0] = xy(rr, aM - half), [x1, y1] = xy(rr, aM + half);
        const arcD = `M${x0},${y0}A${rr * U},${rr * U} 0 0 0 ${x1},${y1}`;
        const grp = tA.append("g").classed("clickable", true)
            .style("pointer-events", "auto")
            .attr("opacity", open ? 1 : 0.55)
            .on("click", () => selectPlace(i));
        if (selectedPlace() === i)
            grp.append("path").attr("d", arcD)
                .attr("fill", "none").attr("stroke", "#000")
                .attr("stroke-width", 0.11 * U + 2.6 * PT).attr("stroke-linecap", "round");
        grp.append("path").attr("d", arcD) // white halo
            .attr("fill", "none").attr("stroke", "rgba(255,255,255,0.85)")
            .attr("stroke-width", 0.11 * U + 1.4 * PT).attr("stroke-linecap", "round");
        grp.append("path").attr("d", arcD)
            .attr("fill", "none").attr("stroke", leaf.col)
            .attr("stroke-width", 0.11 * U).attr("stroke-linecap", "round")
            .attr("stroke-dasharray", open ? null : "5,4");
        const [ex, ey] = xy(rr, aM);
        grp.append("circle").attr("cx", ex).attr("cy", ey).attr("r", 8)
            .attr("fill", "rgba(255,255,255,0.95)");
        grp.append("text").attr("x", ex).attr("y", ey)
            .attr("text-anchor", "middle").attr("dominant-baseline", "central")
            .attr("font-size", 10).text(p.emoji)
            .append("title").text(`${p.name} · ${p.when}${open ? "" : " (shut now)"}`);
    });
}
