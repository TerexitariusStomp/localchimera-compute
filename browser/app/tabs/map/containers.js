// app/tabs/containers.ts — what contains what, and how each is doing.
//
// A SpatialThing knows what it is contained-in (schemas.scm:203), so the
// scope's places form a FOREST: room ⊂ venue ⊂ block ⊂ commune ⊂ … . This
// overlay draws that forest on the globe — not as markers but as nested
// REGIONS. Each is the padded, rounded convex hull of everything it holds — a
// polytope holding its children's polytopes — tinted by the GEOMETRIC MEAN of
// its members' readings, the worst-off-leaning fold the fragility face
// maximises (nutrition.ts:214, φ = −w·log s). So the map reads, at a glance,
// where the commons is whole and where it is strained, at every level of
// containment at once.
//
// WHAT THE TINT IS, said exactly, because the easy name for it is wrong. It is
// not the scope tree's demand fold (that aggregates over SCOPES — the
// federation tree, vf/aggregation/scope-tree.scm — and most places are not
// scopes). It is `location-slacks` (service.scm): produced ÷ demanded PER
// PLACE, out of one scope's last solve, which this module then re-aggregates up
// the SPATIAL tree. A per-place fill, folded over geography.
//
// Generic by construction. Nothing here knows about nutrition, places, or the
// dial: give it a flat list of {id,name,lat,lng,parent} plus a valueOf(leaf) →
// a number in (0,1] — or NULL for a node that is not one of the things being
// aggregated (see `fold`) — and it renders. A node may also carry its own
// `color`, which is how a THING standing in a place (a box, a crate) nests in
// the same forest without being read as a place that is failing anybody.
// main.js supplies the data — live from the scope snapshot
// (seam.data.snapshot.locations, contained-in included) when a gateway is
// connected, else derived from the dial's own PLACES — and injects what the
// reading means. This module is only the geometry and the fold.
const TAU = 2 * Math.PI;
const d3 = window.d3;
import { styleReady, onStyleReady } from "./ready.js";
// ── the forest: nodes[] with a `parent` id → rooted trees with children[] ──
// A parent pointing outside the set (or nowhere) makes a root. Cycles can't
// arise from a store that rejects them (spatial-things.scm add-location), but a
// node is never its own child regardless.
export function forest(nodes) {
    // `depth` is absent for exactly as long as it takes to root the trees: tag()
    // below assigns it to every node before this function returns.
    const by = new Map(nodes.map((n) => [n.id, { ...n, children: [] }]));
    const roots = [];
    for (const n of by.values()) {
        const p = n.parent != null && by.get(n.parent);
        if (p && p !== n)
            p.children.push(n);
        else
            roots.push(n);
    }
    const tag = (n, d) => { n.depth = d; n.children.forEach(c => tag(c, d + 1)); };
    roots.forEach(r => tag(r, 0));
    return roots;
}
// every coordinate in a subtree — the point cloud a container's hull spans
// (its own point, if it has one, plus all descendants').
function subtreePts(n, out = []) {
    // the LOOSE global isFinite on purpose: it answers false for a node with no
    // coordinate at all, which is exactly the question being asked.
    if (isFinite(n.lat) && isFinite(n.lng))
        out.push([n.lng, n.lat]);
    n.children.forEach(c => subtreePts(c, out));
    return out;
}
// ── the fold: social-desire aggregated up the tree ───────────────────────
// A leaf's desire is valueOf(leaf) ∈ (0,1] — 1 whole, → 0 strained. A
// container's is exp(mean(ln s)) over its leaves: the geometric mean, which one
// badly-off member drags down (worst-off-leaning), scale-free, bounded (0,1].
// Exactly the aggregate the fragility wheel completes (harmony = −Σφ = Σ w·log s
// is monotone in it). Mutates each node with {slack, n}.
// valueOf may return NULL for a node that is not one of the things being
// aggregated — a THING standing in a place rather than a place. Such a node, and
// everything under it, is outside the aggregate: it nests and it draws, but it
// carries no value and drags on nobody's. So a node whose only children are
// such things is still a leaf of the aggregate and keeps its own reading, and a
// container's value counts the members it was defined over, never their
// contents. With no nulls in the tree this is the plain walk-to-leaves it has
// always been.
export function fold(n, valueOf) {
    const leaves = [];
    const counts = (x) => valueOf(x) !== null;
    (function walk(x) {
        if (!counts(x))
            return;
        const kids = x.children.filter(counts);
        kids.length ? kids.forEach(walk) : leaves.push(x);
    })(n);
    const ss = leaves.map(valueOf).filter((s) => isFinite(s) && s > 0);
    n.slack = ss.length ? Math.exp(ss.reduce((a, s) => a + Math.log(s), 0) / ss.length) : 1;
    n.n = leaves.length;
    n.children.forEach(c => fold(c, valueOf));
    return n;
}
// ── colour: the harmony ramp, keyed by slack ──────────────────────────────
// Mirrors fragility.js harmonyColor — a warm grey where nothing is realised
// (s→0), deepening to a vivid harmony green at the healthy steady state (s→1).
// A container reddens toward grey exactly as its aggregate desire goes unmet.
const STOPS = [[0, [201, 106, 96]], [0.35, [214, 176, 108]],
    [0.68, [140, 190, 120]], [1, [45, 138, 86]]];
// The inferred `| undefined` is unreachable: STOPS is non-empty, so the loop
// reaches k === STOPS.length - 1, where the condition holds unconditionally.
function harmonyColor(s) {
    s = Math.max(0, Math.min(1, s));
    for (let k = 1; k < STOPS.length; k++) {
        if (s <= STOPS[k][0] || k === STOPS.length - 1) {
            const [a, ca] = STOPS[k - 1], [b, cb] = STOPS[k];
            const u = Math.min(1, Math.max(0, (s - a) / (b - a)));
            const c = ca.map((v, j) => Math.round(v + (cb[j] - v) * u));
            return `rgb(${c[0]},${c[1]},${c[2]})`;
        }
    }
}
// ── geometry: a node's region is the padded, rounded hull of its points ────
// Longitude degrees shrink with latitude; we work in a locally isotropic frame
// (x scaled by 1/cos φ) so hulls and discs stay round on the ground.
const kxOf = (lat) => 1 / Math.max(0.2, Math.cos(lat * Math.PI / 180));
// only ever called with a non-empty cloud (ring guards), so the means are real.
const centroid = (pts) => [d3.mean(pts, p => p[0]), d3.mean(pts, p => p[1])];
const distIso = (p, c, kx) => Math.hypot((p[0] - c[0]) / kx, p[1] - c[1]);
function disc([lng, lat], rDeg, m = 44) {
    const kx = kxOf(lat), out = [];
    for (let i = 0; i <= m; i++) {
        const a = TAU * i / m;
        out.push([lng + rDeg * kx * Math.cos(a), lat + rDeg * Math.sin(a)]);
    }
    return out;
}
// push a hull vertex outward from the centroid by `pad` latitude-degrees
function outward([x, y], [cx, cy], pad) {
    const kx = kxOf(cy);
    let dx = (x - cx) / kx, dy = y - cy;
    const L = Math.hypot(dx, dy) || 1;
    return [x + pad * kx * dx / L, y + pad * dy / L];
}
// Chaikin corner-cutting — the hull relaxed into a rounded polytope. `ring`
// must be closed (first === last).
function smooth(ring, passes = 2) {
    let r = ring;
    for (let k = 0; k < passes; k++) {
        const out = [];
        for (let i = 0; i < r.length - 1; i++) {
            const a = r[i], b = r[i + 1];
            out.push([a[0] * 0.75 + b[0] * 0.25, a[1] * 0.75 + b[1] * 0.25]);
            out.push([a[0] * 0.25 + b[0] * 0.75, a[1] * 0.25 + b[1] * 0.75]);
        }
        out.push(out[0]);
        r = out;
    }
    return r;
}
// the region ring for a set of points: 1–2 or collinear points → a disc that
// covers them; ≥3 → their convex hull, grown by `pad` and rounded.
function ring(pts, pad) {
    const uniq = [...new Map(pts.map((p) => [p.join(","), p])).values()];
    const c = centroid(uniq), kx = kxOf(c[1]);
    const hull = uniq.length >= 3 ? d3.polygonHull(uniq.map(p => p.slice())) : null;
    if (!hull) {
        const r = Math.max(0, ...uniq.map(p => distIso(p, c, kx))) + pad;
        return disc(c, r);
    }
    const grown = hull.map(p => outward(p, c, pad));
    grown.push(grown[0]);
    return smooth(grown);
}
// ── the maplibre overlay: one source, two layers (fill · outline) ─────────
// No text layer: the map style carries no glyphs (main.js mkMap), so regions
// speak by colour and the existing DOM place-markers carry the names.
const SRC = "containers", FILL = "containers-fill", LINE = "containers-line";
let _map = null, mounted = false, visible = true, lastForest = null;
let emphasis = 1, lastZoom = 13;
let selectedId = null; // the region you have open, if any
const empty = () => ({ type: "FeatureCollection", features: [] });
// ── zoom descends the containment tree ─────────────────────────────────────
// The forest carries every level of containment at once, but the eye wants the
// level it's looking AT: zoomed out you read the federation whole; zoomed in you
// read a single venue. So a container's prominence PEAKS when the current zoom
// "targets" its depth — focus = (zoom−Z0)/ZPER, one containment level per ZPER
// zoom levels — and fades with distance from it: a smooth crossfade DOWN the
// tree as you zoom in, never a hard pop. The default earth zoom (13) targets
// venues (depth 2). A faint floor keeps every level legible for context. This
// composes multiplicatively with the σ emphasis (setEmphasis).
const Z0 = 9, ZPER = 2, BAND = 1.6; // depth 0 in focus at zoom 9; +1 level / 2 zoom
const FILL_HI = 0.30, FILL_LO = 0.05; // in-focus vs out-of-focus fill opacity
const LINE_HI = 0.85, LINE_LO = 0.12; // …and outline
const MAXD = 6; // deepest containment we build stops for
// Its own, rather than app/geom's: this module imports NOTHING, and a forest
// of hulls tinted by a fold is worth keeping free of the dial's geometry for
// the sake of one line.
const clamp01 = (v) => Math.max(0, Math.min(1, v));
const focusDepth = (z) => (z - Z0) / ZPER;
// prominence ∈ [0,1] of a depth-d container at zoom z: 1 at the targeted depth,
// falling linearly to 0 BAND levels away.
const prominence = (d, z) => Math.max(0, 1 - Math.abs(d - focusDepth(z)) / BAND);
// A DATA-DRIVEN opacity expression for the current zoom. maplibre forbids
// nesting ["zoom"] inside a ["match"] (zoom + data-driven can't combine in one
// property), so we bake the zoom in on the JS side and refresh on the map's zoom
// event. emphasis scales the whole curve.
function opacityByDepth(hi, lo) {
    const at = (d) => +(emphasis * (lo + (hi - lo) * prominence(d, lastZoom))).toFixed(3);
    const e = ["match", ["get", "depth"]];
    for (let d = 0; d < MAXD; d++)
        e.push(d, at(d));
    e.push(at(MAXD)); // default: depth ≥ MAXD
    return e;
}
// The SELECTED region — the one you have open — is lifted out of the depth
// curve entirely: a thing you are looking into should not fade because the zoom
// happens to target another level. Everything else keeps its zoom prominence.
const selected = (expr) => selectedId
    ? ["case", ["==", ["get", "id"], selectedId], SEL_HI, expr]
    : expr;
const SEL_HI = 0.9;
// mounted implies _map: mount() assigns it before it ever sets mounted.
function applyPaint() {
    if (!mounted)
        return;
    _map.setPaintProperty(FILL, "fill-opacity", selected(opacityByDepth(FILL_HI, FILL_LO)));
    _map.setPaintProperty(LINE, "line-opacity", selected(opacityByDepth(LINE_HI, LINE_LO)));
    _map.setPaintProperty(LINE, "line-width", selectedId
        ? ["case", ["==", ["get", "id"], selectedId], 3.2,
            ["interpolate", ["linear"], ["get", "depth"], 0, 2.6, 4, 1]]
        : ["interpolate", ["linear"], ["get", "depth"], 0, 2.6, 4, 1]);
}
function onZoom() { if (!mounted)
    return; lastZoom = _map.getZoom(); applyPaint(); }
export function mount(map) {
    _map = map;
    if (!map)
        return;
    if (!styleReady(map)) {
        onStyleReady(map, () => mount(map));
        return;
    }
    if (mounted)
        return;
    lastZoom = map.getZoom();
    map.addSource(SRC, { type: "geojson", data: empty() });
    map.addLayer({
        id: FILL, type: "fill", source: SRC,
        paint: { "fill-color": ["get", "color"], "fill-opacity": opacityByDepth(FILL_HI, FILL_LO) },
    });
    map.addLayer({
        id: LINE, type: "line", source: SRC,
        paint: {
            "line-color": ["get", "color"],
            "line-width": ["interpolate", ["linear"], ["get", "depth"], 0, 2.6, 4, 1],
            "line-opacity": opacityByDepth(LINE_HI, LINE_LO),
        },
    });
    mounted = true;
    if (!map.__containersZoomBound) {
        map.on("zoom", onZoom);
        map.__containersZoomBound = true;
    }
    applyVisible();
    if (lastForest)
        draw(lastForest);
}
function applyVisible() {
    if (!mounted)
        return;
    const v = visible ? "visible" : "none";
    [FILL, LINE].forEach(id => _map.setLayoutProperty(id, "visibility", v));
}
export function setVisible(on) { visible = !!on; applyVisible(); }
// couple the overlay's prominence to the dial's local⇄global blend σ∈[0,1]:
// the desire regions aggregate the WHOLE commune's demand, so they surface as
// you go "everyone's" and recede toward "your day" — exactly as events/law do.
// Guarded: a no-op until mounted, and only ever touches the overlay's own paint.
// the open region, by id — null clears it. Paint-only, so it costs a repaint
// and never a re-render.
export function setSelected(id) {
    if (selectedId === (id || null))
        return;
    selectedId = id || null;
    applyPaint();
}
export function setEmphasis(sigma) {
    emphasis = 0.25 + 0.75 * clamp01(sigma || 0);
    applyPaint();
}
// build the FeatureCollection from a folded forest and push it to the source.
function draw(roots) {
    lastForest = roots;
    if (!mounted || !_map.getSource(SRC))
        return;
    const feats = [];
    const PAD0 = 0.0018; // ≈ 200 m of breathing room at the root; tighter when deep
    const emit = (n) => {
        const pts = subtreePts(n);
        // a node with a REAL boundary (an ecoregion / nation, from vendored geometry)
        // draws that polygon as-is — concavities, holes, coastlines and all; otherwise
        // the derived convex hull of what it contains (the right fallback for a scope
        // with no published boundary, e.g. a commune or a venue cluster).
        const geometry = n.boundary
            ? n.boundary
            : (pts.length ? { type: "Polygon", coordinates: [ring(pts, PAD0 / (n.depth + 1))] } : null);
        if (geometry) {
            feats.push({
                type: "Feature",
                properties: {
                    id: n.id, name: n.name || n.id, depth: n.depth, n: n.n || 1,
                    slack: +(n.slack ?? 1).toFixed(3),
                    // a node may carry its own colour. Places are tinted by the desire
                    // aggregated in them (the harmony ramp); a node that is a THING rather
                    // than a place — a container standing in one — says so by naming its
                    // own hue, and this module needs to know nothing about which is which.
                    color: n.color || harmonyColor(n.slack ?? 1),
                    real: n.boundary ? 1 : 0, // a true boundary vs a derived hull
                },
                geometry,
            });
        }
        n.children.forEach(emit);
    };
    roots.forEach(emit);
    // shallow first, deep on top
    feats.sort((a, b) => a.properties.depth - b.properties.depth);
    _map.getSource(SRC).setData({ type: "FeatureCollection", features: feats });
}
// ── point-in-polygon: which real region CONTAINS a coordinate ──────────────
// Ray-casting on a GeoJSON geometry (Polygon | MultiPolygon), lng/lat. So a leaf's
// contained-in can be DERIVED from real ecoregion boundaries — a farm sits in the
// shed whose polygon holds it — the way One Earth nests places, not by a hull guess.
function inRing(lng, lat, ring) {
    let inside = false;
    for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
        const xi = ring[i][0], yi = ring[i][1], xj = ring[j][0], yj = ring[j][1];
        if (((yi > lat) !== (yj > lat)) &&
            (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi))
            inside = !inside;
    }
    return inside;
}
export function inGeometry(lng, lat, geom) {
    if (!geom)
        return false;
    const polys = geom.type === "MultiPolygon" ? geom.coordinates
        : geom.type === "Polygon" ? [geom.coordinates] : [];
    for (const rings of polys) { // outer ring holds ∧ no hole excludes
        if (rings.length && inRing(lng, lat, rings[0]) &&
            !rings.slice(1).some(h => inRing(lng, lat, h)))
            return true;
    }
    return false;
}
// the id of the region (from a [{id, boundary}] list) whose polygon holds (lng,lat), or null.
export function regionAt(lng, lat, regions) {
    for (const r of regions)
        if (r.boundary && inGeometry(lng, lat, r.boundary))
            return r.id;
    return null;
}
// ── the one entry main.js calls: hand it a flat node list + valueOf ────────
// nodes: [{id, name, lat, lng, parent}], each leaf also carrying whatever
// valueOf needs. Builds the forest, folds desire up it, renders.
export function render(nodes, valueOf) {
    if (!Array.isArray(nodes) || !nodes.length) {
        if (mounted)
            draw([]);
        return;
    }
    const roots = forest(nodes);
    roots.forEach(r => fold(r, valueOf));
    draw(roots);
}
export function destroy() {
    if (_map && mounted) {
        [LINE, FILL].forEach(id => _map.getLayer(id) && _map.removeLayer(id));
        _map.getSource(SRC) && _map.removeSource(SRC);
        if (_map.__containersZoomBound) {
            _map.off("zoom", onZoom);
            _map.__containersZoomBound = false;
        }
    }
    mounted = false;
    lastForest = null;
}
