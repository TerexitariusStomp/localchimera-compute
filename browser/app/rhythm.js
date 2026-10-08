// app/rhythm.ts — the τ-time argument, drawn: rhythm, anticipation, phase
// displacement, decay.
//
// Three readings that all say the same thing in different places on the face.
// A need's SPECTRUM is its character — how many times per turn it peaks — and
// that character is a planning rule, not a decoration: a peaked need is
// scheduled provision, a flat one is standing. A CHORD is a work event's hours
// travelling around the turn to the desire-peak they answer. A SPIRAL is what
// storing something costs you while it waits.
//
// ── THE ANTICIPATION LEAD ───────────────────────────────────────────────────
// A need that peaks k times per turn must be BEGUN a quarter of its own period
// early — τ∕4k, which is 24/4k hours on the day dial. Every peak therefore
// carries two marks: a solid dot where the need peaks and a hollow one a
// quarter-period before it, where the work has to start. The same vocabulary
// appears on the small rhythm glyph and on the dial itself, so the reading
// transfers.
//
// ── THE RHYTHM AS A CIRCLE ──────────────────────────────────────────────────
// The glyph draws the share curve around one small turn, so a k-petaled shape
// IS "k times per turn" — the same geometry as the dial, at a size you can take
// in at once. In ValueFlows terms the need is a standing Intent and this curve
// is its temporal expression.
//
// ── STORAGE IS PHASE DISPLACEMENT ───────────────────────────────────────────
// A chord IS the VF `satisfies` edge (EconomicEvent → Intent) drawn in time:
// crystallised hours made at one hour of the turn, answering a desire at
// another. Top level only — the needs have to be ON the dial for a chord to
// land somewhere meaningful.
import { S } from './state.js';
import { U, PT, R, n, ang, xy, fpt, poly } from './geom.js';
import { stage } from './stage.js';
import { evs } from './events.js';
import { spectrum, peakHours } from './bands.js';
import { L } from './layers.js';
/** Hours as the caption says them: "3 h 49 m" above the hour, "45 m" below. */
const fmtLead = (h) => h >= 1
    ? `${Math.floor(h)} h${h % 1 ? ` ${Math.round((h % 1) * 60)} m` : ""}`
    : `${Math.round(h * 60)} m`;
/** Band `k`'s share of the turn at each sample. */
const shareOf = (k) => (i) => stage.cums[i].cum[k + 1] - stage.cums[i].cum[k];
/**
 * Read band `k`'s rhythm: the glyph, the caption, and the lead marks on the
 * dial itself.
 *
 * A need only counts as PEAKED when its dominant harmonic carries at least a
 * quarter of the energy. Below that it is standing — wanted at any hour — and
 * saying "1× per turn" about a flat curve would be reading noise as structure.
 */
export function showRhythm(d, k) {
    const share = shareOf(k);
    const spec = spectrum(share);
    const kbest = spec.indexOf(d3.max(spec)) + 1;
    const peaked = spec[kbest - 1] >= 0.25;
    const lead = 24 / (4 * kbest);
    drawGlyph(d, share, kbest, peaked);
    d3.select("#rcap").html(peaked
        ? `<b style="color:${d.col}; font-style:normal">${d.name}</b> — ${kbest}× per turn · lead τ∕${4 * kbest} = ${fmtLead(lead)}`
        : `<b style="color:${d.col}; font-style:normal">${d.name}</b> — standing: wanted at any hour`);
    drawLeadMarks(share, k, lead, peaked);
}
/** The small circular glyph: the share curve drawn around one turn. */
function drawGlyph(d, share, kbest, peaked) {
    const sv = d3.select("#rglyph");
    sv.selectAll("*").remove();
    const cx = 59, cy = 57, R0 = 40;
    const pxy = (r, t) => {
        const a = ang(t);
        return [cx + r * Math.cos(a), cy - r * Math.sin(a)];
    };
    // the turn-circle, faint, with its four τ marks
    sv.append("circle").attr("cx", cx).attr("cy", cy).attr("r", R0)
        .attr("fill", "none").attr("stroke", "#2c4a6e")
        .attr("stroke-width", 0.8).attr("opacity", 0.3);
    for (let q = 0; q < 4; q++) {
        const [x1, y1] = pxy(R0 - 2.5, q * 6), [x2, y2] = pxy(R0 + 2.5, q * 6);
        sv.append("line").attr("x1", x1).attr("y1", y1).attr("x2", x2).attr("y2", y2)
            .attr("stroke", "#2c4a6e").attr("stroke-width", 0.8).attr("opacity", 0.45);
    }
    // the waveform: r(t) breathes with the need's share at hour t
    let wmax = 1e-9;
    for (let i = 0; i < n; i++)
        wmax = Math.max(wmax, share(i));
    const rAt = (i) => R0 * (0.42 + 0.50 * share(i) / wmax);
    const pts = [];
    for (let i = 0; i < n; i++)
        pts.push(pxy(rAt(i), 24 * i / n));
    sv.append("path").attr("d", poly(pts))
        .attr("fill", d.col).attr("fill-opacity", 0.16)
        .attr("stroke", d.col).attr("stroke-width", 1.6)
        .attr("stroke-linejoin", "round");
    if (!peaked)
        return;
    const lead = 24 / (4 * kbest);
    for (const p of peakHours(share)) {
        const [sx, sy] = pxy(rAt(p.i), p.t);
        sv.append("circle").attr("cx", sx).attr("cy", sy).attr("r", 2.6).attr("fill", "#000");
        const tb = (p.t - lead + 24) % 24, ib = Math.round(tb / 24 * n) % n;
        const [hx, hy] = pxy(rAt(ib), tb);
        sv.append("circle").attr("cx", hx).attr("cy", hy).attr("r", 2.6)
            .attr("fill", "#fff").attr("stroke", "#000").attr("stroke-width", 0.9);
    }
    sv.append("text").attr("x", cx).attr("y", cy + 4.5)
        .attr("text-anchor", "middle").attr("font-size", 13)
        .attr("font-weight", 600).attr("fill", d.col)
        .text(`${kbest}×`);
}
/** On the dial: a solid dot at each peak, a hollow one a quarter-period before. */
function drawLeadMarks(share, k, lead, peaked) {
    L.prev.selectAll(".lead").remove();
    if (!peaked)
        return;
    const mk = L.prev.append("g").attr("class", "lead");
    const dot = (i, fill, stroke) => {
        const mid = (stage.cums[i].cum[k] + stage.cums[i].cum[k + 1]) / 2;
        const [x, y] = fpt(mid, i);
        const c = mk.append("circle").attr("cx", x).attr("cy", y)
            .attr("r", 0.045 * U).attr("fill", fill);
        if (stroke)
            c.attr("stroke", stroke).attr("stroke-width", 0.6 * PT);
    };
    for (const p of peakHours(share)) {
        dot(p.i, "#000");
        dot(Math.round(((p.t - lead + 24) % 24) / 24 * n) % n, "#fff", "#000");
    }
}
// ── chords: storage as phase displacement ───────────────────────────────────
/** Every work event's hours, drawn to the desire-peak they answer. */
export function drawChords() {
    L.chords.selectAll("*").remove();
    if (!d3.select("#chords").property("checked") || stage.focus !== S.root)
        return;
    const kids = S.root.children || [];
    evs.filter(e => e.serves).forEach(ev => {
        if (ev._tmid == null)
            return; // not standing on this turn
        const k = kids.findIndex(d => d.name === ev.serves);
        if (k < 0)
            return;
        const d = kids[k];
        const p = peakHours(shareOf(k))[0];
        // land INSIDE the met core, not on the band's edge: the chord answers the
        // desire, and the met part is the answered part
        const midMet = (stage.cums[p.i].cum[k] + stage.cums[p.i].met[k]) / 2;
        const [tx, ty] = fpt(midMet, p.i);
        // one straight line, from the event's own place on THIS turn
        const [sx, sy] = xy(ev._r ?? R, ang(ev._tmid));
        const col = d3.color(d.col).darker(0.4) + "";
        L.chords.append("line")
            .attr("x1", sx).attr("y1", sy).attr("x2", tx).attr("y2", ty)
            .attr("stroke", col).attr("stroke-width", 1.0 * PT).attr("opacity", 0.8);
        L.chords.append("circle").attr("cx", tx).attr("cy", ty).attr("r", 0.05 * U)
            .attr("fill", col);
    });
}
// ── spirals: what keeping something costs ───────────────────────────────────
/**
 * Stored from NOW, a quantity traces r = R·ρ^(Δ∕24): a logarithmic spiral,
 * equal angles for equal fractions.
 *
 * Perfect storage would be a circle. Everything real winds inward at its own
 * rate, and the three drawn here span the range — milk falling away within the
 * turn, grain barely bending.
 */
const DECAY = [["milk", 0.20], ["bread", 0.70], ["grain", 0.97]];
const DASH = ["1.5,2.5", "4,3", null];
export function drawSpirals(now) {
    L.spiral.selectAll("*").remove();
    if (!d3.select("#spirals").property("checked"))
        return;
    DECAY.forEach(([name, rho], j) => {
        const pts = d3.range(0, 24.001, 0.2).map(dt => xy(R * Math.pow(rho, dt / 24), ang(now + dt)));
        L.spiral.append("path")
            .attr("d", "M" + pts.map(p => p.map(v => v.toFixed(1)).join(",")).join("L"))
            .attr("fill", "none").attr("stroke", "#444")
            .attr("stroke-width", 0.55 * PT)
            .attr("stroke-dasharray", DASH[j])
            .attr("opacity", 0.8);
        const [ex, ey] = pts[pts.length - 1];
        L.spiral.append("text").attr("x", ex).attr("y", ey - 4)
            .attr("text-anchor", "middle").attr("font-size", 4.2 * PT).attr("fill", "#444")
            .text(`${name} ρ=${rho}`);
    });
}
