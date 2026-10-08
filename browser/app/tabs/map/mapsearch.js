// app/tabs/mapsearch.ts — the map's search panel, ported from
// free-association's MapSidePanel.svelte (src/lib/components/MapSidePanel.svelte)
// onto this dial's own reactivity (app/reactive.js signals, no framework).
//
// The Svelte original is a floating Google-Maps-style panel pinned top-left of
// the map with three states driven by one store: EXPANDED (just the search
// input, with the time filter riding INSIDE the pill), SEARCH (a results list
// under the pill), and MARKER (one thing's details — header, location,
// slots). This port keeps that architecture verbatim — the state machine is
// three signals and one derived render — and swaps only the data layer:
//
//   their Commitment/AvailabilitySlot     →  THE row (app/tabs/atlas.js —
//     (capacity_slots, priority_…)           the one map-data layer: slots,
//                                            places, offers, one shape)
//   their markers/geocoding               →  atlas's coordinate ladder
//   their timeFilterBy any|now|next24h|   →  the same four, over atlas's
//     between (store + re-search)            window readers
//
// WHERE IT LIVES NOW. The panel has no pill of its own: the express bar at the
// foot is the search (one query, one clock, one place), and what the pill's
// results list, a tapped marker's details, a bundle and the saved lists used to
// draw under it they draw in the bar's pull-up sheet (a view, owner "map").
// The 🔖 rides in the bar beside the faces button. The cards keep the
// original's styling, re-tokened for the theme system (app.html .ms-* rules).
import { signal, effect } from '../../reactive.js';
// Only what main still OWNS comes from main. The map, willingness and the
// wayfinder are modules of their own now, and importing them directly is the
// difference between "the panel needs the dial" and "the panel needs a map".
import { commit, decline } from '../../day/respond.js';
import { USER } from '../../core.js';
import { offered } from '../../events.js';
import { theMap } from '../../mapview.js';
import { offerWillingness, widOf } from '../../willingness.js';
import { startNavTo } from '../../nav.js';
import { rows, rowOfPt, passesFilter, havKm, fmtKm } from './atlas.js';
import * as pins from './pins.js';
import * as book from './book.js';
import { heldHere, wireHeldHere } from './held-here.js';
import { revealSlot, F, railSwitch, openSheetView, closeSheetView, sheetViewIs, sheetHolds, sheetHeight } from '../social/share.js';
// a result is somebody ELSE's listing — name, provider, note and match all come
// off the search wire, so each is escaped where it lands in the card.
import { esc } from '../../template.js';
import { two } from '../../timefmt.js';
import { mk } from '../../dom.js';
// ── the store (their globalState, as signals) ───────────────────────────────
// The query and the time filter are the SHARE BAR's (tabs/social/share.ts F):
// one sift for the one pool. Typing in the footer's name sifts these pins and
// this list; this pill is a second handle on the same filter, not a second
// filter (the match ring keeps its own instance). What stays here is the
// map's own state: which row is open, which bundle.
const { query, timeBy, t0d, t0t, t1d, t1t, bump } = F;
const marker = signal(null); // the selected row (detail state)
const cluster = signal(null); // a tapped bundle's rows (cluster view)
// ── search + rank (their relevance/distance sort; atlas's one haversine) ────
function results() {
    bump();
    return rows()
        .filter(r => F.passes(r))
        .map(r => ({ ...r, km: havKm(USER, r) }))
        .sort((x, y) => x.km - y.km)
        .slice(0, 40);
}
// ── the views (their three panel states, one draw each) ─────────────────────
const KINDWORD = { need: "🚩 a need", means: "🤲 in the commons",
    place: "📍 a place", offer: "📅 on the day" };
function drawResults(host) {
    host.replaceChildren();
    const q = query().trim();
    // narrowed off F's OWN rest state, not a bare "any" — this F ships with
    // next24h as its default (search.ts, defaultTimeBy), so comparing against
    // "any" read every fresh page load as an active search and popped this
    // list open before anyone had touched anything.
    const searching = !!q || timeBy() !== F.defaultTimeBy || F.radiusKm() > 0;
    if (!searching)
        return; // expanded state: pill only
    const rs = results();
    const head = mk("div", "ms-head");
    head.append(mk("h3", "ms-count", rs.length ? `${rs.length} ${rs.length === 1 ? "result" : "results"}`
        : q ? "No results found" : "Everything in this window"), 
    // Requests ⇄ Offers rides beside the count, present exactly while a search
    // is: the same rail the toolbar's expression and the drawer read.
    railSwitch());
    host.append(head);
    const list = mk("div", "ms-list");
    for (const r of rs)
        list.append(itemEl(r, () => select(r, true)));
    host.append(list);
}
// ONE result-card renderer — the search list and the cluster view share it
// (the reference's .search-result-item / .cluster-result-item twins, unified)
function itemEl(r, onclick) {
    const it = mk("div", "ms-item");
    const km = r.km != null ? r.km : havKm(USER, r);
    it.innerHTML =
        `<div class="ms-row"><span class="ms-title"><span class="ms-emoji">${esc(r.emoji)}</span>` +
            `<b>${esc(r.name)}</b></span><span class="ms-dist">${fmtKm(km)}</span></div>` +
            `<div class="ms-sub"><span>👤 ${esc(r.provider)}</span>` +
            (r.unit ? `<span class="ms-unit">${esc(r.qty ?? "")} ${esc(r.unit)}</span>` : "") +
            `<span class="ms-kind">${KINDWORD[r.kind] || ""}</span></div>` +
            (r.note ? `<div class="ms-note">${esc(String(r.note).slice(0, 90))}</div>` : "");
    it.onclick = onclick;
    return it;
}
// ── the CLUSTER VIEW: what a tapped bundle holds (their clusterViewResults) ──
// The bubble's members as the same cards the search list uses; tapping one
// opens its details, whose ← returns HERE (the cluster survives the visit).
function drawCluster(host) {
    const rs = cluster() || [];
    host.replaceChildren();
    const head = mk("div", "ms-head ms-chead");
    head.append(mk("h3", "ms-count", `🎁 ${rs.length} at this spot`));
    const split = mk("a", "ms-split", "zoom to split");
    split.title = "zoom in until the bundle separates";
    split.onclick = () => {
        const map = theMap();
        if (!map || !rs.length)
            return;
        const lats = rs.map(r => r.lat), lngs = rs.map(r => r.lng);
        map.fitBounds([[Math.min(...lngs), Math.min(...lats)],
            [Math.max(...lngs), Math.max(...lats)]], { padding: 80, duration: 600, maxZoom: 17 });
    };
    const x = mk("button", "ms-close", "✕");
    x.onclick = () => cluster.set(null);
    head.append(split, x);
    host.append(head);
    const list = mk("div", "ms-list");
    for (const r of rs)
        list.append(itemEl(r, () => select(r, false)));
    host.append(list);
}
// a bundle on the MAP was tapped: list its members here
export function showCluster(rowsIn) {
    marker.set(null);
    cluster.set(rowsIn);
}
const arcLabel = (a) => {
    const ds = (a.days || []).map(d => d.slice(0, 3)).join(" ") || "every day";
    return a.start ? `${ds} ${a.start}–${a.end}` : ds;
};
function drawMarker(host, fromSearch) {
    const r = marker();
    host.replaceChildren();
    if (!r)
        return;
    const box = mk("div", "ms-detail");
    box.innerHTML =
        `<div class="ms-dhead">` +
            (fromSearch ? `<button class="ms-back" title="Back to search">←</button>` : "") +
            `<div class="ms-dinfo"><h2 class="ms-dtitle"><span>${esc(r.emoji)}</span> ${esc(r.name)}</h2>` +
            `<div class="ms-dprov">👤 ${esc(r.provider)}` +
            (r.unit ? ` <span class="ms-badge">${esc(r.qty ?? "")} ${esc(r.unit)}</span>` : "") +
            (r.matched ? ` <span class="ms-badge ms-matched">matched → ${esc(r.matched)}</span>` : "") +
            `</div></div><button class="ms-close" title="Close">✕</button></div>` +
            `<div class="ms-sec"><h3 class="ms-sect">📍 Location</h3>` +
            `<div class="ms-coords">📐 <code>${r.lat.toFixed(6)}, ${r.lng.toFixed(6)}</code></div></div>` +
            `<div class="ms-sec"><h3 class="ms-sect">${r.kind === "need" ? "🚩 The need" : "📅 Availability"}</h3>` +
            ((r.arcs && r.arcs.length)
                ? `<div class="ms-pills">${r.arcs.map(a => `<span class="ms-tpill">${esc(arcLabel(a))}</span>`).join("")}</div>`
                : `<div class="ms-pills"><span class="ms-tpill">✅ ${r.t0 != null
                    ? `${two(Math.floor(r.t0))}:00–${two(Math.ceil(r.t1))}:00`
                    : "standing — any time"}</span></div>`) +
            (r.until ? `<div class="ms-until">until ${esc(String(r.until).slice(0, 10))}</div>` : "") +
            (r.note ? `<div class="ms-note">${esc(r.note)}</div>` : "") + `</div>` +
            `<div class="ms-sec ms-acts"><button class="ms-nav">↦ directions</button>` +
            `<button class="ms-save">🔖 save</button>` +
            ((r.kind === "need" || r.kind === "means") && r.spec
                ? `<button class="ms-card">open its card →</button>` : "") + `</div>` +
            `<div class="ms-sec ms-saved"></div>` +
            heldHere(r) +
            // the ACT, in the same panel — a proposal takes your ✓/✗ (accept-proposal,
            // exactly the rail's buttons), an open work-intent your willingness: the
            // selection surface and the consent surface are one
            // `o` carries a Place on a place row and a DayEvent on an offer row. Only
            // the latter has a status, and every control below is emitted behind
            // `r.o &&`, so these reads are on an offer or they do not happen.
            (r.o && r.o.status === "proposed"
                ? `<div class="ms-sec ms-acts"><button class="ms-yes">✓ accept</button>` +
                    `<button class="ms-no">✗ pass</button></div>`
                : r.o
                    ? `<div class="ms-sec ms-acts"><button class="ms-will">` +
                        `${offered.has(widOf(r.o)) ? "↩ withdraw willingness" : "✋ offer willingness"}` +
                        `</button></div>` : "");
    // drawMarker wrote .ms-close into box immediately above.
    box.querySelector(".ms-close").onclick = () => marker.set(null);
    const back = box.querySelector(".ms-back");
    if (back)
        back.onclick = () => marker.set(null);
    const card = box.querySelector(".ms-card");
    if (card)
        card.onclick = () => revealSlot(r.spec, r.kind === "need" ? "need" : "capacity");
    // directions there — the dial's OWN routing (Valhalla /route, the
    // walk/bike/drive card floated over the map), not an external map app
    const navBtn = box.querySelector(".ms-nav");
    if (navBtn)
        navBtn.onclick = () => startNavTo({ lat: r.lat, lng: r.lng }, r.name || "");
    // the book: the lists this row stands in, and the menu that files it
    const savedSec = box.querySelector(".ms-saved"); // written above
    const drawSaved = (menu) => book.drawSaved(savedSec, r, menu, () => drawSaved(true));
    drawSaved(false);
    box.querySelector(".ms-save").onclick = () => drawSaved(!savedSec.querySelector(".ms-savemenu"));
    const yes = box.querySelector(".ms-yes");
    if (yes)
        yes.onclick = () => { commit(r.o); marker.set(null); if (onFilter)
            onFilter(); };
    const no = box.querySelector(".ms-no");
    if (no)
        no.onclick = () => { decline(r.o); marker.set(null); if (onFilter)
            onFilter(); };
    const will = box.querySelector(".ms-will");
    if (will)
        will.onclick = async () => {
            await offerWillingness(r.o);
            drawMarker(host, fromSearch); // relabel willing ⇄ withdraw in place
        };
    wireHeldHere(box); // what is held at a place counts from its panel
    host.append(box);
}
// select a row: fly the map there and open its details (their
// onSearchResultClick → marker state)
let cameFromSearch = false;
function select(r, fromSearch) {
    cameFromSearch = !!fromSearch;
    if (fromSearch)
        cluster.set(null); // a search pick leaves any bundle view
    marker.set(r);
    // centre the marker in the VISIBLE map — the sheet covers the foot of it,
    // so the camera pads for it (the reference apps' off-centre centring)
    // the sheet takes the foot of the screen once it has drawn this selection (a frame or two on), so the camera
    // pads by the height it really has and the marker lands in the middle of the map that is left
    const map = theMap();
    if (!map)
        return;
    const go = () => {
        map.flyTo({ center: [r.lng, r.lat], zoom: Math.max(map.getZoom(), 14), duration: 600,
            padding: { left: 20, top: 20, right: 20, bottom: sheetHeight() } });
    };
    requestAnimationFrame(() => requestAnimationFrame(go));
}
// ── the SAVED view lives in book.ts; the panel keeps only its two doors ────
/** The pill's 🔖: open the book (a second tap closes it). */
export function toggleSaved() {
    if (pins.view.peek()) {
        pins.close();
        return;
    }
    marker.set(null);
    cluster.set(null);
    pins.openBook();
}
/** A press-and-hold on the map: a bare spot, in the detail view, ready to save. */
export function showSpot(lat, lng) {
    cluster.set(null);
    select(pins.spotRow(lat, lng), false);
}
// ── mount: the map's view in the bar's sheet, and the 🔖 in the bar ─────────
/** The view and the effects that keep it live, so unmount can stop both. */
let mounted = null;
const OWNER = "map";
export function mountMapSearch() {
    const wrap = document.getElementById("maptab"); // the tab's OWN container
    if (!wrap || mounted)
        return;
    pins.mergeServer(); // the book follows the AID: a fresh device reads it here
    const body = mk("div", "ms-body ms-sheet");
    // the book's door rides the bar, as the faces button does
    const bookBtn = mk("button", "ms-book", "🔖");
    bookBtn.title = "Saved — your lists";
    bookBtn.id = "bookbtn";
    bookBtn.type = "button";
    bookBtn.onclick = toggleSaved;
    document.querySelector("#sharebar .share-end")?.prepend(bookBtn);
    // the book draws into the same body, through the panel's own card and select
    book.mount({ item: itemEl, select: r => select(r, false),
        clear: () => { marker.set(null); cluster.set(null); } });
    // the bar's words, the clock or the place moving drops a detail/cluster view back to the results list
    let lastFacets = "";
    const facets = () => [query(), timeBy(), t0d(), t0t(), t1d(), t1t(), F.radiusKm()].join("|");
    // a view the reader put away stays away until what it shows changes
    let dismissed = false, lastSig = "", leaving = false;
    // put away by the reader (a tap on the map, the grip, Esc): the selection goes with it, so tapping the same
    // marker again is a change the sheet answers
    const gone = () => { if (leaving)
        return; dismissed = true; marker.set(null); cluster.set(null); };
    const effects = [
        effect(() => {
            query();
            timeBy();
            t0d();
            t0t();
            t1d();
            t1t();
            F.radiusKm();
            bump();
            cluster();
            pins.version();
            pins.ourLists();
            const f = facets();
            if (lastFacets && f !== lastFacets && (marker.peek() || cluster.peek())) {
                marker.set(null);
                cluster.set(null);
            }
            lastFacets = f;
            const v = pins.view();
            bookBtn.classList.toggle("on", !!v);
            if (marker())
                drawMarker(body, cameFromSearch || !!cluster.peek());
            else if (cluster())
                drawCluster(body);
            else if (v)
                book.draw(body, v);
            else
                drawResults(body);
            // the sheet shows it whenever there is something to show: a search, a selection, a list
            const searching = !!query().trim() || timeBy() !== F.defaultTimeBy || F.radiusKm() > 0;
            const showing = !!marker() || !!cluster() || !!v || searching;
            const sig = [showing, f, marker()?.name, !!cluster(), !!v].join("|");
            if (sig !== lastSig) {
                dismissed = false;
                lastSig = sig;
            }
            if (showing && !dismissed && !sheetViewIs(OWNER)) {
                const held = sheetHolds(); // the inventory, or another menu, is not pushed aside by a search
                if (!held)
                    openSheetView(OWNER, body, gone, false, true);
            }
            else if (!showing && sheetViewIs(OWNER)) {
                leaving = true;
                closeSheetView(OWNER);
                leaving = false;
            }
            if (onFilter)
                onFilter(); // the map re-filters with the list
        }),
    ];
    const key = (e) => { if (e.key === "Escape" && sheetViewIs(OWNER)) {
        e.preventDefault();
        closeSheetView(OWNER);
    } };
    document.addEventListener("keydown", key);
    mounted = { body, bookBtn, effects, key };
}
export function unmountMapSearch() {
    if (!mounted)
        return;
    mounted.effects.forEach(stop => stop());
    closeSheetView(OWNER);
    mounted.bookBtn.remove();
    document.removeEventListener("keydown", mounted.key);
    mounted = null;
    marker.set(null);
    pins.close();
}
// a marker on the MAP was tapped: open its details here (their marker state)
export function showOnPanel(row) { cluster.set(null); select(row, false); }
/**
 * A spec's own place: the pool's first live means-or-need listing for it —
 * the same row a tap on its marker would open (pool.ts's own onclick), found
 * by spec rather than by pointer so a caller with only the join key (a
 * recipe line, an event's own flow) can ask too. False when nothing in the
 * pool stands under this spec, so the caller has a fallback place to fly to
 * instead of a wrong one.
 */
export function showSpecOnMap(spec) {
    const row = rows().find(r => r.spec === spec && (r.kind === "means" || r.kind === "need"));
    if (!row)
        return false;
    showOnPanel(row);
    return true;
}
// ── search-as-map-filter ────────────────────────────────────────────────────
// The reference's `filteredMarkers` derivation, inverted for our pull model:
// the map's markerPoints() asks THIS predicate about every point, so while a
// search or a time filter is in force the map shows exactly what the results
// list names — one truth, two surfaces. main.js binds its re-render here so
// each keystroke re-filters the markers as it re-filters the list.
let onFilter = null;
export function bindFilter(cb) { onFilter = cb; }
export const filterActive = F.active;
export function matchesPt(pt) {
    if (!passesFilter(pt, F))
        return false;
    // an open list narrows the map to what it holds
    if (!pins.narrowing())
        return true;
    const row = rowOfPt(pt);
    return pins.passes(row ? pins.subjectOf(row) : null);
}
// THE point→row converter (atlas's), re-exported so the map's click handlers
// have one import site for panel + rows alike
export { rowOfPt };
