// app/tabs/pool.ts — the socialized pool, DRAWN.
//
// Markers only: this module renders the slot pool onto the map and nothing
// else. The DATA — the slots-at wire, the demo twin, the coordinate ladder,
// the day clip — lives in app/tabs/atlas.js (THE map-data layer); the panel
// the taps land in is app/tabs/mapsearch.js. A means in the commons is a
// warm-ringed emoji marker with its occupancy; a placed need is a dashed
// ring, closing solid green when the plan matched it.
import { slotsPool, refetchSlots, onSlots, coordsOf, onViewedDay, rowOfPt } from './atlas.js';
import { showOnPanel } from './mapsearch.js';
import { html, render } from '../../template.js';
let refresh = () => { };
let mounted = false;
let unhook = null;
export function mountPool(opts) {
    refresh = (opts && opts.refresh) || refresh;
    mounted = true;
    if (!unhook)
        unhook = onSlots(() => { if (mounted)
            refresh(); });
    refetchSlots();
}
export function unmountPool() { mounted = false; }
export function refetch() { refetchSlots(); } // the old name, kept
// ── the map's points: means (in the commons) + placed needs ─────────────────
// Shapes match markerPoints(): {lng, lat, kind:"pool", s, need?} — clustering
// and the search filter treat them like any other point. The day clip and the
// coordinates are atlas's — one derivation, every reader.
export function poolPoints() {
    const P = slotsPool();
    const pts = [];
    for (const s of (P.means || [])) {
        const c = onViewedDay(s) && coordsOf(s);
        if (c)
            pts.push({ lng: c.lng, lat: c.lat, kind: "pool", s });
    }
    for (const s of (P.needs || [])) {
        const c = onViewedDay(s) && coordsOf(s);
        if (c)
            pts.push({ lng: c.lng, lat: c.lat, kind: "pool", s, need: true });
    }
    return pts;
}
/** The pool point's label, as the map draws it: name, then what the solve says of it. */
export function poolLabel(pt) {
    const s = pt.s;
    const occ = (!pt.need && isFinite(+s.drawn) && +s.qty)
        ? `${Math.round(+s.drawn * +s.qty)}/${+s.qty} taken` : "";
    const qty = s.qty ? `${s.qty} ${s.unit || ""}`.trim() : "";
    const text = `${s.name || s.spec || ""}${occ ? " · " + occ : qty ? " · " + qty : ""}`
        + (pt.need && s.matched ? ` → ${s.matched}` : "");
    return { text, ink: pt.need && s.matched ? "#2e7d32" : "#b87333" };
}
// ── the DOM for one pool point ──────────────────────────────────────────────
export function poolEl(pt) {
    // a POOL point always carries its slot — atlas's own rowOfPt reads pt.s! on
    // the same branch, for the same reason.
    const s = pt.s;
    const el = document.createElement("div");
    el.className = "map-slot-marker pool-marker" + (pt.need ? " pool-need" : "")
        + (pt.need && s.matched ? " pool-matched" : "");
    const face = s.emoji || (pt.need ? "🌱" : "🤲");
    const qty = s.qty ? `${s.qty} ${s.unit || ""}`.trim() : "";
    render(el, html `<div class="marker-icon">${face}</div>`);
    el.title = (slotsPool().demo ? "demo — " : "") + (pt.need
        ? (s.matched
            ? `matched — the plan fills ${s.name || s.spec} from ${s.matched}; ` +
                `the ✓ on its proposal is what makes it a commitment`
            : `needed here — ${s.name || s.spec}${qty ? ` (${qty})` : ""}` +
                `${s.who ? ` · ${s.who.slice(0, 12)}` : ""} · the plan matches it from the pool`)
        : `in the commons — ${s.name || s.spec}${qty ? ` (${qty})` : ""}` +
            `${s.owner ? ` · lent by ${s.owner.slice(0, 12)} (rights stay theirs)` : ""}`);
    // tap-through: the marker answers in the search panel with THE row (atlas)
    // rowOfPt hands slotRow the point's own coordinates, so it always answers a row.
    el.onclick = (e) => { e.stopPropagation(); showOnPanel(rowOfPt(pt)); };
    return el;
}
