// app/tabs/web-draft.ts — drafting a recipe on the web, and proposing it.
//
// A hole on the web is a challenge: a good the scope reaches for and no recipe
// here accounts for. The answer is a recipe, and this module is where one is
// written. A DRAFT is a recipe in the wire's own shape (a ScopeRecipe with
// steps and flows) marked as a draft, kept on this device until it is
// proposed. It is drawn on the web beside the real recipes, dashed, so the
// author sees what it closes as they write it.
//
// Two ways to write one, over the SAME draft:
//
//   THE FORM   name, the need it serves, its steps, and each step's flows as
//              rows — action, spec, quantity, unit. Every field edits the
//              draft in place and the web redraws behind it.
//   THE WEB    a step is ARMED for its inputs or its outputs, and a tap on a
//              good adds that good as a flow of the step. A good the web does
//              not have yet is named in the form's own field and joins the
//              same way. Arming is the one piece of state the two share.
//
// A draft is PROPOSED through the forum's own door: a ballot in the recipe
// domain, its subject the draft's id, its text the human line the forum shows
// plus the recipe itself as JSON — so the proposal carries the recipe whole,
// and adoption on a yes is the seeding of exactly what was voted on.
import { LOG_ACTIONS, isAdjustment, isInput, isOutput } from "../actions-catalogue.js";
import { esc } from '../template.js';
import { readJSON, writeJSON } from '../store.js';
import { wire } from '../forum/wire.js';
import { scopeSig } from '../scope.js';
import { scopeName } from '../recipe-graph.js';
import { K } from "../keys.js";
const KEY = K.webDrafts;
let DRAFTS = readJSON(KEY, []).filter(d => d && typeof d.id === "string");
let EDITING = null;
let ARMED = null;
export const drafts = () => DRAFTS;
export const editing = () => DRAFTS.find(d => d.id === EDITING) || null;
export const armed = () => ARMED;
export const draftById = (id) => DRAFTS.find(d => d.id === id) || null;
const save = () => { writeJSON(KEY, DRAFTS); };
const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "recipe";
/** A fresh draft, seeded with what the hole asked for, and opened for editing. */
export function newDraft(seed = {}) {
    const base = seed.name || (seed.produces ? `${seed.produces} recipe` : "new recipe");
    let id = `draft:${slug(base)}`, n = 2;
    while (DRAFTS.some(d => d.id === id))
        id = `draft:${slug(base)}-${n++}`;
    const step = { name: "step 1", hours: 1, in: [],
        out: seed.produces ? [{ spec: seed.produces, q: 1, u: "", action: "produce", primary: true, emoji: seed.emoji || "" }] : [] };
    const d = { id, name: base, emoji: seed.emoji || "✏️", produces: seed.produces || "", need: seed.need || "", steps: [step], draft: true };
    DRAFTS.push(d);
    save();
    EDITING = id;
    ARMED = null;
    return d;
}
export function edit(id) { EDITING = id; if (!id)
    ARMED = null; }
export function removeDraft(id) {
    DRAFTS = DRAFTS.filter(d => d.id !== id);
    save();
    if (EDITING === id)
        EDITING = null;
    if (ARMED && ARMED.draft === id)
        ARMED = null;
}
export function arm(a) { ARMED = a; }
/** A tap on a good while a step is armed: the good becomes a flow of that step. */
export function addFlowFromTap(spec, emoji) {
    if (!ARMED)
        return false;
    const d = draftById(ARMED.draft);
    if (!d)
        return false;
    const s = d.steps[ARMED.step];
    if (!s)
        return false;
    const list = ARMED.side === "in" ? (s.in ||= []) : (s.out ||= []);
    if (list.some(f => f.spec === spec))
        return true; // already a flow of this side
    list.push(ARMED.side === "in" ? { spec, q: 1, u: "", action: "consume", emoji }
        : { spec, q: 1, u: "", action: "produce", emoji, primary: list.length === 0 });
    if (ARMED.side === "out" && !d.produces)
        d.produces = spec;
    save();
    return true;
}
/** The draft as the web reads recipes: the same shape, its id marking it a draft. */
export const asRecipes = () => DRAFTS.map(d => ({ ...d }));
/** A run over the draft's flows: the label the proposal text and the panel share. */
function summary(d) {
    return d.steps.map(s => {
        const f = (x) => `${x.q || ""}${x.u ? " " + x.u : ""} ${x.spec || ""}`.trim();
        return `${s.name || "step"}${s.hours ? ` (${s.hours} h)` : ""}: ${(s.in || []).map(x => `${x.action === "use" ? "use " : x.action === "work" ? "work " : ""}${f(x)}`).join(", ") || "—"} → ${(s.out || []).map(f).join(", ") || "—"}`;
    }).join("\n");
}
/** Propose the draft to the forum: a ballot in the recipe domain carrying the recipe whole. */
export async function propose(d) {
    const sid = scopeSig();
    const makes = d.produces || d.steps.flatMap(s => s.out || []).find(f => f.primary)?.spec || "";
    const text = `Adopt “${d.name}” as ${scopeName()}'s recipe for ${makes || "this"}?\n\n${summary(d)}\n\nrecipe-json: ${JSON.stringify({ ...d, draft: undefined })}`;
    const r = await wire().open(d.id, "recipe", text, sid ? `scope:${sid}` : "federation", `recipe:${d.id}`);
    d.proposed = r;
    save();
    return r;
}
// what a drafted step may narrate: the log's verbs, less a count's adjustments;
// which side each stands on is the table's
const ACTIONS = LOG_ACTIONS.filter(a => !isAdjustment(a));
function flowRow(si, side, fi, f) {
    const acts = side === "in" ? ACTIONS.filter(isInput) : ACTIONS.filter(isOutput);
    return `<div class="wd-flow" data-step="${si}" data-side="${side}" data-flow="${fi}">`
        + `<select class="wd-act" title="what the flow does">${acts.map(a => `<option${(f.action || (side === "in" ? "consume" : "produce")) === a ? " selected" : ""}>${a}</option>`).join("")}</select>`
        + `<input class="wd-q" type="number" step="any" min="0" value="${esc(String(f.q ?? ""))}" title="quantity">`
        + `<input class="wd-u" value="${esc(f.u || "")}" placeholder="unit" title="unit">`
        + `<input class="wd-spec" list="wd-goods" value="${esc(f.spec || "")}" placeholder="good" title="the resource specification">`
        + `<button class="wd-x" title="drop this flow">×</button></div>`;
}
function stepCard(d, si, s, a) {
    const armedHere = (side) => !!a && a.draft === d.id && a.step === si && a.side === side;
    return `<div class="wd-step" data-step="${si}">
    <div class="wd-step-h"><input class="wd-sname" value="${esc(s.name || "")}" placeholder="step name">
      <input class="wd-hours" type="number" step="any" min="0" value="${esc(String(s.hours ?? ""))}" title="hours of labour per run"><span class="wd-dim">h</span>
      <button class="wd-xstep" title="drop this step">×</button></div>
    <div class="wd-side"><span class="wd-side-h">in</span>
      <button class="wd-arm${armedHere("in") ? " is-on" : ""}" data-side="in" title="then tap goods on the web to add them as inputs">${armedHere("in") ? "tapping goods… done" : "⊕ pick on the web"}</button>
      <button class="wd-add" data-side="in" title="add an input row">+ row</button></div>
    ${(s.in || []).map((f, fi) => flowRow(si, "in", fi, f)).join("")}
    <div class="wd-side"><span class="wd-side-h">out</span>
      <button class="wd-arm${armedHere("out") ? " is-on" : ""}" data-side="out" title="then tap goods on the web to add them as outputs">${armedHere("out") ? "tapping goods… done" : "⊕ pick on the web"}</button>
      <button class="wd-add" data-side="out" title="add an output row">+ row</button></div>
    ${(s.out || []).map((f, fi) => flowRow(si, "out", fi, f)).join("")}
  </div>`;
}
/**
 * Draw the builder into HOST for the draft being edited (nothing when none).
 * Text fields edit the draft in place without redrawing the form, so typing
 * keeps its focus; adding or dropping a step or a row redraws it.
 */
export function renderBuilder(host, h) {
    const d = editing();
    if (!d) {
        host.innerHTML = "";
        host.classList.remove("is-open");
        return;
    }
    host.classList.add("is-open");
    const a = ARMED;
    host.innerHTML = `<div class="wd">
    <div class="wd-h"><span class="wd-title">✏️ writing a recipe</span>
      <button class="wd-close" title="put the draft away — it stays on this device">close</button></div>
    <datalist id="wd-goods">${h.goods.map(g => `<option value="${esc(g.spec)}">`).join("")}</datalist>
    <datalist id="wd-needs">${h.needs.map(n => `<option value="${esc(n)}">`).join("")}</datalist>
    <label class="wd-l">name <input class="wd-name" value="${esc(d.name)}"></label>
    <label class="wd-l">for the need <input class="wd-need" list="wd-needs" value="${esc(d.need || "")}" placeholder="nourishment/meals"></label>
    <label class="wd-l">makes <input class="wd-makes" list="wd-goods" value="${esc(d.produces || "")}" placeholder="the good it delivers"></label>
    ${d.steps.map((s, si) => stepCard(d, si, s, a)).join("")}
    <div class="wd-row"><button class="wd-addstep">+ step</button>
      <span class="wd-newgood"><input class="wd-ng" placeholder="a good not on the web yet" list="wd-goods"><button class="wd-ng-add" title="add it as a flow of the armed step">add to armed step</button></span></div>
    ${a && a.draft === d.id ? `<div class="wd-arming">tap goods on the web: each becomes an <b>${a.side === "in" ? "input" : "output"}</b> of <b>${esc(d.steps[a.step]?.name || "the step")}</b></div>` : ""}
    <div class="wd-row wd-actions">
      <button class="wd-propose" ${d.proposed && d.proposed !== "kept" && !d.proposed.startsWith("err") ? "disabled" : ""}>propose to the forum</button>
      <button class="wd-drop" title="delete the draft">delete</button>
      <span class="wd-outcome">${d.proposed ? (d.proposed === "ok" ? "proposed — open on the forum" : d.proposed === "kept" ? "kept on this device — it reaches the commune once one is configured" : esc(d.proposed)) : ""}</span>
    </div>
  </div>`;
    const redraw = () => { save(); h.onChange(); };
    const rebuild = () => { save(); renderBuilder(host, h); h.onChange(); };
    const q = (sel) => host.querySelector(sel);
    q(".wd-name").oninput = ev => { d.name = ev.target.value; redraw(); };
    q(".wd-need").oninput = ev => { d.need = ev.target.value; redraw(); };
    q(".wd-makes").oninput = ev => { d.produces = ev.target.value; redraw(); };
    q(".wd-close").onclick = () => { edit(null); renderBuilder(host, h); h.onChange(); };
    q(".wd-drop").onclick = () => { removeDraft(d.id); renderBuilder(host, h); h.onChange(); };
    q(".wd-addstep").onclick = () => { d.steps.push({ name: `step ${d.steps.length + 1}`, hours: 1, in: [], out: [] }); rebuild(); };
    q(".wd-propose").onclick = async () => {
        const b = q(".wd-propose");
        b.disabled = true;
        b.textContent = "proposing…";
        await propose(d);
        renderBuilder(host, h);
        h.onChange();
    };
    q(".wd-ng-add").onclick = () => {
        const inp = q(".wd-ng");
        const spec = inp.value.trim();
        if (!spec)
            return;
        if (!ARMED || ARMED.draft !== d.id)
            ARMED = { draft: d.id, step: 0, side: "in" };
        addFlowFromTap(spec, "");
        inp.value = "";
        rebuild();
    };
    host.querySelectorAll(".wd-step").forEach(el => {
        const si = Number(el.dataset.step);
        const s = d.steps[si];
        el.querySelector(".wd-sname").oninput = ev => { s.name = ev.target.value; redraw(); };
        el.querySelector(".wd-hours").oninput = ev => { s.hours = Number(ev.target.value) || 0; redraw(); };
        el.querySelector(".wd-xstep").onclick = () => { d.steps.splice(si, 1); if (ARMED && ARMED.draft === d.id)
            ARMED = null; rebuild(); };
        el.querySelectorAll(".wd-arm").forEach(b => b.onclick = () => {
            const side = b.dataset.side;
            const on = ARMED && ARMED.draft === d.id && ARMED.step === si && ARMED.side === side;
            ARMED = on ? null : { draft: d.id, step: si, side };
            renderBuilder(host, h);
            h.onChange();
        });
        el.querySelectorAll(".wd-add").forEach(b => b.onclick = () => {
            const side = b.dataset.side;
            (side === "in" ? (s.in ||= []) : (s.out ||= [])).push(side === "in" ? { spec: "", q: 1, u: "", action: "consume" } : { spec: "", q: 1, u: "", action: "produce", primary: !(s.out || []).length });
            rebuild();
        });
        el.querySelectorAll(".wd-flow").forEach(row => {
            const side = row.dataset.side, fi = Number(row.dataset.flow);
            const list = side === "in" ? (s.in ||= []) : (s.out ||= []);
            const f = list[fi];
            row.querySelector(".wd-act").onchange = ev => { f.action = ev.target.value; redraw(); };
            row.querySelector(".wd-q").oninput = ev => { f.q = Number(ev.target.value) || 0; redraw(); };
            row.querySelector(".wd-u").oninput = ev => { f.u = ev.target.value; redraw(); };
            row.querySelector(".wd-spec").onchange = ev => { f.spec = ev.target.value.trim(); redraw(); };
            row.querySelector(".wd-x").onclick = () => { list.splice(fi, 1); rebuild(); };
        });
    });
}
