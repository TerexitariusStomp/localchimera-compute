// app/tabs/law.ts — the law face: one screen, read by place.
//
// One state drives everything on it — an ACTIVITY, a PLACE and a WAY of doing
// the activity. The map is the navigator: it paints every place by what the law
// asks there and a click moves the place. The docket beside it reads the place
// in three tabs: the ways and their bills, the program (what we ask of the law
// here, and what is already won here), and the sources.
//
// Face subsystem with a state-owning API: it keeps ALL of its own state
// (lawData, lawSel, lawReading, lawMode, lawTab, projections, …) private and
// exposes only entry points. The core face-switcher (setFace, in main.js)
// calls lawEnter()/lawSizeSvg()/lawRestoreSvg(); the boot deep-link calls
// lawDeepLink(). It reads a few core objects (the L.law layer, svg,
// map, mode, stage.face, updateChromeTargets) only at call time, so the
// main.js <-> law.js import cycle is benign.
import { svg } from '../layers.js';
import { updateChromeTargets } from '../chrome.js';
import { L } from '../layers.js';
import { stage } from '../stage.js';
import { PT } from '../geom.js';
// law data is the bundled snapshot, an artefact of the box's fold, and every
// NAME, SOURCE and ID it carries is escaped where it lands.
import { html, raw, render } from '../template.js';
import { signal, effect } from '../reactive.js';
import { chip } from '../chips.js';
import { segRail } from '../seg.js';
// the legal bodies you steward: each stands in a jurisdiction the map reads,
// and holds (or owes) what the bill here asks
import { bodies, readBodies, readBody, jurisdictionOf, jurisdictionPlace } from '../bodies.js';
import { setFace } from '../faces.js';
/**
 * Null only between module load and the first initLaw() or lawDeepLink. The two
 * entry points that could run before either — drawLaw and lawSetView — check and
 * bail, so every reader past them has a snapshot. Typed non-null so that fact is
 * stated once here rather than asserted at a hundred call sites; the explicit
 * `if (!lawData)` guards below still read exactly as they did.
 */
let lawData = null;
let lawTopo = null;
let lawWorldTopo = null;
let lawLoading = false;
const lawLoaded = signal(false); // the snapshot and both topologies are in
// THE FACE'S VIEW STATE, as signals. Every one of these is read by the map, the
// panel, the legend and the crumb at once, so a write propagates by itself —
// which is why none of the handlers below calls drawLaw(). One effect at the
// bottom of this file renders whatever these currently say.
const lawSel = signal(null); // THE place: the docket reads it (null = the world)
const lawReading = signal("burden"); // "burden" | "scope"
const lawActivity = signal(null); // the chosen action
const lawMode = signal(null); // a chosen way (null = the lightest legal)
const lawTab = signal("ways"); // the docket's tab: "ways" | "program" | "sources"
const lawArc = signal(null); // a supply arc the docket reads instead of a place
const lawLeg = signal("export"); // that arc's leg: "export" | "crossing" | "import"
// two projections: the whole planet (countries) and the US (states inset).
const lawNatural = d3.geoNaturalEarth1();
const lawAlbers = d3.geoAlbersUsa();
let lawProj = lawNatural; // the active projection (set per view)
let lawPathGen = d3.geoPath(lawProj);
// the active action + how a place scores under it (the selected mode, or the
// lightest legal mode if none is pinned). This is the generic cube slice.
function lawAct() { return (lawData.activities || []).find(a => a.id === lawActivity()); }
function placeAB(p) {
    return p && p.byActivity && p.byActivity[lawActivity()];
}
// A way's score is its bill's: the burden, and the stance the fold read off it
// (legal-registry.scm `bill-stance`). A place's score is its lightest way's; with
// no way open it is `off`.
const modeScore = (m) => ({ burden: m.burden, stance: m.bill && m.bill.stance });
function placeScore(p) {
    const ab = placeAB(p);
    if (!ab)
        return null;
    if (lawMode()) {
        const m = (ab.modes || []).find(x => x.id === lawMode());
        return m ? modeScore(m) : null;
    }
    return headlineScore(ab);
}
function headlineScore(ab) {
    const best = (ab.modes || []).find(x => x.id === ab.recommended);
    return { burden: ab.headline, stance: best ? modeScore(best).stance : "off" };
}
/** A prohibition stands: sure (`off`) or doubted (`soft`). */
const lawForbids = (s) => !!s && (s.stance === "off" || s.stance === "soft");
/** Some of what the way trips has no rule written for it here. */
const lawUnread = (s) => !!s && s.stance === "unread";
// burden → tier: a green→red gradient; forbidden is the deepest red. The tiers
// themselves — where each ends and what it is called — ride the snapshot, named
// by the fold that weighs a bill (legal-registry.scm); the face owns the paint.
const LAW_UNREAD = "#e3e6ea";
const LAW_FORBIDDEN = ["#7a2e2e", "forbidden"];
const LAW_TIER_PAINT = ["#6fbf8e", "#b6cf6a", "#e2c265", "#dd9450", "#c75d43"];
/** → [colour, name] of the tier a score falls in. */
function lawTiers() {
    return (lawData.tiers || []).map((t, i) => [LAW_TIER_PAINT[Math.min(i, LAW_TIER_PAINT.length - 1)], t.name]);
}
function lawTier(s) {
    if (!s)
        return null;
    if (lawForbids(s))
        return LAW_FORBIDDEN;
    const tiers = lawData.tiers || [];
    const i = tiers.findIndex(t => t.upTo == null || s.burden <= t.upTo);
    return lawTiers()[i < 0 ? tiers.length - 1 : i] || null;
}
function lawColor(s) {
    const t = lawTier(s);
    return t ? t[0] : LAW_UNREAD;
}
// the fill for a region under the active reading.
function lawFill(p, id) {
    if (lawReading() === "scope")
        return lawScopeColor(id);
    return lawColor(placeScore(p));
}
function lawScopeColor(id) {
    return lawLit.has(id) ? "#9a7fc4" : LAW_UNREAD;
}
const lawMemberPlaces = new Set(); // every place with a member operating in it or below it
let lawLit = lawMemberPlaces; // those, and every place a body of ours is declared in or below: drawLaw reads it off
/** Every place the federation works in or below — a member's place, or a body's jurisdiction. */
function lawActivePlaces() {
    const lit = new Set(lawMemberPlaces);
    for (const b of bodies()) {
        const j = lawBodyPlace(b);
        if (j)
            lawPath(j).forEach(id => lit.add(id));
    }
    return lit;
}
/** The snapshot place a body is declared in, or null when the map has no such place. */
const lawBodyPlace = (b) => { const j = jurisdictionOf(b); return j && placeOf(jurisdictionPlace(j)) ? jurisdictionPlace(j) : null; };
/** Our bodies declared at a place or anywhere up its chain — the ones the law here reaches. */
function lawBodiesAt(id) {
    if (!id)
        return [];
    const path = lawPath(id);
    return bodies().filter(b => { const j = lawBodyPlace(b); return !!j && path.includes(j); });
}
/** Stance → [colour, word], the paint the map uses for a place under that stance. */
export function lawStancePaint(stance) {
    switch (stance) {
        case "off": return LAW_FORBIDDEN;
        case "soft": return [LAW_TIER_PAINT[4], "forbidden — doubted"];
        case "notice": return [LAW_TIER_PAINT[2], "notice"];
        case "open": return [LAW_TIER_PAINT[0], "open"];
        default: return [LAW_UNREAD, "unread"];
    }
}
function placeOf(id) { return lawData && lawData.places ? lawData.places[id] : null; }
function lawRecipe(id) { return lawData && (lawData.recipes || []).find(r => r.id === id); }
// members operating at a place (the place itself, or — for a state — its localities)
function membersForPlace(id) {
    if (!lawData)
        return [];
    return (lawData.federation.members || []).filter(m => m.place === id || (placeOf(m.place) && placeOf(m.place).parent === id));
}
// A `let`, not a declaration: lawDeepLink WRAPS it to land on a jurisdiction
// after the first load. Every call is inside another function, so nothing runs
// before this line.
let initLaw = async function () {
    if (lawLoaded.peek() || lawLoading)
        return;
    lawLoading = true;
    try {
        lawData = await (await fetch("data/snapshots/law-snapshot.json")).json();
        lawActivity.set(lawData.defaultActivity || (lawData.activities && lawData.activities[0].id));
        lawTopo = await (await fetch("data/geo/us-states-10m.json")).json();
        lawWorldTopo = await (await fetch("data/geo/world-countries-110m.json")).json();
        // where the federation operates (for the "who operates" reading): a
        // member's place and every place that contains it
        (lawData.federation.members || []).forEach(m => lawPath(m.place).forEach(id => lawMemberPlaces.add(id)));
        lawLoaded.set(true); // the effects below take it from here
    }
    catch (e) {
        console.warn("[law] load failed", e);
        lawData = null;
    }
    lawLoading = false;
};
// a place and everything that contains it, nearest first
function lawPath(id) {
    const out = [];
    for (let p = placeOf(id), cur = id; p && out.length < 24; cur = p.parent, p = placeOf(cur))
        out.push(cur);
    return out;
}
// The map FRAME is a function of the place, so the two cannot disagree: a US
// place frames its state (or the US), a place inside a region of nations — the
// EU — frames that region, and anything else frames the world.
function lawFrameOf(id) {
    if (!id)
        return "world";
    const path = lawPath(id);
    const state = path.find(lawIsUsState);
    if (state)
        return state;
    if (path.includes("us"))
        return "us";
    const top = path[path.length - 1]; // the ancestor directly under the world
    const holdsNations = !!top && !lawIsNation(top) && (lawData.nations || []).some(n => lawPath(n.id).includes(top));
    return holdsNations ? top : "world";
}
const lawNode = () => lawFrameOf(lawSel());
// THE navigation: one write moves the docket and the map together.
function lawGoto(id) {
    lawArc.set(null);
    lawSel.set(id && placeOf(id) ? id : null);
}
// what belongs to the chosen activity: the federation's members and arcs
const lawOfActivity = () => !!lawData.federation.activity && lawData.federation.activity === lawActivity();
// the place the docket reads; null is the whole world
const lawPlaceId = () => lawSel();
// the nation a node sits in (a state → "us"; a nation → itself; world → #f)
function lawIsNation(id) { return (lawData.nations || []).some(n => n.id === id); }
function lawNationIso(id) { const n = (lawData.nations || []).find(n => n.id === id); return n && n.iso; }
function lawIsoNation(iso) { const n = (lawData.nations || []).find(n => n.iso === String(iso)); return n && n.id; }
function lawIsUsState(id) { return /^us-\d\d$/.test(id); }
function lawStateFeatures() {
    return topojson.feature(lawTopo, lawTopo.objects.states).features
        .filter(f => placeOf("us-" + f.id)); // only the 50 states + DC we model
}
function lawCountryFeatures() {
    return topojson.feature(lawWorldTopo, lawWorldTopo.objects.countries).features;
}
// project a place to map coords under the ACTIVE projection: a locality by its
// lat/long, a state/nation by its polygon centroid. Drives the supply arcs.
function lawProjPoint(id) {
    const p = placeOf(id);
    if (p && p.lat != null)
        return lawProj([p.long, p.lat]);
    if (lawIsUsState(id) || id === "us") {
        if (lawProj === lawAlbers) {
            const ff = lawStateFeatures().find(x => ("us-" + x.id) === id);
            return ff ? lawPathGen.centroid(ff) : null;
        }
    }
    if (lawIsNation(id)) {
        const iso = lawNationIso(id);
        const f = lawCountryFeatures().find(ff => String(ff.id) === iso);
        return f ? lawPathGen.centroid(f) : null;
    }
    const fips = id.replace(/^us-/, "");
    const f = lawStateFeatures().find(ff => ff.id === fips);
    return f ? lawPathGen.centroid(f) : null;
}
// give the SVG the whole orbwrap (overriding the dial's square aspect) and a
// 1:1 pixel viewBox, so the map can fill the full width. Restored on exit.
function lawSizeSvg() {
    // the stage's own wrapper — the law face only draws once it is mounted.
    const wrap = document.getElementById("orbwrap");
    const W = Math.max(320, wrap.clientWidth), H = Math.max(320, wrap.clientHeight);
    svg.style("width", W + "px").style("height", H + "px")
        .style("max-width", "none").style("aspect-ratio", "auto")
        .attr("viewBox", `0 0 ${W} ${H}`).attr("preserveAspectRatio", "xMidYMid meet");
    return [W, H];
}
function lawRestoreSvg() {
    svg.style("width", null).style("height", null).style("max-width", null).style("aspect-ratio", null);
    if (typeof updateChromeTargets === "function")
        updateChromeTargets(); // reset dial viewBox
}
// ── the map ───────────────────────────────────────────────────────────────
// The map box is whatever the bar and the docket leave: the docket stands
// beside the map on a wide stage and below it on a narrow one (CSS decides), so
// the box is read off where they actually are.
function lawMapBox(W, H) {
    const wrap = document.getElementById("orbwrap").getBoundingClientRect();
    const dk = document.getElementById("lawdocket").getBoundingClientRect();
    const bar = document.getElementById("lawbar").getBoundingClientRect();
    const top = Math.max(8, bar.bottom - wrap.top + 8);
    const beside = dk.left - wrap.left > W * 0.3;
    const right = beside ? dk.left - wrap.left - 12 : W - 8;
    const bottom = (beside ? H : dk.top - wrap.top) - 40; // the legend strip sits under the map
    return [[8, top], [Math.max(right, 120), Math.max(bottom, top + 80)]];
}
function drawLaw() {
    L.law.selectAll("*").remove();
    if (!lawLoaded()) {
        L.law.append("text").attr("text-anchor", "middle").attr("y", 0)
            .attr("fill", "#888").attr("font-size", 8 * PT).text("loading the legal map…");
        return;
    }
    // the law face takes the WHOLE orbwrap (the dial's square viewBox would waste
    // the width) — a pixel-matched viewBox.
    const [W, H] = lawSizeSvg();
    const box = lawMapBox(W, H);
    lawLit = lawActivePlaces();
    // pick the projection + features for this level of the contained-in tree.
    const usView = lawNode() === "us" || lawIsUsState(lawNode());
    let features, placeIdOf;
    if (usView) { // US — states inset projection
        lawProj = lawAlbers;
        const all = lawStateFeatures();
        features = lawNode() === "us" ? all : all.filter(f => ("us-" + f.id) === lawNode());
        placeIdOf = f => "us-" + f.id;
    }
    else { // the whole planet
        lawProj = lawNatural;
        features = lawCountryFeatures();
        placeIdOf = f => lawIsoNation(f.id) || null; // a modelled nation, or null
    }
    lawPathGen = d3.geoPath(lawProj);
    // a region frame (the EU) fits the same planet to the mainlands of the
    // region's nations; every country is still drawn, the view just comes closer
    const frame = lawNode();
    const inFrame = usView || frame === "world" ? features
        : features.filter(f => lawPath(placeIdOf(f) || "").includes(frame)).map(lawMainland);
    lawProj.fitExtent(box, { type: "FeatureCollection", features: inFrame.length ? inFrame : features });
    const here = lawPlaceId();
    // the selected place's own outline; a state that IS the frame needs none
    const onPath = (here ? lawPath(here) : []).filter(id => id !== lawNode());
    const base = (usView ? 0.8 : 0.5) * PT, picked = base * (usView ? 2.2 : 1.3);
    const several = features.length > 1;
    const fills = new Set();
    // the map keeps to its own cell: a closer frame would otherwise run under the
    // bar and the docket
    L.law.append("clipPath").attr("id", "lawclip").append("rect")
        .attr("x", box[0][0] - 4).attr("y", box[0][1] - 4)
        .attr("width", box[1][0] - box[0][0] + 8).attr("height", box[1][1] - box[0][1] + 8).attr("rx", 10);
    L.law.append("g").attr("clip-path", "url(#lawclip)").selectAll("path").data(features).join("path")
        .attr("d", lawPathGen)
        .attr("fill", f => {
        const id = placeIdOf(f), p = id && placeOf(id);
        if (!p)
            return LAW_UNREAD; // no law read here yet
        const c = lawFill(p, id);
        fills.add(c);
        return c;
    })
        .attr("stroke", f => onPath.includes(placeIdOf(f) || "") ? "#2c3038" : "#ffffff")
        .attr("stroke-width", f => onPath.includes(placeIdOf(f) || "") ? picked : base)
        .attr("cursor", f => placeIdOf(f) ? "pointer" : "default")
        .on("mouseover", function (_e, f) {
        d3.select(this).attr("stroke", "#2c3038").attr("stroke-width", picked);
        lawLegend(placeIdOf(f), several && fills.size === 1);
    })
        .on("mouseout", function (_e, f) {
        const sel = onPath.includes(placeIdOf(f) || "");
        d3.select(this).attr("stroke", sel ? "#2c3038" : "#ffffff").attr("stroke-width", sel ? picked : base);
        lawLegend(null, several && fills.size === 1);
    })
        .on("click", (_e, f) => { const id = placeIdOf(f); if (id)
        lawGoto(id); });
    // the selected region paints last, so its outline sits over its neighbours'
    L.law.selectAll("g > path").filter(f => onPath.includes(placeIdOf(f) || "")).raise();
    // supply ARCS (§2.6). On the world view: international arcs. On the US view:
    // interstate arcs. A crossing is dashed-orange with an import→export head.
    drawLawArcs();
    // localities inside a drilled-in state: markers
    if (lawIsUsState(lawNode())) {
        const lg = L.law.append("g");
        Object.entries(lawData.places)
            .filter(([, p]) => p.parent === lawNode() && p.lat != null)
            .forEach(([id, p]) => {
            const xy = lawProj([p.long, p.lat]);
            if (!xy)
                return;
            lg.append("circle").attr("cx", xy[0]).attr("cy", xy[1]).attr("r", 3.6 * PT)
                .attr("fill", lawFill(p, id)).attr("stroke", "#2c3038")
                .attr("stroke-width", (id === here ? 2 : 1) * PT)
                .attr("cursor", "pointer").on("click", () => lawGoto(id));
            lg.append("text").attr("x", xy[0]).attr("y", xy[1] - 5.2 * PT)
                .attr("text-anchor", "middle").attr("font-size", 4.2 * PT).attr("font-weight", 600)
                .attr("fill", "#2c3038").text(p.name.split(",")[0]);
        });
    }
    lawLegend(null, several && fills.size === 1);
}
// A nation's mainland: its largest polygon. France's outline carries Guiana,
// and a fit to the whole of it would span the Atlantic.
function lawMainland(f) {
    const g = f.geometry;
    if (g.type !== "MultiPolygon")
        return f;
    const polys = g.coordinates.map(c => ({ type: "Feature", geometry: { type: "Polygon", coordinates: c } }));
    return polys.reduce((a, b) => d3.geoArea(b) > d3.geoArea(a) ? b : a);
}
// draw the supply arcs for the current view, with a directional import head.
function drawLawArcs() {
    if (lawReading() !== "burden" || !lawOfActivity())
        return;
    const worldView = !(lawNode() === "us" || lawIsUsState(lawNode()));
    const ag = L.law.append("g").attr("pointer-events", "stroke").attr("clip-path", "url(#lawclip)");
    (lawData.federation.arcs || []).forEach((a, i) => {
        if (worldView ? !a.international : a.international)
            return; // arcs that fit this scale
        const p0 = lawProjPoint(a.from), p1 = lawProjPoint(a.to);
        if (!p0 || !p1)
            return;
        const pick = () => { lawLeg.set("export"); lawArc.set(i); };
        const mx = (p0[0] + p1[0]) / 2, my = (p0[1] + p1[1]) / 2;
        const dx = p1[0] - p0[0], dy = p1[1] - p0[1], len = Math.hypot(dx, dy) || 1;
        const cx = mx - dy / len * len * 0.16, cy = my + dx / len * len * 0.16;
        const col = a.international ? "#b5632f" : (a.crossesBorder ? "#d4824a" : "#7a8088");
        ag.append("path").attr("d", `M${p0[0]},${p0[1]} Q${cx},${cy} ${p1[0]},${p1[1]}`)
            .attr("fill", "none").attr("stroke", col).attr("stroke-width", (lawArc() === i ? 2.6 : 1.6) * PT)
            .attr("stroke-dasharray", a.crossesBorder ? `${2.4 * PT},${2 * PT}` : null)
            .attr("opacity", 0.92).attr("cursor", "pointer").on("click", pick);
        ag.append("circle").attr("cx", p0[0]).attr("cy", p0[1]).attr("r", 2.2 * PT)
            .attr("fill", "#3a4150").attr("cursor", "pointer").on("click", pick); // EXPORT origin
        ag.append("circle").attr("cx", p1[0]).attr("cy", p1[1]).attr("r", 2.6 * PT) // IMPORT dest
            .attr("fill", col).attr("stroke", "#fff").attr("stroke-width", 1.1 * PT)
            .attr("cursor", "pointer").on("click", pick);
    });
}
// the legend: one line under the map. Hovering a region names it and its tier;
// when every place in view paints alike, it says so and points at the ways.
function lawLegend(hoverId, uniform) {
    const sw = (c, label) => html `<span class="sw" style="background:${c}" title="${label}"></span>`;
    const end = (label) => html `<span class="lg-end">${label}</span>`;
    const p = hoverId ? placeOf(hoverId) : null;
    // on a narrow stage the bar drops its lens and the legend carries it: a tap
    // moves to the next reading (CSS shows this only there)
    const lens = Math.max(0, LAW_LENSES.findIndex(l => l[0] === lawReading()));
    const next = () => lawReading.set(LAW_LENSES[(lens + 1) % LAW_LENSES.length][0]);
    const reading = lawReading();
    let scale, said = null;
    if (reading === "burden") {
        scale = html `${end("lighter")}${lawTiers().map(t => sw(t[0], t[1]))}${end("heavier")}${sw(LAW_FORBIDDEN[0], LAW_FORBIDDEN[1])}${end("forbidden")}`;
        const t = p ? lawTier(placeScore(p)) : null;
        said = p ? (t ? t[1] + (lawUnread(placeScore(p)) ? " · not all read here" : "") : "")
            : uniform ? html `<span class="lg-note">every place in view reads alike for ${lawMode() ? "this way" : "the lightest way"} — pick ${lawMode() ? "another" : "a"} way in the list to compare</span>` : null;
    }
    else {
        scale = html `${sw("#9a7fc4", "a member operates here")}${end("a member operates here")}`;
    }
    render("#lawlegend", html `
    <a class="lg-lens" title="change what the map paints" onclick=${next}>${LAW_LENSES[lens][1]} ▾</a>${scale}
    ${p ? html `<b>${p.name}</b>` : null}${said}
    ${!p && !uniform ? html `${sw(LAW_UNREAD, "no law read here yet")}${end("unread")}` : null}`);
}
// ── the bar: activity · where · lens — the whole control surface, one row ──
const LAW_LENSES = [["burden", "burden"], ["scope", "who operates"]];
function lawBar() {
    const here = lawPlaceId();
    const trail = here ? lawPath(here).reverse() : [];
    return html `
    ${segRail((lawData.activities || []).map(a => [a.id, a.name]), lawActivity() || "", id => { lawActivity.set(id); lawMode.set(null); lawArc.set(null); })}
    <div class="lw-crumb">
      <a class="${here ? "" : "on"}" onclick=${() => lawGoto(null)}>World</a>${trail.map(id => html `
      <span class="sep">›</span><a class="${id === here ? "on" : ""}" onclick=${() => lawGoto(id)}>${placeOf(id).name}</a>`)}
    </div>
    ${segRail(LAW_LENSES, lawReading(), k => lawReading.set(k), "lw-lens")}`;
}
// ── the four do×want cells, shown CATEGORICALLY — each clause by name, in its
// labelled coloured group. No %, no bar: the clauses are not commensurable
// units over a common denominator, so a ratio would be a category error.
// A clause in the law's own words that nobody has mapped onto a federation
// aspect is none of the four — nothing is yet said of it — and is shown as such.
// Every stance is the federation's own, so each reads as "we …": [clause group,
// style, what the row says].
const LID_CL = [["redundant", "provide", "we provide"], ["absorbFirst", "build", "we build"],
    ["reproduceUnwanted", "bear", "we bear"], ["transform", "reject", "we reject"],
    ["unmapped", "unmapped", "not yet mapped"]];
function lawCells(e) {
    if (!e)
        return null;
    const parts = LID_CL.map(([k, cls, said]) => {
        const a = (e[k] || []);
        return a.length ? html `<span class="lw-cell ${cls}"><b>${said}</b> ${a.join(" ")}</span>` : null;
    }).filter(Boolean);
    return parts.length ? html `<div class="lw-cells">${parts}</div>` : null;
}
// ── a bill: what one way owes here, by what each demand asks of you ────────
function lawDemand(d, cls) {
    const meta = [];
    if (d.issuer && d.issuer !== "null")
        meta.push(d.issuer);
    if (d.per && d.per !== "null")
        meta.push(String(d.per).replace(/-/g, " "));
    if (d.to && d.to !== "null")
        meta.push("to " + d.to);
    if (d.discloses && d.discloses.length)
        meta.push("discloses " + d.discloses.join(", "));
    if (d.reason && d.reason !== "null" && d.reason !== d.name)
        meta.push(d.reason);
    if (d.direction && d.direction !== "null")
        meta.push(d.direction);
    return html `<div class="dk-dem ${cls}"><b>${d.name}</b>${meta.length ? html `<span class="dk-meta">${meta.join(" · ")}</span>` : null}
    ${lawHeldBy(d.name)}
    ${d.reform && d.reform !== "null" ? lawCells(d.reform) : null}</div>`;
}
// what a holding's status means for the demand: the paint of the tier it would land in
const LAW_HOLD_PAINT = { satisfied: LAW_TIER_PAINT[0], held: LAW_TIER_PAINT[0], obligation: LAW_TIER_PAINT[2], doubted: LAW_TIER_PAINT[3],
    missing: LAW_FORBIDDEN[0], expired: LAW_FORBIDDEN[0], forbidden: LAW_FORBIDDEN[0] };
/** "held by <body> · <status>" for each of our bodies here that holds something against this demand. */
function lawHeldBy(name) {
    if (!name || lawArc() != null)
        return null;
    const marks = lawBodiesAt(lawPlaceId()).flatMap(b => (b.holdings || []).filter(h => h.spec === name).map(h => ({ b, h })));
    return marks.length ? html `<span class="dk-meta dk-held">${marks.map(({ b, h }) => html `<span class="dk-hold ${h.status}" title="${h.name || h.spec}">held by <b>${b.name}</b> · <span class="st" style="color:${LAW_HOLD_PAINT[h.status] || LAW_UNREAD}">${h.status}</span></span>`)}</span>` : null;
}
// every group of a bill has its words (the keys are the fold's: BILL_KEYS), shown
// with the prohibition first
const LAW_BILL_WORDS = {
    forbid: ["forbidden", "forbid"], obtainEntity: ["obtain — an authorisation", "obtain"],
    obtainPerson: ["obtain — a competence", "obtain"], pay: ["pay — a levy", "pay"], tell: ["tell — a disclosure", "tell"]
};
const LAW_BILL = ["forbid", "obtainEntity", "obtainPerson", "pay", "tell"].map(k => [k, ...LAW_BILL_WORDS[k]]);
function lawBill(bill) {
    const blocks = LAW_BILL.map(([k, label, cls]) => {
        const arr = ((bill && bill[k]) || []);
        return arr.length ? html `<div class="dk-kind">${label}</div>${arr.map(d => lawDemand(d, cls))}` : null;
    }).filter(Boolean);
    const unread = (bill && bill.unread) || [];
    const gloss = (id) => ((lawData.crossings || []).find(c => c.id === id) || { gloss: "" }).gloss || id.replace(/-/g, " ");
    const silent = unread.length
        ? html `<div class="dk-meta dk-none" title="no rule has been written for these here; a steward's reading fills them in">no steward has read here yet: ${unread.map(gloss).join(" · ")}</div>`
        : null;
    return blocks.length ? html `${blocks}${silent}`
        : silent || html `<div class="dk-meta dk-none">the law read here asks nothing of this way</div>`;
}
/** " · read by <steward>", for a rule or a reading somebody stands behind. */
const lawBy = (steward) => steward ? " · read by " + steward.replace(/^scope:/, "") : "";
// ── the docket ────────────────────────────────────────────────────────────
function lawBadge(s) {
    return html `<span class="dk-b" style="--tier:${lawColor(s)}" title="${lawUnread(s) ? "some of what this way trips has no rule written for it here" : ""}">${!s ? "·" : lawForbids(s) ? "✗" : s.burden}${lawUnread(s) ? html `<sup>○</sup>` : null}</span>`;
}
const lawEntryOf = (name) => (lawData.program || []).find(e => e.name === name);
const lawModeName = (aid, mid) => {
    const a = (lawData.activities || []).find(x => x.id === aid);
    const m = a && a.modes.find(x => x.id === mid);
    return m ? m.name : mid;
};
// The reading of a structural demand that a place stands under: the nearest one
// up its chain, else the general case — the root's reading, which the demand's
// own entry IS. `at` is the place that was read, or null for the general case.
function lawReadingAt(id, d) {
    for (const pid of id ? lawPath(id) : []) {
        const r = (placeOf(pid).structural || []).find(x => x.name === d.name);
        if (r)
            return { reading: r, at: pid };
    }
    return { reading: d, at: null };
}
// WAYS — the ways of doing the activity, lightest first; the picked way paints
// the map and opens its bill.
function lawWays(id) {
    const act = lawAct();
    const p = id ? placeOf(id) : null, ab = p ? placeAB(p) : null;
    const metaOf = (mid) => act.modes.find(m => m.id === mid);
    const rows = ab
        ? (ab.modes || []).slice().sort((a, b) => a.burden - b.burden).map(m => ({ id: m.id, score: modeScore(m), bill: m.bill }))
        : act.modes.map(m => ({ id: m.id, score: null }));
    const pin = (mid) => lawMode.set(lawMode() === mid ? null : mid);
    const ours = lawOfActivity();
    const members = !ours ? [] : id ? membersForPlace(id) : (lawData.federation.members || []);
    const arcs = ours && !id ? (lawData.federation.arcs || []) : [];
    const kids = id ? Object.entries(lawData.places).filter(([, c]) => c.parent === id) : [];
    const ourBodies = lawBodiesAt(id);
    // reading a body whole opens it on its own face
    const openBody = (b) => void readBody(b.id).then(r => { if (r === "ok")
        setFace("bodies"); });
    return html `
    ${id && !ab ? html `<div class="dk-meta dk-none">no law is read here yet for this activity</div>` : null}
    ${rows.map(r => {
        const m = metaOf(r.id), sel = lawMode() === r.id, best = !!ab && !lawForbids(headlineScore(ab)) && ab.recommended === r.id;
        return html `<div class="dk-way${sel ? " sel" : ""}${best ? " best" : ""}" onclick=${() => pin(r.id)}>
          ${lawBadge(r.score)}<span class="dk-wn"><b>${m ? m.name : r.id}</b>
          <span class="dk-meta">${best ? "the lightest way here · " : ""}${m ? (m.steps || []).join(" → ") : ""}</span></span></div>
        ${sel ? html `<div class="dk-bill">${m && m.performs && m.performs.length ? html `<div class="dk-meta">performs ${m.performs.join(" · ")}</div>` : null}${ab ? lawBill(r.bill) : html `<div class="dk-meta">${m ? String(m.note || "") : ""} The map now paints this way; pick a place to read its bill.</div>`}</div>` : null}`;
    })}
    ${members.length ? html `<div class="dk-grp">operating ${id ? "here" : "in the federation"}</div>
      <div class="dk-chips">${members.map(m => {
        const r = lawRecipe(m.recipe);
        return chip(m.place === id, String(m.scope), () => lawGoto(m.place), "runs " + (r ? String(r.name) : m.recipe));
    })}</div>` : null}
    ${ourBodies.length ? html `<div class="dk-grp">our bodies here</div>
      <div class="dk-chips dk-bodies">${ourBodies.map(b => chip(lawBodyPlace(b) === id, b.name, () => openBody(b), "declared in " + (placeOf(lawBodyPlace(b)).name) + " — read it whole"))}</div>` : null}
    ${arcs.length ? html `<div class="dk-grp">supply arcs — the border is a crossing</div>
      ${arcs.map((a, i) => html `<div class="dk-way" onclick=${() => { lawLeg.set("export"); lawArc.set(i); }}>
        <span class="dk-b" style="--tier:${a.crossesBorder ? "#d4824a" : "#7a8088"}">${String(a.burden)}</span>
        <span class="dk-wn"><b>${a.fromName} → ${a.toName}</b><span class="dk-meta">${a.good}${a.crossesBorder ? " · crosses a border" : " · within one jurisdiction"}</span></span></div>`)}` : null}
    ${kids.length && kids.length <= 30 ? html `<div class="dk-grp">within ${p.name}</div>
      <div class="dk-chips">${kids.map(([cid, c]) => chip(false, c.name, () => lawGoto(cid)))}</div>` : null}`;
}
// PROGRAM — what we ask of the law HERE: the demands in force at this place,
// each by its four cells, and how each structural demand stands here.
const LAW_CLASSES = ["civic", "property", "value", "force", "border"];
const LAW_STATUS = { won: ["✓", "won here"], partly: ["½", "partly won here"], standing: ["●", "standing here"], unread: ["○", "unread here"], general: ["·", ""] };
// What the cells say to do about a demand, in words: demand the state's version
// withered (we already provide all we want of it), build first (something we want
// is not yet done), or reject (only the shell is left). A place that has already
// shed the whole shell has nothing left to press.
const LAW_MOVE = {
    wither: ["ready to demand", "we already provide all we want of it, so the state's version can wither"],
    absorb: ["build first", "something we want of it, no way a member runs does yet"],
    transform: ["reject", "only the shell is left: press to change it"],
    keep: ["", ""],
};
const LAW_MOVE_RANK = { wither: 0, absorb: 1, transform: 2, keep: 3 };
const lawMoveOf = (r, status) => status === "won" ? "keep" : r.move || "keep";
function lawMoveMark(r, status) {
    const move = lawMoveOf(r, status);
    return LAW_MOVE[move][0] ? html `<span class="mv ${move}" title="${LAW_MOVE[move][1]}">${LAW_MOVE[move][0]}</span>` : null;
}
function lawMoveLine(r, status) {
    if (status === "won")
        return html `<div class="dk-meta">nothing left to press here — the coercive shell is already shed</div>`;
    const move = lawMoveOf(r, status);
    return LAW_MOVE[move][0] ? html `<div class="dk-meta"><b>${LAW_MOVE[move][0]}</b> — ${LAW_MOVE[move][1]}</div>` : null;
}
function lawAbolitions(id) {
    const demands = ((lawData.structuralProgram || {}).demands || []);
    // at the world there is no place to be unread: the general case is the reading
    const stand = (d) => {
        const r = lawReadingAt(id, d);
        return { d, r, status: (id ? r.reading.status : "general") };
    };
    return html `${LAW_CLASSES.map(cls => {
        // the move we can make now leads its class; a demand already won sinks to the end
        const rank = (x) => LAW_MOVE_RANK[lawMoveOf(x.r.reading, x.status)];
        const rows = demands.filter(d => d.class === cls).map(stand).sort((a, b) => rank(a) - rank(b));
        if (!rows.length)
            return null;
        // a class says what has been read in it, in words; the marks live on the rows
        const read = ["won", "partly", "standing"]
            .map(s => [s, rows.filter(x => x.status === s).length]).filter(([, n]) => n);
        const ready = rows.filter(x => lawMoveOf(x.r.reading, x.status) === "wither").length;
        const tally = [!id ? `${rows.length} demands` : read.length ? read.map(([s, n]) => `${n} ${s}`).join(" · ") : "none read here",
            ready ? `${ready} ready to demand` : ""].filter(Boolean).join(" · ");
        return html `<details class="dk-cls"${raw(rows.some(x => x.r.at) ? " open" : "")}>
      <summary><b>${cls}</b><span class="dk-meta">${tally}</span></summary>
      ${rows.map(({ d, r, status }) => html `<details class="dk-ab ${status}">
        <summary><span class="st ${status}" title="${LAW_STATUS[status][1]}">${LAW_STATUS[status][0]}</span><span class="nm"><b>${d.name}</b>${status === "unread" || status === "general" ? null : html ` <span class="dk-meta">${LAW_STATUS[status][1]}</span>`}</span>${lawMoveMark(r.reading, status)}</summary>
        ${lawMoveLine(r.reading, status)}
        ${r.reading.won && r.reading.won.length ? html `<div class="lw-cells"><span class="lw-cell provide"><b>shed here</b> ${r.reading.won.join(" ")}</span></div>` : null}
        ${lawCells(r.reading)}
        ${r.reading.note ? html `<div class="dk-meta">${r.reading.note}</div>` : null}
        ${r.at ? html `<div class="dk-cite">${r.reading.source} <span class="conf">${r.reading.confidence}${lawBy(r.reading.steward)}${r.reading.asOf ? " · read " + r.reading.asOf : ""}${r.at !== id ? " · read for " + placeOf(r.at).name : ""}</span></div>`
            : id ? html `<div class="dk-meta">No steward has read ${placeOf(id).name} on this yet; these are the clauses of the general case.</div>` : null}
        <div class="dk-vision">→ ${d.becomes}</div>
      </details>`)}
    </details>`;
    })}`;
}
function lawProgram(id) {
    const act = lawAct();
    if (!id) { // the world: every nation at a glance
        const nations = (lawData.nations || []).map(n => {
            const rows = (placeOf(n.id).program || []).filter(r => r.via.some(v => v.activity === act.id));
            const marks = ((lawData.structuralProgram || {}).demands || [])
                .map(d => lawReadingAt(n.id, d)).filter(r => r.at).map(r => r.reading);
            return { n, rows, marks };
        });
        const border = (lawData.program || []).filter(e => e.border);
        return html `
      <div class="dk-grp">what the law asks to ${act.verb}, by nation</div>
      ${nations.map(({ n, rows, marks }) => html `<div class="dk-way" onclick=${() => lawGoto(n.id)}>
        ${lawBadge(placeScore(placeOf(n.id)))}<span class="dk-wn"><b>${n.name}</b>
        <span class="dk-meta">${rows.length ? rows.length + (rows.length === 1 ? " demand" : " demands") : "no demand read"}${marks.map(r => html ` · <span class="st ${r.status}">${LAW_STATUS[r.status][0]}</span> ${r.name.toLowerCase()}`)}</span></span></div>`)}
      ${border.length ? html `<details class="dk-cls"><summary><b>at the border</b><span class="dk-meta">${border.length} demands ride an arc between two places</span></summary>
        ${border.map(e => html `<div class="dk-dem obtain"><b>${e.name}</b><span class="dk-meta">${(e.jurisdictions || []).map(j => j.name).join(" · ")}</span>${lawCells(e)}</div>`)}</details>` : null}
      <div class="dk-grp">the deeper program — the general case</div>
      ${lawAbolitions(null)}`;
    }
    const p = placeOf(id);
    const all = p.program || [];
    const mine = all.filter(r => r.via.some(v => v.activity === act.id));
    const unmodelled = all.filter(r => !r.via.length);
    const others = (lawData.activities || []).filter(a => a.id !== act.id)
        .map(a => ({ a, n: all.filter(r => r.via.some(v => v.activity === a.id)).length })).filter(x => x.n);
    // a long program keeps one line a demand, so the deeper program stays in view;
    // a row opens to its cells
    const dense = mine.length + unmodelled.length > 5;
    const row = (r) => {
        const e = lawEntryOf(r.name), ways = r.via.filter(v => v.activity === act.id);
        return html `<details class="dk-dem obtain${dense ? " dense" : ""}">
      <summary><b>${r.name}</b><span class="dk-meta">${r.by && placeOf(r.by) ? "asked by " + placeOf(r.by).name : ""}</span>${dense ? null : lawCells(e)}</summary>
      ${dense ? lawCells(e) : null}
      ${ways.length ? html `<div class="dk-meta">tripped by ${ways.map(v => lawModeName(v.activity, v.mode)).join(" · ")}</div>` : null}
      ${e && e.sources ? e.sources.map(src => html `<div class="dk-cite">${src}</div>`) : null}
    </details>`;
    };
    return html `
    <div class="dk-grp">the law's demands here, to ${act.verb}</div>
    ${mine.length ? mine.map(row) : html `<div class="dk-meta dk-none">no spec-bearing demand is read here for this activity</div>`}
    ${unmodelled.length ? html `<div class="dk-grp">also in force here, for ways nobody has modelled</div>${unmodelled.map(row)}` : null}
    ${others.map(({ a, n }) => html `<a class="dk-more" onclick=${() => { lawActivity.set(a.id); lawMode.set(null); }}>${n} more under ${a.name} ▸</a>`)}
    <div class="dk-grp">the deeper program, here</div>
    <div class="dk-key">${Object.entries(LAW_STATUS).filter(([k]) => k !== "general").map(([k, [mark, label]]) => html `<span><span class="st ${k}">${mark}</span> ${label.replace(" here", "")}</span>`)}</div>
    ${lawAbolitions(id)}`;
}
// SOURCES — the rules the fold landed on here, with how sure it is of each.
function lawSources(id) {
    if (!id)
        return html `<div class="dk-meta dk-none">Pick a place: the rules that fire there are cited here, each with its confidence.</div>
    <div class="dk-cite">${lawData.generatedBy || ""}</div>`;
    const p = placeOf(id), ab = placeAB(p);
    const hits = (ab && ab.hits) || [];
    const shields = (p.protections || []).filter(s => s.activity === lawActivity());
    return html `
    <div class="dk-grp">law in force here</div>
    ${hits.length ? hits.map(h => html `<div class="dk-cite">${h.source} <span class="conf">${h.confidence}${lawBy(h.steward)}${h.asOf ? " · in force " + h.asOf : ""}</span></div>`)
        : html `<div class="dk-meta dk-none">no rule fires here for this activity</div>`}
    ${shields.length ? html `<div class="dk-grp">protections in scope</div>
      ${shields.map(s => html `<div class="dk-dem shield"><b>${s.name}</b><span class="dk-meta">${s.shields}</span><div class="dk-cite">${s.source}</div></div>`)}` : null}`;
}
// AN ARC — export · border · import, the three legs a crossing is billed in.
function lawArcDocket(a) {
    const nn = (id) => { const p = placeOf(id); return p ? p.name : id; };
    const legs = [["export", "export — " + nn(a.fromNation || a.from), a.export],
        ["crossing", "at the border", a.crossing], ["import", "import — " + nn(a.toNation || a.to), a.import]];
    const leg = legs.find(l => l[0] === lawLeg()) || legs[0];
    return html `
    <div class="dk-head"><a class="dk-back" onclick=${() => lawArc.set(null)}>‹ back</a>
      <h4>${a.fromName} → ${a.toName}</h4>
      <div class="dk-sub">${a.good} · by ${a.by} · ${a.international ? "an international crossing: exported from one nation, imported into the other"
        : a.crossesBorder ? "crosses a border at " + nn(String(a.borderLevel)) + ": both ends' rules apply"
            : "both ends lie in one jurisdiction; no crossing is tripped"}</div></div>
    ${segRail(legs.map(l => [l[0], l[1].split(" — ")[0], l[2] ? l[2].burden : ""]), leg[0], k => lawLeg.set(k), "dk-tabs")}
    <div class="dk-body"><div class="dk-grp">${leg[1]}</div>${lawBill(leg[2] && leg[2].bill)}
      ${a.hits && a.hits.length ? html `<div class="dk-grp">law in force</div>${a.hits.map(h => html `<div class="dk-cite">${h.source} <span class="conf">${String(h.confidence || "")}${lawBy(String(h.steward || ""))}</span></div>`)}` : null}</div>`;
}
function lawDocket() {
    const arc = lawArc() != null ? (lawData.federation.arcs || [])[lawArc()] : null;
    if (arc)
        return lawArcDocket(arc);
    const id = lawPlaceId(), p = id ? placeOf(id) : null, act = lawAct();
    const ab = p ? placeAB(p) : null;
    const head = ab ? headlineScore(ab) : null;
    const best = ab && !lawForbids(head) ? act.modes.find(m => m.id === ab.recommended) : null;
    const tier = lawTier(head);
    const sub = !p ? `${lawData.federation.name || "the federation"} · ${(lawData.nations || []).length} nations read`
        : !ab ? "no law read here yet"
            : lawForbids(head) ? `no legal way to ${act.verb} here`
                : `to ${act.verb}: ${best ? best.name : "the lightest way"} — ${tier ? tier[1] : ""}${lawUnread(head) ? ", of what is read here" : ""}`;
    const nProgram = p ? (p.program || []).filter(r => r.via.some(v => v.activity === act.id) || !r.via.length).length
        : (lawData.program || []).filter(e => (e.activities || []).includes(act.id)).length;
    const tab = lawTab();
    return html `
    <div class="dk-head"><h4>${p ? p.name : "World"}</h4><div class="dk-sub">${sub}</div></div>
    ${segRail([["ways", "Ways", act.modes.length], ["program", "Program", nProgram], ["sources", "Sources", ab && ab.hits ? ab.hits.length : ""]], tab, k => lawTab.set(k), "dk-tabs")}
    <div class="dk-body">${tab === "program" ? lawProgram(id) : tab === "sources" ? lawSources(id) : lawWays(id)}</div>`;
}
// the rail: how to read the face. Static, so it is drawn once on entry.
function lawRail() {
    render("#lawpanel", html `
    <h4>The law, read by place</h4>
    <div class="sub">derived from each place's rules and from what the ways the federation's members run perform</div>
    <div class="grp">the map</div>
    <div class="meta">Pick an activity, then a place. The map paints each place by what the law asks of the lightest way there; pick a way in the list to paint that way instead.</div>
    <div class="grp">the four cells of a demand</div>
    <div class="lw-cells stack">
      <span class="lw-cell provide"><b>we provide</b> we already do it, in a way a member runs, and we want it: the state's check can wither</span>
      <span class="lw-cell build"><b>we build</b> we want it and no way a member runs does it yet</span>
      <span class="lw-cell bear"><b>we bear</b> we do it under duress, and do not want it: carried for now</span>
      <span class="lw-cell reject"><b>we reject</b> we neither do it nor want it: the coercive shell</span>
      <span class="lw-cell unmapped"><b>not yet mapped</b> a clause in the law's own words that nobody has mapped onto what we do</span></div>
    <div class="grp">the deeper program, in a place</div>
    <div class="meta"><span class="st won">✓</span> won here · <span class="st partly">½</span> partly · <span class="st standing">●</span> standing · <span class="st unread">○</span> no steward has read this place yet</div>`);
    d3.select("#lawpanel").style("display", "block");
}
// ── state-owning API for the core face-switcher & boot deep-link ──────────
// enter the law face: kick the loader; the effects paint once it lands.
export function lawEnter() { lawRail(); startLawEffect(); initLaw(); if (!bodies().length)
    void readBodies(); }
// URL deep-link (?face=law&place=…&view=program): the boot block in main.js
// calls this, then setFace("law"). All the law-state mutation stays in here.
export function lawDeepLink(place, view) {
    if (place) { // deep-link straight to a jurisdiction
        const orig = initLaw;
        initLaw = async function () { await orig(); if (lawLoaded.peek())
            lawGoto(place); };
    }
    if (view === "program" || view === "sources")
        lawTab.set(view);
}
// THE renders. Reading each signal unconditionally (the discipline the calendar
// face states: a read that only happens on some runs is a dependency the effect
// silently loses) means any write above repaints what depends on it — and no
// handler has to know that. The chrome goes first: the map's box is read off
// where the bar and the docket actually are.
//
// Registered on first entry, not at module scope: this module is imported BY
// main.js, so its body runs while main.js's bindings are still in their temporal
// dead zone and `stage.face` cannot be read yet.
let lawEffectOn = false;
function startLawEffect() {
    if (lawEffectOn)
        return;
    lawEffectOn = true;
    effect(() => {
        lawSel();
        lawReading();
        lawActivity();
        lawMode();
        lawTab();
        lawArc();
        lawLeg();
        bodies();
        if (!lawLoaded() || stage.face !== "law")
            return;
        render("#lawbar", lawBar());
        render("#lawdocket", lawDocket());
    });
    effect(() => {
        lawSel();
        lawReading();
        lawActivity();
        lawMode();
        lawArc();
        bodies();
        if (lawLoaded() && stage.face === "law")
            drawLaw();
    });
}
export { drawLaw, lawSizeSvg, lawRestoreSvg };
