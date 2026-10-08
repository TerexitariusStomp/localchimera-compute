// app/tabs/recipes.ts — the "recipes" face: the SELECTED SCOPE's recipe library.
//
// Every recipe the scope's ^recipe-store carries — how each good is made: its steps, and
// for each step the inputs it consumes/uses, the labour it works, and what it produces.
// Scope-reactive: main.js's setRecipes() runs on every snapshot (a scope switch re-fetches
// and re-feeds it), then emits "recipes" → this re-renders. So switching scope in
// the header breadcrumb swaps the library to that scope's own recipes.
//
// recipe-graph.ts exports recipes() (the live library) + scopeName().


import { esc } from '../template.js';
import type { ScopeRecipe } from '../seam.js';

import { on } from '../bus.js';
import { recipes, scopeName, knownGoods, knownNeeds } from '../recipe-graph.js';
import { seam } from '../seam.js';
import { scopeSig } from '../scope.js';
import { REGIME_TAILS, REGIME_PROCESS, REGIME_UNSAID, regimeReads, spoken, regimeSentence } from '../slots/declarations.js';
import { drafts, newDraft, edit as editDraft, removeDraft, renderBuilder } from '../tabs/web-draft.js';
import type { Draft } from '../tabs/web-draft.js';
import { relocationOf, trim, flowChip as flow, standingRow, POSITION_LABEL } from './recipe-render.js';
import { roomChip, roomAbout } from '../voice/roomchip.js';

function recipeCardBody(r: ScopeRecipe): string {
  const out = r.produces || (r.steps && r.steps.length ? (r.steps[r.steps.length - 1].out || [])[0]?.spec : "") || "";
  const steps = (r.steps || []).map(s => {
    const ins = (s.in || []);
    const outs = (s.out || []);
    const move = relocationOf(s);
    const note = move ? `<span class="rc-step-move">relocation · rates per km of the haul, for
          ${trim(move.payload)}${move.unit ? " " + esc(move.unit) : ""} carried</span>` : "";
    return `<div class="rc-step${move ? " rc-step-reloc" : ""}">
      <div class="rc-step-h"><span class="rc-step-emoji">${s.emoji || "▸"}</span>
        <span class="rc-step-name">${esc(s.name || "step")}</span>
        ${s.hours ? `<span class="rc-step-h-h">${(+s.hours).toFixed(s.hours % 1 ? 1 : 0)}h</span>` : ""}
        ${note}</div>
      <div class="rc-flows">
        ${ins.length ? `<span class="rc-in">${ins.map(f => flow(f, move)).join("")}</span>` : `<span class="rc-in rc-none">—</span>`}
        <span class="rc-arrow">→</span>
        <span class="rc-out">${outs.map(f => flow(f, move)).join("")}</span>
      </div></div>`;
  }).join("");
  return `<div class="rc-head"><span class="rc-h-emoji">${r.emoji || "🍲"}</span>
      <span class="rc-h-name">${esc(r.name || r.id || "recipe")}</span>
      ${out ? `<span class="rc-makes">makes <b>${esc(out)}</b></span>` : ""}
      ${r.need ? `<span class="rc-need">for ${esc(r.need)}</span>` : ""}</div>
    ${standingRow(r)}
    <div class="rc-steps">${steps}</div>
    ${regimeRow(r)}`;
}

function recipeCard(r: ScopeRecipe): string {
  return `<div class="rc-card"><span class="rc-room">${roomChip(roomAbout("recipe", r.id || r.name || ""), "talk it over")}</span>${recipeCardBody(r)}</div>`;
}

function draftCard(d: Draft): string {
  const outcome = d.proposed
    ? (d.proposed === "ok" ? "proposed — open on the forum" : d.proposed === "kept" ? "kept on this device — reaches the commune once one is configured" : esc(d.proposed))
    : "";
  return `<div class="rc-card rc-card-draft" data-draft="${esc(d.id)}">
    <div class="rc-draft-ribbon">✏️ draft — not yet in the library</div>
    ${recipeCardBody(d)}
    <div class="rc-draft-actions">
      <button class="rc-edit-draft">keep writing it</button>
      <button class="rc-drop-draft">delete</button>
      ${outcome ? `<span class="rc-draft-outcome">${outcome}</span>` : ""}
    </div>
  </div>`;
}

// ── the regime claim: what a recipe's domain licenses, spoken as a governor ──
// Two words — the tails and the process of the domain the recipe stands in
// (slots/declarations.ts) — and the reading they license, claimed through the
// claimRegime door for the scope on the breadcrumb. Drawn only where the door
// stands and a scope is picked; the click rides the stage's one listener,
// since the cards are template text.
const canClaim = (): boolean => !!(seam.handlers && seam.handlers.claimRegime && scopeSig());
const chips = (group: string, words: readonly string[]): string =>
  words.map(w => `<a class="sl-chip${w === REGIME_UNSAID ? " on" : ""}" data-group="${group}" data-word="${w}">${w}</a>`).join("");
function regimeRow(r: ScopeRecipe): string {
  if (!canClaim() || !r.id) return "";
  return `<div class="rc-regime" data-recipe="${esc(r.id)}">
    <span class="rc-regime-l">regime · tails</span>${chips("tails", REGIME_TAILS)}
    <span class="rc-regime-l">process</span>${chips("process", REGIME_PROCESS)}
    <span class="rc-regime-reads">reads ${regimeReads(REGIME_UNSAID, REGIME_UNSAID)}</span>
    <button class="sl-soc-go rc-regime-go">claim the regime</button>
    <span class="rc-regime-note"></span>
  </div>`;
}
const wordOf = (row: Element, group: string): string =>
  row.querySelector<HTMLElement>(`.sl-chip.on[data-group="${group}"]`)?.dataset.word || REGIME_UNSAID;
function onRegimeClick(row: HTMLElement, t: HTMLElement): boolean {
  if (t.classList.contains("sl-chip") && t.dataset.group) {
    row.querySelectorAll(`.sl-chip[data-group="${t.dataset.group}"]`).forEach(c => c.classList.remove("on"));
    t.classList.add("on");
    const reads = row.querySelector(".rc-regime-reads");
    if (reads) reads.textContent = `reads ${regimeReads(wordOf(row, "tails"), wordOf(row, "process"))}`;
    return true;
  }
  if (!t.classList.contains("rc-regime-go")) return false;
  const go = t as HTMLButtonElement;
  const note = row.querySelector<HTMLElement>(".rc-regime-note");
  const recipe = row.dataset.recipe || "";
  const tails = wordOf(row, "tails"), process = wordOf(row, "process");
  go.disabled = true; go.textContent = "claiming…";
  spoken(seam.handlers!.claimRegime!(scopeSig() || "", recipe, tails, process),
         regimeSentence(recipe, tails, process)).then(w => {
    go.disabled = false; go.textContent = "claim the regime";
    if (note) note.textContent = w.text;
  });
  return true;
}

// ── suggesting: a draft is a recipe (or, defaulted, one process) written on
// this device and proposed to the forum — the SAME builder web.ts uses, so
// there is one way to write a recipe, not two. knownGoods/knownNeeds
// (recipe-graph.ts) come off the scope's own library, the SAME reading
// web.ts's builder host uses, so both faces offer the same suggestions.

function onStageClick(ev: Event): void {
  const t = ev.target as HTMLElement | null;
  if (!t) return;
  const row = t.closest<HTMLElement>(".rc-regime");
  if (row && onRegimeClick(row, t)) return;
  if (t.classList.contains("rc-suggest")) { newDraft(); render(); return; }
  const card = t.closest<HTMLElement>(".rc-card-draft");
  if (card) {
    const id = card.dataset.draft || "";
    if (t.classList.contains("rc-edit-draft")) { editDraft(id); render(); }
    else if (t.classList.contains("rc-drop-draft")) { removeDraft(id); render(); }
  }
}

function render(): void {
  const stage = document.getElementById("recipesstage");
  if (stage) {
    if (!stage.dataset.regimeWired) {   // the cards are rebuilt as text; the listener stands once
      stage.dataset.regimeWired = "1";
      stage.addEventListener("click", onStageClick);
    }
    const rs = recipes();
    const ds = drafts();
    stage.innerHTML = `<div class="rc">
      <div class="rc-top"><h3>recipes</h3>
        <div class="rc-sub">How <b>${esc(scopeName())}</b> makes what it makes — every recipe in this
          scope's library, its steps, and what each step draws in and puts out; and, read off what it
          has actually run and never declared, what it delivers under each stress it has met — the
          curve the plan leans on it by (docs/planning/solve/recipe-metabolism-barbell.md). Switch
          the scope in the header to see another commune's library.</div>
        <button class="rc-suggest">✏️ suggest a recipe</button></div>
      ${ds.length ? `<div class="rc-drafts-h">drafting</div><div class="rc-list rc-list-drafts">${ds.map(draftCard).join("")}</div>` : ""}
      ${rs.length ? `<div class="rc-list">${rs.map(recipeCard).join("")}</div>`
                  : `<div class="rc-empty">This scope has no recipes yet.</div>`}
    </div>`;
  }
  const panel = document.getElementById("recipespanel");
  if (panel) {
    const rs = recipes();
    const specs = new Set(); rs.forEach(r => { const o = r.produces; if (o) specs.add(o); });
    const positions = new Map<string, number>();
    rs.forEach(r => { if (r.standing) positions.set(r.standing, (positions.get(r.standing) || 0) + 1); });
    panel.innerHTML = `<div class="wb-draftform" id="rc-draftmount"></div>
    <div class="rc-panel">
      <div class="rc-panel-h">the library</div>
      <div class="rc-panel-stat"><b>${rs.length}</b> recipe${rs.length === 1 ? "" : "s"} · <b>${specs.size}</b> goods made</div>
      <div class="rc-panel-room">${roomChip(roomAbout("recipes"), "talk the library over")}</div>
      <div class="rc-panel-note">Each recipe is a real process in this scope's ^recipe-store — the same
        topology the plan walks (need ↦ recipe ↦ work). It changes with the selected scope.</div>
      ${positions.size ? `<div class="rc-panel-h">standing, read off real runs</div>
        <div class="rc-panel-stat rc-panel-standing">${[...positions.entries()].map(([p, n]) =>
          `<span class="rc-pos rc-pos-${esc(p)}">${n} ${POSITION_LABEL[p] || p}</span>`).join("")}</div>` : ""}
    </div>`;
    const mount = document.getElementById("rc-draftmount");
    if (mount) renderBuilder(mount, { goods: knownGoods(), needs: knownNeeds(), onChange: render });
  }
}

export function initRecipes(): void {
  on("recipes", render);   // re-render when the scope's recipes reload
  render();
}
