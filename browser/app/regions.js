// app/regions.ts — the containment forest the map draws.
//
// ── THREE TREES MEET ON THIS MAP AND THEY ARE NOT THE SAME RELATION ─────────
//
//   places   SpatialThing.contained-in — GEOGRAPHY. This is what the hulls nest,
//            and the only one of the three that is inherently spatial.
//   scopes   the federation tree (vf/aggregation/scope-tree.scm) — where demand and
//            labour actually aggregate. A scope is a container of a governance
//            kind; most containers are not scopes.
//   things   EconomicResource.contained-in — the MEREOLOGY of stuff: a box in a
//            van, a nutrient in a carrot. Not spatial, not a scope, and a thing
//            here may have no place of its own at all.
//
// The map is a SPATIAL view, so a thing enters it only through where it is — its
// own location, else the location of whatever holds it. It then hangs off the
// thing that actually holds it when that thing is on the map too, and off its
// place otherwise. What is INSIDE a container is not drawn as geography at all;
// that is the card's job, because containment of stuff is not a shape on the
// ground.
//
// ── REGIONS ARE DATA, NOT CODE ──────────────────────────────────────────────
// A region's extent is a real published polygon (data/geo/boundaries.json), and
// each feature may DECLARE a finer layer of its own
// (properties.ecoregions = "<id>-ecoregions.json"), nested through containedIn.
// So adding a bioregion's ecoregions is a file plus a declaration — nothing here
// is per-region, and nothing here names one.
//
// Containment is then DERIVED rather than asserted: a scope is contained-in the
// deepest published region whose polygon holds its coordinate. That is why the
// region the map draws is the SAME object, by id, that the planner reasons about.
import { S } from './state.js';
import { PLACES, USER } from './core.js';
import { seam } from './seam.js';
import { colorFor } from './palette.js';
import { isWilling } from './willingness.js';
import { DEMO_BIOREGION_SCOPES } from './demo.js';
import * as containers from './tabs/map/containers.js';
import * as dropoff from './tabs/map/dropoff.js';
let REGIONS = [];
let host;
/**
 * A SpatialThing's EXTENT off the wire. schemas.scm carries `boundary` as a
 * GeoJSON geometry, and it rides as a JSON STRING because the wire encodes
 * floats that way. Absent, or unparseable, means a point — which is a shape the
 * overlay handles, so there is nothing to report.
 */
const parseBoundary = (b) => {
    if (!b)
        return undefined;
    // The cast is the wire's claim, not this module's: schemas.scm says `boundary`
    // is a GeoJSON geometry. inGeometry narrows on `type` at runtime anyway, and
    // answers false for anything it does not recognise.
    try {
        return (typeof b === "string" ? JSON.parse(b) : b);
    }
    catch {
        return undefined;
    }
};
/**
 * The DEEPEST region holding a coordinate: among every region whose polygon
 * contains it, the most specific — a child ecoregion beats its parent
 * bioregion. So a scope nests in its ecoregion, which nests in its bioregion,
 * and none of that is named here.
 */
export function deepestRegionAt(lng, lat, regions = REGIONS) {
    const hits = regions.filter(r => r.boundary && containers.inGeometry(lng, lat, r.boundary));
    if (!hits.length)
        return null;
    // The deepest hit is the one NO other hit claims as its parent — a leaf of the
    // containment chain that holds this point.
    //
    // Asking it the other way round ("a hit whose parent is also a hit") answers
    // the first such hit, which is the deepest only when there are exactly TWO
    // tiers. With bioregion ⊃ ecoregion ⊃ district it returns the middle one, and
    // which one it returns depends on the order the layer files happened to load
    // in — so a farm would file one tier too coarse, silently, and differently
    // after a rename.
    const claimed = new Set(hits.map(h => h.parent).filter(Boolean));
    return (hits.find(h => !claimed.has(h.id)) || hits[0]).id;
}
/**
 * Attach real extents, and DERIVE containment from geography.
 *
 * Generic over any region layer — bioregions, their ecoregions, nations. Every
 * region becomes a node carrying its true shape, and every non-region node with
 * a coordinate is attached to the deepest region that holds it, unless it
 * already names a parent the set contains.
 *
 * MUTATES and returns `nodes`, because the caller built the array for this.
 */
export function regionalize(nodes, regions = REGIONS) {
    if (!regions.length)
        return nodes;
    const byId = new Map(nodes.map(n => [n.id, n]));
    const regionIds = new Set(regions.map(r => r.id));
    // 1. a node for EVERY region, nested by its own containedIn — the extent basemap
    for (const r of regions) {
        const node = byId.get(r.id)
            || { id: r.id, name: r.name, parent: r.parent ?? null, lat: NaN, lng: NaN };
        if (!node.boundary)
            node.boundary = r.boundary;
        if (node.parent == null && r.parent != null)
            node.parent = r.parent;
        byId.set(r.id, node);
        if (!nodes.includes(node))
            nodes.push(node);
    }
    // 2. attach each non-region node to the deepest region that holds it
    for (const n of nodes.slice()) {
        if (regionIds.has(n.id) || !(isFinite(n.lat) && isFinite(n.lng)))
            continue;
        const r = deepestRegionAt(n.lng, n.lat, regions);
        // An asserted parent wins — but only if it is a parent the forest HAS.
        if (r && (n.parent == null || !byId.has(n.parent)))
            n.parent = r;
    }
    return nodes;
}
/**
 * The located containers, as nodes of the same forest.
 *
 * Coordinates come from dropoff.js — the single derivation of where a container
 * is — so the region and the marker cannot disagree. Colour is its own (a thing,
 * not a place), and `desire: null` keeps it out of the per-place fill the hulls
 * are tinted by: a box is not a need anybody has failed to meet.
 */
function containerRegionNodes() {
    try {
        const pts = dropoff.dropPoints();
        const mapped = new Set(pts.map(pt => pt.c.id));
        return pts.map(pt => ({
            id: pt.c.id, name: pt.c.name,
            parent: (pt.c.heldBy && mapped.has(pt.c.heldBy))
                ? pt.c.heldBy : (pt.c.placeId ?? null),
            lat: pt.lat, lng: pt.lng,
            color: colorFor("drop point") || "#7a5a2e", desire: null,
        })).filter(n => n.parent && isFinite(n.lat) && isFinite(n.lng));
    }
    catch (_) {
        return [];
    }
}
/**
 * The forest itself: LIVE from the scope snapshot's SpatialThings when a gateway
 * is connected, else from the dial's own PLACES — whose "a/b/c" keys ARE a
 * containment path, so the demo nests for free (learning ⊃ learning/practice ⊃
 * its venues).
 */
export function containerNodes() {
    const snap = seam.data && seam.data.snapshot;
    const L = snap && snap.locations;
    if (Array.isArray(L) && L.length) {
        return regionalize(L.map((x) => {
            const s = parseFloat(String(x.slack)); // per-place demand shortfall met∕want
            return {
                id: x.id, name: x.name || x.id,
                lat: parseFloat(String(x.lat)), lng: parseFloat(String(x.lng ?? x.long)),
                parent: x.containedIn ?? null,
                desire: isFinite(s) ? s : 1, // no demand recorded there → whole
                boundary: parseBoundary(x.boundary),
            };
        }).concat(containerRegionNodes()));
    }
    const nodes = new Map();
    const ensure = (id, name, parent) => {
        if (!nodes.has(id))
            nodes.set(id, { id, name, parent, lat: NaN, lng: NaN });
    };
    const addContainers = () => containerRegionNodes().forEach(n => { if (nodes.has(n.parent))
        nodes.set(n.id, n); });
    for (const [key, places] of Object.entries(PLACES)) {
        const segs = key.split("/");
        let parent = null, path = "";
        segs.forEach((sg, i) => { path = i ? `${path}/${sg}` : sg; ensure(path, sg, parent); parent = path; });
        (places || []).forEach((p, i) => nodes.set(`${key}#${i}`, {
            id: `${key}#${i}`, name: p.name, parent: key,
            lat: USER.lat + p.dLat, lng: USER.lng + p.dLng, place: p,
        }));
    }
    // Demo scopes at ABSOLUTE coordinates (independent of the viewer), so each
    // bioregion's REAL polygon renders around a live scope — a concave published
    // boundary holding the scope's hulls, not a hull of the scope.
    DEMO_BIOREGION_SCOPES.forEach(({ root, plots }) => {
        nodes.set(root.id, { ...root, parent: null });
        plots.forEach(p => nodes.set(p.id, { ...p, parent: root.id }));
    });
    addContainers(); // the boxes standing in those places, nesting as they do live
    return regionalize([...nodes.values()]);
}
/**
 * A leaf's desire ∈ (0,1]: a strained work-intent nobody has taken reads low
 * (red); a fulfilled or commons place reads high (green). The overlay folds
 * these up the tree by GEOMETRIC MEAN — worst-off-leaning, the same aggregate
 * the fragility wheel completes.
 */
export function leafDesire(node) {
    // The overlay walks the forest THIS module built, so every node it hands back
    // is one of ours. The widening to TreeNode is the overlay's signature — it
    // does not know whose nodes it is folding — not a different set of objects.
    const n = node;
    if (n.place)
        return isWilling(n.place) ? 0.95
            : n.place.mode === "work" ? 0.42 : 0.82;
    // null is a node that is a THING rather than a place: it nests, it draws, and
    // it counts toward nobody's fill.
    return n.desire === null ? null : (n.desire != null ? n.desire : 1);
}
/** Rebuild and repaint the overlay. A no-op with no map to draw on. */
export function refreshContainers() {
    if (!host.hasMap())
        return;
    containers.render(containerNodes(), leafDesire);
    containers.setEmphasis(S.sigma);
}
/** One published feature, as a region. */
const toRegion = (f) => ({
    id: f.properties.id,
    name: f.properties.name,
    parent: f.properties.containedIn ?? null,
    boundary: f.geometry,
});
/**
 * Load the extent layers, once. boundaries.json is the top tier; a feature may
 * declare a finer one, resolved against data/geo/ so a new layer just lands
 * beside it. Redraws with true polygons when they arrive — and redraws anyway if
 * they do not, so a failed fetch leaves the hulls rather than an empty map.
 */
export function initRegions(h) {
    host = h;
    fetch("data/geo/boundaries.json").then(r => r.ok ? r.json() : null).then(async (fc) => {
        const feats = (fc && Array.isArray(fc.features) ? fc.features : []);
        REGIONS = feats.map(toRegion);
        const layers = [...new Set(feats.map(f => f.properties.ecoregions).filter(Boolean))];
        const ecos = await Promise.all(layers.map(f => fetch(`data/geo/${f}`).then(r => r.ok ? r.json() : null).catch(() => null)));
        for (const e of ecos)
            if (e && Array.isArray(e.features))
                REGIONS.push(...e.features.map(toRegion));
        refreshContainers();
    }).catch(() => refreshContainers());
}
