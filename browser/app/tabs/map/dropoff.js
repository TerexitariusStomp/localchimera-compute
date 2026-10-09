// app/tabs/dropoff.ts — leaving things at places, and taking them away.
//
// This is a VIEW, and it invents nothing. A DROP POINT is any container
// standing at a place — a lending shelf, a street fridge, a left-luggage
// locker, a box under a bridge. In the model that is one EconomicResource
// conforming to a keep-in-place ResourceSpecification, and two recipes
// (knowledge/recipes/transport.scm):
//
//   recipe-hold    pickup → `use` the container → dropoff. Through a thing that
//                  stays put, so the engine tiles the arc through TIME: what you
//                  leave is still there tomorrow, having paid the container's
//                  own service for the stay.
//   recipe-carry   the same pair with no container, so the arc is through SPACE:
//                  somebody standing there walks it to where it is wanted, and
//                  the walk is paid in their hours.
//
// So `pickup` and `dropoff` are the whole vocabulary. What this face adds is a
// WAY OF INTERACTING with them, borrowed from geocaching, because geocaching
// worked out long ago how to make leaving things for strangers legible:
//
//   • you have to be there. A place with a boundary is one you must be standing
//     inside to open; further off you get the direction, the distance, and
//     whatever the place says about itself (its `note` — the hint).
//   • leave one to take one. Nothing in the model enforces it; it is the
//     etiquette that keeps a shared box from being emptied, so the view holds
//     the taker to their own leavings.
//   • the log is the record — who has opened it, what is in it now.
//
// And the move it is all for: INTO THE PLAN. Granting a commune custody of what
// you left (the ordinary custody attestation — `HANDLERS.socialize`, naming the
// resource) makes it stock at that place, and the solve draws on it where it
// lies. Ungranted, the same thing in the same box is invisible to the plan.
// Socializing is an act, and it is yours.
//
// It invents no wire either. Everything below is derived from the two the scope
// already publishes:
//
//   EXT.inventory.resources     service.scm `resource->inv-alist` — every
//                               resource with its `location`, its `contained-in`,
//                               its `custodian-scope`, and `container?` (its spec
//                               keeps what is in it in place)
//   snapshot.locations          service.scm `scope-locations->wire` — every place
//                               with its coordinates, its `note` and its
//                               `boundary`
//
// A drop point is one row crossed with the other: a CONTAINER at a PLACE. Its
// contents are the rows whose `contained-in` is it. Whether it is in the plan is
// its `custodian-scope`. The inventory face reads the same list by rail; this one
// reads it by where it stands. Offline, leaving and taking append rows of the
// same shape from localStorage, so both paths run through one derivation.
import { seam } from '../../seam.js';
import { HANDLERS, hint, USER, EXT } from '../../core.js';
// the map-data layer's shared pieces: THE coordinate ladder + the one haversine
import { coordsOf, havKm } from './atlas.js';
// spec → emoji: the inventory face's table, so a resource reads the same in the
// list and on the map (a live row carries no emoji of its own).
import { emojiFor } from '../../store-data.js';
// `render` here is this panel's own redraw, so the template renderer comes in
// under a different name.
import { html, render as paint } from '../../template.js';
import { readStr, writeStr, readJSON, writeJSON } from '../../store.js';
import { mk } from '../../dom.js';
import { on } from '../../bus.js';
import { scopeSig, scopeName } from '../../scope.js';
import { K } from "../../keys.js";
// ── who is playing ──────────────────────────────────────────────────────────
// the KERI identity when there is one (tabs/id.js stores `aid|name|email|k0`),
// else a local player — the log wants a stable name for a stasher either way.
function me() {
    const h = readStr(K.idHint);
    const aid = h && h.split("|")[0];
    if (aid)
        return aid;
    let anon = readStr(K.dropoffPlayer);
    if (!anon) {
        anon = "finder-" + Math.random().toString(36).slice(2, 6);
        writeStr(K.dropoffPlayer, anon);
    }
    return anon;
}
const shortName = (a) => (a || "").length > 14 ? (a || "").slice(0, 8) + "…" : (a || "someone");
// ── the fabric ──────────────────────────────────────────────────────────────
// One entry per drop point, in the shape the model writes it: the PLACE (id,
// name, its `note` as the hint, its `boundary` as the extent you must stand in)
// and whatever the container advertises about itself (`tags`, from the box's
// classifiers — shown if they are there, ignored if not).
//
// The demo places them as offsets from where you stand, as the dial's other
// places are (main.js ploc), so the fabric assembles wherever the map opens; a
// live drop point carries absolute coordinates and its own boundary, and is
// honoured as it is. Each names the place it stands in (`placeId`) — a
// classification path offline, a SpatialThing id live — so it nests in the
// containment overlay either way.
// (the demo discipline is atlas.js's, stated there once: real rows whenever
// the wire has them, this demo twin only when it brings nothing — see
// points()'s `live.length ? live : DEMO`, never row-mixed)
const DEMO = [
    { id: "shelf/bridge", name: "the box under the bridge", emoji: "🌉", dLat: 0.0007, dLng: 0.0006,
        placeId: "connection/community", tags: ["snug", "dry"],
        hint: "third pillar from the north bank, behind the loose brick" },
    { id: "shelf/oak", name: "the hollow oak", emoji: "🌳", dLat: -0.0011, dLng: 0.0013,
        placeId: "movement/walking", tags: ["seeds"],
        hint: "waist height, on the side the moss grows" },
    { id: "shelf/library", name: "the lending shelf", emoji: "📚", dLat: 0.0021, dLng: -0.0018,
        placeId: "learning/reading", tags: ["indoors", "9–20h"],
        hint: "inside the door, to the left" },
    { id: "fridge/corner", name: "the street fridge", emoji: "🧊", dLat: -0.0034, dLng: -0.0029,
        placeId: "nourishment/meals", tags: ["cold", "food only"],
        hint: "beside the bakery's back door" },
    { id: "shelf/allotment", name: "the allotment shed", emoji: "🛖", dLat: 0.0090, dLng: 0.0075,
        placeId: "nourishment/cooking", tags: ["tools"],
        hint: "the shelf behind the watering cans" },
];
// what each already holds — somebody was here before you
const SEED = [
    { point: "shelf/bridge", spec: "bread", name: "half a rye loaf", emoji: "🍞", qty: 1, unit: "each", by: "ada" },
    { point: "shelf/oak", spec: "seeds", name: "bean seeds", emoji: "🫘", qty: 40, unit: "each", by: "ada" },
    { point: "shelf/library", spec: "book", name: "a field guide", emoji: "📕", qty: 1, unit: "each", by: "sam" },
    { point: "fridge/corner", spec: "vegetable", name: "courgettes", emoji: "🥒", qty: 3, unit: "kg", by: "priya" },
    { point: "shelf/allotment", spec: "tool", name: "13mm spanner", emoji: "🔧", qty: 1, unit: "each", by: "sam" },
];
const KEY = K.dropoffLog;
const FIND_RADIUS_M = 120; // when a place carries no extent of its own
let LOG = []; // acts taken with no gateway to tell
let LOCAL_VISITS = []; // acts taken WITH one, this session (see `visits`)
let SOCIALIZED = {}; // resource id → the commune it is granted to
let ctx = null; // while the map face is up
let openId = null; // the drop point whose card is showing
let card = null, hud = null;
function load() {
    const s = readJSON(KEY, {});
    LOG = Array.isArray(s.log) ? s.log : [];
    SOCIALIZED = s.socialized || {};
    if (!LOG.length)
        LOG = SEED.map((s, i) => ({
            id: `seed${i}`, action: "dropoff", point: String(s.point), provider: s.by, receiver: String(s.point),
            spec: s.spec, name: s.name, emoji: s.emoji, qty: s.qty, unit: s.unit,
            resource: `${s.point}/seed${i}`, at: null,
        }));
}
const save = () => writeJSON(KEY, { log: LOG, socialized: SOCIALIZED });
// ── the two wires, and the join ─────────────────────────────────────────────
const liveRows = () => {
    const inv = EXT.inventory;
    return (inv && Array.isArray(inv.resources)) ? inv.resources : [];
};
const livePlaces = () => {
    const snap = seam.data && seam.data.snapshot;
    return (snap && Array.isArray(snap.locations)) ? snap.locations : [];
};
// the wire spells some fields with a dash and some hosts with a camel; read both
const F = (r, k) => r[k] ?? r[k.replace(/-(\w)/g, (_, c) => c.toUpperCase())];
const containedIn = (r) => F(r, "contained-in");
const onhandOf = (r) => Number(F(r, "onhand")) || 0;
// every row the view knows: what the scope holds, plus what you have left here
// yourself and the spine has not been told about yet.
const rows = () => liveRows().concat(localRows());
// A DROP POINT is a container standing at a place. `container?` comes off the
// spec's keep-in-place flag, so an EMPTY one is still one — a box you can leave
// something in is a box whether or not anybody has.
//
// WHERE a container is takes a climb, because resource containment is not
// spatial: a box may be in a van, a van in a yard, and only the yard is a place.
// So a container's place is its own `location`, else the location of whatever
// contains it — the browser twin of `containment-first` (aggregation/
// containment.scm), which socialization.scm already uses for exactly this ("the
// oven inherits the flat's location"). A container whose chain reaches no
// located thing is nowhere, and is simply not on a map.
//
// A container has no coordinates of its own; it has the coordinates of what
// holds it. Several standing in one place would therefore sit on one pixel, so
// siblings fan out around that point — far enough to be separately tappable,
// near enough to read as inside the place. THE fan-out, not one per surface:
// the map's markers and the containment regions both come from here, so they
// cannot disagree about where a box is.
const FAN_M = 18; // how far a sibling steps off centre
const MAX_CLIMB = 8; // cycle guard, as the Scheme climb has
// the nearest located thing at or above R, and the place it names
function placeOf(r, byId) {
    let x = r;
    for (let i = 0; x && i < MAX_CLIMB; i++) {
        const loc = F(x, "location");
        if (loc)
            return loc;
        x = byId.get(String(containedIn(x)));
    }
    return null;
}
function points() {
    const places = new Map(livePlaces().map(p => [String(p.id), p]));
    const all = rows();
    const byId = new Map(all.map(r => [String(r.id), r]));
    const byHolder = new Map();
    const live = all.filter(r => F(r, "container?") && placeOf(r, byId))
        .map(r => {
        const placeId = String(placeOf(r, byId));
        const p = places.get(placeId) || {};
        const lat = p.lat != null ? Number(p.lat) : NaN;
        const lng = (p.lng ?? p.long) != null ? Number(p.lng ?? p.long) : NaN;
        // fan apart from SIBLINGS — things sharing a holder — not from everything
        // sharing a place. A crate inside a van sits concentric with its van (it
        // really is there); two crates in one van, or two boxes in one yard, step
        // apart from each other.
        const hold = String(containedIn(r) || placeId);
        const k = (byHolder.get(hold) || 0);
        byHolder.set(hold, k + 1);
        const fan = fanOffset(k, lat);
        const held = containedIn(r);
        return {
            id: String(r.id), name: String(r.name || r.id), emoji: String(r.emoji || emojiFor(String(F(r, "conforms-to")))),
            placeId, heldBy: held != null ? String(held) : null, // the thing holding it, if a thing does
            lat: lat + fan.dLat, lng: lng + fan.dLng,
            hint: String(p.note || ""), boundary: p.boundary || null,
            tags: r.tags || [],
        };
    })
        .filter(c => isFinite(Number(c.lat)) && isFinite(Number(c.lng)));
    return live.length ? live : DEMO;
}
// the k-th sibling's step off its place's point: 0 stays put, the rest ring it
function fanOffset(k, lat) {
    if (!k || !isFinite(lat))
        return { dLat: 0, dLng: 0 };
    const a = (k - 1) * (2 * Math.PI / 6) + Math.PI / 6;
    const dLat = (FAN_M / 111320) * Math.sin(a);
    const dLng = (FAN_M / (111320 * Math.max(0.2, Math.cos(lat * Math.PI / 180)))) * Math.cos(a);
    return { dLat, dLng };
}
const pointById = (id) => points().find(c => c.id === id) || null;
// ── where you are, and how far that is ──────────────────────────────────────
// USER is the dial's own fix (geolocation when granted, the atlas home
// otherwise), mutated in place on every fix; a demo point's offset rides it, so
// a live point's absolute coordinates are honoured as they are.
// THE coordinate ladder (atlas): a live point's own lat/lng honoured as they
// are, a demo point's offset riding USER — one resolver, every reader
const coordOf = (c) => coordsOf(c);
// metres to a point, on geom's one haversine (atlas re-exports it)
const metresTo = (c) => havKm(USER, coordOf(c)) * 1000;
// ── the search: are you standing in it ─────────────────────────────────────
// A place's extent is its SpatialThing's BOUNDARY, so "am I close enough" is the
// ordinary point-in-extent question every bounded place answers. Ray casting over
// the ring; a place with no boundary falls back to the default radius.
function inExtent(lng, lat, ring) {
    let inside = false;
    for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
        const [xi, yi] = ring[i], [xj, yj] = ring[j];
        if ((yi > lat) !== (yj > lat) &&
            lng < ((xj - xi) * (lat - yi)) / (yj - yi) + xi)
            inside = !inside;
    }
    return inside;
}
function searchRing(c) {
    if (!c.boundary)
        return null;
    try {
        const g = typeof c.boundary === "string" ? JSON.parse(c.boundary) : c.boundary;
        return (g && g.coordinates && g.coordinates[0]) || null;
    }
    catch (_) {
        return null;
    }
}
const found = (c) => {
    const ring = searchRing(c);
    return ring ? inExtent(USER.lng, USER.lat, ring) : metresTo(c) <= FIND_RADIUS_M;
};
const fmtM = (m) => m < 1000 ? `${Math.round(m)} m` : `${(m / 1000).toFixed(1)} km`;
// ── the local log, folded into rows of the same wire shape ──────────────────
// A dropoff increments what is there, a pickup decrements it, an emptied one is
// gone — the ActionDefinition's own arithmetic (schemas.scm), done here so the
// view is playable before a gateway answers. What it produces is inventory rows,
// not a private shape, so `contents` below is one filter over one list.
function localRows() {
    const by = new Map();
    for (const ev of LOG) {
        const r = by.get(ev.resource);
        if (ev.action === "dropoff") {
            if (r)
                r.onhand = Number(r.onhand) + Number(ev.qty);
            else
                by.set(ev.resource, {
                    id: ev.resource, name: ev.name, emoji: ev.emoji,
                    "conforms-to": ev.spec, onhand: ev.qty, unit: ev.unit,
                    location: ev.place || null, "contained-in": ev.point,
                    custodian: ev.owner || null, // nobody, unless somebody claimed it
                    "custodian-scope": SOCIALIZED[ev.resource] || null,
                    "container?": false,
                });
        }
        else if (ev.action === "pickup" && r) {
            r.onhand = Math.max(0, Number(r.onhand) - Number(ev.qty));
        }
    }
    return [...by.values()].filter(r => Number(r.onhand) > 0);
}
// ── what there is to leave ──────────────────────────────────────────────────
// Things the books already know, that are not already inside something: what
// you hold, and what the commons holds. Leaving one of these MOVES it — its
// rights, its rail and its history come along untouched — which is the whole
// difference between carrying the commune's soup to a street fridge and
// quietly acquiring it.
function leavable() {
    const mine = me();
    return rows().filter(r => !F(r, "container?") && !containedIn(r) && onhandOf(r) > 0 &&
        (F(r, "primary-accountable") === mine || F(r, "custodian") === mine ||
            F(r, "custodian-scope") === (scopeSig() || "")))
        .map((r) => ({
        id: r.id, name: String(r.name || r.id), spec: String(F(r, "conforms-to") || ""),
        emoji: String(r.emoji || emojiFor(String(F(r, "conforms-to")))),
        qty: onhandOf(r), unit: String(r.unit || ""),
        whose: F(r, "custodian-scope") === (scopeSig() || "") ? "the commons" : "yours",
    }));
}
// what is in a drop point: one filter over the one list.
function contents(pointId) {
    return rows()
        .filter(r => containedIn(r) === pointId && onhandOf(r) > 0)
        .map((r) => ({
        id: r.id, spec: String(F(r, "conforms-to") || ""), name: String(r.name || r.id),
        emoji: String(r.emoji || emojiFor(String(F(r, "conforms-to")))), qty: onhandOf(r), unit: String(r.unit || ""),
        // who owns it — the rights field itself, never `custodian` (which falls
        // back to the custodian SCOPE, i.e. the box, when nobody is accountable)
        owner: String(F(r, "primary-accountable") || ""),
        ownerName: String(F(r, "custodian-name") || F(r, "primary-accountable") || ""),
        inPlan: F(r, "custodian-scope") || null,
    }));
}
// ── the swap ledger, and who has opened this ────────────────────────────────
// Both read the acts THIS person can see: the local log (offline) plus what
// they have done here this session (connected — the ledger records the events,
// but who-opened-what is not on the inventory wire, so the card is honest about
// knowing only its own visits until it is).
const visits = (pointId) => LOG.filter(ev => ev.point === pointId)
    .map((ev) => ({ action: ev.action, point: ev.point,
    who: ev.action === "dropoff" ? ev.provider : ev.receiver }))
    .concat(LOCAL_VISITS.filter(v => v.point === pointId));
function balance(pointId, who = me()) {
    return visits(pointId).reduce((n, v) => v.who !== who ? n
        : v.action === "dropoff" ? n + 1 : n - 1, 0);
}
function finders(pointId) {
    const out = [];
    for (const v of visits(pointId))
        if (v.who && !out.includes(v.who))
            out.push(v.who);
    // whoever left what is in it now, from the ledger itself
    for (const r of contents(pointId))
        if (r.owner) {
            const o = String(r.owner);
            if (!out.includes(o))
                out.push(o);
        }
    return out;
}
const opened = (pointId) => finders(pointId).includes(me());
// ── the acts ────────────────────────────────────────────────────────────────
// One path, two endings. Connected, the act IS the EconomicEvent: the spine
// records it (planner service `drop-event`), the observer applies the
// ActionDefinition, a fresh snapshot comes back, and the box redraws from the
// ledger. Offline, the same act becomes a local row of the same wire shape so
// the map stays playable — and says so, rather than pretending it landed.
const evId = () => "ev" + Date.now().toString(36) + Math.random().toString(36).slice(2, 5);
const online = () => !!(HANDLERS.dropEvent && scopeSig());
async function act(action, pointId, item, rid) {
    // moving a thing the books already hold names it; introducing one does not,
    // and may carry a claim (item.mine === "mine") — never a default
    const resourceId = item.resource || rid || "";
    if (!online()) { // the local log is the whole truth here
        const at = pointById(pointId);
        LOG.push({ id: evId(), action, point: pointId,
            provider: action === "dropoff" ? me() : pointId,
            receiver: action === "dropoff" ? pointId : me(),
            spec: item.spec, name: item.name, emoji: item.emoji,
            qty: item.qty, unit: item.unit, resource: resourceId,
            owner: item.mine === "mine" ? me() : null,
            place: (at && at.placeId) || pointId, at: new Date().toISOString() });
        save();
        render();
        return true;
    }
    const reply = await HANDLERS.dropEvent(action, pointId, item.spec, item.qty, item.unit, resourceId, item.mine || "");
    if (typeof reply === "string" && reply.startsWith("err:")) {
        hint(reply.slice(4) || "the commons did not record that", "error");
        return false;
    }
    // the snapshot the write triggered repaints through onInventory; this keeps
    // the card honest in the gap before it lands
    LOCAL_VISITS.push({ action, point: pointId, who: me() });
    render();
    return true;
}
function drop(pointId, item) { act("dropoff", pointId, item, `${pointId}/${evId()}`); }
function take(pointId, r) {
    if (balance(pointId) <= 0) {
        hint("leave something first — a shared box stays full because everyone who takes also leaves", "warn");
        return;
    }
    act("pickup", pointId, r, r.id);
}
// ── into the plan ───────────────────────────────────────────────────────────
// The real socialization path: a custody attestation over the stashed resource,
// issued to the selected scope. The planner then reads the stash as located
// stock at that place — the same grant the share face lends a workshop with,
// pointed at a thing you left in a box.
async function socialize(r) {
    const commune = scopeSig() || "";
    if (!HANDLERS.socialize || !commune) { // offline: the grant is local
        SOCIALIZED[String(r.id)] = "the commons";
        save();
        render();
        hint(`${r.name} is in the plan — offline, so the grant is local until you connect`, "warn");
        return;
    }
    const reply = await HANDLERS.socialize(commune, r.spec, r.qty, "", false, "", "", r.id);
    if (reply === "ok") {
        SOCIALIZED[String(r.id)] = scopeName();
        save();
        render();
        hint(`${r.name} is now ${scopeName()}'s to draw on — you still own it`, "success");
    }
    else {
        hint(String(reply).replace(/^err:/, "") || "the grant did not go through", "error");
    }
}
// whatever the container says about itself — cold, indoors, tools, open 9–20h.
// Shown when it is there and simply absent when it is not: the view asks the
// model for nothing it has not volunteered.
const tagHtml = (c, limit) => ((c.tags || []).slice(0, limit || 3))
    .map(t => html `<span class="drop-tag">${t}</span>`);
export function dropPoints() {
    return points().map(c => {
        // points() has already filtered to those with finite coordinates
        const q = coordOf(c);
        return { lng: q.lng, lat: q.lat, kind: "drop", c, m: metresTo(c) };
    });
}
/** The drop's label, as the map draws it: near, its name and count; far, its distance and first tag. */
export function dropLabel(pt) {
    const c = pt.c;
    return found(c)
        ? { text: `${c.name} · ${contents(c.id).length}`, ink: "#7a5a2e" }
        : { text: `${fmtM(pt.m)}${(c.tags || []).length ? " · " + (c.tags || [])[0] : ""}`, ink: "#7a5a2e" };
}
export function dropEl(pt) {
    const c = pt.c, near = found(c);
    const el = document.createElement("div");
    el.className = "drop-marker" + (near ? " near" : " far") +
        (opened(c.id) ? " opened" : "") + (openId === c.id ? " sel" : "");
    // Far away you get the region, not the spot: a ring the size of the search,
    // the ratings and the distance. Near enough, the box itself, and what's in it.
    // a point's name, hint and tags are wire text — whoever registered the box
    // wrote them — so they land escaped, as content.
    paint(el, near ? html `<div class="drop-icon">${c.emoji}</div>` : html `<div class="drop-ring">?</div>`);
    el.title = near ? `${c.name} — open it` : `${c.name} — ${fmtM(pt.m)} away · ${c.hint}`;
    el.onclick = e => {
        e.stopPropagation();
        if (!near) {
            hint(`${c.name} — ${fmtM(pt.m)} off. ${c.hint}`);
            return;
        }
        openId = openId === c.id ? null : c.id;
        render();
    };
    return el;
}
// ── the card: what is in it, and what you can do ────────────────────────────
function ensureCard() {
    if (card)
        return card;
    // inside the map's own container, as the edge-indicator markers are: it then
    // rides the map into fullscreen instead of being left behind under it
    const wrap = document.getElementById("maptab"); // drops mount on the map tab only
    if (!wrap)
        return null;
    const el = mk("div", "drop-card");
    el.style.display = "none";
    wrap.appendChild(el);
    card = el;
    return el;
}
function ensureHud() {
    if (hud)
        return hud;
    // inside the map's own container, as the edge-indicator markers are: it then
    // rides the map into fullscreen instead of being left behind under it
    const wrap = document.getElementById("maptab"); // drops mount on the map tab only
    if (!wrap)
        return null;
    hud = mk("div", "drop-hud");
    wrap.appendChild(hud);
    return hud;
}
function drawHud() {
    // TEMPORARILY OFF: the geocache score strip yielded its top-of-map spot to
    // the search panel (app/tabs/mapsearch.js). Un-comment the body to bring
    // the found/stashed/in-plan/nearest chips back.
    return;
    /* eslint-disable no-unreachable */
    const h = ensureHud();
    if (!h)
        return;
    const all = points();
    const mine = LOG.filter(e => e.action === "dropoff" && e.provider === me());
    const opens = all.filter(c => opened(c.id)).length;
    const inPlan = all.reduce((n, c) => n + contents(c.id).filter(r => r.inPlan || SOCIALIZED[String(r.id)]).length, 0);
    const near = all.map(c => ({ c, m: metresTo(c) })).sort((a, b) => a.m - b.m)[0];
    paint(h, html `
    <span class="drop-score"><b>${opens}</b>/${all.length} found</span>
    <span class="drop-score"><b>${mine.length}</b> stashed</span>
    <span class="drop-score in-plan"><b>${inPlan}</b> in the plan</span>${near ? html `<span class="drop-near">nearest · ${near.c.emoji} ${near.c.name} ${fmtM(near.m)}</span>` : ""}`);
    /* eslint-enable no-unreachable */
}
function drawCard() {
    const el = ensureCard();
    if (!el)
        return;
    const c = openId && pointById(openId);
    if (!c) {
        el.style.display = "none";
        return;
    }
    el.style.display = "block";
    el.innerHTML = "";
    const head = mk("div", "drop-head");
    paint(head, html `
    <span class="drop-head-emoji">${c.emoji}</span>
    <span class="drop-head-name">${c.name}</span>${tagHtml(c)}
    <span class="drop-head-dist">${fmtM(metresTo(c))}</span>`);
    const close = mk("a", "drop-close", "×");
    close.onclick = () => { openId = null; render(); };
    head.appendChild(close);
    el.appendChild(head);
    el.appendChild(mk("div", "drop-hint", c.hint));
    const fs = finders(c.id);
    el.appendChild(mk("div", "drop-finders", fs.length ? `found by ${fs.map(shortName).join(", ")}` : "nobody has opened this yet — first find"));
    // what is in the box: each row is one stashed EconomicResource, held by the
    // box and owned by whoever left it.
    const list = mk("div", "drop-list");
    const items = contents(c.id);
    const bal = balance(c.id);
    if (!items.length)
        list.appendChild(mk("div", "drop-empty", "empty — leave something and it starts again"));
    for (const r of items) {
        const row = mk("div", "drop-row");
        // the resource's name and its owner's name belong to whoever left it here
        paint(row, html `
      <span class="dr-emoji">${r.emoji || "📦"}</span>
      <span class="dr-name">${r.name}<span class="dr-owner">${r.owner === (scopeSig() || "\u0000") ? "the commons'"
            : r.owner ? "left by " + shortName(String(r.ownerName || r.owner)) : "unclaimed"}</span></span>
      <span class="dr-qty">${Number(r.qty).toLocaleString()} ${r.unit}</span>`);
        const acts = mk("span", "dr-acts");
        const takeBtn = mk("button", "dr-take", "take");
        takeBtn.disabled = bal <= 0;
        takeBtn.title = bal > 0 ? "pick it up — custody passes to you"
            : "leave something first: take one, leave one";
        takeBtn.onclick = () => take(c.id, r);
        acts.appendChild(takeBtn);
        // yours to grant: only what you left is yours to put into the plan
        // in the plan = a custodian-scope on the row (the live custody grant), or a
        // grant made here that the spine has not answered for yet
        const holder = r.inPlan || SOCIALIZED[String(r.id)];
        if (holder) {
            const tag = mk("span", "dr-inplan", "in the plan");
            tag.title = `${holder} holds it where it lies and the solve can draw on it — the rights stay yours`;
            acts.appendChild(tag);
        }
        else if (r.owner === me()) {
            // only what you OWN is yours to lend: a grant reaches only what its issuer
            // holds the rights to (%grant-over?), so offering it otherwise would offer
            // an act that quietly does nothing. A thing that is already the commons'
            // needs no grant — the plan can draw on it where it lies.
            const soc = mk("button", "dr-social", "into the plan");
            soc.title = `grant ${scopeName()} custody — the plan can draw on it where it lies, and you keep the rights`;
            soc.onclick = () => socialize(r);
            acts.appendChild(soc);
        }
        row.appendChild(acts);
        list.appendChild(row);
    }
    el.appendChild(list);
    // leaving something: one line, the same shape the share face declares with
    // Leaving something. Typing the name of a thing the books already hold MOVES
    // that thing; typing anything else introduces one — and only then is there a
    // question of whose it is, answered by a chip that says "nobody's" until
    // somebody claims otherwise. Putting a thing down is not how people come to
    // own things, so the claim is never the default.
    const pill = mk("div", "drop-pill");
    const held = leavable();
    const emoji = mk("input", "drop-in-emoji");
    emoji.placeholder = "📦";
    emoji.maxLength = 4;
    const name = mk("input", "drop-in-name");
    name.placeholder = held.length ? "leave something you hold, or name a new thing…"
        : "leave something…";
    name.setAttribute("list", "drop-held");
    const dl = mk("datalist");
    dl.id = "drop-held";
    held.forEach(h => {
        const o = document.createElement("option");
        o.value = String(h.name);
        o.label = `${h.qty} ${h.unit} · ${h.whose}`;
        dl.appendChild(o);
    });
    const qty = mk("input", "drop-in-qty");
    qty.type = "number";
    qty.min = "0";
    qty.step = "any";
    qty.value = "1";
    const unit = mk("input", "drop-in-unit");
    unit.placeholder = "each";
    unit.value = "each";
    // Whose is it? Asked only of a thing the books have never seen, and answered
    // "the commons'" until somebody says otherwise: a public box is a common
    // thing, and what you put in it claiming nothing joins the commons rather
    // than becoming the property of whoever last touched it. One tap says
    // otherwise, so this takes nothing that was not given — but it says what it
    // is doing rather than deciding quietly.
    let claimed = false;
    const claim = mk("a", "drop-claim", "the commons'");
    claim.title = "whose is it? — unclaimed, it joins the commons; tap to keep it yours";
    const matched = () => held.find(h => String(h.name).toLowerCase() === name.value.trim().toLowerCase());
    const restyle = () => {
        const m = matched();
        claim.style.display = m ? "none" : ""; // a thing that exists already has an answer
        claim.textContent = claimed ? "mine" : "the commons'";
        claim.classList.toggle("on", claimed);
        unit.disabled = !!m;
        emoji.disabled = !!m; // a known thing brings its own
        if (m) {
            unit.value = m.unit || "each";
            emoji.value = m.emoji || "";
        }
    };
    claim.addEventListener("click", () => { claimed = !claimed; restyle(); });
    name.addEventListener("input", restyle);
    const add = mk("button", "drop-leave", "leave it");
    const submit = () => {
        const t = name.value.trim();
        if (!t)
            return;
        const m = matched();
        drop(c.id, m
            ? { spec: m.spec, name: m.name, emoji: m.emoji, unit: m.unit,
                qty: Math.min(Number(qty.value) || 1, Number(m.qty)), resource: m.id, mine: "" }
            : { spec: t.toLowerCase().replace(/\s+/g, "-"), name: t,
                emoji: emoji.value || "📦", qty: +qty.value || 1,
                unit: unit.value || "each", mine: claimed ? "mine" : "" });
        name.value = "";
        emoji.value = "";
        qty.value = "1";
        claimed = false;
        restyle();
    };
    add.onclick = submit;
    for (const i of [name, emoji, unit, qty])
        i.addEventListener("keydown", e => { if (e.key === "Enter")
            submit(); });
    pill.append(emoji, name, qty, unit, claim, add, dl);
    restyle();
    el.appendChild(pill);
    el.appendChild(mk("div", "drop-foot", bal > 0 ? `you have left ${bal} more than you have taken here — take away`
        : "leave one to take one: that is what keeps a shared box full"));
}
function render() {
    drawHud();
    drawCard();
    // the open box lights its own region in the containment overlay — one id, a
    // repaint, no re-render (see containers.js setSelected)
    if (ctx && ctx.select)
        ctx.select(openId);
    if (ctx && ctx.refresh)
        ctx.refresh(); // markers restyle (selection, counts)
}
// ── mount / unmount with the map face ───────────────────────────────────────
// a fresh scope snapshot means new containers, new contents, new custody — the
// map redraws off the same push the inventory list does.
on("inventory", () => { if (ctx)
    render(); });
export function mountDrops(c) {
    ctx = c;
    if (!LOG.length)
        load();
    const h = ensureHud();
    if (h)
        h.style.display = "flex";
    render();
}
export function unmountDrops() {
    openId = null;
    ctx = null;
    if (card)
        card.style.display = "none";
    if (hud)
        hud.style.display = "none";
}
load();
