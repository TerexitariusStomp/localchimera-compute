// app/sky.ts — the sun, from where you stand.
//
// The rim wears the day's own light. The sun's altitude at each hour maps to a
// sky colour — night navy, day cyan, a warm gold band where it crosses the
// horizon — so the clock face is lit the way the day outside is, at YOUR
// latitude and on THIS day of the year, not by a stock gradient.
//
// Weather, where it is known, greys the daylight arc by cloud and ticks it with
// rain. Known means the seam pushed hourly readings; `?weather` stands in a
// demo front for looking at it, and with neither the sky is simply clear rather
// than pretending to a forecast.
//
// The astronomy is exact and small, which is why it is worth having rather than
// approximating: declination from the day of the year, then the hour angle
// (cos H₀ = −tan φ · tan δ) for rise and set, and the standard altitude formula
// for everything between. The rise azimuth is cos az = sin δ ∕ cos φ, and the
// set is its mirror across the meridian.
import { USER } from './core.js';
import { R, U, PT, TAU, ang, xy, poly, havKm } from './geom.js';
import { seam } from './seam.js';
/**
 * The sun's declination for a day of the year, in radians — how far north or
 * south of the equator it stands. Everything else here is derived from it, so
 * it is written once.
 */
export const solarDec = (dd) => 23.44 * Math.PI / 180 * Math.sin(TAU * (284 + dd + 1) / 365);
/**
 * The sun's altitude above the horizon at hour `t` of day `dd`, in degrees.
 * Negative is below: the sky scale reads down to −25°, which is well into
 * astronomical night.
 */
export function sunAltDeg(t, dd) {
    const lat = USER.lat * Math.PI / 180, dec = solarDec(dd), H = (t - 12) * (TAU / 24);
    return Math.asin(Math.sin(lat) * Math.sin(dec)
        + Math.cos(lat) * Math.cos(dec) * Math.cos(H)) * 180 / Math.PI;
}
export function sunFor(dd) {
    const lat = USER.lat * Math.PI / 180;
    const dec = solarDec(dd);
    const c = -Math.tan(lat) * Math.tan(dec);
    if (c <= -1 || c >= 1)
        return {}; // polar day / polar night
    const half = Math.acos(c) / (TAU / 24); // hours from solar noon
    const azR = Math.acos(Math.sin(dec) / Math.cos(lat)) * 180 / Math.PI;
    return { rise: 12 - half, set: 12 + half, azRise: azR, azSet: 360 - azR };
}
// ── the sky's colours ───────────────────────────────────────────────────────
// Keyed on ALTITUDE rather than on the hour, which is why one scale serves every
// latitude and season: −25° is astronomical night wherever you are, and the gold
// sits at the horizon crossing rather than at a nominal "6 pm".
const skyScale = d3.scaleLinear()
    .domain([-25, -12, -6, -1, 3, 9, 25, 60])
    .range(["#0d1230", "#1a1f4d", "#3a2f63", "#c4683a", "#f4ab4e", "#cfe9f2", "#7cc6e2", "#57a8d8"])
    .interpolate(d3.interpolateLab).clamp(true);
const weatherDemo = new URLSearchParams(location.search).has("weather");
/**
 * The weather at an hour: the seam's hourly readings when it has pushed any,
 * a demo afternoon front under `?weather`, and otherwise clear — not a guess.
 */
export function weatherAt(h) {
    const W = seam.data && seam.data.weather; // [{h,cloud,precip}…] hourly
    if (Array.isArray(W) && W.length) {
        const w = (W[Math.round(h) % W.length] || {});
        return { cloud: Math.max(0, Math.min(1, +(w.cloud ?? 0) || 0)),
            precip: Math.max(0, Math.min(1, +(w.precip ?? 0) || 0)) };
    }
    if (!weatherDemo)
        return { cloud: 0, precip: 0 };
    const g = (x, c, s) => Math.exp(-((x - c) ** 2) / (2 * s * s));
    return { cloud: Math.min(1, 0.12 + 0.66 * g(h / 24, 0.70, 0.13)),
        precip: Math.min(1, 0.9 * g(h / 24, 0.71, 0.045)) };
}
/** Paint the day's light around the rim, into the chrome layer. */
export function drawSkyRing(g, dd) {
    const rIn = R - 0.030, rOut = R + 0.046, m = 720, grey = "#aab2b8";
    // Many fine, slightly-overlapping sectors with NO stroke — that is what makes
    // a seamless gradient out of flat fills. The 1.4 overlap kills the seams.
    for (let i = 0; i < m; i++) {
        const hm = 24 * (i + 0.5) / m, w = weatherAt(hm);
        let col = skyScale(sunAltDeg(hm, dd));
        if (w.cloud > 0.01)
            col = d3.interpolateLab(col, grey)(w.cloud * 0.55);
        const a0 = ang(24 * i / m), a1 = ang(24 * (i + 1.4) / m);
        g.append("path")
            .attr("d", poly([xy(rOut, a0), xy(rOut, a1), xy(rIn, a1), xy(rIn, a0)]))
            .attr("fill", col);
    }
    // rain: short blue ticks just outside the daylight arc, sampled coarser
    for (let i = 0; i < 64; i++) {
        const hm = 24 * (i + 0.5) / 64, w = weatherAt(hm);
        if (w.precip <= 0.35)
            continue;
        const a = ang(hm);
        const [x0, y0] = xy(rOut + 0.014, a);
        const [x1, y1] = xy(rOut + 0.014 + 0.06 * w.precip, a);
        g.append("line").attr("x1", x0).attr("y1", y0).attr("x2", x1).attr("y2", y1)
            .attr("stroke", "#3f7fc0").attr("stroke-width", 1.0 * PT)
            .attr("stroke-linecap", "round").attr("opacity", 0.7);
    }
    g.append("circle").attr("r", rOut * U).attr("fill", "none")
        .attr("stroke", "#ffffff").attr("stroke-width", 0.5 * PT).attr("opacity", 0.4);
    g.append("circle").attr("r", rIn * U).attr("fill", "none")
        .attr("stroke", "rgba(0,0,0,0.16)").attr("stroke-width", 0.4 * PT);
}
const NEAR_KM = 30; // the seam's series speaks for your own place, roughly
/**
 * The sky at hour H of day-of-year DD, at a place LOC (or where you stand).
 * `viewed` says whether DD is the day the seam's weather series describes.
 */
export function skyAt(h, dd, viewed, loc) {
    const alt = sunAltDeg(h, dd);
    const sun = sunFor(dd);
    const near = !loc || havKm(USER, loc) <= NEAR_KM;
    const w = viewed && near ? weatherAt(h) : undefined;
    const golden = alt > -6 && alt < 6;
    const rain = w && w.precip >= 0.2, over = w && w.cloud >= 0.7, some = w && w.cloud >= 0.3;
    const glyph = rain ? "🌧" : alt <= -6 ? "🌙" : golden ? "🌅" : over ? "☁" : some ? "🌤" : "☀";
    const sunLine = sun.rise != null
        ? `sun ${fmtHM(sun.rise)}–${fmtHM(sun.set)}` : alt > 0 ? "polar day" : "polar night";
    const line = w
        ? `${sunLine} · cloud ${Math.round(w.cloud * 100)}% · rain ${Math.round(w.precip * 100)}%`
        : `${sunLine} · no weather known here`;
    return { glyph, line, weather: w };
}
const fmtHM = (t) => {
    const m = Math.round(t * 60), hh = Math.floor(m / 60) % 24, mm = m % 60;
    return `${String(hh).padStart(2, "0")}:${String(mm).padStart(2, "0")}`;
};
