// app/plan-column.ts — the plan, and the recipe you drill into from it.
//
// Two surfaces in one column, and only ever one of them showing: a LEDGER LINE
// with a list of needs under it, and — when you tap a need — the recipe that
// fills it, in place. The ledger stays as the section's heading throughout, so
// the descent never loses the frame it started in.
//
// ── A RECIPE IS A LINE, NOT A CYCLE ─────────────────────────────────────────
// A recipe is a CHAIN of process steps with a beginning and an end
// (knowledge/recipes/*.scm: RecipeProcess + RecipeFlows), so its honest shape is
// a line. Each step is a box, its external inputs enter from above, the primary
// output of one flows down the connector into the next, and the last hands out
// the deliverable — or, for terminal consumption, meets the need.
//
// It runs TOP-DOWN here rather than left-right, because the column is narrow.
// Scheduling a recipe ONTO the day — placing its steps at real clock hours — is
// the dial's job and belongs to the desire⇄plan view; here the recipe is shown
// as itself, off the dial, where its linearity is legible.
//
// The graph it walks is app/recipe-graph.js. This file draws.

import { PLAN } from './core.js';
import { effect } from './reactive.js';
import {
  primOut, recipeForSpec, recipeById, active, setActive, pushRecipe, popRecipe,
  trail, canGoBack,
} from './recipe-graph.js';
import type { ScopeRecipe, ScopeRecipeStep, ScopeFlow, PlanNeed } from './seam.js';
import { metCol, CREDIT, STATUS } from './palette.js';

import { on, emit } from './bus.js';
/**
 * Each RecipeFlow's verb — a ValueFlows action — is the single source of how it
 * reads: `dir` says whether it is drawn down or produced, and the colour says
 * which rail it touches (credit, labour, the commons).
 */
interface Verb {
  dir: number;
  col: string;
  word: string;
}
const VERB: Record<string, Verb> = {
  consume: { dir: -1, col: CREDIT,   word: "consume" },  // drawn down (credit rail)
  use:     { dir: -1, col: "#6a8aaa", word: "use"     },  // occupied, not spent
  work:    { dir: -1, col: "#1581a8", word: "work"    },  // labour (skill rail)
  pickup:  { dir: -1, col: "#7a6a8a", word: "pickup"  },
  cite:    { dir: -1, col: "#999",    word: "cite"    },
  produce: { dir:  1, col: "#2e7d32", word: "produce" },  // brought into being
  dropoff: { dir:  1, col: "#2e7d32", word: "dropoff" },
  modify:  { dir:  1, col: "#3f8f6a", word: "modify"  },
  "deliver-service": { dir: 1, col: "#2e7d32", word: "deliver" },  // produced & delivered, never held
};
const verbOf = (action: string | undefined): Partial<Verb> => VERB[action || ""] || {};

const fmtQ = (f: ScopeFlow): string =>
  `${f.q}${f.u && f.u !== "each" ? " " + f.u : ""}`.trim();

/**
 * A flow's label: its emoji where it has one (the demo recipes), else its spec
 * name — real recipes from the store carry a name, not an emoji.
 */
const flabel = (f: ScopeFlow): string => f.emoji || f.name || "";

/** How met reads as a colour: green, amber, or the red of a real shortfall. */

const footHint = (msg: string): void => { d3.select("#planrecipe .rf-foot").html(msg); };

// ── the plan list ───────────────────────────────────────────────────────────

/**
 * The scope's plan, in the sidebar, in the same quiet list language as the
 * calendar and the proposals: a ledger line — coverage · labour · yields — over
 * a provisioning map, one row per need with its met bar and the recipe and work
 * that fill it.
 *
 * The dial's rim carries the SCHEDULE; this is the need↦recipe↦work bridge.
 */
export function drawPlanList(): void {
  const plan = PLAN();
  const needs = plan.needs || [];
  // Prefer the solver's authoritative totals — the real plan carries them — and
  // derive from the rows only for the demo plan, which does not.
  const metPct = plan.coverage != null ? plan.coverage
    : (needs.length ? d3.mean(needs, n => n.met)! : 0);
  const labourH = plan.labourH != null ? plan.labourH
    : d3.sum(needs, n => n.labourH || 0);
  const produced = (plan.produced || [])
    .map(p => `${p.emoji || (p.spec ? p.spec + " " : "")}${p.q}${p.u && p.u !== "each" ? " " + p.u : ""}`.trim())
    .join(" · ");
  d3.select("#planledger").html(
    `<b style="color:${metCol(metPct)}">${Math.round(metPct * 100)}%</b> met`
    + ` · <b>${labourH.toFixed(1)} h</b>${produced ? ` · ${produced}` : ""}`);

  const ul = d3.select("#planlist");
  ul.selectAll("*").remove();
  // least-met first — the rows where the plan strains sit at the top
  needs.slice().sort((a, b) => a.met - b.met).forEach(need => {
    const col = metCol(need.met);
    const rcp = recipeById(need.recipeId);
    const sub = rcp
      ? `${rcp.emoji || ""} ${rcp.name} ×${need.runs}`
        + (need.labourH ? ` · ${need.labourH} h` : "")
        + (need.willing ? ` · <span style="color:#1581a8">${need.willing} willing</span>` : "")
      : `<span style="color:${STATUS.strained}">unmet · no recipe yet</span>`;
    const li = ul.append("li").attr("class", "plan-li" + (rcp ? " tappable" : ""));
    if (rcp) li.on("click", () => openNeedRecipe(need));
    li.html(
      `<span class="pl-emoji">${need.emoji || ""}</span>`
      + `<div class="pl-body"><div class="pl-top">`
      + `<span class="pl-name">${need.label}</span>`
      + `<span class="pl-bar"><i style="width:${Math.round(need.met * 100)}%;background:${col}"></i></span>`
      + `<span class="pl-pct" style="color:${col}">${Math.round(need.met * 100)}%</span></div>`
      + `<div class="pl-sub">${sub}</div></div>`);
  });
}

// ── the card ────────────────────────────────────────────────────────────────

/** Follow a resource to the recipe that makes it, keeping the way back. */
function navToRecipe(rcp: ScopeRecipe): void {
  if (pushRecipe(rcp)) drawRecipeRibbon(active());
}

/** Back up the trail; at its top, close to the plan list, in place. */
function navBackRecipe(): void {
  if (popRecipe()) drawRecipeRibbon(active());
  else closeRecipeCard();
}

/**
 * Drill from a need into the recipe that fills it — IN PLACE. The plan list
 * gives way to the recipe, with a back-trail.
 */
export function openNeedRecipe(need: PlanNeed): void {
  const rcp = recipeById(need.recipeId);
  if (!rcp) return;
  setActive(rcp);
  d3.select("#planlist").style("display", "none");
  drawRecipeRibbon(rcp);
  d3.select("#planrecipe").style("display", "block");
}

/** Close the card and bring the list back. */
export function closeRecipeCard(): void {
  d3.select("#planrecipe").style("display", "none").selectAll("*").remove();
  d3.select("#planlist").style("display", null);
}

/** One step's vertical slot: its external inputs, its box, its connector. */
interface StepBox {
  s: ScopeRecipeStep;
  /** The inputs that do NOT come from the previous step — they enter from above. */
  ext: ScopeFlow[];
  top: number;
  boxTop: number;
  /** The connector's height, or 0 for the last step. */
  conn: number;
}

/** The recipe as a top-down stepped flow. */
function drawRecipeRibbon(rcp: ScopeRecipe | null): void {
  const wrap = d3.select("#planrecipe");
  wrap.selectAll("*").remove();
  if (!rcp) return;
  const steps = rcp.steps || [];
  const D = d3.sum(steps, s => s.hours || 0);
  const trailNames = trail().map(r => `${r.emoji || ""} ${r.name}`).join(" › ");
  const head = wrap.append("div").attr("class", "rf-head").html(
    `<span class="rf-back">${canGoBack() ? "‹ back" : "‹ close"}</span> `
    + (trailNames ? `<span style="color:#c4ccd6">${trailNames} › </span>` : "")
    + `${rcp.emoji || ""} <b>${rcp.name}</b> `
    + `<span style="color:#999">· ${D.toFixed(1)} h · `
    + `${steps.length} step${steps.length > 1 ? "s" : ""}</span>`);
  head.select(".rf-back").on("click", navBackRecipe);

  const W = 240, cx = W / 2, bw = 132, bh = 44, inH = 15, connH = 30, deliverH = 30;
  // first pass: lay out the vertical slots (inputs block · box · connector)
  const slots: StepBox[] = [];
  let y = 8;
  steps.forEach((s, i) => {
    const prevPrim = i > 0 ? primOut(steps[i - 1]) : null;
    const ext = (s.in || []).filter(f => !prevPrim || f.spec !== prevPrim.spec);
    const inBlock = ext.length ? ext.length * inH + 7 : 0;
    const boxTop = y + inBlock;
    const conn = (i < steps.length - 1 && primOut(s)) ? connH : 0;
    slots.push({ s, ext, top: y, boxTop, conn });
    y = boxTop + bh + conn;
  });
  const H = y + deliverH + 2;
  const svg = wrap.append("svg")
    .attr("viewBox", `0 0 ${W} ${H}`).attr("width", W).attr("height", H)
    .style("max-width", "100%");
  svg.append("defs").html(
    `<marker id="rcparrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7"`
    + ` markerHeight="7" orient="auto-start-reverse">`
    + `<path d="M0,0 L10,5 L0,10 z" fill="#9aa6b2"/></marker>`
    + `<filter id="rcpshadow" x="-30%" y="-30%" width="160%" height="170%">`
    + `<feDropShadow dx="0" dy="1.4" stdDeviation="1.6"`
    + ` flood-color="#1a2a4a" flood-opacity="0.10"/></filter>`);

  /** A label on a soft rounded chip, so it reads cleanly over a connector. */
  const chip = (t: d3.Selection, fill?: string, stroke?: string): void => {
    const bb = (t.node() as SVGGraphicsElement).getBBox(), px = 5, py = 2.5;
    svg.insert("rect", () => t.node()!)
      .attr("x", bb.x - px).attr("y", bb.y - py)
      .attr("width", bb.width + 2 * px).attr("height", bb.height + 2 * py)
      .attr("rx", (bb.height + 2 * py) / 2)
      .attr("fill", fill || "#fff").attr("stroke", stroke || "#eceff2").attr("stroke-width", 1);
  };

  /**
   * A resource you can walk INTO — follow it to the recipe that makes it. A raw
   * input names itself in the footer instead. The dotted underline is what
   * marks the walkable ones, so the affordance is visible before the tap.
   */
  const bindResource = (sel: d3.Selection, f: ScopeFlow): void => {
    const r = recipeForSpec(f.spec);
    sel.style("cursor", "pointer");
    if (r && r !== rcp)
      sel.style("text-decoration", "underline dotted").on("click", () => navToRecipe(r));
    else
      sel.on("click", () => footHint(`${f.emoji || ""} <b>${f.spec}</b> — `
        + (r ? "made by this recipe" : "raw input · no recipe yet")));
  };

  slots.forEach(slot => {
    const { s, ext, top, boxTop, conn } = slot;
    const prim = primOut(s);
    const col = prim ? verbOf(prim.action).col || "#3f8f6a" : "#9aa6b2";
    // external inputs, stacked above the box
    ext.forEach((f, fi) => {
      const v = verbOf(f.action);
      const t = svg.append("text").attr("x", cx).attr("y", top + 10 + fi * inH)
        .attr("text-anchor", "middle").attr("font-size", 10.5).attr("fill", v.col || "#999")
        .text(`${flabel(f)} ${fmtQ(f)} ${v.word || f.action}`.trim());
      bindResource(t, f);
    });
    if (ext.length)
      svg.append("line").attr("x1", cx).attr("y1", boxTop - 8).attr("x2", cx).attr("y2", boxTop - 1)
        .attr("stroke", "#c4ccd6").attr("stroke-width", 1.2).attr("marker-end", "url(#rcparrow)");
    // the process box — tap it for the step's full bill in the footer
    const g = svg.append("g").style("cursor", "pointer").on("click", () =>
      footHint(`${s.emoji || ""} <b>${s.name}</b> · ${s.hours} h — `
        + [...(s.in || []).map(f => `${f.emoji || ""}${fmtQ(f)} ${verbOf(f.action).word || f.action}`),
           ...(s.out || []).map(f => `→ ${f.emoji || ""}${fmtQ(f)}`)].join(" · ")));
    g.append("rect").attr("x", cx - bw / 2).attr("y", boxTop).attr("width", bw).attr("height", bh)
      .attr("rx", 11).attr("fill", "#fff").attr("filter", "url(#rcpshadow)");
    g.append("rect").attr("x", cx - bw / 2).attr("y", boxTop).attr("width", bw).attr("height", bh)
      .attr("rx", 11).attr("fill", col).attr("fill-opacity", 0.10)
      .attr("stroke", col).attr("stroke-opacity", 0.55).attr("stroke-width", 1.2);
    g.append("text").attr("x", cx).attr("y", boxTop + 19).attr("text-anchor", "middle")
      .attr("font-size", 13).attr("font-weight", 600).attr("fill", "#2c3038")
      .text(`${s.emoji || ""} ${s.name}`);
    g.append("text").attr("x", cx).attr("y", boxTop + 34).attr("text-anchor", "middle")
      .attr("font-size", 10.5).attr("fill", "#9aa0a8").text(`${s.hours} h`);
    // the primary output flows down the connector into the next step
    if (conn && prim) {
      const y0 = boxTop + bh, y1 = y0 + conn;
      svg.append("line").attr("x1", cx).attr("y1", y0 + 2).attr("x2", cx).attr("y2", y1 - 2)
        .attr("stroke", "#9aa6b2").attr("stroke-width", 1.4).attr("marker-end", "url(#rcparrow)");
      const t = svg.append("text").attr("x", cx).attr("y", (y0 + y1) / 2 + 4).attr("text-anchor", "middle")
        .attr("font-size", 10.5).attr("fill", "#2e7d32").attr("font-weight", 500)
        .text(`${flabel(prim)} ${fmtQ(prim)}`.trim());
      bindResource(t, prim);
      chip(t);
    }
  });

  // the end: the deliverable, or terminal consumption meeting the need
  const last = steps[steps.length - 1], lastPrim = primOut(last);
  const lastSlot = slots[slots.length - 1], y0 = lastSlot.boxTop + bh, y1 = y0 + 16;
  svg.append("line").attr("x1", cx).attr("y1", y0 + 2).attr("x2", cx).attr("y2", y1)
    .attr("stroke", "#2e7d32").attr("stroke-width", 1.6).attr("marker-end", "url(#rcparrow)");
  const et = svg.append("text").attr("x", cx).attr("y", y1 + 13).attr("text-anchor", "middle")
    .attr("font-size", 12.5).attr("font-weight", 600).attr("fill", "#2e7d32")
    .text(lastPrim
      ? `${flabel(lastPrim)} ${fmtQ(lastPrim)} ✓`.trim()
      : `✓ ${(rcp.need || "need met").split("/").pop()}`);
  if (lastPrim) bindResource(et, lastPrim);
  chip(et, "#eef7f0", "#cfe6d6");   // the deliverable, as a finished pill

  wrap.append("div").attr("class", "rf-foot")
    .html(`tap a resource to follow it · tap a step for its bill`);
}

/**
 * Wire the column. The list tracks the PLAN signal, so a new plan from the
 * planner re-renders it with nobody asking; an open card is dismissed, because
 * it belonged to the plan that just went.
 */
export function initPlanColumn(): void {
  effect(drawPlanList);
  on("plan", plan => {
    if (plan) PLAN.set(plan as ReturnType<typeof PLAN>);
    closeRecipeCard();
    emit("planRender");   // the full plan face re-renders
  });
}
