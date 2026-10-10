// app/tabs/matter.ts — the RIFT face: an ecological Sankey of substance flows.
//
// Face subsystem: the environment's resources (soil, air, water) whose stocks
// DRIFT — a balanced stock is the loop closed, a drifting one is the rift, per
// nutrient. Read-only lens over S.matterFlow (matterData), with a demo
// fallback fetched by initMatter. Draws into the L.rift layer, sized from svg's
// viewBox, and reads the stage's face to know whether it is on show — all at
// call time, so the main.js <-> matter.js cycle is benign. Core calls only
// drawRift (from setFace's rift branch and the resize handler).
//
// It lays its OWN graph out (layoutMatter): a longest-path column assignment
// over the forward edges, which is a different problem from the dial's band
// geometry and shares no code with it.
import { svg } from '../layers.js';
import { L } from '../layers.js';
import { stage } from '../stage.js';

import { S } from '../state.js';
import type { WireMatterSubstance } from '../wire-rows.js';
/** A substance and the colour it is drawn in: {symbol: "N", color: "#4a7"}. */
type Substance = WireMatterSubstance;

/**
 * A node of the flow graph: a PROCESS (kind !== "resource") or a RESOURCE. An
 * `env` resource is an environment stock — soil, air, water — and those are the
 * only ones whose imbalance counts as the rift.
 */
interface MatterNode {
  id: string;
  label: string;
  kind: string;
  env?: boolean;
  /** Fractional position in the frame. Absent on the wire; layoutMatter writes it. */
  fx?: number;
  fy?: number;
}

/** An element flow from one node to another, keyed by substance. */
interface MatterLink {
  from: string;
  to: string;
  flows?: Record<string, number>;
}

/**
 * The whole graph, exactly as the planner's matter-results->wire emits it. The
 * browser never derives composition — it only draws — so this is a description
 * of a wire format, not a model this module owns.
 */
interface MatterGraph {
  substances: Substance[];
  nodes: MatterNode[];
  links: MatterLink[];
}

/** A link with its drawn width resolved (one substance, or all stacked). */
type DrawnLink = MatterLink & { eff: number };

/** A node's drawn box: where its column sits and how tall its busier side is. */
interface Box { x: number; cy: number; top: number; h: number }

let matterSel: string | null = null;   // a chosen substance to isolate, or null for all

// Pure renderer: the graph {substances, nodes, links} is built in ONE place —
// the planner's matter-results->wire over the contains relation. The browser
// never derives composition; it only draws. Data is S.matterFlow (a live
// solve) or the committed matter-snapshot.json (the real wire's output over a
// demo cycle, by tools/emit/emit-matter-snapshot.scm) — exactly like the law face.
let matterSnap: MatterGraph | null = null, matterLoaded = false, matterLoading = false;
// The one boundary cast: S.matterFlow is a spine payload, typed unknown at the
// seam, and a reader says what it expects. MatterGraph above IS that
// expectation, written out.
const matterData = (): MatterGraph | null =>
  (S.matterFlow as MatterGraph) || matterSnap;
async function initMatter(): Promise<void> {
  if (matterLoaded || matterLoading) return;
  matterLoading = true;
  try {
    matterSnap = (S.matterFlow as MatterGraph)
              || await (await fetch("data/snapshots/matter-snapshot.json")).json();
    matterLoaded = true;
  } catch (e) { console.warn("[matter] load failed", e); matterSnap = null; }
  matterLoading = false;
  if (stage.face === "rift") drawRift();
}
const lkey = (l: MatterLink) => l.from + "→" + l.to;
const cubicLink = (x0: number, y0: number, x1: number, y1: number) => { const mx = (x0 + x1) / 2; return `M${x0},${y0}C${mx},${y0} ${mx},${y1} ${x1},${y1}`; };
const loopLink = (x0: number, y0: number, x1: number, y1: number, lane: number) => { const b = Math.min(0.06 * 800, 56);
  return `M${x0},${y0} C${x0 + b},${y0} ${x0 + b},${lane} ${x0},${lane} L${x1},${lane} C${x1 - b},${lane} ${x1 - b},${y1} ${x1},${y1}`; };
// auto-layout for server-supplied graphs (the demo positions its own nodes):
// depth = longest path over FORWARD edges (DFS back-edges are the circular
// returns), sinks pushed to the far right, nodes stacked within each column.
// Mutates each node's fx/fy in place.
function layoutMatter(nodes: Record<string, MatterNode>, links: MatterLink[]): void {
  const ids = Object.keys(nodes), out: Record<string, string[]> = {};
  ids.forEach(id => out[id] = []);
  links.forEach(l => { if (nodes[l.from] && nodes[l.to]) out[l.from].push(l.to); });
  const onstk: Record<string, number> = {}, seen: Record<string, number> = {}, back = new Set<string>();
  const dfs = (u: string): void => { seen[u] = 1; onstk[u] = 1;
    out[u].forEach(v => { if (onstk[v]) back.add(u + ">" + v); else if (!seen[v]) dfs(v); });
    onstk[u] = 0; };
  const hasIn: Record<string, number> = {}; links.forEach(l => { if (nodes[l.to]) hasIn[l.to] = 1; });
  ids.filter(id => !hasIn[id]).forEach(id => { if (!seen[id]) dfs(id); });   // start from inflow-less roots
  ids.forEach(id => { if (!seen[id]) dfs(id); });
  const depth: Record<string, number> = {}; ids.forEach(id => depth[id] = 0);
  for (let it = 0; it < ids.length; it++) { let ch = false;
    links.forEach(l => { if (back.has(l.from + ">" + l.to) || !nodes[l.from] || !nodes[l.to]) return;
      if (depth[l.from] + 1 > depth[l.to]) { depth[l.to] = depth[l.from] + 1; ch = true; } });
    if (!ch) break; }
  let md = Math.max(1, ...ids.map(id => depth[id]));
  // terminal resources (nothing withdraws from them — a pure accumulation) sit far right
  ids.forEach(id => { if (!out[id].length) depth[id] = md + 1; });
  md = Math.max(1, ...ids.map(id => depth[id]));
  const cols: Record<string, string[]> = {}; ids.forEach(id => (cols[depth[id]] = cols[depth[id]] || []).push(id));
  Object.entries(cols).forEach(([d, list]) => { list.sort(); const n = list.length;
    list.forEach((id, i) => { nodes[id].fx = (+d) / md; nodes[id].fy = n === 1 ? 0.46 : 0.16 + 0.68 * (i / (n - 1)); }); });
}

function drawRift(): void {
  L.rift.selectAll("*").remove();
  const vb = (svg.attr("viewBox") || "0 0 760 560").split(/[ ,]+/).map(Number);
  const X0 = vb[0], Y0 = vb[1], W = vb[2], H = vb[3];
  const D = matterData();
  if (!D) { initMatter(); return; }            // not loaded yet — fetch, then redraw
  const subs = D.substances;
  const subColor = Object.fromEntries(subs.map(s => [s.symbol, s.color]));
  const fs = Math.max(9, W * 0.0135);
  const pad = { l: 0.05 * W, r: 0.13 * W, t: Math.max(0.08 * H, fs * 5), b: 0.05 * H };
  const px = (fx: number) => X0 + pad.l + (W - pad.l - pad.r) * fx;
  const py = (fy: number) => Y0 + pad.t + (H - pad.t - pad.b) * fy;
  const nW = Math.max(7, W * 0.009);

  // nodes → object keyed by id; links carry element flows directly (produce =
  // process→resource, consume = resource→process). Auto-lay-out if unplaced.
  const nodes: Record<string, MatterNode> =
    Object.fromEntries(D.nodes.map((n): [string, MatterNode] => [n.id, { ...n }]));
  const allLinks = D.links.map(l => ({ ...l, flows: l.flows || {} }));
  if (!Object.values(nodes).every(n => n.fx != null)) layoutMatter(nodes, allLinks);
  // fx is set for every node by here: either the graph carried it or layoutMatter
  // just wrote it for all of them.
  const isCirc = (l: MatterLink) => px(nodes[l.to].fx!) <= px(nodes[l.from].fx!);  // target left of source
  const isRes = (id: string) => nodes[id] && nodes[id].kind === "resource";

  // each RESOURCE's net drift = produced into it − consumed from it, per element.
  // A balanced stock drifts 0 (the loop closed); the environment stocks that DON'T
  // are the rift.
  const drift: Record<string, Record<string, number>> = {};
  Object.keys(nodes).forEach(id => { if (isRes(id)) drift[id] = {}; });
  allLinks.forEach(l => { subs.forEach(({ symbol: k }) => { const v = l.flows[k] || 0;
    if (drift[l.to])   drift[l.to][k]   = (drift[l.to][k]   || 0) + v;    // produced into
    if (drift[l.from]) drift[l.from][k] = (drift[l.from][k] || 0) - v; }); });  // consumed from
  const netDrift = (id: string) => { const d = drift[id] || {}; return subs.reduce((s, { symbol: k }) => s + (d[k] || 0), 0); };

  // each link's effective drawn width: the isolated substance, or all stacked.
  const links = allLinks.map(l => {
    const eff = matterSel ? (l.flows[matterSel] || 0) : subs.reduce((s, { symbol: k }) => s + (l.flows[k] || 0), 0);
    return { ...l, eff }; }).filter(l => l.eff > 1e-9);

  // the rift per substance = how out-of-balance the ENVIRONMENT's stocks are:
  // Σ|net drift| of env resources over the substance they handle. Balanced → 0;
  // a stock that only fills (runoff) or only drains (soil) → toward 1.
  const losD: Record<string, number> = {}, grossD: Record<string, number> = {};
  Object.keys(nodes).forEach(id => { if (isRes(id) && nodes[id].env) {
    const d = drift[id] || {}; subs.forEach(({ symbol: k }) => losD[k] = (losD[k] || 0) + Math.abs(d[k] || 0)); } });
  allLinks.forEach(l => { if ((isRes(l.from) && nodes[l.from].env) || (isRes(l.to) && nodes[l.to].env))
    subs.forEach(({ symbol: k }) => grossD[k] = (grossD[k] || 0) + (l.flows[k] || 0)); });
  const rift = (k: string) => { const L = losD[k] || 0, G = grossD[k] || 0; return G > 0 ? Math.min(1, L / G) : 0; };

  // a node's height is its busier side; the busiest node sets the mass→px scale
  const outOf = (id: string) => links.filter(l => l.from === id);
  const inOf  = (id: string) => links.filter(l => l.to === id);
  const nodeVal = (id: string) => Math.max(outOf(id).reduce((s, l) => s + l.eff, 0),
                                 inOf(id).reduce((s, l) => s + l.eff, 0));
  const ids = Object.keys(nodes);
  const SCALE = (H - pad.t - pad.b) * 0.34 / Math.max(1, ...ids.map(nodeVal));
  const fwdFirst = (ls: DrawnLink[]) => ls.slice().sort((a, b) => (isCirc(a) ? 1 : 0) - (isCirc(b) ? 1 : 0));

  // stack each node's links: forward links on top, circular ones below, so the
  // loops peel off the bottom and dive under. Record each link's slot tops.
  const box: Record<string, Box> = {}, srcTop: Record<string, number> = {}, tgtTop: Record<string, number> = {};
  ids.forEach(id => {
    const cy = py(nodes[id].fy!), h = nodeVal(id) * SCALE;
    box[id] = { x: px(nodes[id].fx!), cy, top: cy - h / 2, h };
    let co = box[id].top; fwdFirst(outOf(id)).forEach(l => { srcTop[lkey(l)] = co; co += l.eff * SCALE; });
    let ci = box[id].top; fwdFirst(inOf(id)).forEach(l => { tgtTop[lkey(l)] = ci; ci += l.eff * SCALE; });
  });

  // links: circular first (drawn under), then forward. Each is a stack of
  // per-substance strokes offset within the band — equal slot heights at both
  // ends keep the offsets constant, so parallel strokes give a clean ribbon.
  const lane0 = Y0 + H - pad.b;
  const drawLinks = (circ: boolean) => links.filter(l => isCirc(l) === circ).forEach((l, idx) => {
    const sx = box[l.from].x + nW / 2, tx = box[l.to].x - nW / 2;
    const sMid = srcTop[lkey(l)] + l.eff * SCALE / 2, tMid = tgtTop[lkey(l)] + l.eff * SCALE / 2;
    const lane = lane0 - idx * Math.max(8, l.eff * SCALE * 0.18);
    const dim = 0.82;
    let cum = 0;
    subs.forEach(({ symbol: k }) => {
      if (matterSel && k !== matterSel) return;
      const v = l.flows[k] || 0; if (v <= 0) return;
      const oy = ((cum + v / 2) - l.eff / 2) * SCALE; cum += v;
      const d = circ ? loopLink(sx, sMid + oy, tx, tMid + oy, lane) : cubicLink(sx, sMid + oy, tx, tMid + oy);
      L.rift.append("path").attr("d", d).attr("fill", "none")
        .attr("stroke", subColor[k]).attr("stroke-width", Math.max(0.5, v * SCALE)).attr("opacity", dim);
    });
  });
  drawLinks(true); drawLinks(false);

  // nodes + labels. A process is navy. A resource is coloured by its balance:
  // an environment stock that's filling (carbon → air, runoff) is red, draining
  // (soil mined) is amber, balanced is green; the economy's own resources are grey.
  ids.forEach(id => {
    const b = box[id], nd = nodes[id], right = nd.fx! > 0.88;
    const net = isRes(id) ? netDrift(id) : 0;
    L.rift.append("rect").attr("x", b.x - nW / 2).attr("y", b.top).attr("width", nW)
      .attr("height", Math.max(2, b.h)).attr("rx", 2)
      .attr("fill", !isRes(id) ? "#23394e"                       // a process
                  : !nd.env    ? "#9bb0c4"                       // economy resource (in flight)
                  : net >  1e-6 ? "#7a3b3b"                       // env stock filling — the rift
                  : net < -1e-6 ? "#9c7430"                       // env stock draining — the rift
                  :               "#3f7d63");                     // env stock balanced — closed
    if (right)
      L.rift.append("text").attr("x", b.x + nW * 1.2).attr("y", b.cy).attr("font-size", fs)
        .attr("fill", "#3a5168").attr("dominant-baseline", "central").text(nd.label);
    else
      L.rift.append("text").attr("x", b.x).attr("y", b.top - fs * 0.55).attr("font-size", fs)
        .attr("fill", "#3a5168").attr("font-weight", 600).attr("text-anchor", "middle").text(nd.label);
  });

  // ── header band (reserved by pad.t): title + substance buttons ──
  const tx0 = X0 + pad.l, ty0 = Y0 + fs * 1.6;
  L.rift.append("text").attr("x", tx0).attr("y", ty0).attr("font-size", fs * 1.5)
    .attr("font-weight", 700).attr("fill", "#2c4a6e").text("matter");
  L.rift.append("text").attr("x", tx0 + fs * 5.2).attr("y", ty0).attr("font-size", fs * 0.92)
    .attr("fill", "#7a8aa0").text("substance flow · the % each loses from the loop — the rift");

  // selector = legend = rift readout, all on the buttons: "all" + one chip per
  // substance showing its lost share; click to isolate that substance.
  let cxp = tx0;
  const chip = (lab: string, val: string | null, col: string | null, pct: number | null) => {
    const text = pct == null ? lab : lab + "  " + Math.round(pct * 100) + "%";
    const on = matterSel === val, w = text.length * fs * 0.6 + fs * (col ? 2.0 : 1.2);
    const g = L.rift.append("g").style("cursor", "pointer").on("click", () => { matterSel = val; drawRift(); });
    g.append("rect").attr("x", cxp).attr("y", ty0 + fs * 1.0).attr("width", w).attr("height", fs * 1.6)
      .attr("rx", fs * 0.8).attr("fill", on ? "#2c4a6e" : "#eef1f5");
    if (col) g.append("rect").attr("x", cxp + fs * 0.6).attr("y", ty0 + fs * 1.46).attr("width", fs * 0.72)
      .attr("height", fs * 0.72).attr("rx", 1).attr("fill", col);
    g.append("text").attr("x", cxp + (col ? fs * 1.62 : fs * 0.62)).attr("y", ty0 + fs * 2.04)
      .attr("font-size", fs * 0.85).attr("fill", on ? "#fff" : "#3a5168").text(text);
    cxp += w + fs * 0.5;
  };
  chip("all", null, null, null);
  subs.forEach(({ symbol: k, color: c }) => chip(k, k, c, rift(k)));
}

export { drawRift };
