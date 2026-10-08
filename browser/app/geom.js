// app/geom.ts — pure geometry & math primitives for the dial.
//
// No dependency on mutable dial state (no root/turnH/heading/svg): every
// export is a pure function of its arguments (plus the shared constants
// below), so this module is safe to import anywhere. `d3` is the global
// from the classic vendor/d3.v7.min.js script — only referenced at call time
// (see d3.d.ts for why it is declared by hand rather than imported).
export const U = 100, PT = U / 28.35; // dial unit; SVG points per unit
export const R = 2.6, n = 240, TAU = 2 * Math.PI; // area radius, sample count, 2π
export const ringW = 0.15, ringGap = 0.05; // context rings, outside the rim
// a band's colour washed toward white — the "unmet / pale" tint, used by the
// dial bands, the priority bar, and the contacts tags (t = how far to white).
export const paleCol = (col, t = 0.62) => d3.interpolateRgb(col, "#ffffff")(t);
// AREA-TRUE: r(f) = √(f·R²) — equal pigment, equal person-hours
export const rad = (f) => R * Math.sqrt(Math.max(0, f));
// dial angle/coordinate helpers: t in turn-hours (0..24) → angle → SVG xy
export const ang = (t) => (Math.PI / 2) - t * (TAU / 24);
export const xy = (r, a) => [U * r * Math.cos(a), -U * r * Math.sin(a)];
export const fpt = (f, i) => xy(rad(f), ang(24 * i / n));
/**
 * A closed polygon through points, as an SVG path.
 *
 * Two decimals is deliberate: the dial's unit is 100 SVG points, so a hundredth
 * of a unit is well under a device pixel, and the shorter `d` is a real saving
 * across the 720 sectors the sky ring paints.
 */
export const poly = (pts) => "M" + pts.map(p => p[0].toFixed(2) + "," + p[1].toFixed(2)).join("L") + "Z";
/**
 * A closed ring between two share curves: out along the outer, back along the
 * inner.
 *
 * Every band on the dial is one of these. Both edges are functions of the
 * sample index rather than constants, which is what lets a band's thickness
 * breathe through the turn — and what lets the zoom and the reveal push both
 * edges through the same remap and keep the ring closed at every frame.
 */
export const ringPath = (fOuter, fInner) => poly(d3.range(n + 1).map(i => fpt(fOuter(i), i))
    .concat(d3.range(n, -1, -1).map(i => fpt(fInner(i), i))));
export const lerp = (a, b, u) => a + (b - a) * u;
export const clamp01 = (x) => Math.max(0, Math.min(1, x));
/**
 * Cubic ease in and out — the dial's own curve for a hand-run tween.
 *
 * The same shape d3.easeCubicInOut has. It is written out here because the two
 * blends that use it (σ and the priority ⇄ spend morph) do NOT run on a d3
 * transition: they drive a plain number by requestAnimationFrame, so that a
 * newer flip can take the road over mid-journey.
 */
export const easeCubic = (t) => t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
/**
 * Walk a scalar to `target` over `dur` ms, calling `step` on every frame.
 *
 * The guard is the point. Both blends on the dial are TOGGLES that read as
 * roads: pressing the other one mid-journey has to turn the journey round, not
 * queue a second one behind it. So each frame asks whether it still owns the
 * road — `owns()` answers false once a newer call has set a different target —
 * and simply stops if it does not. No cancellation bookkeeping, and no way for
 * two tweens to fight over one number.
 */
export function tween(from, target, dur, owns, step) {
    const t0 = performance.now();
    const frame = (now) => {
        if (!owns())
            return;
        const t = Math.min(1, (now - t0) / dur);
        step(from + (target - from) * easeCubic(t));
        if (t < 1)
            requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
}
// great-circle distance (km) between {lat,lng} points — haversine
export const havKm = (a, b) => {
    const dla = (b.lat - a.lat) * Math.PI / 180, dlo = (b.lng - a.lng) * Math.PI / 180;
    const s = Math.sin(dla / 2) ** 2 +
        Math.cos(a.lat * Math.PI / 180) * Math.cos(b.lat * Math.PI / 180) * Math.sin(dlo / 2) ** 2;
    return 2 * 6371 * Math.asin(Math.sqrt(s));
};
// initial compass bearing (degrees, 0..360) from point a to point b
export const bearingDeg = (a, b) => {
    const f1 = a.lat * Math.PI / 180, f2 = b.lat * Math.PI / 180;
    const dl = (b.lng - a.lng) * Math.PI / 180;
    const th = Math.atan2(Math.sin(dl) * Math.cos(f2), Math.cos(f1) * Math.sin(f2) - Math.sin(f1) * Math.cos(f2) * Math.cos(dl));
    return ((th * 180 / Math.PI) + 360) % 360;
};
