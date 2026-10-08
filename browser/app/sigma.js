// app/sigma.ts — individual ⇄ social: what dissolves, and what condenses.
//
// σ is the dial's one blend between YOUR day and EVERYONE'S. It is a toggle to
// press but a road to travel: flipping it tweens σ across [0,1] with a cubic
// ease, so the dial morphs rather than snapping, at the same per-frame cost the
// old slider had.
//
// ── THE PERSONAL IS LOCAL ───────────────────────────────────────────────────
// Your events, proposals and chords belong to the "you" end. As σ leaves zero
// they dissolve, and are gone by σ = ⅓ — not hidden, dissolved, because at any
// social scale they are not what is being shown.
//
// ── AND IT RE-CONDENSES ─────────────────────────────────────────────────────
// In the very lane the events occupied, as a ring: at every hour of the turn,
// the blend of work-time and free time ACROSS EVERYONE. Your sharp arcs melt
// into a gradient — the phase spread of everyone's similar days widens with σ —
// and by σ = 1 it is a nearly even band with a mild diurnal breath, because some
// longitude is always working and some always at play.
//
// The wash and the ring are two readings of one field: sectors of EVERYONE
// rather than of events.
import { S } from './state.js';
import { U, xy, ang, clamp01, tween } from './geom.js';
import { cWarm, cYea } from './core.js';
import { evs, pending, turnAnchor } from './events.js';
import { onEarth } from './stage.js';
import { seam } from './seam.js';
import * as containers from './tabs/map/containers.js';
import { L, outerEdge } from './layers.js';
let host;
/**
 * Fade the personal out as σ leaves "you", and the social ring in.
 *
 * Pointer-events go with the opacity: a dissolved artifact must not still be
 * clickable, or the dial keeps answering for something nobody can see.
 */
export function applyPresence() {
    const a = clamp01(1 - 3 * S.sigma);
    for (const grp of host.personal())
        grp.attr("opacity", a).attr("pointer-events", a > 0 ? null : "none");
    d3.select("#calprops").style("opacity", a)
        .style("pointer-events", a > 0 ? null : "none");
    drawToilRing();
}
/** Pastel: ease the chroma back, lift the lightness. */
const soften = (c) => {
    const h = d3.hcl(c);
    h.c *= 0.8;
    h.l = Math.min(92, h.l + 8);
    return h + "";
};
/** The social ring: the blend of work and free across everyone, hour by hour. */
export function drawToilRing() {
    const gToil = L.toil;
    gToil.selectAll("*").remove();
    const op = clamp01(3 * S.sigma); // fades in exactly as the events fade out
    if (op <= 0.02 || onEarth())
        return;
    const blur = 0.3 + 6 * S.sigma; // hours: everyone's phase spread
    /** How WORKED the social hour is, 0..1. */
    const share = (h) => {
        let w = 0, f = 0.25; // uncommitted time leans free
        for (const ev of evs.concat(pending())) {
            const mid = (ev.t0 + ev.t1) / 2, half = (ev.t1 - ev.t0) / 2;
            let d = Math.abs((((h - mid) % 24) + 36) % 24 - 12);
            d = Math.max(0, d - half); // inside the event: full weight
            const g = Math.exp(-(d / blur) * (d / blur));
            if (ev.kind === "work")
                w += g;
            else
                f += g;
        }
        return w / (w + f);
    };
    const r0 = outerEdge() + 0.66, r1 = r0 + 0.77; // the events' own lanes
    const rm = (r0 + r1) / 2, sw = (r1 - r0) * U;
    const mix = d3.interpolateHcl(soften(cYea), soften(cWarm)); // gold↔cyan, via green
    // CONTINUOUS: each segment wears the AVERAGE share over the hours it spans —
    // integration, not point-sampling. At the day scale a segment is a point; at
    // the year a segment covers many whole days and gets exactly the day-mean, so
    // the daily tiling can never moiré into stripes.
    const B = 96, prof = d3.range(B).map(i => share(24 * i / B));
    const meanAll = d3.mean(prof); // B is 96, so the mean exists
    const segShare = (h0, h1) => {
        if (h1 - h0 >= 24)
            return meanAll;
        const b0 = Math.floor((((h0 % 24) + 24) % 24) / 24 * B);
        const nb = Math.max(1, Math.round((h1 - h0) / 24 * B));
        let s = 0;
        for (let j = 0; j < nb; j++)
            s += prof[(b0 + j) % B];
        return s / nb;
    };
    // Opacity lives on the GROUPS, not the segments: overlapping same-colour
    // segments composite opaquely first and then fade as one, so there are no
    // seam stripes at partial σ.
    const gw = gToil.append("g").attr("opacity", op * 0.05); // the wash
    const gr = gToil.append("g").attr("opacity", op * 0.65); // the ring
    const K = 144;
    for (let i = 0; i < K; i++) {
        const t0 = 24 * i / K, t1 = 24 * (i + 1.15) / K; // overlap: no seams
        const h0 = turnAnchor() + t0 / 24 * S.turnH;
        const h1 = turnAnchor() + t1 / 24 * S.turnH;
        const [x0, y0] = xy(rm, ang(t0)), [x1, y1] = xy(rm, ang(t1));
        // Stretch around the midpoint: shares hover mid-range, so the poles need
        // room. HCL walks gold→green→teal, the way pigments actually mix.
        const col = mix(clamp01(0.5 + (segShare(h0, h1) - 0.5) * 1.8));
        gr.append("path")
            .attr("d", `M${x0},${y0}A${rm * U},${rm * U} 0 0 1 ${x1},${y1}`)
            .attr("fill", "none").attr("stroke", col).attr("stroke-width", sw);
        const [wx0, wy0] = xy(r0, ang(t0)), [wx1, wy1] = xy(r0, ang(t1));
        gw.append("path")
            .attr("d", `M0,0L${wx0},${wy0}A${r0 * U},${r0 * U} 0 0 1 ${wx1},${wy1}Z`)
            .attr("fill", col);
    }
}
/** Where σ is heading. A newer flip owns the road and the older frame stops. */
let sigmaTarget = 0; // individual: the time face opens on your own day
/** Flip between your day and everyone's, travelling the whole road. */
export function tweenSigma(target) {
    sigmaTarget = target;
    d3.select("#sigl").classed("on", target === 0);
    d3.select("#sigg").classed("on", target === 1);
    // The toggle also swings the FOLKSONOMY LENS: social reads the commons' own
    // aggregate cut, individual reads yours. Offline this no-ops; online the cut
    // is re-fetched and the spine re-derives from it.
    if (seam.handlers && seam.handlers.taxonomyLens)
        seam.handlers.taxonomyLens(target === 1 ? "social" : "individual");
    if (S.sigma === target)
        return;
    tween(S.sigma, target, 900, () => sigmaTarget === target, v => {
        S.sigma = v;
        applyPresence();
        containers.setEmphasis(S.sigma); // desire regions surface toward everyone's
        host.relayout();
    });
}
/** Wire the two σ buttons. */
export function initSigma(h) {
    host = h;
    d3.select("#sigl").on("click", () => tweenSigma(0));
    d3.select("#sigg").on("click", () => tweenSigma(1));
}
