// app/tabs/web.ts — the "web" face: the SELECTED SCOPE's recipes as ONE graph.
//
// The plan face lays the same recipes out as stages in production time, and to
// do that it cuts every cycle. This face keeps them. A good is a node, a
// process is a node, a flow is an edge — consume runs good→process, produce
// runs process→good — and the graph is drawn by a force layout, so a loop
// (waste → compost → soil → vegetables → waste) reads as a loop.
//
// Three readings sit on the one drawing:
//
//   SECTORS   every process belongs to a sector — the head of the need path
//             its recipe serves (nourishment, movement, rest…). A sector starts
//             FOLDED: one dashed node standing for its whole interior, with
//             only the goods that cross its boundary drawn. Tap it and it
//             opens in place: its processes appear inside a dashed hull, wired
//             to the goods they actually touch. Tap the hull's name to fold it.
//             That is the folksonomy at work — a sector is a term, and its
//             fillers are the recipes classified under it.
//   HOLES     a good NOTHING in this scope makes is a source hole; a good
//             NOTHING here takes, and no need asks for, is a sink hole. Both
//             draw dashed and are listed on the rail as the scope's open ends,
//             ranked by how much of the plan's flow passes through them — the
//             mapping work in order of what it carries. Once the recipe store
//             holds explicit holes (a term plus its ports and no steps) they
//             land here through the same list.
//   LOOPS     a strongly connected component of the graph is a closed loop of
//             reproduction; its nodes and edges draw green. The count of loops
//             closed against open ends is the scope's circularity, read off
//             the same edges the solve uses.
//
//   REACTIONS the same web as a directed HYPERGRAPH: a process is a hyperedge
//             from its reactant set to its product set, drawn as a BUNDLE —
//             the tails curve in from the reactants to one junction, the
//             junction is a chevron carrying the process's name, the heads
//             fan out to the products — over a faint hull of the set. The
//             goods are the only nodes. That is the chemist's reaction
//             network (docs/playnet.typ "A reaction network is a plan"): the
//             flow quantities are the stoichiometric coefficients, and the
//             solve's activity levels are the fluxes. The head toggles between
//             the two drawings; the layout underneath is one and the same.
//
//   OFFERS    a hole selected opens as a SPACE OF OFFERS: every recipe that
//             could fill it — the scope's own whose output conforms to the
//             port, another commune's library where one is in hand — each a
//             proposal away, and beside them the door to write a new one.
//             An EXPLICIT hole (a step tagged "hole", knowledge/holes.scm)
//             is a process known by its boundary: it draws dashed, its ports
//             are its flows, and it yields on the solve once mapped.
//
// Tapping a good traces it: everything upstream and downstream lights, the
// rest fades. Positions survive a fold/unfold, so the reader keeps their
// bearings. Scope-reactive on the same two pushes as the plan face. Drafts
// (tabs/web-draft.ts) draw beside the real recipes while they are written, and
// a step armed for its flows turns a tap on a good into a flow of it.

import { esc } from '../template.js';
import type { ScopeRecipe, ScopeRecipeStep, ScopeFlow, Plan } from '../seam.js';
import { on } from '../bus.js';
import { PLAN } from '../core.js';
import { readStr, writeStr } from '../store.js';
import { recipes as scopeRecipes, recipeById, recipeOutSpec, scopeName, knownNeeds } from '../recipe-graph.js';
import { S } from '../state.js';
import { holdPanelOpen } from '../panel.js';
import { DEMO_RECIPES, DEMO_RECIPES_DE, DEMO_SCOPE_PLAN } from '../demo.js';
import { scopesSig, scopeSig } from '../scope.js';
import { wire } from '../forum/wire.js';
import { drafts, asRecipes as draftRecipes, armed, arm, addFlowFromTap, newDraft, edit as editDraft, editing, renderBuilder } from './web-draft.js';
import { relocationOf, flowChip, standingRow } from './recipe-render.js';
import { K } from "../keys.js";
// how far short of the whole a recipe's record says it delivers under the stress live now, 0..1
const strainOf = (r?: { yield?: number | string } | null): number => Math.min(1, Math.max(0, 1 - Number(r?.yield ?? 1)));

// ── the graph ──────────────────────────────────────────────────────────────

type NodeKind = "good" | "proc" | "sector";
type HoleKind = "source" | "sink" | "explicit";
type Cut = "need" | "activity";
const MARKERS = new Set(["hole", "whole-count", "whole"]);   // tags that classify nothing

interface WNode extends d3.SimulationNode {
  id: string;
  kind: NodeKind;
  label: string;
  emoji: string;
  /** the sector this node sits under: a process's recipe, a good's first maker (else first taker) */
  sector: string;
  hole?: HoleKind;
  /** an explicit hole's folksonomy term */
  term?: string;
  /** a step of a draft being written on this device */
  draft?: boolean;
  /** the step's balance over the tracked elements: "closed", "open" (the rift at this step), or "" untracked */
  balance?: string;
  /** a good only ever USED — a tool, a place — never consumed or made here */
  means?: boolean;
  /** a good that meets independent demand */
  final?: boolean;
  /** quantity through the node: the larger of what comes in and what goes out */
  flow: number;
  unit: string;
  /** on a closed loop */
  loop?: boolean;
  /** proc: living labour, in hours; sector: its processes' sum */
  hours: number;
  /** sector: how many processes it folds */
  members: number;
  /** production stage: a source or a means stands at 0, a process one past the deepest good it consumes,
   *  a good at its makers' deepest — the flow layout's column, cycles broken at their back edge */
  stage: number;
  r: number;
  step?: ScopeRecipeStep;
  recipe?: ScopeRecipe;
  /** proc: every recipe that lists this process — more than one where the step's own id is shared, one otherwise. */
  recipes?: ScopeRecipe[];
}

type LinkKind = "consume" | "produce" | "use";

interface WLink extends d3.SimulationLink<WNode> {
  id: string;
  kind: LinkKind;
  q: number;
  u: string;
  loop?: boolean;
}

interface Graph {
  nodes: WNode[];
  links: WLink[];
  /** every sector, in first-seen order */
  sectors: string[];
  /** the open ends, heaviest flow first */
  holes: WNode[];
  /** closed loops: how many, and how many nodes they hold */
  loops: number;
  loopNodes: number;
}

/**
 * The need a recipe serves: its own `need`, else the plan need that names it
 * (live recipes ride the wire without one, and the plan's needs carry the
 * recipe id). The sector is the head of that path — the demand-side cut.
 */
function needOf(r: ScopeRecipe, p: Plan): string {
  if (r.need) return r.need;
  const n = (p.needs || []).find(x => x.recipeId && x.recipeId === r.id);
  return n ? n.id : "";
}
const activityOf = (r: ScopeRecipe): string =>
  (r.steps || []).flatMap(s => s.tags || []).find(t => !MARKERS.has(t)) || "";
const sectorOf = (r: ScopeRecipe, p: Plan, cut: Cut): string =>
  (cut === "activity" ? activityOf(r).split("/")[0] : needOf(r, p).split("/")[0]) || "unsorted";
const num = (x: unknown): number => Number(x) || 0;
const n1 = (x: number): string => (x % 1 ? x.toFixed(1) : String(x));
const good = (spec: string): string => `g:${spec}`;
/** A link end's id — the string it starts as, or the node d3 swaps in once the layout runs. */
const endId = (e: WNode | string | number): string => (typeof e === "object" ? e.id : String(e));
const isProduce = (f: ScopeFlow): boolean => !f.action || f.action === "produce";

/** The specs the plan's needs pull on — the finals — expressed against the recipe library. */
function finalSpecs(p: Plan): Set<string> {
  const live = Array.isArray(p.flow) && p.flow.length > 0;
  const out = new Set<string>();
  (p.needs || []).forEach(n => {
    if (live) { out.add(n.id); return; }
    const r = n.recipeId ? recipeById(n.recipeId) : null;
    const s = r ? recipeOutSpec(r) : "";
    if (s) out.add(s);
  });
  return out;
}

/** Tarjan's strongly connected components over the material edges (consume + produce). */
function loopsOf(nodes: WNode[], links: WLink[]): { loop: Set<string>; loops: number } {
  const adj = new Map<string, string[]>();
  nodes.forEach(n => adj.set(n.id, []));
  links.forEach(l => { if (l.kind !== "use") adj.get(endId(l.source))?.push(endId(l.target)); });
  let index = 0;
  const idx = new Map<string, number>(), low = new Map<string, number>(), onStack = new Set<string>();
  const stack: string[] = [], loop = new Set<string>();
  let loops = 0;
  const visit = (v: string): void => {
    idx.set(v, index); low.set(v, index); index++;
    stack.push(v); onStack.add(v);
    for (const w of adj.get(v) || []) {
      if (!idx.has(w)) { visit(w); low.set(v, Math.min(low.get(v)!, low.get(w)!)); }
      else if (onStack.has(w)) low.set(v, Math.min(low.get(v)!, idx.get(w)!));
    }
    if (low.get(v) === idx.get(v)) {
      const comp: string[] = [];
      let w: string;
      do { w = stack.pop()!; onStack.delete(w); comp.push(w); } while (w !== v);
      if (comp.length > 1) { loops++; comp.forEach(c => loop.add(c)); }
    }
  };
  nodes.forEach(n => { if (!idx.has(n.id)) visit(n.id); });
  return { loop, loops };
}

/**
 * Production stages: the plan face's topological order with cycles kept. A
 * depth-first walk marks every BACK edge (one landing on a node still on the
 * walk's stack); the rest is acyclic, and a node's stage is its longest path
 * over those edges — a process one past the deepest good it consumes, a good
 * at its deepest maker, a source or a means at 0. The back edges are the
 * returns the flow layout bows out.
 */
function stagesOf(nodes: WNode[], links: WLink[]): void {
  const out = new Map<string, WLink[]>();
  nodes.forEach(n => out.set(n.id, []));
  links.forEach(l => { if (l.kind !== "use") out.get(endId(l.source))!.push(l); });
  const back = new Set<string>();
  const state = new Map<string, 1 | 2>();   // 1 on the stack, 2 finished
  const walk = (id: string): void => {
    state.set(id, 1);
    for (const l of out.get(id) || []) {
      const t = endId(l.target), st = state.get(t);
      if (st === 1) back.add(l.id);
      else if (!st) walk(t);
    }
    state.set(id, 2);
  };
  // the walk starts from the sources — what enters unmade — so a loop's back
  // edge is the one that returns against the direction supply actually flows
  const indeg = new Map<string, number>();
  links.forEach(l => { if (l.kind !== "use") indeg.set(endId(l.target), (indeg.get(endId(l.target)) || 0) + 1); });
  // rank: an unmade good first (the true sources), then a process with no
  // material input (an acquisition), then everything else in its own order
  const rank = (n: WNode): number => (indeg.get(n.id) || 0) > 0 ? 2 : n.kind === "good" ? 0 : 1;
  [...nodes].sort((a, b) => rank(a) - rank(b)).forEach(n => { if (!state.has(n.id)) walk(n.id); });
  const into = new Map<string, string[]>();
  links.forEach(l => { if (l.kind !== "use" && !back.has(l.id)) (into.get(endId(l.target)) || into.set(endId(l.target), []).get(endId(l.target))!).push(endId(l.source)); });
  const byId = new Map(nodes.map(n => [n.id, n]));
  const done = new Map<string, number>();
  const stage = (id: string): number => {
    if (done.has(id)) return done.get(id)!;
    const feeds = into.get(id) || [];
    const deepest = feeds.reduce((m, f) => Math.max(m, stage(f)), 0);
    const s = byId.get(id)!.kind === "proc" ? 1 + deepest : deepest;
    done.set(id, s);
    return s;
  };
  nodes.forEach(n => { n.stage = stage(n.id); });
}

/**
 * The full graph — every process of every recipe, every good they touch — before
 * any sector is folded. Built once per data push; folding is a projection of it.
 */
function buildFull(rs: ScopeRecipe[], p: Plan, cut: Cut): Graph {
  const nodes = new Map<string, WNode>();
  const links: WLink[] = [];
  const sectors: string[] = [];
  const producers = new Map<string, string[]>(), consumers = new Map<string, string[]>();
  const inflow = new Map<string, number>(), outflow = new Map<string, number>();
  const add = (k: Map<string, number>, id: string, q: number): void => { k.set(id, (k.get(id) || 0) + q); };

  const goodNode = (f: ScopeFlow, sector: string): WNode => {
    const spec = f.spec || "";
    let g = nodes.get(good(spec));
    if (!g) {
      g = { id: good(spec), kind: "good", label: f.name || spec, emoji: f.emoji || "•", sector,
            flow: 0, unit: f.u || "", hours: 0, members: 0, stage: 0, r: 14 };
      nodes.set(g.id, g);
    } else if (!g.emoji || g.emoji === "•") g.emoji = f.emoji || g.emoji;
    return g;
  };

  rs.forEach(r => {
    const sector = sectorOf(r, p, cut);
    if (!sectors.includes(sector)) sectors.push(sector);
    (r.steps || []).forEach((s, i) => {
      // a stable process id (the RecipeProcess's own store id) draws the SAME
      // process once even where two recipes list it; demo/draft steps carry
      // none, so fall back to a per-recipe synthesized id as before
      const pid = s.id ? `p:${s.id}` : `p:${r.id || r.name || "recipe"}#${i}`;
      const seen = nodes.get(pid);
      if (seen && seen.kind === "proc") { (seen.recipes ||= []).push(r); return; }   // its flows are already built
      const proc: WNode = { id: pid, kind: "proc", label: s.name || "step", emoji: s.emoji || r.emoji || "▸",
                            sector, flow: 0, unit: "", hours: num(s.hours), members: 1, stage: 0, r: 12, step: s, recipe: r, recipes: [r] };
      if ((s.tags || []).includes("hole")) { proc.hole = "explicit"; proc.term = (s.tags || []).find(t => !MARKERS.has(t)) || ""; proc.r = 18; }
      if ((r.id || "").startsWith("draft:")) proc.draft = true;
      if (s.balance === "closed" || s.balance === "open") proc.balance = s.balance;
      nodes.set(pid, proc);
      (s.in || []).forEach(f => {
        if (f.action === "work") { if (!s.hours) proc.hours += num(f.q); return; }
        if (!f.spec) return;
        const g = goodNode(f, sector);
        const kind: LinkKind = f.action === "use" ? "use" : "consume";
        links.push({ id: `${g.id}>${pid}:${kind}`, source: g.id, target: pid, kind, q: num(f.q), u: f.u || "" });
        if (kind === "consume") { add(outflow, g.id, num(f.q)); (consumers.get(g.id) || consumers.set(g.id, []).get(g.id)!).push(pid); }
      });
      (s.out || []).forEach(f => {
        if (!f.spec || !isProduce(f)) return;
        const g = goodNode(f, sector);
        links.push({ id: `${pid}>${g.id}:produce`, source: pid, target: g.id, kind: "produce", q: num(f.q), u: f.u || "" });
        add(inflow, g.id, num(f.q));
        const made = producers.get(g.id) || producers.set(g.id, []).get(g.id)!;
        made.push(pid);
        // a good belongs to the sector that MAKES it — the first maker wins
        if (made.length === 1) g.sector = sector;
      });
    });
  });

  // the live solve's own quantities, where it ran: what each spec actually carried
  (p.flow || []).forEach(pr => {
    const gid = good(pr.specId);
    if (nodes.has(gid)) add(inflow, gid, num(pr.q));
    (pr.in || []).forEach(f => { if (f.action === "consume" && nodes.has(good(f.id))) add(outflow, good(f.id), num(f.q)); });
  });

  const finals = finalSpecs(p);
  const all = [...nodes.values()];
  all.forEach(n => {
    if (n.kind !== "good") return;
    n.flow = Math.max(inflow.get(n.id) || 0, outflow.get(n.id) || 0);
    n.final = finals.has(n.id.slice(2));
    const made = (producers.get(n.id) || []).length > 0, taken = (consumers.get(n.id) || []).length > 0;
    if (!made && !taken) n.means = true;
    else if (!made) n.hole = "source";
    else if (!taken && !n.final) n.hole = "sink";
    n.r = 12 + Math.min(10, Math.sqrt(n.flow));
  });
  all.forEach(n => { if (n.kind === "proc") n.flow = links.filter(l => l.target === n.id && l.kind === "consume").reduce((a, l) => a + l.q, 0); });

  const { loop, loops } = loopsOf(all, links);
  all.forEach(n => { n.loop = loop.has(n.id); });
  stagesOf(all, links);
  links.forEach(l => { l.loop = loop.has(endId(l.source)) && loop.has(endId(l.target)); });

  const holes = all.filter(n => n.hole && !n.draft).sort((a, b) => b.flow - a.flow || a.label.localeCompare(b.label));
  return { nodes: all, links, sectors, holes, loops, loopNodes: loop.size };
}

/**
 * The graph as drawn: every process of a FOLDED sector collapses into one
 * sector node, its edges re-aimed at that node and merged by (end, end, kind);
 * a good touched only from inside one folded sector disappears with it, unless
 * it is a hole or a final — those are the scope's boundary and always show.
 */
function fold(full: Graph, open: Set<string>): Graph {
  const folded = new Set(sectors ? full.sectors.filter(s => !open.has(s)) : []);
  const nodes = new Map<string, WNode>();
  const sectorNode = (s: string): WNode => {
    const id = `s:${s}`;
    let n = nodes.get(id);
    if (!n) {
      n = { id, kind: "sector", label: s, emoji: "", sector: s, flow: 0, unit: "", hours: 0, members: 0, stage: 0, r: 30 };
      nodes.set(id, n);
    }
    return n;
  };
  full.nodes.forEach(n => {
    if (n.kind === "proc" && folded.has(n.sector) && !n.draft) {
      const sn = sectorNode(n.sector); sn.members += 1; sn.hours += n.hours; sn.loop = sn.loop || n.loop; sn.stage = Math.max(sn.stage, n.stage);
    } else if (n.kind === "proc") nodes.set(n.id, n);
  });
  const byId = new Map(full.nodes.map(n => [n.id, n]));
  const endOf = (id: string): string => {
    const n = byId.get(id)!;   // every link end is a node built beside it
    return n.kind === "proc" && folded.has(n.sector) ? `s:${n.sector}` : id;
  };
  const merged = new Map<string, WLink>();
  full.links.forEach(l => {
    const s = endOf(endId(l.source)), t = endOf(endId(l.target));
    const id = `${s}>${t}:${l.kind}`;
    const m = merged.get(id);
    if (m) { m.q += l.q; m.loop = m.loop || l.loop; }
    else merged.set(id, { ...l, id, source: s, target: t });
  });
  // the goods that survive: on the boundary, or touched by something drawn
  const touched = new Map<string, Set<string>>();
  merged.forEach(l => {
    for (const [g, other] of [[endId(l.source), endId(l.target)], [endId(l.target), endId(l.source)]])
      (touched.get(g) || touched.set(g, new Set()).get(g)!).add(other);
  });
  full.nodes.forEach(n => {
    if (n.kind !== "good") return;
    const t = touched.get(n.id) || new Set<string>();
    const onlyInside = t.size === 1 && [...t][0] === `s:${n.sector}`;
    if (n.hole || n.final || (!onlyInside && t.size > 0)) nodes.set(n.id, n);
  });
  const links = [...merged.values()].filter(l => nodes.has(endId(l.source)) && nodes.has(endId(l.target)));
  return { nodes: [...nodes.values()], links, sectors: full.sectors, holes: full.holes, loops: full.loops, loopNodes: full.loopNodes };
}

// ── state ──────────────────────────────────────────────────────────────────

const open = new Set<string>();           // the sectors unfolded
// the drawing: ARROWS (a process a node, straight arrows), REACTIONS (a process a junction, its
// tails and heads a bundle over a faint hull), or BOTH — the bundle with arrowheads where the
// products land, so direction reads at a glance. Both is the default.
type Drawing = "arrows" | "reactions" | "both";
const DRAWING_KEY = K.webDrawing;
const DRAWINGS: Drawing[] = ["arrows", "reactions", "both"];
let drawing: Drawing = DRAWINGS.find(d => d === readStr(DRAWING_KEY)) || "both";
let hyper = drawing !== "arrows";   // a process is a hyperedge in the last two
const SECTORS_KEY = K.webSectors;
let sectors = readStr(SECTORS_KEY) === "1";   // the folksonomy fold: off until chosen — every process in view, no hulls
const FLOW_KEY = K.webFlow;
let flowLayout = readStr(FLOW_KEY) === "1";   // columns by production stage, supply left and demand right
type Dir = "both" | "up" | "down";
const CUT_KEY = K.webCut;
let cut: Cut = readStr(CUT_KEY) === "activity" ? "activity" : "need";
let traceDir: Dir = "both";                   // a trace from the supply flank runs down, from the demand flank up
let selected: string | null = null;       // the node being traced
let pickedRecipe: string | null = null;   // the recipe selected whole: every step of it, lit together
// a selected PROCESS starts narrow — its own flows only, the recipe it lists
// in named but not lit — since the process is the default unit a plan is
// generated from directly (docs/valueflows/algorithms/dependent-demand.md:
// "a Recipe is not really a thing, it's just a graph"); "the whole recipe"
// and "trace what it depends on" are explicit widenings from there, not a
// second tap's hidden meaning.
let procTrace = false;
/** The recipe a step belongs to — its id, else its name. */
/** Every recipe id/name that lists N — more than one where its process id is shared. Membership, not a label. */
const ridsOf = (n: WNode): string[] => (n.recipes && n.recipes.length ? n.recipes : n.recipe ? [n.recipe] : []).map(r => r.id || r.name || "");
const remembered = new Map<string, { x: number; y: number }>();   // positions across a re-layout
let full: Graph | null = null;
let drawn: Graph | null = null;        // the fold currently on the stage
let sim: d3.Simulation<WNode> | null = null;
let zoomer: d3.ZoomBehavior | null = null;
let view: d3.ZoomTransform | null = null;

/** Nodes reachable from `id` along material edges, upstream and downstream, ids of the links walked. */
function traceOf(g: Graph, id: string, dir: Dir = "both"): { nodes: Set<string>; links: Set<string> } {
  const nodes = new Set<string>([id]), links = new Set<string>();
  const walk = (from: string, forward: boolean): void => {
    g.links.forEach(l => {
      if (l.kind === "use") return;
      const s = endId(l.source), t = endId(l.target);
      const next = forward ? (s === from ? t : null) : (t === from ? s : null);
      if (next && !links.has(l.id)) { links.add(l.id); if (!nodes.has(next)) { nodes.add(next); walk(next, forward); } }
    });
  };
  if (dir !== "up") walk(id, true);
  if (dir !== "down") walk(id, false);
  return { nodes, links };
}

/** Just ID's own flows: its direct neighbours over material edges, one hop, no walk. */
function directOf(g: Graph, id: string): { nodes: Set<string>; links: Set<string> } {
  const nodes = new Set<string>([id]), links = new Set<string>();
  g.links.forEach(l => {
    if (l.kind === "use") return;
    const s = endId(l.source), t = endId(l.target);
    if (s === id) { links.add(l.id); nodes.add(t); }
    else if (t === id) { links.add(l.id); nodes.add(s); }
  });
  return { nodes, links };
}

// ── the drawing ────────────────────────────────────────────────────────────

function stageBox(): { w: number; h: number } {
  const el = document.getElementById("webstage");
  const w = el ? el.clientWidth : 800, h = el ? el.clientHeight : 600;
  return { w: Math.max(320, w), h: Math.max(320, h) };
}

function draw(): void {
  const stage = document.getElementById("webstage");
  if (!stage || !full) return;
  const g = fold(full, open);
  drawn = g;
  const { w, h } = stageBox();
  if (sim) sim.stop();

  // positions carry over; a node new to the drawing starts beside its sector
  g.nodes.forEach(n => {
    const p = remembered.get(n.id) || remembered.get(`s:${n.sector}`);
    n.x = p ? p.x + (remembered.has(n.id) ? 0 : (Math.random() - 0.5) * 40) : w / 2 + (Math.random() - 0.5) * 120;
    n.y = p ? p.y + (remembered.has(n.id) ? 0 : (Math.random() - 0.5) * 40) : h / 2 + (Math.random() - 0.5) * 120;
  });

  const svg = d3.select("#webstage svg");
  svg.attr("viewBox", `0 0 ${w} ${h}`).attr("width", w).attr("height", h);
  d3.select("#webstage").classed("is-hyper", hyper).classed("is-both", drawing === "both").classed("is-flow", flowLayout).classed("is-arming", !!armed());
  const root = svg.select("g.wb-root");
  if (view) root.attr("transform", view.toString());

  const link = root.select("g.wb-links").selectAll("path").data(g.links, d => d.id)
    .join("path")
    .attr("class", d => `wb-link wb-${d.kind}${d.loop ? " is-loop" : ""}`)
    .attr("stroke-width", d => 1 + Math.min(6, Math.sqrt(d.q)))
    .attr("marker-end", d => d.kind === "use" ? null : "url(#wb-arrow)");
  link.on("click", (ev, d) => { ev.stopPropagation(); const p = procOfLink(g, d); if (p) selectProc(g, p); });
  // a hover names the flow: the edge's kind and its quantity
  link.each(function (d) { this.setAttribute("data-tip", `${d.kind} · ${n1(d.q)}${d.u ? " " + d.u : ""}`); });

  const node = root.select("g.wb-nodes").selectAll("g.wb-node").data(g.nodes, d => d.id)
    .join(enter => {
      const e = enter.append("g");
      e.append("circle");
      e.append("path").attr("class", "wb-junction").attr("d", "M-9,-7 L7,0 L-9,7 L-4,0 Z");
      e.append("text").attr("class", "wb-emoji").attr("text-anchor", "middle").attr("dy", "0.35em");
      e.append("text").attr("class", "wb-label").attr("text-anchor", "middle");
      e.append("text").attr("class", "wb-sub").attr("text-anchor", "middle");
      return e;
    })
    // strained: a process whose recipe yields less than the weather allows
    // right now rings in proportion to the shortfall (--strain, below) — the
    // same reading recipes.ts shows as a pill, and the plan takes in the solve.
    .attr("class", d => `wb-node wb-${d.kind}${d.hole ? " is-hole is-" + d.hole : ""}${d.means ? " is-means" : ""}${d.final ? " is-final" : ""}${d.loop ? " is-loop" : ""}${d.draft ? " is-draft" : ""}${d.balance === "closed" ? " is-closed" : d.balance === "open" ? " is-leak" : ""}${d.kind === "proc" && strainOf(d.recipe) > 0 ? " is-strained" : ""}`)
    .style("--strain", d => d.kind === "proc" && strainOf(d.recipe) > 0 ? strainOf(d.recipe).toFixed(2) : null)
    .attr("data-id", d => d.id)
    .attr("data-stage", d => d.stage)
    // in the reactions drawing a process is a hyperedge, and its node only an anchor for the hull
    .classed("is-anchor", d => hyper && d.kind === "proc");
  node.select("circle").attr("r", d => d.r);
  node.select("text.wb-emoji").text(d => d.kind === "sector" ? "▣" : d.emoji).attr("font-size", d => d.kind === "sector" ? 22 : Math.max(12, d.r));
  node.select("text.wb-label").attr("dy", d => d.r + 13).text(d => d.label);
  node.select("text.wb-sub").attr("dy", d => d.r + 25).text(d => {
    if (d.kind === "sector") return `${d.members} process${d.members === 1 ? "" : "es"} · tap to open`;
    if (d.hole === "explicit") return `a hole · ${d.term || "unmapped"} · tap for who could fill it`;
    if (d.kind === "proc") return (d.draft ? "draft · " : "") + (d.hours ? `${n1(d.hours)} h` : "") + (d.balance === "open" ? " · leaks" : d.balance === "closed" ? " · balanced" : "") + (strainOf(d.recipe) > 0 ? ` · delivers ${Math.round(100 * (1 - strainOf(d.recipe)))}%` : "");
    if (d.hole === "source") return "nothing here makes it";
    if (d.hole === "sink") return "nothing here takes it";
    if (d.means) return "a means, used";
    return d.flow ? `${n1(d.flow)}${d.unit ? " " + d.unit : ""}` : "";
  });
  node.on("click", (ev, d) => {
    ev.stopPropagation();
    if (d.kind === "sector") { open.add(d.sector); remember(g); draw(); return; }
    if (armed() && d.kind === "good" && addFlowFromTap(d.id.slice(2), d.emoji)) { remember(g); rebuild(); return; }
    if (d.kind === "proc") { selectProc(g, d.id); return; }
    pickedRecipe = null;
    procTrace = false;
    renderHead(g);
    selected = selected === d.id ? null : d.id;
    traceDir = "both";
    paintTrace(g);
    renderPanel(g);
    holdPanelOpen("web", !!editing() || !!(selected && d.hole));
  });
  // the datum under the gesture is the event's subject: the node, pinned while held
  const held = (ev: d3.DragEvent): WNode | null => (ev.subject && typeof ev.subject === "object" ? ev.subject as WNode : null);
  const drag = d3.drag()
    .on("start", ev => { if (sim) sim.alphaTarget(0.3).restart(); const d = held(ev); if (d) { d.fx = d.x; d.fy = d.y; } })
    .on("drag", ev => { const d = held(ev); if (d) { d.fx = ev.x; d.fy = ev.y; } })
    .on("end", ev => { if (sim) sim.alphaTarget(0); const d = held(ev); if (d) { d.fx = null; d.fy = null; } });
  drag(node);

  const maxStage = g.nodes.reduce((m, n) => Math.max(m, n.stage), 0);
  sim = d3.forceSimulation<WNode>(g.nodes)
    .force("link", d3.forceLink<WNode, WLink>(g.links).id(d => d.id)
      .distance(l => { const s = l.source as WNode, t = l.target as WNode; return 50 + s.r + t.r + (l.kind === "use" ? 20 : 0); })
      .strength(l => l.kind === "use" ? 0.2 : 0.6))
    .force("charge", d3.forceManyBody<WNode>().strength(d => d.kind === "sector" ? -900 : -320).distanceMax(420))
    .force("collide", d3.forceCollide<WNode>(d => d.r + 22))
    .force("center", flowLayout ? null : d3.forceCenter<WNode>(w / 2, h / 2).strength(0.05))
    // the flow layout: x is the production stage, supply at the left edge and the deepest stage at the right
    .force("x", flowLayout ? d3.forceX<WNode>(d => 70 + d.stage * ((w - 140) / Math.max(1, maxStage))).strength(0.9)
                           : d3.forceX<WNode>(w / 2).strength(0.03))
    .force("y", d3.forceY<WNode>(h / 2).strength(flowLayout ? 0.06 : 0.03))
    .alpha(1).alphaDecay(0.04)
    .on("tick", () => {
      // the reactions drawing: every process's junction faces from its reactants to its products,
      // and every tail arrives along that axis, every head leaves along it, so a bundle reads as one
      const axis = new Map<string, [number, number]>();
      if (hyper) g.nodes.forEach(n => { if (n.kind === "proc") { const a = facing(g, n) * Math.PI / 180; axis.set(n.id, [Math.cos(a), Math.sin(a)]); } });
      // an edge runs rim to rim, so the arrowhead lands on the target's edge rather than under it
      link.each(function (d) {
        const s = d.source as WNode, t = d.target as WNode;
        const dx = t.x! - s.x!, dy = t.y! - s.y!, len = Math.hypot(dx, dy) || 1;
        const ux = dx / len, uy = dy / len;
        const x1 = s.x! + ux * s.r, y1 = s.y! + uy * s.r, x2 = t.x! - ux * (t.r + 3), y2 = t.y! - uy * (t.r + 3);
        // in the flow layout an edge running against the stages is a return: it bows out so it reads as one
        const back = flowLayout && d.kind !== "use" && t.stage <= s.stage && t.x! < s.x! + 1;
        if (hyper && d.kind !== "use") {
          // a bundle: a tail leaves its good toward the junction and arrives along the
          // junction's axis; a head leaves along the axis and lands on its good — cubic
          // curves whose junction-side control point lies on the axis, so every flow of
          // the process meets the chevron at the same tangent
          const proc = s.kind === "proc" ? s : t;
          const gx = proc === s ? t : s;
          const [px, py] = axis.get(proc.id) || [ux, uy];
          const jx = proc.x!, jy = proc.y!;
          const gxr = gx.x! + (proc === s ? -ux : ux) * gx.r, gyr = gx.y! + (proc === s ? -uy : uy) * gx.r;
          const reach = Math.max(24, len * 0.45);
          if (proc === s) {   // a head: junction → good
            this.setAttribute("d", `M${jx},${jy} C${jx + px * reach},${jy + py * reach} ${gxr + (jx - gxr) * 0.3},${gyr + (jy - gyr) * 0.3} ${gxr},${gyr}`);
          } else {            // a tail: good → junction
            this.setAttribute("d", `M${gxr},${gyr} C${gxr + (jx - gxr) * 0.3},${gyr + (jy - gyr) * 0.3} ${jx - px * reach},${jy - py * reach} ${jx},${jy}`);
          }
        } else {
          this.setAttribute("d", back ? `M${x1},${y1} A${len * .7},${len * .7} 0 0 1 ${x2},${y2}` : `M${x1},${y1} L${x2},${y2}`);
        }
        this.classList.toggle("is-back", back);
      });
      if (hyper) node.filter(d => d.kind === "proc").select("path.wb-junction").attr("transform", d => `rotate(${facing(g, d)})`);
      node.attr("transform", d => `translate(${d.x},${d.y})`);
      paintHulls(g);
    });
  paintTrace(g);
  renderHead(g);
  renderFlanks(g);
  renderPanel(g);
  const sel = selected ? g.nodes.find(n => n.id === selected) : null;
  holdPanelOpen("web", !!editing() || !!(sel && sel.hole));
  const host = document.getElementById("webdraft");
  if (host) renderBuilder(host, {
    goods: (full ? full.nodes : []).filter(n => n.kind === "good").map(n => ({ spec: n.id.slice(2), emoji: n.emoji })),
    needs: knownNeeds(),
    onChange: () => { if (drawn) remember(drawn); rebuild(); },
  });
}

/**
 * The two ends of the web, as lists. SUPPLY: every good that enters from
 * outside — the source holes, and the means — tapping one traces DOWN, to
 * every need it reaches. DEMAND: the plan's needs, tapping one traces UP from
 * the good that meets it, to every source it bottoms out in. Reading the same
 * graph from either end is the choice between the two lists.
 */
function renderFlanks(g: Graph): void {
  const p = PLAN();
  const sup = document.getElementById("websupply"), dem = document.getElementById("webdemand");
  if (!sup || !dem || !full) return;
  const entering = full.nodes.filter(n => n.kind === "good" && (n.hole === "source" || n.means))
    .sort((a, b) => (a.means ? 1 : 0) - (b.means ? 1 : 0) || b.flow - a.flow || a.label.localeCompare(b.label));
  sup.innerHTML = `<div class="wb-flank-h">supply · from outside</div>
    <div class="wb-flank-sub">what enters the web unmade. Tap one to follow it down to every need it reaches.</div>
    ${entering.map(n => `<div class="wb-fitem${n.means ? " wb-fmeans" : ""}${selected === n.id ? " is-on" : ""}" data-id="${esc(n.id)}">
      <span class="wb-femoji">${n.emoji}</span><b>${esc(n.label)}</b>
      <span class="wb-fq">${n.means ? "means" : n.flow ? n1(n.flow) + (n.unit ? " " + esc(n.unit) : "") : ""}</span></div>`).join("") || `<div class="wb-none">—</div>`}`;
  const needs = p.needs || [];
  const finalOf = (nd: { id: string; recipeId: string | null }): string | null => {
    const live = Array.isArray(p.flow) && p.flow.length > 0;
    if (live) return full!.nodes.some(n => n.id === good(nd.id)) ? good(nd.id) : null;
    const r = nd.recipeId ? recipeById(nd.recipeId) : null;
    const spec = r ? recipeOutSpec(r) : "";
    return spec && full!.nodes.some(n => n.id === good(spec)) ? good(spec) : null;
  };
  dem.innerHTML = `<div class="wb-flank-h">demand · the needs</div>
    <div class="wb-flank-sub">what the web exists to meet. Tap one to follow it up to every source it draws on.</div>
    ${needs.map(nd => { const f = finalOf(nd); const met = Math.round((Number(nd.met) || 0) * 100);
      return `<div class="wb-fitem${f ? "" : " wb-funmet"}${f && selected === f ? " is-on" : ""}" data-id="${esc(f || "")}" title="${f ? "" : "no recipe here meets it — an open end of the demand side"}">
      <span class="wb-femoji">${nd.emoji || "•"}</span><b>${esc(nd.label || nd.id)}</b>
      <span class="wb-fq">${met}%</span></div>`; }).join("") || `<div class="wb-none">—</div>`}`;
  const start = (el: HTMLElement, dir: Dir): void => {
    const id = el.dataset.id || "";
    if (!id) return;
    pickedRecipe = null;
    procTrace = false;
    selected = selected === id && traceDir === dir ? null : id;
    traceDir = dir;
    // the traced node may sit inside a folded sector: open what it touches
    openAround(id);
    remember(g); draw();
  };
  sup.querySelectorAll<HTMLElement>(".wb-fitem").forEach(el => el.onclick = () => start(el, "down"));
  dem.querySelectorAll<HTMLElement>(".wb-fitem").forEach(el => el.onclick = () => start(el, "up"));
}

/** Open every sector whose process touches the node, so a trace through it has something to light. */
function openAround(id: string): void {
  if (!full) return;
  const byId = new Map(full.nodes.map(n => [n.id, n]));
  full.links.forEach(l => {
    const other = endId(l.source) === id ? endId(l.target) : endId(l.target) === id ? endId(l.source) : null;
    const o = other ? byId.get(other) : null;
    if (o && o.kind === "proc") open.add(o.sector);
  });
  const n = byId.get(id);
  if (n && n.kind === "proc") open.add(n.sector);
}

/** The angle a process's junction faces: from the mean of its reactants toward the mean of its products. */
function facing(g: Graph, pn: WNode): number {
  let ix = 0, iy = 0, ni = 0, ox = 0, oy = 0, no = 0;
  g.links.forEach(l => {
    if (l.kind === "use") return;
    const s = l.source as WNode, t = l.target as WNode;
    if (t === pn) { ix += s.x!; iy += s.y!; ni++; }
    if (s === pn) { ox += t.x!; oy += t.y!; no++; }
  });
  const fx = ni ? ix / ni : pn.x! - 1, fy = ni ? iy / ni : pn.y!;
  const tx = no ? ox / no : pn.x! + 1, ty = no ? oy / no : pn.y!;
  return Math.atan2(ty - fy, tx - fx) * 180 / Math.PI;
}

/**
 * Select a recipe by touching any part of it: a step's node, its hull, or one of
 * its flow lines. Every step of the recipe and every good they touch lights
 * together and the rest recedes; the rail shows the whole recipe. A recipe with
 * a declared hole in it also selects the hole, so the space of offers opens.
 */
function pickRecipe(g: Graph, id: string): void {
  pickedRecipe = pickedRecipe === id ? null : id;
  procTrace = false;
  const hole = pickedRecipe ? full?.nodes.find(n => n.kind === "proc" && n.hole === "explicit" && ridsOf(n).includes(pickedRecipe!)) : null;
  selected = hole ? hole.id : null;
  traceDir = "both";
  paintTrace(g); renderHead(g); renderPanel(g);
  holdPanelOpen("web", !!editing() || !!hole);
}

/** The recipe of a link: the recipe of whichever end is a step. */
/** Every recipe a link's process end lists — membership, for is-pick where that step is shared. */
function ridsOfLink(g: Graph, l: WLink): string[] {
  const ends = [endId(l.source), endId(l.target)].map(id => g.nodes.find(n => n.id === id));
  const proc = ends.find(n => n && n.kind === "proc");
  return proc ? ridsOf(proc) : [];
}

/** The process id of a link: whichever end is a step, its own id — not its recipe's. */
function procOfLink(g: Graph, l: WLink): string {
  const ends = [endId(l.source), endId(l.target)].map(id => g.nodes.find(n => n.id === id));
  const proc = ends.find(n => n && n.kind === "proc");
  return proc ? proc.id : "";
}

/**
 * Select a single process, narrowly: its own flows light, and the rail names
 * which recipe lists it — no more. The process is the default unit; touching
 * its node, its hull, or one of its own flow lines all land here. Touching
 * the same one again lets it go, same as a good.
 */
function selectProc(g: Graph, id: string): void {
  pickedRecipe = null;
  procTrace = false;
  selected = selected === id ? null : id;
  traceDir = "both";
  renderHead(g); paintTrace(g); renderPanel(g);
  const n = selected ? full?.nodes.find(x => x.id === selected) : null;
  holdPanelOpen("web", !!editing() || !!(n && n.hole));
}

/** Stash every drawn position, so the next layout starts from here. */
function remember(g: Graph): void {
  g.nodes.forEach(n => { if (n.x != null && n.y != null) remembered.set(n.id, { x: n.x, y: n.y }); });
}

/** One hue per process in the reactions drawing — position in the graph, so a re-layout keeps it. */
const HUES = [152, 12, 268, 38, 200, 320, 88, 230];
const hueOf = (g: Graph, n: WNode): number => HUES[g.nodes.filter(x => x.kind === "proc").indexOf(n) % HUES.length];

/** The padded cloud of points a hull is fitted to. */
function cloud(members: WNode[], extra: number): number[][] {
  const pts: number[][] = [];
  members.forEach(n => { const pad = n.r + extra;
    for (const [dx, dy] of [[pad, 0], [-pad, 0], [0, pad], [0, -pad], [pad * .7, pad * .7], [-pad * .7, pad * .7], [pad * .7, -pad * .7], [-pad * .7, -pad * .7]])
      pts.push([n.x! + dx, n.y! + dy]); });
  return pts;
}
const hullPath = (pts: number[][]): string => { const h = pts.length >= 3 ? d3.polygonHull(pts.slice()) : null; return h ? "M" + h.map(p => p.join(",")).join("L") + "Z" : ""; };

/** The reactions drawing: every drawn process as a hull over its reactants and products. */
function paintReactions(g: Graph): void {
  const byId = new Map(g.nodes.map(n => [n.id, n]));
  const edges = hyper ? g.nodes.filter(n => n.kind === "proc").map(pn => {
    const goods = g.links.filter(l => l.kind !== "use" && (endId(l.source) === pn.id || endId(l.target) === pn.id))
      .map(l => byId.get(endId(l.source) === pn.id ? endId(l.target) : endId(l.source))).filter((x): x is WNode => !!x);
    return { id: pn.id, rids: ridsOf(pn), path: hullPath(cloud([pn, ...goods], 16)), hue: hueOf(g, pn), x: pn.x!, y: pn.y!, label: `${pn.emoji} ${pn.label}` };
  }) : [];
  const sel = d3.select("#webstage g.wb-hulls").selectAll("g.wb-edge").data(edges, d => d.id)
    .join(enter => { const e = enter.append("g").attr("class", "wb-edge"); e.append("path"); e.append("text").attr("text-anchor", "middle"); return e; });
  sel.classed("is-pick", d => !!pickedRecipe && d.rids.includes(pickedRecipe))
    .classed("is-selected", d => d.id === selected)
    .on("click", (ev, d) => { ev.stopPropagation(); selectProc(g, d.id); });
  sel.select("path").attr("d", d => d.path).attr("fill", d => `hsl(${d.hue} 45% 60%)`).attr("stroke", d => `hsl(${d.hue} 40% 45%)`);
  sel.select("text").attr("x", d => d.x).attr("y", d => d.y - 14).text(d => d.label).attr("fill", d => `hsl(${d.hue} 45% 32%)`);
}

/** A dashed hull around every OPEN sector's processes and the goods it makes. */
function paintHulls(g: Graph): void {
  paintReactions(g);
  const hulls = (sectors ? [...open].filter(s => g.sectors.includes(s)) : []).map(s => {
    const members = g.nodes.filter(n => n.sector === s && (n.kind === "proc" || (n.kind === "good" && !n.hole && !n.final)));
    const path = hullPath(cloud(members, 26));
    const top = members.reduce((m, n) => (n.y! - n.r < m.y ? { x: n.x!, y: n.y! - n.r } : m), { x: members[0]?.x || 0, y: (members[0]?.y || 0) });
    return { s, path, x: top.x, y: top.y - 34, hours: members.filter(m => m.kind === "proc").reduce((a, m) => a + m.hours, 0) };
  });
  const sel = d3.select("#webstage g.wb-hulls").selectAll("g.wb-hull").data(hulls, d => d.s)
    .join(enter => { const e = enter.append("g").attr("class", "wb-hull"); e.append("path"); e.append("text").attr("text-anchor", "middle"); return e; });
  sel.select("path").attr("d", d => d.path);
  sel.select("text").attr("x", d => d.x).attr("y", d => d.y).text(d => `${d.s} · ${n1(d.hours)} h · tap to fold`)
    .on("click", (ev, d) => { ev.stopPropagation(); open.delete(d.s); remember(g); draw(); });
}

/** Light the trace of the selected node; with none selected, everything reads plain.
 *  A selected PROCESS starts narrow — directOf, its own flows only — until
 *  `procTrace` widens it to the same upstream/downstream walk a good gets. */
function paintTrace(g: Graph): void {
  const selNode = selected ? g.nodes.find(n => n.id === selected) : null;
  const narrow = !!selNode && selNode.kind === "proc" && !procTrace;
  const t = selected && !pickedRecipe ? (narrow ? directOf(g, selected) : traceOf(g, selected, traceDir)) : null;
  d3.select("#webstage").classed("is-tracing", !!t).classed("is-picking", !!pickedRecipe);
  // a picked recipe: its steps, the goods they touch, and their flow lines
  const mine = new Set<string>();
  if (pickedRecipe) {
    g.nodes.forEach(n => { if (n.kind === "proc" && ridsOf(n).includes(pickedRecipe!)) mine.add(n.id); });
    g.links.forEach(l => { if (mine.has(endId(l.source))) mine.add(endId(l.target)); if (mine.has(endId(l.target))) mine.add(endId(l.source)); });
  }
  d3.select("#webstage g.wb-nodes").selectAll("g.wb-node").classed("is-pick", d => mine.has((d as WNode).id));
  d3.select("#webstage g.wb-links").selectAll("path").classed("is-pick", d => !!pickedRecipe && ridsOfLink(g, d as WLink).includes(pickedRecipe));
  d3.select("#webstage g.wb-hulls").selectAll("g.wb-edge").classed("is-pick", d => !!pickedRecipe && (d as { rid: string }).rid === pickedRecipe);
  d3.select("#webstage g.wb-nodes").selectAll("g.wb-node")
    .classed("is-on", d => !!t && t.nodes.has((d as WNode).id))
    .classed("is-selected", d => (d as WNode).id === selected);
  d3.select("#webstage g.wb-links").selectAll("path").classed("is-on", d => !!t && t.links.has((d as WLink).id));
  // selectAll answers unknown data: the casts say what the join above bound
}

// ── conformance, and the space of offers ───────────────────────────────────

/** The folksonomy path above a term, from the spine the dial holds (root→…→term), or none. */
function ancestors(id: string): string[] {
  const find = (n: { id: string; children?: { id: string }[] } | null): { id: string; parent?: unknown }[] | null => {
    if (!n) return null;
    if (n.id === id) return [n];
    for (const c of n.children || []) { const r = find(c as { id: string; children?: { id: string }[] }); if (r) return [n, ...r]; }
    return null;
  };
  const chain = find(S.root as { id: string; children?: { id: string }[] } | null);
  return chain ? chain.slice(0, -1).map(n => n.id) : [];
}

/** A flow of SPEC fills a port of TERM: the same, a path under it, or a spine term beneath it (knowledge/holes.scm's rule, read here). */
export const conforms = (term: string, spec: string): boolean =>
  !!term && !!spec && (term === spec || spec.startsWith(term + "/") || ancestors(spec).includes(term));

interface Offer { recipe: ScopeRecipe; from: string; here: boolean }

/** Every recipe in hand that could fill a hole with output port TERM — the scope's own first, then another library's. */
function offersFor(term: string, exceptId: string): Offer[] {
  const own = (scopeRecipes() || []).filter(r => r.id !== exceptId && !(r.id || "").startsWith("draft:")
    && !(r.steps || []).some(s => (s.tags || []).includes("hole")) && conforms(term, recipeOutSpec(r) || ""));
  const out: Offer[] = own.map(r => ({ recipe: r, from: scopeName(), here: true }));
  if (!(scopesSig() || []).length) {   // offline: the other demo library stands in for another commune's
    const cur = scopeRecipes() || [];
    for (const [lib, region] of [[DEMO_RECIPES, "ca"], [DEMO_RECIPES_DE, "de"]] as [ScopeRecipe[], string][]) {
      if (cur.length && cur[0] && lib.some(r => r.id === cur[0].id)) continue;
      const name = Object.values(DEMO_SCOPE_PLAN).find(c => c.region === region)?.scope || "another commune";
      lib.filter(r => conforms(term, recipeOutSpec(r) || "")).forEach(r => out.push({ recipe: r, from: name, here: false }));
    }
  }
  return out;
}

/** The output terms a hole answers for: an explicit hole's output ports, else the good itself. */
function portsOf(n: WNode): { term: string; emoji: string }[] {
  if (n.hole === "explicit") return (n.step?.out || []).filter(f => f.spec).map(f => ({ term: f.spec!, emoji: f.emoji || "•" }));
  return [{ term: n.id.slice(2), emoji: n.emoji }];
}

function offersSpace(n: WNode): string {
  const ports = portsOf(n);
  const groups = ports.map(pt => {
    const offers = offersFor(pt.term, n.recipe?.id || "");
    const rows = offers.map(o => { const r = o.recipe; const hrs = (r.steps || []).reduce((a, s) => a + num(s.hours), 0);
      return `<div class="wb-offer${o.here ? "" : " wb-offer-away"}" data-rid="${esc(r.id || "")}">
        <span class="wb-o-emoji">${r.emoji || "🍲"}</span><b>${esc(r.name || r.id || "recipe")}</b>
        <span class="wb-o-sub">makes ${esc(recipeOutSpec(r) || "")} · ${(r.steps || []).length} step${(r.steps || []).length === 1 ? "" : "s"}${hrs ? ` · ${n1(hrs)} h` : ""} · ${o.here ? "this scope's" : "from " + esc(o.from)}</span>
        <span class="wb-o-acts"><button class="wb-o-propose" data-rid="${esc(r.id || "")}" title="a ballot: adopt this recipe here">propose adopting</button><button class="wb-o-copy" data-rid="${esc(r.id || "")}" title="start a draft from it">copy as draft</button></span></div>`; }).join("");
    return `<div class="wb-port"><div class="wb-port-h">${pt.emoji} who could make <b>${esc(pt.term)}</b></div>
      ${rows || `<div class="wb-none">no recipe in hand makes it — the space is open</div>`}
      <button class="wb-write" data-term="${esc(pt.term)}" data-emoji="${esc(pt.emoji)}" title="write a recipe that makes it, on the web or as a form">✏️ write a recipe for ${esc(pt.term)}</button></div>`;
  }).join("");
  return `<div class="wb-offers"><div class="wb-panel-h">the space of offers</div>${groups}</div>`;
}

// ── the head and the rail ──────────────────────────────────────────────────

/** The picked recipe, said once: its name and its steps in order — "Garden greens · Sow & tend → Harvest". */
function pickLine(): string {
  if (!pickedRecipe || !full) return "";
  const steps = full.nodes.filter(n => n.kind === "proc" && ridsOf(n).includes(pickedRecipe!));
  const r = steps[0]?.recipes?.find(o => (o.id || o.name) === pickedRecipe) || steps[0]?.recipe;
  return r ? `<span class="wb-pick">${r.emoji || "🍲"} <b>${esc(r.name || r.id || "recipe")}</b> · ${steps.map(n => esc(n.label)).join(" → ")}</span> · tap the stage to let go` : "";
}

function renderHead(g: Graph): void {
  const head = document.getElementById("webhead");
  if (!head) return;
  const goods = g.nodes.filter(n => n.kind === "good").length, procs = full ? full.nodes.filter(n => n.kind === "proc").length : 0;
  const balanced = full ? full.nodes.filter(n => n.balance === "closed").length : 0, leaks = full ? full.nodes.filter(n => n.balance === "open").length : 0;
  head.innerHTML = `<h3>web · the recipe web</h3>
    <span class="wb-stat"><b>${procs}</b> process${procs === 1 ? "" : "es"}</span>
    <span class="wb-stat"><b>${goods}</b> goods</span>
    <span class="wb-stat wb-stat-loop"><b>${g.loops}</b> loop${g.loops === 1 ? "" : "s"} closed</span>
    <span class="wb-stat wb-stat-hole"><b>${g.holes.length}</b> open end${g.holes.length === 1 ? "" : "s"}</span>
    ${balanced + leaks ? `<span class="wb-stat wb-stat-leak" title="over the tracked elements: a step is balanced when every element it consumes reappears in a named output; it leaks when some leaves unnamed — the metabolic rift, at one step"><b>${balanced}</b> balanced · <b>${leaks}</b> leak${leaks === 1 ? "s" : ""}</span>` : ""}
    <span class="wb-toggle" title="the same web drawn as arrows (a process a node joined by arrows), as reactions (a process a junction, tails from its reactants and heads to its products over a faint hull — the directed hypergraph of a reaction network), or both: the reaction bundle with arrowheads where the products land">
      ${DRAWINGS.map(d => `<button class="wb-tg${drawing === d ? " is-on" : ""}" data-mode="${d}">${d}</button>`).join("")}</span>
    <span class="wb-toggle" title="free: the force layout settles the web on its own. flow: columns by production stage — supply enters at the left, demand pulls at the right, and an edge running back against the stages bows out as a return">
      <button class="wb-tg wb-lay${flowLayout ? "" : " is-on"}" data-mode="free">free</button><button class="wb-tg wb-lay${flowLayout ? " is-on" : ""}" data-mode="flow">flow</button></span>
    <span class="wb-toggle" title="plain: every process in view. sectors: the folksonomy fold — processes grouped under a term, folded to one node each until opened">
      <button class="wb-tg wb-sec${sectors ? "" : " is-on"}" data-mode="plain">plain</button><button class="wb-tg wb-sec${sectors ? " is-on" : ""}" data-mode="sectors">sectors</button></span>
    ${sectors ? `<span class="wb-toggle" title="the cut the sectors fold by: by need — the head of the need path each recipe serves (the demand side); by activity — each process's own classification (the supply side, where the wire carries one)">
      <button class="wb-tg wb-cut${cut === "need" ? " is-on" : ""}" data-mode="need">by need</button><button class="wb-tg wb-cut${cut === "activity" ? " is-on" : ""}" data-mode="activity">by activity</button></span>` : ""}
    <span class="wb-hint">${pickedRecipe && pickLine() ? pickLine() : armed() ? `<b>tap a good</b> to add it as an ${armed()!.side === "in" ? "input" : "output"} of the armed step · tap the stage to stop` : `${sectors ? "tap a sector to open it · " : ""}tap a step to see it, tap a good to trace it · tap a hole for who could fill it · drag to move · scroll to zoom`}</span>`;
  head.querySelectorAll<HTMLButtonElement>(".wb-tg").forEach(b => b.onclick = () => {
    if (b.classList.contains("wb-lay")) { flowLayout = b.dataset.mode === "flow"; writeStr(FLOW_KEY, flowLayout ? "1" : "0"); }
    else if (b.classList.contains("wb-sec")) { sectors = b.dataset.mode === "sectors"; writeStr(SECTORS_KEY, sectors ? "1" : "0"); open.clear(); if (drawn) remember(drawn); rebuild(); return; }
    else if (b.classList.contains("wb-cut")) { cut = b.dataset.mode === "activity" ? "activity" : "need"; writeStr(CUT_KEY, cut); open.clear(); if (drawn) remember(drawn); rebuild(); return; }
    else { drawing = DRAWINGS.find(d => d === b.dataset.mode) || "both"; hyper = drawing !== "arrows"; writeStr(DRAWING_KEY, drawing); }
    if (drawn) remember(drawn);
    draw();
  });
}

function renderPanel(g: Graph): void {
  const panel = document.getElementById("webpanel");
  if (!panel) return;
  const sel = selected ? g.nodes.find(n => n.id === selected) : null;
  // one flow-chip formatter for both faces (recipe-render.ts): a relocation
  // step's rates read per km of the haul here exactly as they do in recipes.ts
  const flows = (s: ScopeRecipeStep | undefined): string => {
    const move = relocationOf(s || {});
    return `<div class="wb-flows">${(s?.in || []).map(f => flowChip(f, move)).join("")}<span class="wb-arrow">→</span>${(s?.out || []).map(f => flowChip(f, move)).join("")}</div>`;
  };
  // a selected PROCESS, narrow: its own flows, its recipe named but not lit,
  // and the two explicit widenings — the whole recipe, or what it depends on
  // (the spec's own back-scheduling, docs/valueflows/algorithms/dependent-demand.md)
  const procFocus = (): string => {
    // the process is the default unit — a recipe is not really a thing, it's
    // just a graph (docs/valueflows/algorithms/dependent-demand.md) — so a
    // step SHARED by more than one recipe (the same stable process id) names
    // every one of them here, rather than picking one to stand for all
    const owners = sel!.recipes && sel!.recipes.length ? sel!.recipes : (sel!.recipe ? [sel!.recipe] : []);
    return `<div class="wb-focus"><div class="wb-focus-h">${sel!.emoji} ${esc(sel!.label)}</div>
         <div class="wb-focus-sub">a step${sel!.hours ? ` · ${n1(sel!.hours)} h` : ""}${sel!.balance === "open" ? " · leaks" : sel!.balance === "closed" ? " · balanced" : ""}${sel!.loop ? " · on a closed loop" : ""}</div>
         ${sel!.recipe ? standingRow(sel!.recipe) : ""}
         ${flows(sel!.step)}
         ${owners.length ? `<div class="wb-focus-note">lists in ${owners.length === 1 ? `<b>${esc(owners[0].name || owners[0].id || "a recipe")}</b>`
                                                                        : `${owners.length} recipes`}</div>` : ""}
         <div class="wb-focus-acts">
           <button class="wb-trace-up">${procTrace ? "just this step" : "trace what it depends on"}</button>
           ${owners.map(o => `<button class="wb-see-recipe" data-rid="${esc(o.id || o.name || "")}">${owners.length > 1 ? `see ${esc(o.name || o.id || "recipe")}` : "the whole recipe"}</button>`).join("")}
         </div></div>`;
  };
  const focus = !sel ? "" : sel.hole === "explicit"
    ? `<div class="wb-focus wb-focus-hole"><div class="wb-focus-h">◌ ${esc(sel.label)}</div>
         <div class="wb-focus-sub">a hole: a process known by its boundary alone · <b>${esc(sel.term || "")}</b> · ${esc(sel.sector)}${sel.hours ? ` · ${n1(sel.hours)} h` : ""}</div>
         ${sel.recipe ? standingRow(sel.recipe) : ""}
         <div class="wb-focus-note">its ports are what crosses; the solve balances through them until a recipe here fills it</div>${flows(sel.step)}</div>${offersSpace(sel)}`
    : sel.kind === "proc" ? procFocus()
    : `<div class="wb-focus"><div class="wb-focus-h">${sel.emoji} ${esc(sel.label)}</div>
         <div class="wb-focus-sub">${sel.hole === "source" ? "a source hole: nothing in this scope makes it" : sel.hole === "sink" ? "a sink hole: nothing here takes it, no need asks for it" : sel.loop ? "on a closed loop" : "made and taken inside the scope"}${sel.final ? " · meets a need" : ""}${sel.flow ? ` · ${n1(sel.flow)}${sel.unit ? " " + esc(sel.unit) : ""}` : ""}</div>
         <div class="wb-focus-note">everything upstream and downstream of it is lit on the web</div></div>${sel.hole ? offersSpace(sel) : ""}`;
  /** The picked recipe whole: its steps in order, each with its hours, its balance and its flows. */
  const recipeCard = (): string => {
    if (!pickedRecipe || !full) return "";
    const steps = full.nodes.filter(n => n.kind === "proc" && ridsOf(n).includes(pickedRecipe!));
    const r = steps[0]?.recipes?.find(o => (o.id || o.name) === pickedRecipe) || steps[0]?.recipe;
    if (!r) return "";
    const hrs = steps.reduce((a, n) => a + n.hours, 0);
    return `<div class="wb-focus wb-recipe"><div class="wb-focus-h">${r.emoji || "🍲"} ${esc(r.name || r.id || "recipe")}</div>
      <div class="wb-focus-sub">a recipe of ${steps.length} step${steps.length === 1 ? "" : "s"}${hrs ? ` · ${n1(hrs)} h` : ""}${r.need ? ` · for ${esc(r.need)}` : ""}${steps[0].draft ? " · a draft on this device" : ""}</div>
      ${standingRow(r)}
      ${steps.map(n => `<div class="wb-rstep"><div class="wb-rstep-h">${n.emoji} <b>${esc(n.label)}</b>${n.hours ? ` <span class="wb-h-flow">${n1(n.hours)} h</span>` : ""}${n.balance === "open" ? ` <span class="wb-leak">leaks</span>` : n.balance === "closed" ? ` <span class="wb-ok">balanced</span>` : ""}</div>${flows(n.step)}</div>`).join("")}
      ${steps[0].draft && r.id ? `<button class="wb-edit-draft" data-did="${esc(r.id)}">✏️ keep writing it</button>` : ""}</div>`;
  };
  const rows = g.holes.map(hn => `<div class="wb-hole wb-hole-${hn.hole}" data-id="${esc(hn.id)}" title="${hn.hole === "source" ? "consumed here, made nowhere here — map the recipe that makes it, or the scope it comes from" : hn.hole === "sink" ? "made here, taken by nothing — map where it goes: a use, a market, a loop back" : "a process known by its boundary alone — map its interior"}">
      <span class="wb-h-emoji">${hn.hole === "explicit" ? "◌" : hn.emoji}</span><b>${esc(hn.label)}</b>
      <span class="wb-h-kind">${hn.hole === "source" ? "from outside" : hn.hole === "sink" ? "to nowhere" : esc(hn.term || "a hole")}</span>
      <span class="wb-h-flow">${hn.flow ? n1(hn.flow) + (hn.unit ? " " + esc(hn.unit) : "") : "—"}</span></div>`).join("");
  panel.innerHTML = `<div class="wb-panel">
    <div class="wb-panel-h">the web</div>
    <div class="wb-panel-stat"><b>${esc(scopeName())}</b> · <b>${g.loops}</b> loop${g.loops === 1 ? "" : "s"} closed over <b>${g.loopNodes}</b> nodes · <b>${g.holes.length}</b> open end${g.holes.length === 1 ? "" : "s"}</div>
    ${recipeCard()}${focus}
    <div class="wb-panel-h">to map · the open ends, heaviest first</div>
    <div class="wb-panel-note">Each is a good this scope's recipes reach for and no recipe here accounts for. Mapping one is writing the recipe that makes it, naming the scope it comes from, or closing the loop it leaks through.</div>
    ${rows || `<div class="wb-none">every good here is both made and taken — the web is closed</div>`}
    <div class="wb-panel-h">drafts · recipes being written here</div>
    ${drafts().map(d => `<div class="wb-draft-row${editing()?.id === d.id ? " is-on" : ""}" data-did="${esc(d.id)}"><span>${d.emoji || "✏️"}</span><b>${esc(d.name)}</b><span class="wb-h-kind">${d.proposed ? (d.proposed === "ok" ? "proposed" : d.proposed === "kept" ? "kept here" : "proposal failed") : "draft"}</span></div>`).join("")}
    <button class="wb-write wb-write-new">✏️ write a new recipe</button>
    <div class="wb-legend">
      <span><span class="wb-sw wb-sw-sector">▣</span> a sector, folded — its processes inside</span>
      <span><span class="wb-sw wb-sw-loop">●</span> on a closed loop</span>
      <span><span class="wb-sw wb-sw-source">◌</span> source hole — comes from outside</span>
      <span><span class="wb-sw wb-sw-sink">◌</span> sink hole — goes nowhere</span>
      <span><span class="wb-sw wb-sw-final">●</span> meets a need</span>
      <span><span class="wb-sw wb-sw-explicit">◌</span> a hole declared — known by its ports</span>
      <span><span class="wb-sw wb-sw-draft">✏️</span> a draft being written here</span>
      <span><span class="wb-sw wb-sw-leak">◆</span> a step that leaks — matter leaves it unnamed</span>
      <span><span class="wb-sw wb-sw-strained">◆</span> strained — delivers less than the weather allows right now; the plan leans on it in proportion</span>
    </div></div>`;
  panel.querySelectorAll<HTMLElement>(".wb-trace-up").forEach(el => el.onclick = () => {
    procTrace = !procTrace;
    paintTrace(g); renderPanel(g);
  });
  panel.querySelectorAll<HTMLElement>(".wb-see-recipe").forEach(el => el.onclick = () => {
    const owner = el.dataset.rid || "";
    if (owner) pickRecipe(g, owner);
  });
  panel.querySelectorAll<HTMLElement>(".wb-write").forEach(el => el.onclick = () => {
    newDraft(el.dataset.term ? { produces: el.dataset.term, emoji: el.dataset.emoji || "", need: sel?.recipe?.need || (sel ? needOf({ id: "" }, PLAN()) : "") } : {});
    if (drawn) remember(drawn);
    rebuild();
  });
  panel.querySelectorAll<HTMLElement>(".wb-edit-draft, .wb-draft-row").forEach(el => el.onclick = () => {
    editDraft(el.dataset.did || null); if (drawn) remember(drawn); rebuild();
  });
  panel.querySelectorAll<HTMLElement>(".wb-o-copy").forEach(el => el.onclick = () => {
    const r = [...(scopeRecipes() || []), ...DEMO_RECIPES, ...DEMO_RECIPES_DE].find(x => x.id === el.dataset.rid);
    if (!r) return;
    const d = newDraft({ name: r.name || r.id, produces: recipeOutSpec(r) || "", emoji: r.emoji || "", need: r.need || "" });
    d.steps = JSON.parse(JSON.stringify(r.steps || [])) as ScopeRecipeStep[];
    if (drawn) remember(drawn); rebuild();
  });
  panel.querySelectorAll<HTMLButtonElement>(".wb-o-propose").forEach(el => el.onclick = async () => {
    const r = [...(scopeRecipes() || []), ...DEMO_RECIPES, ...DEMO_RECIPES_DE].find(x => x.id === el.dataset.rid);
    if (!r) return;
    el.disabled = true; el.textContent = "proposing…";
    const sid = scopeSig();
    const out = await wire().open(`adopt:${r.id}`, "recipe", `Adopt “${r.name || r.id}” as ${scopeName()}'s recipe for ${recipeOutSpec(r) || "this"}?`,
                                  sid ? `scope:${sid}` : "federation", `recipe:${r.id}`);
    el.textContent = out === "ok" ? "proposed" : out === "kept" ? "kept on this device" : out;
  });
  panel.querySelectorAll<HTMLElement>(".wb-hole").forEach(el => el.onclick = () => {
    const id = el.dataset.id || "";
    const n = full?.nodes.find(x => x.id === id);
    if (!n) return;
    openAround(id);
    pickedRecipe = null;
    procTrace = false;
    selected = id;
    traceDir = "both";
    remember(g); draw();
  });
}

// ── the door ───────────────────────────────────────────────────────────────

function rebuild(): void {
  full = buildFull([...(scopeRecipes() || []), ...draftRecipes()], PLAN(), cut);
  // one sector alone has nothing to fold against
  if (full.sectors.length === 1) open.add(full.sectors[0]);
  [...open].forEach(s => { if (!full!.sectors.includes(s)) open.delete(s); });
  draw();
}

/** The stage changed size: re-centre the layout in the new box. */
export function refitWeb(): void {
  if (full) draw();
}

export function initWeb(): void {
  const stage = document.getElementById("webstage");
  if (stage && !stage.querySelector("svg")) {
    // the arrowhead every material edge ends in — one definition, referenced by url()
    d3.select("#webstage").append("svg").attr("class", "wb-svg");
    const svg = d3.select("#webstage svg");
    svg.append("defs").append("marker").attr("id", "wb-arrow").attr("viewBox", "0 -4 8 8").attr("refX", 8).attr("refY", 0)
      .attr("markerWidth", 9).attr("markerHeight", 9).attr("markerUnits", "userSpaceOnUse").attr("orient", "auto")
      .append("path").attr("d", "M0,-4L8,0L0,4Z").attr("class", "wb-arrowhead");
    const root = svg.append("g").attr("class", "wb-root");
    root.append("g").attr("class", "wb-hulls");
    root.append("g").attr("class", "wb-links");
    root.append("g").attr("class", "wb-nodes");
    zoomer = d3.zoom().scaleExtent([0.25, 4]).on("zoom", ev => { view = ev.transform; root.attr("transform", ev.transform.toString()); });
    zoomer(svg);
    // a tap on the empty stage ends the trace
    svg.on("click", () => {
      if (armed()) { arm(null); if (drawn) remember(drawn); rebuild(); return; }
      if ((selected || pickedRecipe) && drawn) { selected = null; pickedRecipe = null; procTrace = false; paintTrace(drawn); renderHead(drawn); renderPanel(drawn); }
    });
    on("recipes", rebuild);
    on("planRender", rebuild);
  }
  rebuild();
}
