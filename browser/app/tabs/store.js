// app/tabs/store.ts — the "store" face: what is held, as it is arranged.
//
// The rail's inventory list is a compact reading of the stock; this face is the
// stage version (docs/observation/capture.md §10). The left is the store as it
// is arranged: one card for each outermost place, the places inside it and what
// is held at each a step in, a container with what is in it a step further, each
// stock one short line (rail stripe, name, status glyphs, quantity). Above it one
// band holds the filters, a find box and the tools. The right is a desk for
// whatever is chosen: with nothing chosen, the counts due and the contests open;
// with a stock chosen, its figure and one primary act (count it), the plan's
// range, the other acts as small buttons, and the readings behind a fold.
//
// It reads the same signals the rail does (store-data.ts), so the two cannot
// disagree, and draws what store-view.ts arranges. Every act opens the capture
// sheet, which lays over the stage.
import { HANDLERS } from '../core.js';
import { signal, effect } from '../reactive.js';
import { html, render, list } from '../template.js';
import { on } from '../bus.js';
import { placePath } from '../store-tree.js';
import { knownPlaces } from '../books.js';
import { spoken } from '../labels.js';
import { quantity, planRange } from '../count.js';
import { planNote } from '../plan-note.js';
import { contested, openContests, ensureContests, refreshContests } from '../contests.js';
import { readsOf, readsLine } from '../allotment.js';
import { storeTree, filterTree, cards, dueOrder, dueLine, glyphs, ledgerLine, unfiltered, dueCount, railCounts } from '../store-view.js';
import { schedule, readingsTick, printNote, RAIL_ORDER, railMeta, fetchReadings, fetchSchedule, rowFacts, heldStock, offerCounts, printShown } from '../store-data.js';
import { openCaptureLabel, openCaptureLook, openCaptureStock, openCapturePhotoOf, openCaptureContests, openCaptureQueue } from '../capture.js';
import { waiting } from '../queue.js';
import { F } from './social/share.js';
// ── what the face holds apart from the shared signals ──────────────────────
const selected = signal(null); // the stock on the desk, by id
const filter = signal({});
const reads = signal(null); // the week's photo reads
const shut = signal(new Set()); // the cards folded to their heading, by place id
const held = heldStock;
// a stock chosen is put on the desk; where the desk sits under the cards (a phone), the page goes to it
function choose(id) {
    selected.set(id);
    if (id && window.matchMedia?.("(max-width: 700px)").matches)
        queueMicrotask(() => document.getElementById("storedesk")?.scrollIntoView({ block: "start", behavior: "smooth" }));
}
function refreshAside() {
    void Promise.resolve(HANDLERS.allotment?.()).then(readsOf).then(reads.set).catch(() => reads.set(null));
    void refreshContests();
}
// ── the tree ───────────────────────────────────────────────────────────────
/** The filter in force: the chips, and what is typed in the Express bar, the app's one search (the map reads it too). */
const narrowed = () => ({ ...filter(), q: F.query() });
/** The tree under the filter, with the stock on it. */
function shownTree() {
    const nodes = storeTree(held(), knownPlaces());
    return filterTree(nodes, narrowed(), schedule(), contested());
}
/** One line of a card: a place inside it, or a stock, a step in for each step it sits in. */
function line(n, sched, cont, sel) {
    const step = n.depth - 1;
    if (n.kind === "place")
        return html `<li class="st-place sub" data-depth="${n.depth}" style="--d:${step}"><span class="st-pin">📍</span><span class="st-pname" title="${n.name}">${n.name.split(" › ").pop()}</span><span class="st-held">${n.holds}</span></li>`;
    const r = n.row, rm = railMeta(r.rail), gl = glyphs(r, sched, cont), on = sel === r.id;
    return html `<li class="st-stock${on ? " on" : ""}" data-id="${r.id}" data-depth="${n.depth}" style="--d:${step};--rail:${rm.col}" onclick=${() => choose(on ? null : r.id)}>
    <span class="st-dot" title="${rm.label}"></span><span class="st-emoji">${r.emoji}</span><span class="st-sname" title="${r.name} · ${rm.label}">${r.name}</span>${n.holds ? html `<span class="st-held" title="what it holds">${n.holds} inside</span>` : ""}${gl.length ? html `<span class="st-glyphs">${gl.map(g => html `<span class="st-glyph${g.warn ? " warn" : ""}" title="${g.word}" aria-label="${g.word}">${g.glyph}</span>`)}</span>` : ""}<span class="st-qty">${!n.holds && r.onhand ? quantity(r.onhand, r.unit) : ""}</span>${on ? html `<span class="st-ssub">${[rm.label, r.keeps].filter(Boolean).join(" · ")}</span>` : ""}</li>`;
}
function drawTree() {
    readingsTick();
    const nodes = shownTree();
    const sched = schedule(), cont = contested(), sel = selected(), folded = shut();
    const empty = !held().length ? "nothing is held on the books yet — read a label, or declare what you have from the share bar"
        : !nodes.length ? "nothing here under this filter" : "";
    render("#storetreenote", empty ? html `<div class="st-empty">${empty}</div>` : "");
    list("#storetree", cards(nodes), c => `card:${c.id}`, c => {
        const open = !folded.has(c.id);
        const toggle = () => shut.update(s => { const n = new Set(s); n.has(c.id) ? n.delete(c.id) : n.add(c.id); return n; });
        return html `<section class="st-card${open ? "" : " folded"}" data-place="${c.id}">
      <header class="st-place" data-depth="0" role="button" aria-expanded="${open}" onclick=${toggle}><span class="st-pin">📍</span><span class="st-pname" title="${c.name}">${c.name}</span><span class="st-held">${c.holds}</span><span class="st-chev">${open ? "▾" : "▸"}</span></header>
      ${open ? html `<ul class="st-rows">${c.nodes.map(n => line(n, sched, cont, sel))}</ul>` : ""}
    </section>`;
    });
}
// ── the filter strip ───────────────────────────────────────────────────────
function drawFilters() {
    const rows = held(), f = filter(), eff = narrowed();
    const sched = schedule(), cont = contested();
    const dueN = dueCount(rows, sched);
    const doubtN = rows.filter(r => r.id && cont.has(r.id)).length;
    const perN = rows.filter(r => r.perishable).length;
    const rails = railCounts(rows, RAIL_ORDER);
    const chip = (label, on, set, title = "") => html `<span class="st-chip${on ? " on" : ""}" title="${title}" onclick=${set}>${label}</span>`;
    render("#storefilters", html `
    ${chip(html `${rows.length} kind${rows.length === 1 ? "" : "s"}`, unfiltered(eff), () => filter.set({}), ledgerLine(rows, sched, cont))}
    ${dueN ? chip(html `⏱ ${dueN} due`, !!f.due, () => filter.set({ ...f, due: !f.due }), "stock whose count is overdue") : ""}
    ${doubtN ? chip(html `⚠ ${doubtN} contested`, !!f.contested, () => filter.set({ ...f, contested: !f.contested }), "stock whose count a member contests") : ""}
    ${perN ? chip(html `🍂 ${perN} perishes`, !!f.perishable, () => filter.set({ ...f, perishable: !f.perishable }), "stock that keeps for days") : ""}
    <span class="st-sep"></span>
    ${rails.map(({ rail, n }) => {
        const m = railMeta(rail);
        return chip(html `<span class="rsw" style="background:${m.col}"></span>${m.label} ${n}`, f.rail === rail, () => filter.set({ ...f, rail: f.rail === rail ? undefined : rail }));
    })}`);
}
// ── the head ───────────────────────────────────────────────────────────────
function drawHead() {
    readingsTick();
    fetchSchedule(); // a landed count asks the schedule again
    const rows = held(), sched = schedule();
    const dueN = dueCount(rows, sched);
    const shown = shownTree().filter(n => n.kind === "stock").map(n => n.row);
    const note = printNote(), line = readsLine(reads()), left = reads();
    render("#storehead", html `
    <button class="st-tool" onclick=${() => openCaptureLabel()} title="scan or type a container's code, then count what is in it">🏷 <span class="lbl">read a label</span></button>
    <button class="st-tool" onclick=${() => openCaptureLook()} title="${line || "a model proposes what the picture shows; you confirm each row"}">📷 <span class="lbl">photograph</span>${left && left.sees ? html `<span class="st-pip" aria-label="${line}">${left.remaining}</span>` : ""}</button>
    ${waiting() ? html `<button class="st-tool" onclick=${() => openCaptureQueue()} title="photographs kept to be read later">📥 ${waiting()} waiting<span class="lbl"> to be read</span></button>` : ""}
    ${dueN || shown.length ? html `<details class="st-more"><summary class="st-tool" title="more">⋯</summary><div class="st-menu">
      ${dueN ? html `<button onclick=${offerCounts} title="offer the counts that are due to whoever's turn it is">offer the counts due</button>` : ""}
      ${shown.length ? html `<button onclick=${() => { void printShown(shown, false); }} title="a sheet of labels for what is shown">labels</button><button onclick=${() => { void printShown(shown, true); }} title="name cards for what is shown">name cards</button>` : ""}
    </div></details>` : ""}
    ${note ? html `<span class="st-note">${note}</span>` : ""}`);
}
// ── the desk ───────────────────────────────────────────────────────────────
/** The overview: what is due, and the contests open. */
function overview() {
    const rows = held();
    const byId = new Map(rows.map(r => [r.id, r]));
    const due = dueOrder([...schedule().values()]).filter(c => byId.has(c.id));
    const open = openContests();
    return html `
    <section class="st-card plain">
    <div class="st-lbl">counts due</div>
    ${due.length ? html `<ul class="st-list">${due.map(c => html `
      <li class="st-due one${c.overdue ? " late" : ""}"><span class="st-dname" onclick=${() => choose(c.id)}>${c.name}</span><span class="st-dsub" title="${dueLine(c)}">${dueLine(c)}</span><button class="st-mini" onclick=${() => { selected.set(c.id); openCaptureStock(c.id); }}>count it</button></li>`)}</ul>`
        : html `<div class="st-empty">${rows.length ? "no count is scheduled yet" : "nothing is held yet, so nothing is due"}</div>`}
    </section>
    <section class="st-card plain">
    <div class="st-lbl">contests</div>
    ${open.length ? html `<ul class="st-list">${open.map(c => {
        const r = c.resource ? byId.get(c.resource) : undefined;
        return html `<li class="st-due${c.role === "attach" ? " late" : ""}"><span class="st-dname">${r ? r.name : c.kind === "count" ? "a count" : "work"}</span><span class="st-dsub">${c.reason || "no reason given"} · ${c.role === "attach" ? "your count: attach your photograph" : c.role === "vote" ? "vote in the forum" : ""}</span>${r ? html `<button class="st-mini" onclick=${() => { selected.set(r.id); openCaptureContests({ id: r.id, name: r.name }); }}>${c.role === "attach" ? "attach" : "see it"}</button>` : ""}</li>`;
    })}</ul>`
        : html `<div class="st-empty">no contest is open</div>`}
    </section>`;
}
/** The desk of one stock: the figure and the one act first, the rest as it is asked for. */
function desk(r) {
    const rows = held();
    const places = knownPlaces();
    const where = r.location ? placePath(r.location, places) : r.where;
    const lines = rows.filter(x => x.containedIn === r.id);
    const sched = schedule(), cont = contested();
    // the prompt below says a count is contested, so the chip that says it too steps aside
    const gl = glyphs(r, sched, cont).filter(g => !(cont.has(r.id) && g.warn));
    const rm = railMeta(r.rail);
    const facts = rowFacts(r);
    const plan = r.expected;
    return html `
    <div class="st-dhead"><span class="st-emoji big">${r.emoji}</span><div><div class="st-dname big">${r.name}</div>
      <div class="st-dsub">${[where, r.code ? spoken(r.code) : "", r.keeps].filter(Boolean).join(" · ")}</div></div>
      <span class="st-close" title="back to the overview" onclick=${() => selected.set(null)}>✕</span></div>
    <div class="st-figure">${lines.length ? html `<span class="st-holds">holds ${lines.length}</span>` : r.onhand ? quantity(r.onhand, r.unit) : "none counted"}<span class="st-rail-tag" style="color:${rm.col}">${rm.label}</span></div>
    ${gl.length ? html `<div class="st-badges">${gl.map(g => html `<span class="st-badge${g.warn ? " warn" : ""}">${g.glyph} ${g.word}</span>`)}</div>` : ""}
    ${cont.has(r.id) ? html `<div class="st-prompt">A member says your count of this was not done. <button class="st-mini" onclick=${() => openCaptureContests({ id: r.id, name: r.name })}>attach your photograph</button></div>` : ""}
    ${plan ? planNote(plan, r.unit, `the plan expects ${planRange(plan, r.unit)}`) : ""}
    <div class="st-verbs">
      <button class="st-tool st-primary" onclick=${() => openCaptureStock(r.id)}>count</button>
      <button class="st-tool" onclick=${() => openCaptureContests({ id: r.id, name: r.name })} title="the counts of this stock; say one was not done">history</button>
      <button class="st-tool" onclick=${() => openCapturePhotoOf(r.id)}>📷 photograph</button>
      <details class="st-more"><summary class="st-tool" title="print a label or a name card">print ▾</summary><div class="st-menu">
        <button onclick=${() => { void printShown([r], false); }}>label</button>
        <button onclick=${() => { void printShown([r], true); }}>name card</button>
      </div></details>
    </div>
    ${facts.length ? html `<details class="st-fold"><summary>what the counts have found</summary><ul class="st-facts">${facts.map(f => html `<li>${f}</li>`)}</ul></details>` : ""}
    ${lines.length ? html `<div class="st-lbl">in it</div><ul class="st-list">${lines.map(l => html `
      <li class="st-due"><span class="st-dname" onclick=${() => choose(l.id)}>${l.emoji} ${l.name}</span><span class="st-dsub">${l.onhand ? quantity(l.onhand, l.unit) : ""}</span><button class="st-mini" onclick=${() => openCaptureStock(l.id)}>count</button></li>`)}</ul>` : ""}`;
}
function drawDesk() {
    readingsTick();
    const id = selected();
    const r = id ? held().find(x => x.id === id) : undefined;
    if (r && r.spec)
        fetchReadings(r.spec);
    render("#storedesk", r ? desk(r) : overview());
}
// ── mounting ───────────────────────────────────────────────────────────────
let wired = false;
function ensureWired() {
    if (wired)
        return;
    wired = true;
    render("#storestage", html `
    <div class="st-band">
      <div id="storefilters"></div>
      <div id="storehead"></div>
    </div>
    <div class="st-cols">
      <div class="st-left"><div id="storetreenote"></div><div id="storetree"></div></div>
      <div class="st-right" id="storedesk"></div>
    </div>`);
    on("inventory", () => { refreshAside(); });
    effect(drawHead);
    effect(drawFilters);
    effect(drawTree);
    effect(drawDesk);
}
export function initStore() {
    ensureWired();
    fetchSchedule();
    ensureContests();
    refreshAside();
}
