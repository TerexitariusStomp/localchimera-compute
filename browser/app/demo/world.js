// app/demo/world.ts — the demo world: one set of people, places and goods.
//
// Offline, every face shows the same neighbourhood: its places on the map are the
// places the store holds stock at, the goods the Resources face lists are the goods
// those stocks conform to, and the people who offer, ask, count and contest are the
// same people everywhere. The people, the places, the venues, the goods and what
// the ledger holds of each are read off the recording of the demo neighbourhood
// (demo/recording.ts, from module/playnet/planner/knowledge/worlds/demo-neighbourhood.scm),
// the same world a gateway adopts as the preset `neighbourhood`.
//
// Pure data and small derivations: type-only imports, no DOM, no signals, so a
// node test reads the whole world (tests/browser/demo-world-test.mjs).
import { RECORDING } from "./recording.js";
const FACE = RECORDING.face;
/** The person the demo is seen through. */
export const YOU = FACE.you;
export const PEOPLE = FACE.people.map(p => ({ id: p.id, name: p.name }));
/** The name a person is shown by; the id itself for one the world does not hold. */
export const personName = (id) => PEOPLE.find(p => p.id === id)?.name ?? id;
const PLACE_EMOJI = FACE.places;
export const WORLD_PLACES = RECORDING.snapshot.locations.map(l => ({
    id: l.id, name: l.name, emoji: PLACE_EMOJI[l.id] ?? "📍",
    containedIn: l.containedIn ?? null,
    dLat: Number(l.lat), dLng: Number(l.lng),
}));
/** The venues, in the order a need lists them. */
export const VENUES = FACE.venues
    .map(v => ({ place: v.place, leaf: v.leaf, mode: v.mode, when: v.when,
    ...(v.name ? { name: v.name } : {}), ...(v.emoji ? { emoji: v.emoji } : {}) }));
/** The place ID names, or undefined. */
export const placeOf = (id) => WORLD_PLACES.find(p => p.id === id);
/** The venues of each taxonomy leaf, in order: what a need opens onto. */
export function venuesByLeaf() {
    const out = {};
    for (const v of VENUES) {
        const p = placeOf(v.place);
        if (!p)
            continue;
        (out[v.leaf] ??= []).push({ dLat: p.dLat, dLng: p.dLng, name: v.name ?? p.name, emoji: v.emoji ?? p.emoji,
            when: v.when, mode: v.mode, place: p.id });
    }
    return out;
}
// The pool is the recording's: each person's needs and offers as their own slots
// door answered them once declared, so a slot's id, quantity, place and hours are
// the planner's. What a solve would say of a lent means (how much of it
// is taken, until when it is lent, which need it answers) is stated here.
const LENT = {
    "means:ana:spec-bed": { drawn: 0.5, untilDays: 60 },
    "means:sam:spec-bed": { drawn: 1, untilDays: 21 },
    "means:meiers:spec-workshop": { drawn: 0 },
    "means:bob:spec-cargo-bike": { drawn: 0 },
};
const MATCHED = {
    "need:you:spec-shelter": "means:ana:spec-bed",
    "need:priya:spec-shelter": "means:sam:spec-bed",
};
const MAP_NAME = { "need:you:spec-shelter": "your housing need" };
const DAY_MS = 86400000;
const daysOn = (date) => date ? Math.round((Date.parse(`${date.slice(0, 10)}T00:00:00Z`) - Date.parse(`${RECORDING.day}T00:00:00Z`)) / DAY_MS) : undefined;
const slotOfWire = (kind) => (r) => {
    const lent = LENT[r.id];
    const untilDays = lent?.untilDays ?? daysOn(r.until);
    return {
        id: r.id, kind, person: (kind === "need" ? r.who : r.owner) ?? "", spec: r.spec, name: r.name, emoji: r.emoji, note: r.note,
        qty: Number(r.qty) || 0, unit: r.unit, cats: [...r.cats],
        arcs: r.arcs.map(a => ({ start: a.start, end: a.end, days: [...a.days] })),
        ...(r.where ? { place: r.where } : {}),
        ...(lent ? { socialized: true, drawn: lent.drawn } : {}),
        ...(untilDays !== undefined ? { untilDays } : {}),
        ...(MATCHED[r.id] ? { matched: MATCHED[r.id] } : {}),
        ...(MAP_NAME[r.id] ? { mapName: MAP_NAME[r.id] } : {}),
    };
};
const POOL = RECORDING.pool;
export const SLOTS = [
    ...POOL.needs.map(slotOfWire("need")),
    ...POOL.means.map(slotOfWire("means")),
];
/** The slot ID names, or undefined. */
export const slotOf = (id) => SLOTS.find(s => s.id === id);
/** The scope's whole pool: every need and every declared means, as the share bar and the match ring read it. */
export function scopePool() {
    const row = (s) => ({
        id: s.id, spec: s.spec, name: s.name, emoji: s.emoji, note: s.note, qty: s.qty, unit: s.unit, cats: s.cats, arcs: s.arcs,
        ...(s.kind === "need" ? { who: s.person } : { owner: s.person }),
    });
    return { needs: SLOTS.filter(s => s.kind === "need").map(row), means: SLOTS.filter(s => s.kind === "means").map(row) };
}
/**
 * What stands at a place: every need that names one, and the means socialized
 * into the commons. ISO gives the date a count of days from today falls on.
 */
export function mapPool(iso) {
    const row = (s) => {
        const p = s.place ? placeOf(s.place) : undefined;
        if (!p)
            return [];
        return [{
                id: s.id, spec: s.spec, name: s.mapName ?? s.name, emoji: s.emoji, qty: s.qty, unit: s.unit,
                ...(s.arcs.length ? { arcs: s.arcs } : {}),
                ...(s.kind === "need" ? { who: personName(s.person) } : { owner: personName(s.person) }),
                ...(s.drawn !== undefined ? { drawn: s.drawn } : {}),
                ...(s.untilDays !== undefined ? { until: iso(s.untilDays) } : {}),
                ...(s.matched ? { matched: slotOf(s.matched)?.name ?? s.matched } : {}),
                dLat: p.dLat, dLng: p.dLng,
            }];
    };
    return { needs: SLOTS.filter(s => s.kind === "need").flatMap(row),
        means: SLOTS.filter(s => s.kind === "means" && s.socialized).flatMap(row) };
}
// ── the demo claimable catalogue ───────────────────────────────────────────
// The goods a person claims against credit: those the commons holds a claimable
// stock of. The Resources face reads them for its standalone book and the dial's
// spend wheel reads them so the experiment breathes offline too.
const STOCKS = RECORDING.snapshot.inventory.resources;
const CLAIMABLE = "individual-claimable";
// the commons' stocks of a good: a person's own offer of it is theirs, and is on the books under their name
const stocksOf = (spec) => STOCKS.filter(r => r["conforms-to"] === spec && r["custodian-name"] === FACE.commons);
/** What the demo commons holds of the good SPEC: the sum of its stocks on the books. */
export const demoHeld = (spec) => stocksOf(spec).reduce((a, r) => a + (Number(r.onhand) || 0), 0);
// What the demo scope keeps of a good for production and the reserve, by spec:
// the social portion the Resources face shows beside the individual one.
export const DEMO_KEPT_BY_SPEC = { "spec-bread": 80, "spec-veg": 120 };
/** A communal good the scope shares part of out against credit. */
function demoHeldCommunal(spec) { return spec in DEMO_KEPT_BY_SPEC; }
/** Every good the neighbourhood holds a stock of. */
export const GOODS = FACE.goods
    .map(g => ({ id: g.id, name: g.name, unit: g.unit, snlt: g.snlt, cats: [...g.cats], emoji: g.emoji, ...(g.external ? { external: true } : {}) }));
/** The goods a person claims against credit. */
export const DEMO_SPECS = GOODS
    .filter(g => stocksOf(g.id).some(r => r["distribution-mode"] === CLAIMABLE) || demoHeldCommunal(g.id));
// How far each good's standing demand is met, where the demo states one.
const MET = { "spec-bread": 0.80, "spec-veg": 0.90, "spec-tea": 0.65, "spec-fabric": 0.90, "spec-coat": 0.50, "spec-chair": 0.50 };
/** One claimable resource per good: what is shared out of it, the kept portion aside. */
export const DEMO_RESOURCES = DEMO_SPECS.map(sp => ({
    id: `r-${sp.id.replace(/^spec-/, "")}-1`, spec: sp.id,
    onhand: Math.max(0, demoHeld(sp.id) - (DEMO_KEPT_BY_SPEC[sp.id] ?? 0)),
    mode: "individual-claimable", met: MET[sp.id] ?? 1,
}));
