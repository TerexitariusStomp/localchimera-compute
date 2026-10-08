// app/tabs/taxonomy.ts — the "taxonomy" face: the folksonomy cut as a treemap.
//
// The match prototype's category treemap, rehomed on the ONE tree the dial
// already holds: S.root, the commons' aggregated cut (folksonomy-template
// through the current lens), the same spine the desire wheel and the shop
// shelves draw. Nothing is fetched here and no second hierarchy is built —
// the face is a different projection of the spine, exactly as the shop's
// shelf bars are. Area is desire weight (_meanW, the wheel's own sizing;
// count of asserters where the desire signal is silent, one where both are),
// colour the node's spine hue, so a term reads the same everywhere.
//
// Click a cell to zoom into that subtree (the breadcrumb bar walks back up);
// hover shows the path root→term. The zoom root rides a signal, so the view
// re-renders on its own when the folksonomy re-folds (rebuildSpine swaps
// S.root; the dial's day-changed notifier ticks) or the theme changes.
import { html, render } from '../template.js';
import { signal, effect } from '../reactive.js';
import { S } from '../state.js';
import { day, inkFor } from '../core.js';
import { searchFilter, searchPill } from '../search.js';
// the tree's search (free-association's searchTreeForNavigation → navigateToPath):
// the dial's own search pill over the terms' names and ids; a hit zooms the
// treemap to the term (or its parent when it is a leaf) and the panel lists
// every hit with its path. Compact — a taxonomy has no clock.
const F = searchFilter({ fields: n => [n.name, n.id] });
const zoomId = signal("__root"); // the term the treemap is rooted at ("__root" = all)
const hovered = signal(null);
const findNode = (id) => {
    if (id === "__root")
        return S.root;
    const walk = (n) => n?.id === id ? n
        : (n?.children || []).map(walk).find(Boolean) || null;
    return walk(S.root);
};
const pathOf = (n) => { const p = []; for (; n && n !== S.root; n = n.parent)
    p.unshift(n); return p; };
const weight = (n) => Number(n._meanW) > 0 ? Number(n._meanW) : n.count > 0 ? n.count : 1;
function draw() {
    day(); // subscribe: a re-fold repaints
    const stage = document.getElementById("taxonomystage");
    if (!stage || !S.root)
        return;
    const root = findNode(zoomId()) || S.root;
    const W = Math.max(320, stage.clientWidth || 900);
    const H = Math.max(320, stage.clientHeight || 600);
    const h = d3.hierarchy(root, d => d.children)
        .sum(d => (d.children && d.children.length) ? 0 : weight(d))
        .sort((a, b) => Number(b.value) - Number(a.value));
    d3.treemap().size([W, H]).paddingOuter(3).paddingTop(19).paddingInner(2).round(true)(h);
    const svg = d3.select(stage).selectAll("svg").data([0]).join("svg")
        .attr("viewBox", `0 0 ${W} ${H}`)
        .attr("width", "100%").attr("height", "100%");
    const cells = svg.selectAll("g.tx-cell")
        .data(h.descendants().filter(d => d.depth > 0), (d) => d.data.id)
        .join(enter => {
        const g = enter.append("g").attr("class", "tx-cell").style("cursor", "pointer");
        g.append("rect");
        g.append("clipPath").attr("id", (d) => "tx-clip-" + d.data.id.replace(/[^\w-]/g, "_")).append("rect");
        g.append("text");
        g.append("title");
        return g;
    });
    cells.attr("transform", d => `translate(${d.x0},${d.y0})`)
        .on("mouseenter", (_, d) => hovered.set(d.data))
        .on("mouseleave", () => hovered.set(null))
        .on("click", (ev, d) => {
        ev.stopPropagation();
        if (d.children && d.children.length)
            zoomId.set(d.data.id);
    });
    cells.select("rect")
        .attr("width", d => Math.max(0, d.x1 - d.x0)).attr("height", d => Math.max(0, d.y1 - d.y0))
        .attr("fill", d => d.data.col || "#777")
        .attr("fill-opacity", d => d.children ? 0.55 : 0.9)
        .attr("stroke", "#000").attr("stroke-opacity", 0.35).attr("rx", 3);
    cells.select("clipPath rect")
        .attr("width", d => Math.max(0, d.x1 - d.x0 - 4)).attr("height", d => Math.max(0, d.y1 - d.y0));
    cells.select("text")
        .attr("clip-path", d => `url(#tx-clip-${d.data.id.replace(/[^\w-]/g, "_")})`)
        .attr("x", 4).attr("y", 13).attr("font-size", d => d.children ? 12 : 11)
        .attr("fill", d => inkFor(d.data.col || "#777"))
        .text(d => (d.x1 - d.x0 > 28 && d.y1 - d.y0 > 14) ? d.data.name : "");
    cells.select("title").text(d => pathOf(d.data).map(n => n.name).join(" › ")
        + (d.data.count ? ` · ${d.data.count} file it here` : ""));
    svg.on("click", () => { const r = findNode(zoomId()); if (r && r.parent)
        zoomId.set(r.parent === S.root ? "__root" : r.parent.id); });
}
// every term the query names, root first — read fresh per query, since the
// spine can be republished under the face
function hits() {
    const q = F.query().trim();
    if (!q)
        return [];
    const out = [];
    const walk = (n) => {
        if (n && n !== S.root && F.passesText(n))
            out.push(n);
        (n?.children || []).forEach(walk);
    };
    walk(S.root);
    return out.slice(0, 30);
}
const goTo = (n) => {
    const target = n.children && n.children.length ? n : n.parent;
    zoomId.set(!target || target === S.root ? "__root" : target.id);
    hovered.set(n);
};
function drawPanel() {
    const root = findNode(zoomId()) || S.root, hov = hovered();
    // S.root is set at boot in main.js, and draw() already returned without it
    const crumbs = [S.root, ...pathOf(root)];
    const count = (n) => { let c = 0; const w = (x) => { c++; (x.children || []).forEach(w); }; (n.children || []).forEach(w); return c; };
    const found = hits();
    render("#taxonomypanel .tx-body", html `
    <div class="tx-panel">
      <div class="tx-h">the taxonomy</div>
      ${found.length ? html `<div class="tx-hits">${found.map(n => html `<a class="tx-hit" onclick=${() => goTo(n)}>
          <span class="tx-hit-dot" style="color:${n.col || ""}">●</span> ${n.name}
          <span class="tx-hit-path">${pathOf(n).slice(0, -1).map(x => x.name).join(" › ") || "root"}</span></a>`)}</div>`
        : F.query().trim() ? html `<div class="tx-hits tx-none">nothing in the taxonomy says “${F.query().trim()}”</div>` : ""}
      <div class="tx-crumbs">${crumbs.map((n, i) => html `<span class="tx-crumb${i === crumbs.length - 1 ? " on" : ""}"
          onclick=${() => zoomId.set(n === S.root ? "__root" : n.id)}>${n === S.root ? "all" : n.name}</span>${i < crumbs.length - 1 ? " › " : ""}`)}</div>
      <div class="tx-stat"><b>${count(root)}</b> terms under ${root === S.root ? "the root" : root.name}</div>
      <div class="tx-hover">${hov ? pathOf(hov).map(n => n.name).join(" › ") : "hover a cell to see its path · click to zoom in · click the ground to zoom out"}</div>
      <div class="tx-note">The commons' own cut of its folksonomy — the same spine the
        wheel and the shop shelves draw — laid out by how much desire each term carries.
        A term filed under a different parent by more people would move; publish your
        cut from the wheel to vote.</div>
    </div>`);
}
let booted = false;
export function initTaxonomy() {
    if (!booted) {
        booted = true;
        // the panel: the search pill once (a rebuilt input eats its own focus),
        // then the body the effect redraws under it
        const panel = document.getElementById("taxonomypanel");
        if (panel && !panel.querySelector(".tx-body")) {
            const pill = searchPill(F, { placeholder: "find a term…", compact: true });
            pill.el.classList.add("tx-search");
            const body = document.createElement("div");
            body.className = "tx-body";
            panel.append(pill.el, body);
        }
        effect(draw);
        effect(drawPanel);
        document.addEventListener("playnet:theme", draw);
        new ResizeObserver(() => draw()).observe(document.getElementById("taxonomystage"));
    }
    else
        draw();
}
