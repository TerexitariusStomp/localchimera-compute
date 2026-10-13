// app/tabs/atlas.ts — THE map-data layer.
//
// Every row the map and its search panel render, from every source, in ONE
// shape, made in ONE place. The inspiration is free-association's Map.svelte,
// where processors turn every protocol object into a single MarkerData type
// and demo/simulated data streams through the SAME type — components never
// know which they are holding. Here likewise: pool.js draws markers,
// mapsearch.js searches and details, main.js clusters — none of them makes a
// row; they all ask this module.
//
// ── THE ROW ─────────────────────────────────────────────────────────────────
//   { id, kind,                  kind ∈ need | means | place | offer | drop
//     emoji, name, provider,     the face, the label, whose it is
//     lat, lng,                  through THE coordinate ladder (coordsOf)
//     qty, unit, note, spec,     what and how much (slots)
//     arcs, from, until,         the window (arcs = the recurring pattern)
//     t0, t1,                    an offer's clock hours on the day
//     matched, drawn,            a need's match; a means' occupancy 0..1
//     s | p | o | c }            the LIVE source object, for the acts
//
// ── THE DEMO DISCIPLINE, stated once ────────────────────────────────────────
//   A source serves its REAL wire whenever the wire has rows, and its demo
//   twin ONLY when the wire brings nothing (offline, or a fresh scope) —
//   marked `demo: true` on the batch, never row-mixed with real data. The
//   demo rows carry the exact wire shape, so every consumer downstream is
//   provably indifferent. (The share face's DEMO slots set the discipline;
//   this module applies it to the map.)
import { mapPool } from '../../demo/world.js';
import { seam } from '../../seam.js';
import { HANDLERS, USER, PLACES } from '../../core.js';
import { evs, pending, eligible, turnAnchor } from '../../events.js';
import { dateOf, clockOf } from '../../timefmt.js';
import { havKm } from '../../geom.js';
import { placesNamed } from './osm-places.js';
import { on } from '../../bus.js';
// ── DISTANCE — geom's one haversine, plus the one way it prints ─────────────
export { havKm };
// ═══ SOURCE 1: the slot pool (real: the slots-at wire · demo: the twin) ═════
const iso = (days) => {
    const d = new Date();
    d.setDate(d.getDate() + days);
    return d.toISOString().slice(0, 10);
};
// the demo pool: what stands at a place in the demo world (demo/world.ts
// mapPool), every need and the means lent into the commons, each at its place's
// offset from the person like every demo place. The Lastenrad's weekday arcs are
// deliberate: browse the mini-month to a weekend and it leaves the map.
const DEMO_POOL = () => ({ demo: true, ...mapPool(iso) });
let POOL = { needs: [], means: [] };
const listeners = new Set(); // whoever renders the pool re-draws
/**
 * Where the map's own fabric is anchored — a FROZEN copy of USER, not USER
 * itself. USER keeps moving continuously (real geolocation drifts by tens of
 * metres between fixes even standing still, and nav.ts/location.ts's live
 * watchers push it further); every place and pool row on the map used to read
 * USER directly at render time, so a render that landed between two drifts
 * repositioned everything relative to wherever USER happened to be at THAT
 * instant — invisible during a pan (nothing re-renders), but a sudden jump of
 * every marker at once the moment a zoom (or any other trigger) forced a
 * redraw, since the viewport itself hadn't moved to match.
 *
 * bakeMapAnchor() is the only writer, called exactly where the viewport
 * itself gets recentred on USER (openMap, arrived()) — so the anchor and what
 * you're looking at always move together, atomically, and never drift apart
 * between those moments.
 */
export const MAP_ANCHOR = { lat: USER.lat, lng: USER.lng };
const anchorReaders = [];
/** Hear the anchor move: what is set down around it is set down again. */
export const onMapAnchor = (f) => { anchorReaders.push(f); };
export function bakeMapAnchor() {
    MAP_ANCHOR.lat = USER.lat;
    MAP_ANCHOR.lng = USER.lng;
    for (const f of anchorReaders)
        f();
}
// BAKE the demo fabric: offsets become ABSOLUTE coordinates at assembly time,
// so a demo row is thereafter indistinguishable from a live one (rung 0 of
// the ladder) and nothing is ever USER-relative at render time. The fabric
// assembles ONCE around wherever the anchor stands when it forms; a
// geolocation fix re-fetches and so re-bakes it once — it never tracks a
// moving anchor frame-by-frame, which is what made markers and captured
// coordinates drift apart.
const bake = (s) => {
    if (!isFinite(Number(s.dLat)) || !isFinite(Number(s.dLng)))
        return s;
    const { dLat, dLng, ...rest } = s;
    return { ...rest, lat: MAP_ANCHOR.lat + Number(dLat), lng: MAP_ANCHOR.lng + Number(dLng) };
};
const baked = (pool) => ({ ...pool, means: (pool.means || []).map(bake),
    needs: (pool.needs || []).map(bake) });
// fetch the pool: real wire first, the demo twin only when it brings nothing
export function refetchSlots() {
    const fallback = () => { POOL = baked(DEMO_POOL()); notify(); };
    if (!HANDLERS.slotsAt) {
        fallback();
        return;
    }
    HANDLERS.slotsAt().then((txt) => {
        try {
            const v = JSON.parse(String(txt));
            if (v && (Array.isArray(v.means) || Array.isArray(v.needs))) {
                const real = { needs: v.needs || [], means: v.means || [] };
                POOL = (real.means.length || real.needs.length) ? real : DEMO_POOL();
                notify();
                return;
            }
            fallback();
        }
        catch (_) {
            fallback();
        } // an err:* string — offline
    }).catch(fallback);
}
// the gateway's push: the pool moved. With a reader mounted (the map face)
// the pins follow at once; with none, nothing is fetched — mountPool refetches
// when the map next opens, so a closed map costs the push nothing.
on("slotsChanged", () => { if (listeners.size)
    refetchSlots(); });
const notify = () => listeners.forEach(fn => { try {
    fn();
}
catch (_) { /* a deaf reader, not a dead push */ } });
export function onSlots(fn) { listeners.add(fn); return () => listeners.delete(fn); }
export function slotsPool() { return POOL; }
// ═══ THE COORDINATE LADDER — one resolver, every reader ═════════════════════
// (their 'coordinates'-first-then-'geocoded' resolution, in our terms:)
//   0. own lat/lng           → honoured as they are (a live drop point, a
//      row that already knows where it stands)
//   1. `where` (a place id)  → snapshot.locations coords — the real rung; a
//      server row arrives here already resolved through the containment climb
//      (%socialization-place-of — the oven inherits the flat), our analog of
//      their geocoding, done once server-side instead of per-render
//   2. dLat/dLng             → an offset from the map's own frozen anchor —
//      MAP_ANCHOR, not live USER (see its own comment above) — the demo rung
//   3. none of these         → null: an unplaced thing is not on a map
function locOf(id) {
    const L = (seam.data && seam.data.snapshot && seam.data.snapshot.locations) || [];
    const x = L.find(l => l && (l.id === id || l.name === id));
    if (!x)
        return null;
    const lat = parseFloat(String(x.lat)), lng = parseFloat(String(x.lng ?? x.long));
    return (isFinite(lat) && isFinite(lng)) ? { lat, lng } : null;
}
export function coordsOf(s) {
    if (isFinite(Number(s.lat)) && isFinite(Number(s.lng)))
        return { lat: Number(s.lat), lng: Number(s.lng) };
    if (s.where)
        return locOf(s.where);
    if (isFinite(Number(s.dLat)) && isFinite(Number(s.dLng)))
        return { lat: MAP_ANCHOR.lat + Number(s.dLat), lng: MAP_ANCHOR.lng + Number(s.dLng) };
    return null;
}
// ═══ TIME — the windows, read one way everywhere ════════════════════════════
export const DAYNAMES = ["sunday", "monday", "tuesday", "wednesday", "thursday",
    "friday", "saturday"];
// does the row's window contain the instant AT?
export function windowCovers(r, at) {
    const isoDay = at.toISOString().slice(0, 10);
    if (r.from && isoDay < String(r.from).slice(0, 10))
        return false;
    if (r.until && isoDay > String(r.until).slice(0, 10))
        return false;
    if (r.t0 != null) { // an offer: clock hours of the day
        const h = at.getHours() + at.getMinutes() / 60;
        return h >= r.t0 && h <= Number(r.t1);
    }
    const arcs = r.arcs || [];
    if (!arcs.length)
        return true; // no pattern = standing
    const wd = DAYNAMES[at.getDay()];
    const hm = clockOf(at);
    return arcs.some(a => (!(a.days || []).length || a.days.includes(wd))
        && (!a.start || (hm >= a.start && hm <= a.end)));
}
// …intersect [a, b]? sampled hourly — windows are hour-grained
export function windowIntersects(r, a, b) {
    for (let t = a.getTime(); t <= b.getTime(); t += 3600e3)
        if (windowCovers(r, new Date(t)))
            return true;
    return false;
}
// does R's own window overlap the RHYTHM dialled into a draft — a day-of-week
// + hour-range set, the arcsEditor's own shape, not a date range? No new
// overlap algorithm: each arc names a weekday and an hour span, so its NEXT
// occurrence in the coming week is one concrete [a, b] — windowIntersects
// already answers "does R's window cover this," the same check `timeBy`
// already rides. An arc with no days names every day (arcsEditor's own
// "anytime" reading); an empty rhythm filters nothing, same as `timeBy: any`.
export function passesRhythm(r, arcs) {
    if (!arcs.length)
        return true;
    const today = new Date();
    for (const arc of arcs) {
        if (!arc.start || !arc.end)
            continue;
        const days = (arc.days && arc.days.length) ? arc.days : DAYNAMES;
        for (const d of days) {
            const target = DAYNAMES.indexOf(d);
            if (target < 0)
                continue;
            for (let add = 0; add < 7; add++) {
                const dt = new Date(today);
                dt.setDate(dt.getDate() + add);
                if (dt.getDay() !== target)
                    continue;
                const [sh, sm] = arc.start.split(":").map(Number);
                const [eh, em] = arc.end.split(":").map(Number);
                const from = new Date(dt);
                from.setHours(sh, sm, 0, 0);
                const to = new Date(dt);
                to.setHours(eh, em, 0, 0);
                if (windowIntersects(r, from, to))
                    return true;
                break; // this weekday's only occurrence in the week ahead
            }
        }
    }
    return false;
}
// does the slot stand on the VIEWED day (the mini-month's day)? [from,until]
// bounds it; its arcs must touch the day's weekday; no window = standing
export function onViewedDay(s) {
    const dt = dateOf(Math.floor(turnAnchor() / 24));
    const isoDay = dt.toISOString().slice(0, 10);
    if (s.from && isoDay < String(s.from).slice(0, 10))
        return false;
    if (s.until && isoDay > String(s.until).slice(0, 10))
        return false;
    const arcs = s.arcs || [];
    if (!arcs.length)
        return true;
    const wd = DAYNAMES[dt.getUTCDay()];
    return arcs.some(a => !(a.days || []).length || a.days.includes(wd));
}
// ═══ THE ROW MAKERS — every source object, through one door ═════════════════
export function slotRow(s, need, at) {
    const c = at || coordsOf(s);
    if (!c)
        return null;
    return { id: s.id, kind: need ? "need" : "means",
        emoji: s.emoji || (need ? "🌱" : "🤲"), name: s.name || s.spec,
        provider: need ? (s.who || "someone") : (s.owner || "the commons"),
        lat: c.lat, lng: c.lng, qty: s.qty, unit: s.unit, note: s.note,
        spec: s.spec, where: s.where || "", arcs: s.arcs || [], from: s.from, until: s.until,
        matched: s.matched, drawn: s.drawn, s };
}
export function placeRow(p, at) {
    const c = at || { lat: MAP_ANCHOR.lat + p.dLat, lng: MAP_ANCHOR.lng + p.dLng };
    // the id is the place's NAME: a pin on it survives the demo fabric
    // reordering its arrays, which a position never would (a MarkerPoint's own
    // `i` still names the marker's slot in that fabric — selection, placeElAt).
    return { id: `place:${p.name}`, kind: "place", emoji: p.emoji, name: p.name,
        provider: p.mode || "place", lat: c.lat, lng: c.lng,
        note: p.when, arcs: [], p, o: p.mode === "work" ? p : null };
}
export function offerRow(o, at) {
    // an offer without coordinates of its own always arrives with `at` supplied
    const c = at || { lat: MAP_ANCHOR.lat + o.at.dLat, lng: MAP_ANCHOR.lng + o.at.dLng };
    return { id: `offer:${o.label}@${o.t0}`, kind: "offer",
        emoji: o.kind === "work" ? "🛠" : "📅", name: o.label,
        provider: o.from || "you", lat: c.lat, lng: c.lng,
        note: o.place, arcs: [], t0: o.t0, t1: o.t1, o };
}
export function dropRow(c, at) {
    return { id: `drop:${c && c.id}`, kind: "drop", emoji: (c && c.emoji) || "📦",
        name: (c && c.name) || "a drop point", provider: "drop point",
        lat: at && at.lat, lng: at && at.lng,
        note: c && c.hint, arcs: [], c };
}
// a MARKER POINT (main.js markerPoints shapes), through the same door — the
// map's selection and the panel's are one row
export function rowOfPt(pt) {
    // Each point carries the fields its own kind needs, and all four builders are
    // handed the point's own coordinates — which MarkerPoint requires — so what
    // comes back is placed whenever it comes back at all. Only the pool branch
    // can answer null, and only for a slot with no location to begin with.
    const at = { lat: pt.lat, lng: pt.lng };
    const row = pt.kind === "pool" ? slotRow(pt.s, !!pt.need, at)
        : pt.kind === "place" ? placeRow(pt.p, at)
            : pt.kind === "drop" ? dropRow(pt.c, at)
                : offerRow(pt.o, at);
    return row;
}
// does a point pass a SearchFilter, through the row it converts to — the one
// check every search that touches the map makes (mapsearch's own pill,
// markers.ts ANDing the share drawer's onto it), factored so both read the
// same "no row ⇒ let it through, don't guess" rule rather than each other's copy.
export function passesFilter(pt, f) {
    if (!f.active())
        return true;
    const row = rowOfPt(pt);
    return row ? f.passes(row) : true;
}
// ═══ ROWS — everything searchable, one list ═════════════════════════════════
export function rows() {
    const out = [];
    const P = slotsPool();
    for (const s of (P.means || [])) {
        const r = slotRow(s, false);
        if (r)
            out.push(r);
    }
    for (const s of (P.needs || [])) {
        const r = slotRow(s, true);
        if (r)
            out.push(r);
    }
    for (const ps of Object.values(PLACES))
        ps.forEach(p => out.push(placeRow(p)));
    for (const o of [...evs, ...pending(), ...eligible])
        if (o.at)
            out.push(offerRow(o));
    return out;
}
/**
 * The places a person can name, nearest to `from` first: the commons' rows that `keep` admits and — when a name
 * is asked for — OpenStreetMap's places on the tiles the map holds whose name says `q`. A place that is both is
 * listed once. The search list and the route preview's two fields read through this.
 */
export function placesNear(from, q, map, keep, limit) {
    const seen = new Set();
    return [...rows().filter(keep), ...(map ? placesNamed(map, q) : [])]
        .filter(r => !r.id || !seen.has(r.id) && !!seen.add(r.id))
        .map(r => ({ ...r, km: havKm(from, r) }))
        .sort((x, y) => x.km - y.km)
        .slice(0, limit);
}
