// app/wheel.ts — the wheel itself: the bands, and every way of moving through
// them.
//
// One sibling set, drawn as rings whose thickness at each angle is that need's
// share of the turn at that hour. The met part is solid and the unmet part
// pale, with a graded edge between them, so a glance reads two things at once:
// what is wanted when, and how much of it is answered.
//
// ── ONE REMAP CARRIES EVERY TRANSITION ──────────────────────────────────────
// Zooming in, zooming out and the earth's reveal are the same arithmetic: the
// chosen band's interior dilates toward the whole dial while its siblings
// squash onto the centre and the rim, and which of the three you are watching
// is only a matter of which way `u` is going. The arithmetic itself is
// `dilate` in app/bands.ts — beside the layouts it remaps — and the in-flight
// drawers below are the ones app/earth.ts calls, rather than a second pair.
//
// ── WHAT A CHILDLESS BAND DOES IS NOT THE WHEEL'S TO KNOW ───────────────────
// A band with children zooms; a band without one has no finer subdivision in
// time, and its answer is a WHERE — but "the reveal" is the dial's arrangement
// talking, not the wheel's drawing. So the wheel asks its host, and app/earth
// imports these drawers straight. The alternative was the reverse, and it read
// as acyclic while being circular in fact: earth held wheel's three drawers as
// host members that main answered by handing back wheel's own functions.
//
// ── MID-FLIGHT DRAWS SHARP, SETTLED DRAWS SOFT ──────────────────────────────
// A settled band grades its met edge over nine steps and carries a label; a
// band in flight gets a single sharp edge and no text. Not a shortcut — nine
// gradient rings per band per frame is the kind of cost that turns an
// animation into a stutter, and the gradient is unreadable while it moves.
//
// ── PRIORITY ⇄ SPEND: THE SAME WHEEL, RE-DENOMINATED ────────────────────────
// The priority wheel is unit-sum at every angle: the TIME budget, in which
// every hour holds exactly one hour. The SPEND wheel shows only where CREDIT
// flows — each band's mass is the share of drawable credit its subtree's
// claimable goods carry, shaped through time by the band's own phase curve.
// Radius becomes credit-flow density, a real unit, and non-purchasable bands
// (rest, movement) honestly collapse to hairlines rather than being hidden.
// Natural units stay a per-good conversion, never an axis.
//
// spendU tweens 0→1 exactly as σ does, so the wheel MORPHS between the two
// readings rather than switching: they are one wheel in two denominations, and
// watching one become the other is the argument.
import { S } from './state.js';
import { U, PT, n, fpt, poly, paleCol, ringPath, lerp, tween } from './geom.js';
import { cDeep, inkFor, haloed } from './core.js';
import { creditNow } from './credit.js';
import { stage } from './stage.js';
import { layout, spendLayout, blendLay, dilate, nestInto } from './bands.js';
import { drawChrome, updateChromeTargets } from './chrome.js';
import { drawHand, handNow } from './hand.js';
import { drawEvents } from './ribbons.js';
import { drawCrumb } from './crumb.js';
import { applyPresence } from './sigma.js';
import { grabbedTerm, spineEditClick } from './spine.js';
import { showRhythm, drawChords } from './rhythm.js';
import { L } from './layers.js';
let host;
/** Half-width of the graded met edge, in shares. */
const wq = 0.045;
// ── the settled wheel ───────────────────────────────────────────────────────
/**
 * Draw one sibling set through a share-remap.
 *
 * `steps` is the number of gradient rings across the met edge: 9 when settled,
 * 0 in flight (a single sharp edge instead). `interactive` wires the hover
 * preview and the click that descends — off during a transition, so a band
 * cannot be clicked out from under the animation that is moving it.
 */
export function drawBands(nodes, lay, remap, steps, interactive) {
    L.bands.selectAll("*").remove();
    L.seams.selectAll("*").remove();
    const grabbed = grabbedTerm();
    nodes.forEach((d, k) => {
        const pale = paleCol(d.col);
        const lo = (i) => Math.max(lay[i].cum[k], lay[i].met[k] - wq);
        const hi = (i) => Math.min(lay[i].cum[k + 1], lay[i].met[k] + wq);
        const band = L.bands.append("g");
        band.append("path")
            .attr("d", ringPath(i => remap(lo(i), i), i => remap(lay[i].cum[k], i)))
            .attr("fill", d.col);
        for (let j = 0; j < steps; j++) {
            const m = (j + 0.5) / steps;
            band.append("path")
                .attr("d", ringPath(i => remap(lo(i) + (hi(i) - lo(i)) * (j + 1) / steps, i), i => remap(lo(i) + (hi(i) - lo(i)) * j / steps, i)))
                .attr("fill", d3.interpolateRgb(d.col, pale)(m));
        }
        if (steps === 0) // a sharp edge mid-flight
            band.append("path")
                .attr("d", ringPath(i => remap(hi(i), i), i => remap(lo(i), i)))
                .attr("fill", d3.interpolateRgb(d.col, pale)(0.5));
        band.append("path")
            .attr("d", ringPath(i => remap(lay[i].cum[k + 1], i), i => remap(hi(i), i)))
            .attr("fill", pale);
        if (grabbed && d.id === grabbed)
            band.style("opacity", 0.55); // lifted, awaiting a drop
        if (!interactive)
            return;
        band.classed("clickable", true)
            .on("click", (ev) => ev.altKey ? spineEditClick(d)
            : (d.children ? zoomIn(d, k) : host.onLeaf(d, k)));
        if (d.children)
            band.on("mouseenter", () => { previewChildren(d, k); showRhythm(d, k); })
                .on("mouseleave", () => { L.prev.selectAll("*").remove(); });
        else
            band.on("mouseenter", () => showRhythm(d, k));
    });
    drawSeams(nodes, lay, remap);
}
/** The white hairlines between adjacent bands. */
function drawSeams(nodes, lay, remap) {
    for (let k = 1; k < nodes.length; k++)
        L.seams.append("path")
            .attr("d", poly(d3.range(n + 1).map(i => fpt(remap(lay[i].cum[k], i), i))))
            .attr("fill", "none").attr("stroke", "#fff").attr("stroke-width", 0.9 * PT);
}
/**
 * A label at each band's peak DRAWN thickness — the share through the remap,
 * not the raw share.
 *
 * Which matters in spend mode: a band that is 20% of a near-zero radius is
 * still a hairline, and a hairline gets no label rather than an overlapping
 * one. The folksonomy count rides along where there is one ("12 nest Grain
 * under Food") — the consensus behind the cut being offered.
 */
export function drawLabels(nodes, lay, remap = f => f) {
    L.bands.selectAll("text").remove();
    nodes.forEach((d, k) => {
        let best = 0, bestW = -1;
        for (let i = 0; i <= n; i += 2) {
            const w = remap(lay[i].cum[k + 1], i) - remap(lay[i].cum[k], i);
            if (w > bestW) {
                bestW = w;
                best = i;
            }
        }
        if (bestW < 0.012)
            return; // a hairline: no label
        const c = lay[best];
        const mid = (c.cum[k] + c.cum[k + 1]) / 2;
        const isMet = mid < c.met[k];
        const ink = isMet ? inkFor(d.col) : d3.color(d.col).darker(1.3).formatHex();
        const fs = 6.5 * PT;
        const [x, y] = fpt(remap(mid, best), best);
        haloed(L.bands.append("text").attr("x", x).attr("y", y)
            .attr("text-anchor", "middle").attr("dominant-baseline", "central")
            .attr("font-size", fs).attr("font-weight", 600)
            .attr("pointer-events", "none")
            .text(d.count > 0 ? `${d.name} ·${d.count}` : d.name), ink, fs);
    });
}
/**
 * The centre disc: the way back UP, one level toward the root.
 *
 * Absent at the root, because there is nowhere above it. The bar stack still
 * does lateral jumps, and tapping where you already are on the bar goes all the
 * way out; this is the single step. A small caret marks it tappable.
 */
export function drawCentre() {
    L.centre.selectAll("*").remove();
    if (stage.focus === S.root)
        return;
    const disc = L.centre.append("g")
        .style("cursor", "pointer")
        .on("click", () => { if (!stage.zooming && stage.mode === "dial")
        zoomOut(); });
    const rDisc = 0.40;
    const fs = Math.min(5.6, (1.6 * rDisc * U) / (0.58 * stage.focus.name.length * PT));
    disc.append("circle").attr("r", rDisc * U)
        .attr("fill", "#fff").attr("stroke", cDeep).attr("stroke-width", 0.7 * PT);
    disc.append("text").attr("y", -rDisc * U * 0.52)
        .attr("text-anchor", "middle").attr("dominant-baseline", "central")
        .attr("font-size", 3.2 * PT).attr("fill", cDeep).attr("opacity", 0.65)
        .text("⌃");
    disc.append("text").attr("y", rDisc * U * 0.06)
        .attr("text-anchor", "middle").attr("dominant-baseline", "central")
        .attr("font-size", fs * PT).attr("font-weight", "bold").attr("fill", cDeep)
        .text(stage.focus.name);
}
// ── hover: the nesting, in situ ─────────────────────────────────────────────
/**
 * The children's subdivision drawn INSIDE the hovered band — the very seams
 * that will expand to fill the dial if you click it.
 */
export function previewChildren(d, k) {
    L.prev.selectAll("*").remove();
    const kids = d.children || [];
    const sub = layout(kids);
    for (let j = 1; j < kids.length; j++)
        L.prev.append("path")
            .attr("d", poly(d3.range(n + 1).map(i => {
            const lo = stage.cums[i].cum[k], hi = stage.cums[i].cum[k + 1];
            return fpt(lo + sub[i].cum[j] * (hi - lo), i);
        })))
            .attr("fill", "none").attr("stroke", "#fff")
            .attr("stroke-width", 0.55 * PT).attr("stroke-dasharray", "3,3")
            .attr("opacity", 0.85);
    L.prev.append("path")
        .attr("d", ringPath(i => stage.cums[i].cum[k + 1], i => stage.cums[i].cum[k]))
        .attr("fill", "none").attr("stroke", "#fff").attr("stroke-width", 1.4 * PT);
}
// ── zooming ─────────────────────────────────────────────────────────────────
/** Siblings during flight: two flat rings each, and band `skip` left out. */
export function drawBandsRaw(nodes, lay, remap, skip) {
    nodes.forEach((d, k) => {
        if (k === skip)
            return;
        L.bands.append("path")
            .attr("d", ringPath(i => remap(lay[i].met[k], i), i => remap(lay[i].cum[k], i)))
            .attr("fill", d.col);
        L.bands.append("path")
            .attr("d", ringPath(i => remap(lay[i].cum[k + 1], i), i => remap(lay[i].met[k], i)))
            .attr("fill", paleCol(d.col));
    });
}
/** Children during flight: a sharp met edge, seams, and no labels. */
export function drawBands2(nodes, lay, remap) {
    drawBandsRaw(nodes, lay, remap, -1);
    drawSeams(nodes, lay, remap);
}
/**
 * Run one zoom, in whichever direction.
 *
 * The FOCUS and the layout are set to the destination before the animation
 * begins — the world is already there, and only the drawing is in flight. That
 * is the same discipline the rescale keeps, and for the same reason: anything
 * that reads the dial mid-animation should read where it is going, not a
 * halfway state that never existed.
 */
function runZoom(outerNodes, outerLay, innerNodes, nestedLay, k, forward) {
    d3.transition().duration(900).ease(d3.easeCubicInOut)
        .tween("zoom", () => (t) => {
        const g = dilate(outerLay, k, forward ? t : 1 - t);
        L.bands.selectAll("*").remove();
        L.seams.selectAll("*").remove();
        drawBandsRaw(outerNodes, outerLay, g, k); // siblings, squashing
        drawBands2(innerNodes, nestedLay, g); // children, dilating
    })
        .on("end", () => { stage.zooming = false; settle(); });
    updateChromeTargets();
}
/** Descend into band `k`: its interior becomes the whole dial. */
export function zoomIn(d, k) {
    if (stage.zooming || !d.children)
        return;
    stage.zooming = true;
    L.prev.selectAll("*").remove();
    L.chords.selectAll("*").remove();
    const oldNodes = stage.focus.children || [], oldLay = stage.cums;
    const sub = layout(d.children);
    const nested = nestInto(sub, oldLay, k);
    stage.focus = d;
    stage.cums = sub;
    runZoom(oldNodes, oldLay, d.children, nested, k, true);
}
/** Rise one level: the dial contracts back into the band it came from. */
export function zoomOut() {
    if (stage.zooming || stage.focus === S.root)
        return;
    stage.zooming = true;
    L.prev.selectAll("*").remove();
    L.chords.selectAll("*").remove();
    const child = stage.focus, parent = child.parent;
    const parentLay = layout(parent.children || []);
    const k = (parent.children || []).indexOf(child);
    const nested = nestInto(stage.cums, parentLay, k);
    stage.focus = parent;
    stage.cums = parentLay;
    runZoom(parent.children || [], parentLay, child.children || [], nested, k, false);
}
// ── priority ⇄ spend ────────────────────────────────────────────────────────
/** How far along the morph from the time budget to the credit flow, 0..1. */
let spendU = 0;
/** Where it is heading. A newer flip owns the morph and the older frame stops. */
let spendTarget = 0;
/** The layout drawn this frame: the priority wheel, or a blend toward spend. */
function drawnLay() {
    return spendU > 0
        ? blendLay(stage.cums, spendLayout(stage.focus.children || []), spendU)
        : stage.cums;
}
/**
 * The radial envelope that carries flow.
 *
 * The priority wheel fills the disc at every angle because shares sum to one.
 * The spend wheel must not: how MUCH is claimable at an hour is the reading, so
 * the whole disc breathes with the desire mass rather than staying full.
 */
function envRemap(lay) {
    if (spendU <= 0 || lay === stage.cums)
        return f => f;
    const totMax = d3.max(lay, c => c.tot) || 1;
    return (f, i) => f * lerp(1, Math.max(0.10, (lay[i].tot || 0) / totMax), spendU);
}
/**
 * The live flow readout beside the toggle: drawable credit × the flow density
 * at the hand's hour — embodied-hours per clock-hour, the spend wheel's actual
 * unit. Blank in priority mode, and when nothing is claimable.
 */
function updateSpendFlow(lay) {
    const el = document.getElementById("spendflow");
    if (!el)
        return;
    if (spendU < 0.5 || lay === stage.cums) {
        el.textContent = "";
        return;
    }
    // the drawable credit: the snapshot's when it carries one, the demo's standalone (credit.ts)
    const K = Number(creditNow().drawable);
    const t = ((handNow() % 24) + 24) % 24;
    const i = Math.min(n, Math.round(t / 24 * n));
    const meanTot = d3.mean(lay, c => c.tot) || 1;
    el.textContent = ` · ≈${(K * (lay[i].tot / (meanTot * 24))).toFixed(2)} h∕h now`;
}
/** Morph between the two denominations of the wheel. */
export function tweenSpend(target) {
    spendTarget = target;
    d3.select("#spendpri").classed("on", target === 0);
    d3.select("#spendqty").classed("on", target === 1);
    if (spendU === target)
        return;
    tween(spendU, target, 900, () => spendTarget === target, v => {
        spendU = v;
        if (!stage.zooming)
            settle();
    });
}
// ── settling ────────────────────────────────────────────────────────────────
/**
 * The settled view: soft edges, labels, chrome, the hand, and everything that
 * stands on the wheel.
 *
 * This is the dial's one repaint. Anything that changes what the wheel says
 * calls it and does not name the pieces — which is why a new surface on the
 * dial is added here once rather than at every site that could have moved it.
 */
export function settle() {
    for (const grp of [L.bands, L.seams, L.hand, L.centre, L.spiral])
        grp.attr("opacity", 1);
    L.rings.interrupt().attr("opacity", 1).attr("pointer-events", null);
    const lay = drawnLay(), env = envRemap(lay);
    const kids = stage.focus.children || [];
    drawBands(kids, lay, env, 9, true);
    drawLabels(kids, lay, env);
    updateSpendFlow(lay);
    drawChrome();
    drawCentre();
    drawHand(handNow()); // now, or the scrubbed phase, of the CURRENT turn
    drawEvents();
    drawChords();
    drawCrumb();
    applyPresence();
}
/** Wire the priority ⇄ spend toggle, and what a leaf band answers with. */
export function initWheel(h) {
    host = h;
    d3.select("#spendpri").on("click", () => tweenSpend(0));
    d3.select("#spendqty").on("click", () => tweenSpend(1));
}
