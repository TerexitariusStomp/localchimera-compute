// app/gohere.ts — the one door for three-way navigation.
//
// Every read-only surface that names a moment or a place — a calendar block,
// a detail card, a slot card, a schedule row — answers the same two gestures:
// a TIME opens the calendar at that event, a PLACE opens the map at that
// event's location. The surfaces differ in shape, so each shape gets an
// adapter down to `Here`; the door itself never learns what a slot or a
// schedule row is, which is what keeps the next surface a one-line caller.
//
// ── THE PLACE-LEG MOVES TIME TOO ────────────────────────────────────────────
// "Show me this on the map" means the map AS OF the thing's window: the turn
// window moves first (goToDoy — every time-clipped marker follows it), and
// only then does the camera fly. A map standing at the wrong day would show
// the right place with the thing you asked about filtered out of it.
//
// ── THE FLY SURVIVES THE GPS RE-FIT ─────────────────────────────────────────
// Geolocation resolves whenever it likes, and arrived() re-fits the camera
// around the corrected user — which would silently win over a fly the reader
// just asked for. The last fly is kept as a closure over the LIVE user
// position and re-run by reassert(), so "where were we going?" is recomputed
// against where the user truly is rather than replayed against the default.
import { stage } from './stage.js';
import { setFace } from './faces.js';
import { theMap } from './mapview.js';
import { USER } from './core.js';
import { S } from './state.js';
import { goToDate } from './daterow.js';
import { goToScope } from './scope.js';
import { dateOf, baseYear } from './timefmt.js';
import { selectEvent, selectedEv } from './ribbons.js';
import { evs, proposals, eligible, sched, lived } from './events.js';
import { DAYS } from './slots/model.js';
/**
 * THE APPLIER — one function every caller of `goToMapPlace` / `goToCalendarTime`
 * / a bare scope switch can use instead of choosing between them by hand: give
 * it whatever coordinates you have (a FACE name, a SCOPE id, and/or a Here),
 * and it moves exactly those, in the order that keeps each leg consistent
 * (scope before place — a place only resolves inside the scope that holds it;
 * the place-leg's own doy-then-fly order, unchanged). Absent coordinates are
 * holes: nothing about them moves, because there is nothing to conclude.
 */
export function applyHere(h, face) {
    if (h.scope)
        goToScope(h.scope);
    if (face)
        setFace(face);
    if (h.lat != null || h.ev)
        goToMapPlace(h);
    else if (h.doy != null || h.t0 != null)
        goToCalendarTime(h);
}
/** Where a here's place stands right now — `loc` is absolute truth, `at` rides the live user. */
const targetOf = (h) => (h.ev?.loc && h.ev.loc.lat != null) ? { lat: h.ev.loc.lat, lng: h.ev.loc.lng }
    : h.ev?.at ? { lat: USER.lat + h.ev.at.dLat, lng: USER.lng + h.ev.at.dLng }
        : (h.lat != null && h.lng != null) ? { lat: h.lat, lng: h.lng }
            : null;
/** The turn window that contains a day-of-year, at the current scale. */
export function goToDoy(doy) {
    const d = dateOf(doy);
    goToDate(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());
}
// the last place-leg, kept live for reassert()
let lastFly = null;
/** A here's fly, as a closure over the LIVE map and user — re-runnable. */
const mkFly = (h) => () => {
    const m = theMap(), t = targetOf(h);
    if (m && t)
        m.flyTo({ center: [t.lng, t.lat], zoom: 14, duration: 700 });
};
/**
 * PLACE-LEG: open the map at the here's place, viewed from the here's time.
 * Selects the event when the here carries one, so every surface that follows
 * the selection signal follows the jump.
 */
export function goToMapPlace(h) {
    if (h.doy != null)
        goToDoy(h.doy);
    if (stage.face !== "map")
        setFace("map");
    if (h.ev)
        selectEvent(h.ev);
    lastFly = mkFly(h);
    lastFly();
}
/**
 * TIME-LEG: open the calendar at the here's day, with the event selected so
 * the grid highlights it and the detail card describes it.
 */
export function goToCalendarTime(h) {
    if (h.doy != null)
        goToDoy(h.doy);
    if (stage.face !== "cal")
        setFace("cal");
    if (h.ev)
        selectEvent(h.ev);
}
/**
 * Re-run the last place-leg after something else moved the camera — the GPS
 * arrival's generic re-fit is the one caller today. With no place-leg standing
 * yet, the selection's own venue is what the reader last asked to see.
 */
export function reassert() {
    if (!lastFly) {
        const sel = selectedEv();
        if (sel)
            lastFly = mkFly({ ev: sel });
    }
    if (lastFly)
        lastFly();
}
// ── deep links: the URL's shape, read down to a Here ────────────────────────
// ?doy=YYYY-MM-DD (or a raw day-of-year number) and ?ev=<vfId>. The day leg
// applies at once; the event leg has to WAIT for the snapshot — a vfId only
// exists once ingest has run — so it stands as a pending here that
// resolveHere() (called at the end of every ingest) answers the first time
// the id appears. ?face= keeps deciding which surface opens; the standing
// selection then rides whichever leg that surface speaks — the map flies,
// the calendar highlights.
let pendingEv = null;
/** Apply the URL's here, answering whether it asked for anything. */
export function openHereFromUrl() {
    const p = new URLSearchParams(location.search);
    const dq = p.get("doy"), ev = p.get("ev");
    if (!dq && !ev)
        return false;
    const doy = dq ? (/^\d+$/.test(dq) ? parseInt(dq, 10) : isoDoy(dq)) : null;
    if (doy != null)
        goToDoy(doy);
    if (ev) {
        pendingEv = ev;
        resolveHere();
    }
    return true;
}
/** Answer a standing ?ev= once its id exists in any day list. */
export function resolveHere() {
    if (!pendingEv)
        return;
    const hit = [...evs, ...proposals, ...eligible, ...sched, ...lived]
        .find(e => e.vfId === pendingEv);
    if (!hit)
        return;
    pendingEv = null;
    (stage.face === "map" ? goToMapPlace : goToCalendarTime)(hereOfEvent(hit));
}
// ── adapters: each surface's shape, read down to a Here ─────────────────────
/** A DayEvent's here — its own day when it states one, else the viewed day. */
export const hereOfEvent = (ev) => ({ ...(ev.doy != null ? { doy: ev.doy } : {}), t0: ev.t0, t1: ev.t1, ev });
/** Clock-of-day hours from an "HH:MM" string. */
const hm = (s) => {
    const [h, m] = s.split(":").map(Number);
    return (h || 0) + (m || 0) / 60;
};
/**
 * A zoneless ISO string read as UTC — the wire's datetimes are civil labels on
 * the one clock (utils/clock), so a host-timezone parse would shift every
 * schedule row by the machine's offset.
 */
const utcMs = (iso) => Date.parse(iso.length <= 10 ? iso + "T00:00:00Z"
    : /(?:Z|[+-]\d\d:?\d\d)$/.test(iso) ? iso : iso + "Z");
/** Day-of-year from an ISO "YYYY-MM-DD" (or longer) string. */
const isoDoy = (iso) => {
    const t = utcMs(iso);
    return isFinite(t) ? Math.floor((t - Date.UTC(baseYear, 0, 1)) / 86400000) : null;
};
/**
 * An ISO instant's here — the schedule wire's `when` is one of these.
 * A bare date lands on the day with no clock claim.
 */
export function hereOfInstant(iso) {
    const doy = isoDoy(iso);
    if (doy == null)
        return {};
    const t = utcMs(iso);
    const day0 = utcMs(iso.slice(0, 10));
    return { doy, ...(iso.length > 10 && isFinite(t) && isFinite(day0)
            ? { t0: (t - day0) / 3600000 } : {}) };
}
/**
 * The clock spans of a slot's arcs that stand on a given day — [] when none.
 * Week-of-month follows the schema's own rule (ceil(day/7), see
 * temporal-expression-vs-rrule): tiers an arc leaves empty admit every day.
 * The calendar draws these as standing bands; hereOfSlot walks them forward.
 */
export function slotArcsOn(slot, doy) {
    const from = slot.from ? isoDoy(slot.from) : null;
    const until = slot.until ? isoDoy(slot.until) : null;
    if ((from != null && doy < from) || (until != null && doy > until))
        return [];
    const d = dateOf(doy);
    const day = DAYS[(d.getUTCDay() + 6) % 7]; // JS Sunday-first → our Monday-first
    const out = [];
    for (const a of (slot.arcs || [])) {
        if (!a.days.includes(day))
            continue;
        if (a.months?.length && !a.months.includes(d.getUTCMonth() + 1))
            continue;
        if (a.weeks?.length && !a.weeks.includes(Math.ceil(d.getUTCDate() / 7)))
            continue;
        out.push({ t0: hm(a.start), t1: hm(a.end) });
    }
    return out;
}
/**
 * A slot's here: its place resolved through the WHERE picker's own options,
 * and the FIRST UPCOMING occurrence of its arcs — the calendar day a reader
 * asking "when is this?" actually means.
 */
export function hereOfSlot(slot, locs) {
    const h = {};
    const l = slot.where ? (locs || []).find(x => x.id === slot.where) : null;
    if (l && l.lat != null && l.lng != null) {
        h.lat = l.lat;
        h.lng = l.lng;
    }
    const today = Math.floor(S.nowAbs / 24);
    const from = slot.from ? isoDoy(slot.from) : null;
    const until = slot.until ? isoDoy(slot.until) : null;
    const d0 = Math.max(today, from ?? today);
    if (!(slot.arcs || []).length) {
        h.doy = d0;
        return h;
    } // "anytime": the span's first live day
    for (let doy = d0; doy <= (until ?? d0 + 366); doy++) {
        const occ = slotArcsOn(slot, doy);
        if (occ.length)
            return { ...h, doy, ...occ[0] };
    }
    h.doy = d0; // rhythm past its span: land on the span
    return h;
}
