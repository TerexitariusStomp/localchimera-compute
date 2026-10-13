// app/route/preview.ts — the ways to a place, before you set out.
//
// ↦ directions opens this rather than starting a journey. Three things appear
// together and are one state:
//
//   the from/to card   floats at the top of the map: where from (you, until you
//                      say otherwise), where to, and ⇅. Either end is a field —
//                      type a name, pick a place.
//   the sheet          owner "route" in the share bar's pull-up: the mode tabs
//                      with a time each, the chosen way's summary, Start.
//   the map            the chosen route heavy, its alternatives pale, a time on
//                      each, framed so the whole of it shows between card and sheet.
//
// Every mode is asked at once (app/route/data.ts) and each tab fills as its
// answer lands. Start hands the chosen way to the wayfinder (app/route/nav.ts
// startNavTo) and the preview steps away; ✕ steps back to the place it came from.
//
// The view is `sticky` in the sheet: the page works WITH a route being chosen —
// a tap on the map to pick an alternative must not put it away.
import { theMap } from '../mapview.js';
import { youAt } from '../position.js';
import { openSheetView, closeSheetView, sheetViewIs, sheetHeight } from '../tabs/social/share.js';
import { startNavTo } from './nav.js';
import { fetchRoutes } from './data.js';
import { ROUTE_MODES, modeInfo, travelIcon, DEFAULT_COSTING } from './modes.js';
import { mountFields, youEnd } from './fields.js';
import { fitClear } from './camera.js';
import { paintLines, clearLines } from './lines.js';
import { lineBadge } from './badge.js';
import { fmtMinutes, fmtDistance, headline, legsOf, arrivalClock } from './facts.js';
import { boundsOf, pillAnchor } from './shape.js';
import { havKm } from '../geom.js';
import { readStr, writeStr } from '../store.js';
import { K } from '../keys.js';
import { esc } from '../template.js';
import { mk } from '../dom.js';
const OWNER = "route";
/** The destination pin's height in pixels — the camera leaves it room above the point. */
const PIN_H = 34;
/** How many ways besides the best to ask for, where the engine offers them. */
const ALTERNATES = 2;
let pv = null;
let fields = null;
let markers = [];
// ── the asks ────────────────────────────────────────────────────────────────
/** Where an end is now: you, wherever you have got to; a place, where it is. */
const atOf = (e) => e.live ? youAt() : e.at;
/** Ask every mode, and let each tab fill as its answer lands. */
function ask() {
    const p = pv;
    if (!p)
        return;
    const seq = ++p.seq;
    p.ways = {};
    p.pick = 0;
    draw();
    const a = atOf(p.from), b = atOf(p.to);
    let framed = false;
    for (const m of ROUTE_MODES) {
        fetchRoutes(a, b, m, { alternates: ALTERNATES }).then(rs => {
            if (pv !== p || p.seq !== seq)
                return;
            p.ways[m] = rs;
            draw();
            // the camera frames once, when the chosen mode answers — or, if nothing answers it, when all have
            const done = ROUTE_MODES.every(x => p.ways[x] !== undefined);
            if (!framed && (m === p.mode || done)) {
                framed = true;
                frame();
            }
        });
    }
}
const routes = () => (pv && pv.ways[pv.mode]) || [];
const settled = () => !!pv && ROUTE_MODES.every(m => pv.ways[m] !== undefined);
const nowhere = () => settled() && ROUTE_MODES.every(m => (pv.ways[m] || []).length === 0);
// ── the map ─────────────────────────────────────────────────────────────────
function clearMarkers() { markers.forEach(m => m.remove()); markers = []; }
function pin(map, cls, text, at, anchor, onClick) {
    const el = mk(onClick ? "button" : "div", cls, text);
    if (onClick) {
        el.type = "button";
        el.onclick = e => { e.stopPropagation(); onClick(); };
    }
    markers.push(new maplibregl.Marker({ element: el, anchor }).setLngLat([at.lng, at.lat]).addTo(map));
}
/** The routes, their times and the two ends, drawn from the state. */
function paint() {
    const p = pv, map = theMap();
    if (!p || !map)
        return;
    const rs = routes();
    const a = atOf(p.from), b = atOf(p.to);
    paintLines(map, { ways: rs, pick: p.pick, bearing: nowhere() ? [[a.lng, a.lat], [b.lng, b.lat]] : undefined });
    clearMarkers();
    if (!p.from.live)
        pin(map, "rv-dot", "", p.from.at, "center");
    pin(map, "rv-pin", "📍", atOf(p.to), "bottom");
    rs.forEach((r, i) => {
        const at = pillAnchor(rs, i);
        if (!at)
            return;
        const best = i === 0 && rs.length > 1 && p.pick === 0;
        pin(map, "rv-pill" + (i === p.pick ? " sel" : ""), fmtMinutes(r.s) + (i === p.pick && best ? " · Best route" : ""), { lat: at[1], lng: at[0] }, "center", () => { p.pick = i; draw(); });
    });
}
/** Frame every way of the chosen mode (or the two ends) between the card and the sheet. */
function frame() {
    const p = pv, map = theMap();
    if (!p || !map)
        return;
    const go = () => {
        if (pv !== p)
            return;
        const ends = [[atOf(p.from).lng, atOf(p.from).lat], [atOf(p.to).lng, atOf(p.to).lat]];
        const b = boundsOf(routes()) || boundsOf([{ coords: ends }]);
        if (!b)
            return;
        fitClear(map, b, { duration: 600, maxZoom: 17,
            // the top clears the card AND the destination pin, which stands a pin's height above its point
            padding: { top: (fields?.height() || 0) + 28 + PIN_H, bottom: sheetHeight() + 24, left: 28, right: 28 } });
    };
    // the sheet takes its height a frame or two after it draws; the camera pads by what it really has
    requestAnimationFrame(() => requestAnimationFrame(go));
}
// ── the sheet ───────────────────────────────────────────────────────────────
function drawSheet() {
    const p = pv;
    if (!p)
        return;
    const rs = routes(), r = rs[p.pick] || null;
    const m = modeInfo(p.mode);
    const pending = p.ways[p.mode] === undefined;
    const tab = (id) => {
        const w = p.ways[id];
        const t = w === undefined ? "…" : w.length ? fmtMinutes(w[0].s) : "–";
        return `<button type="button" class="rv-tab${id === p.mode ? " on" : ""}" role="tab" aria-selected="${id === p.mode}" data-mode="${id}">` +
            `<span class="rv-ti">${modeInfo(id).icon}</span><b>${esc(t)}</b></button>`;
    };
    let sum, acts;
    if (pending) {
        sum = `<div class="rv-big">Finding the way…</div>`;
        acts = `<button type="button" class="rv-start" disabled>▲ Start</button>`;
    }
    else if (r) {
        const arrive = arrivalClock(r.s);
        const legs = legsOf(r);
        // a trip of more than one leg shows them: walk 6 min › [48] 14 min › walk 4 min
        const strip = legs.length > 1
            ? `<div class="rv-legs">${legs.map(l => `<span class="rv-leg">${l.line ? lineBadge(l.line).outerHTML : esc(travelIcon(l.mode))} ${esc(fmtMinutes(l.s))}</span>`)
                .join(`<span class="rv-sep">›</span>`)}</div>` : "";
        sum = `<div class="rv-big">${esc(headline(r))}</div>` + strip +
            `<div class="rv-sub">arrive ${esc(arrive)}${r.hasToll ? " · tolls" : ""}${r.hasFerry ? " · ferry" : ""}</div>`;
        acts = p.from.live
            ? `<button type="button" class="rv-start">▲ Start</button>`
            : `<button type="button" class="rv-start rv-fromhere">▲ Start from my location</button>`;
    }
    else if (nowhere()) {
        const km = havKm(atOf(p.from), atOf(p.to));
        sum = `<div class="rv-big">Routing is unavailable here</div>` +
            `<div class="rv-sub">${esc(fmtDistance(km))} as the crow flies</div>`;
        acts = `<button type="button" class="rv-start rv-go">↦ Go by compass</button>`;
    }
    else {
        sum = `<div class="rv-big">No route to here by ${esc(m.label.toLowerCase())}</div>`;
        acts = `<button type="button" class="rv-start" disabled>▲ Start</button>`;
    }
    p.body.innerHTML =
        `<div class="rv-head"><h2 class="rv-title">${esc(m.label)}</h2><button type="button" class="rv-x" title="Close directions">✕</button></div>` +
            `<div class="rv-tabs" role="tablist">${ROUTE_MODES.map(tab).join("")}</div>` +
            `<div class="rv-sum">${sum}</div><div class="rv-acts">${acts}</div>`;
    p.body.querySelector(".rv-x").onclick = () => end(true);
    p.body.querySelectorAll(".rv-tab").forEach(b => b.onclick = () => {
        p.mode = b.dataset.mode;
        p.pick = 0;
        writeStr(K.routeMode, p.mode);
        draw();
        if (p.ways[p.mode] !== undefined)
            frame();
    });
    const start = p.body.querySelector(".rv-start");
    if (start && !start.disabled)
        start.onclick = () => {
            if (start.classList.contains("rv-fromhere")) {
                p.from = youEnd();
                ask();
                return;
            } // a journey sets out from where you are
            go(r);
        };
}
/** Set out: the chosen way (or none — the compass) goes to the wayfinder and the preview steps away. */
function go(r) {
    const p = pv;
    if (!p)
        return;
    const dest = atOf(p.to), name = p.to.name, costing = p.mode;
    end(false);
    void startNavTo(dest, name, { route: r, costing });
}
// ── opening and closing ─────────────────────────────────────────────────────
function draw() { drawSheet(); paint(); }
const onKey = (e) => {
    if (e.key === "Escape" && pv && sheetViewIs(OWNER)) {
        e.preventDefault();
        end(true);
    }
};
/** Whether the preview is up. */
export const routePreviewOpen = () => pv !== null;
/**
 * Show the ways to `dest`. `back`, when given, is where ✕ returns to — the
 * place card the person came from; setting out does not call it.
 */
export function openRoutePreview(dest, name, back) {
    const map = theMap();
    if (!map)
        return;
    if (pv)
        end(false);
    const saved = readStr(K.routeMode);
    const body = mk("div", "rv");
    const p = { from: youEnd(), to: { at: dest, name }, mode: saved && modeInfo(saved) ? saved : DEFAULT_COSTING,
        ways: {}, pick: 0, seq: 0, back: back || null, body };
    pv = p;
    fields = mountFields(map.getContainer(), {
        ends: () => ({ from: p.from, to: p.to }),
        change: next => { Object.assign(p, next); fields?.sync(); ask(); frame(); },
    });
    document.addEventListener("keydown", onKey);
    // sticky: a tap on the map picks a way, it does not put the sheet away
    openSheetView(OWNER, body, teardown, { fit: true, sticky: true });
    ask();
}
/** The view left the sheet, whichever way: take down the card, the lines and the markers. */
function teardown() {
    document.removeEventListener("keydown", onKey);
    fields?.remove();
    fields = null;
    clearMarkers();
    clearLines(theMap());
    pv = null;
}
/** Close the preview. With `back`, return to the place card it began from. */
function end(back) {
    const p = pv;
    if (!p)
        return;
    const b = back ? p.back : null;
    closeSheetView(OWNER); // → teardown
    if (pv)
        teardown(); // a sheet that was already gone leaves nothing to call it
    b?.();
}
