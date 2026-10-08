// app/forum/views.ts — the forum's shared fragments: the class chip, the
// tally, the weight line, a subject as a tile and as a card.
//
// Pure functions of their arguments — the face passes what it holds and binds
// the handlers; nothing here reads the face's state.
import type { ScopeFlow } from '../seam.js';
import { html } from '../template.js';
import type { Fragment } from '../template.js';
import { applyHere } from '../gohere.js';
import { goToScope } from '../scope.js';
import { CLASS_TITLE, pct } from './model.js';
import type { GovClass, Tally } from './model.js';
import { anyRecipe, isMeans, scopeName, subjectOfRecipe } from './subjects.js';
import type { Subject } from './subjects.js';

/**
 * The tally as a proportional bar plus a legend.
 *
 * An option is a KEY off the wire's tally: it names a class here as well as
 * reading as a label, so both positions take it escaped.
 */
export function viewTally(tally: Tally | null | undefined): Fragment {
  const entries = Object.entries(tally || {}).filter(([, w]) => w > 0);
  if (!entries.length) return html`<span class="fo-none">no votes yet</span>`;
  entries.sort((a, b) => b[1] - a[1]);
  const total = entries.reduce((s, [, w]) => s + w, 0) || 1;
  return html`
    <div class="fo-bar">${entries.map(([opt, w]) =>
      html`<div class="fo-bseg fo-${opt}" style="flex:${w}"
                title="${opt} ${pct(w / total)}%"></div>`)}</div>
    <div class="fo-legend">${entries.map(([opt, w]) =>
      html`<span class="fo-leg"><i class="fo-dot fo-${opt}"></i>${opt} ${pct(w / total)}%</span>`)}</div>`;
}

/** The bar alone, thin — a row's glance at where the thread stands. */
export function viewMiniTally(tally: Tally | null | undefined): Fragment | string {
  const entries = Object.entries(tally || {}).filter(([, w]) => w > 0);
  if (!entries.length) return "";
  return html`<div class="fo-bar fo-mini">${entries.map(([opt, w]) =>
    html`<div class="fo-bseg fo-${opt}" style="flex:${w}"></div>`)}</div>`;
}

export const viewClassChip = (cls: GovClass): Fragment =>
  html`<span class="fo-chip fo-cls-${cls}" title="${CLASS_TITLE[cls]}">${cls}</span>`;

/** Your weight on a thread of this class, and where it comes from. */
export function viewWeight(cls: GovClass, w: number | null): Fragment {
  const source = cls === "production" ? `of ${scopeName()}'s labour` : "of the claimable pool";
  const who = cls === "production" ? "producer voice" : "consumer voice";
  return w != null
    ? html`<span class="fo-weight fo-cls-${cls}">${who} — <b>${pct(w)}%</b> ${source}</span>`
    : html`<span class="fo-weight fo-cls-${cls}">${who} — ${cls === "production"
        ? "your share of the scope's labour" : "contribution by ability · citizenship"}</span>`;
}

/** A subject as a small tile — the picker's unit, and a row's badge. */
export const viewSubjectTile = (s: Subject, onPick?: () => void): Fragment => html`
  <a class="fo-subj fo-subj-${s.kind} ${onPick ? "fo-tap" : ""}" onclick=${onPick || null} title="${s.draft}">
    <span class="fo-subj-e">${s.emoji}</span>
    <span class="fo-subj-t"><b>${s.name}</b><small>${s.line}</small></span>
  </a>`;

const flowChip = (f: ScopeFlow): Fragment => html`
  <span class="fo-flowchip fo-${f.action || "use"}">${f.emoji || ""} ${f.q != null ? f.q : ""}${f.u || ""} ${f.name || f.spec || ""}</span>`;

const head = (s: Subject): Fragment => html`
  <div class="fo-subjhead"><span class="fo-subj-e">${s.emoji}</span><div><b>${s.name}</b><div class="fo-subj-line">${s.line}</div></div></div>`;

/** The subject card under a thread: the thing itself, and a door to its face. */
export function viewSubjectCard(s: Subject, producerIn?: (sid: string) => number | null): Fragment {
  if (s.kind === "recipe" && s.recipe) {
    const r = s.recipe;
    return html`<div class="fo-card fo-subjcard">
      <div class="fo-dischead">the recipe <a class="fo-door" onclick=${() => applyHere({}, "recipes")}>open the library ↗</a></div>
      ${head(s)}
      <ol class="fo-steps">${(r.steps || []).map(st => html`<li>
        <span class="fo-step-n">${st.emoji || "▸"} ${st.name || ""}</span>
        ${st.hours != null && html`<span class="fo-step-h">${st.hours}h</span>`}
        <span class="fo-step-flows">${(st.in || []).map(flowChip)}${(st.in || []).length && (st.out || []).length ? html`<span class="fo-arrow">→</span>` : ""}${(st.out || []).map(flowChip)}</span>
      </li>`)}</ol>
    </div>`;
  }
  if (s.kind === "need" && s.need) {
    const n = s.need, r = n.recipeId ? anyRecipe(n.recipeId) : null;
    return html`<div class="fo-card fo-subjcard">
      <div class="fo-dischead">the need <a class="fo-door" onclick=${() => applyHere({}, "plan")}>open the plan ↗</a></div>
      ${head(s)}
      <div class="fo-met"><div class="fo-metbar"><div class="fo-metfill" style="width:${pct(n.met || 0)}%"></div></div>
        <span><b>${pct(n.met || 0)}%</b> met${n.want != null ? ` of ${n.want} asked` : ""}${n.labourH ? ` · ${n.labourH}h labour` : ""}${n.runs ? ` · ${n.runs} runs` : ""}</span></div>
      ${r && html`<div class="fo-subj-line">filled by ${viewSubjectTile(subjectOfRecipe(r))}</div>`}
    </div>`;
  }
  if (s.kind === "slot" && s.slot) {
    const sl = s.slot;
    return html`<div class="fo-card fo-subjcard">
      <div class="fo-dischead">${isMeans(sl) ? "the means" : "the need"} <a class="fo-door" onclick=${() => applyHere({}, "match")}>open the ring ↗</a></div>
      ${head(s)}
      ${sl.note && html`<div class="fo-subj-note">${sl.note}</div>`}
      ${Array.isArray(sl.cats) && sl.cats.length && html`<div class="fo-cats">${sl.cats.map(c => html`<span class="fo-domain">${c}</span>`)}</div>`}
    </div>`;
  }
  if (s.kind === "scope" && s.scope) {
    const sc = s.scope, w = producerIn ? producerIn(sc.id) : null;
    return html`<div class="fo-card fo-subjcard">
      <div class="fo-dischead">the commune <a class="fo-door" onclick=${() => { goToScope(sc.id); applyHere({}, "map"); }}>see it on the map ↗</a></div>
      ${head(s)}
      ${w != null && html`<div class="fo-subj-line">your producer voice there: <b>${pct(w)}%</b></div>`}
    </div>`;
  }
  return html``;
}
