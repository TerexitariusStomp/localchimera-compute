// app/tabs/inventory.ts — the two faces of a resource: stock ON HAND and
// stock TO OBTAIN.
//
// Panel subsystem, two sibling sidebar sections on the time face:
//
//   inventory — the EconomicResources the scope holds on hand, grouped by the
//     RAIL they sit on (distribution-mode: communal → commons, individual-
//     claimable → credit, else yours). Mirrors the planner's inventory wire
//     (service.scm build-inventory-snapshot: resource->inv-alist gives
//     {name, conforms-to, onhand, unit, custodian, location, stage, …}). Live
//     from the seam (EXT.inventory, pushed by day-boot) falling back to the demo
//     stock below, exactly like every other face keeps a standalone fallback.
//
//   shopping — the acquisition list, DERIVED from the live PLAN's shortfalls
//     (needs with met < 1) crossed with PLACES: for each gap, WHERE/HOW to
//     obtain it — by the commons or credit rail, or by contributing work. No
//     market here; "shopping" is provisioning from the commons. It's a checklist
//     you assemble (tap ＋), the cart without the money.
//
// Touches the core only at call time (PLAN/PLACES/MODES/EXT read inside the draw
// functions), so the main.js <-> inventory.js import cycle is benign.
//
// Both sections draw through app/template.js: each row is one html`` expression
// and list() keys them, so wire data is escaped on the way in and a redraw that
// changes one row leaves the others' nodes where they are. Nothing here reaches
// for d3 — the join was bookkeeping in a panel this shape, and the dial's own
// SVG keeps it.
import { PLAN, PLACES, MODES } from '../core.js';
import { signal, effect } from '../reactive.js';
import { html, render, list } from '../template.js';
import { metCol, STATUS } from '../palette.js';
import { openCaptureLabel, openCaptureContests } from '../capture.js';
import { nest } from '../store-tree.js';
import { dueCount } from '../store-view.js';
import { contested, ensureContests } from '../contests.js';
import { spoken } from '../labels.js';
import { quantity } from '../count.js';
import { emojiFor, RAIL_ORDER, railMeta, readingsTick, stockData, fetchReadings, countRow, schedule, fetchSchedule, offerCounts, rowFacts, printNote, printShown, seedStock } from '../store-data.js';
const railFilter = signal("all");
// an empty list still draws a row, so the section says what it means rather
// than going blank. One item, one key, the same keyed path as any other row.
const emptyRow = (word) => [{ empty: word }];
const isEmpty = (r) => "empty" in r;
const drawEmpty = (r) => html `<li class="iv-empty">${r.empty}</li>`;
// ── inventory: the on-hand ledger, filterable by rail ──────────────────────
function drawInventory() {
    const all = stockData() || [];
    const filter = railFilter();
    readingsTick(); // a landed reading redraws the list
    for (const r of all)
        if (r.spec)
            fetchReadings(r.spec);
    fetchSchedule();
    ensureContests();
    const mine = contested(); // a landed answer redraws the list
    const dueN = dueCount(all, schedule());
    // the ledger line: kinds on hand, and how many perish (a nod to the dial's
    // spirals of decay — fresh stock is the storage that won't wait).
    const kinds = all.length;
    const perish = all.filter(r => r.perishable).length;
    const commons = all.filter(r => r.rail === "common").length;
    const note = printNote();
    const shownRows = all.filter(r => filter === "all" ? true : r.rail === filter);
    render("#invledger", html `
    <b>${kinds}</b> kind${kinds === 1 ? "" : "s"} on hand
    · <b style="color:${railMeta("common").col}">${commons}</b> on the commons rail
    ${perish ? html ` · <span style="color:${STATUS.unmet}">${perish} perishable</span>` : ""}
    ${dueN ? html ` · <span style="color:${STATUS.strained}">${dueN} count${dueN === 1 ? "" : "s"} due</span>` : ""}
    ${html `<div class="iv-tools">${dueN ? html `<span class="iv-count" title="offer the counts that are due to whoever's turn it is" onclick=${offerCounts}>offer the counts</span>` : ""}<span class="iv-count" title="scan or type a container's code, then count what is in it" onclick=${() => openCaptureLabel()}>read a label</span><span class="iv-count" title="a sheet of labels for what is shown" onclick=${() => { void printShown(shownRows, false); }}>labels</span><span class="iv-count" title="name cards for what is shown" onclick=${() => { void printShown(shownRows, true); }}>name cards</span>${note ? html `<span class="iv-note">${note}</span>` : ""}</div>`}`);
    // the rail chips — all + one per rail present, count each, click to isolate
    const chips = ["all", ...RAIL_ORDER.filter(k => all.some(r => r.rail === k))];
    list("#invrails", chips, c => c, c => {
        // "all" carries no rail colour of its own; borrow one so railMeta stays total
        const on = c === filter, rm = railMeta(c === "all" ? "own" : c);
        // "all" is the clear-filter chip and carries no rail colour of its own
        const paint = on && c !== "all" ? `background:${rm.col};border-color:${rm.col}` : "";
        const n = c === "all" ? all.length : all.filter(r => r.rail === c).length;
        return html `<span class="ifilter${on ? " on" : ""}" style="${paint}"
                      onclick=${() => railFilter.set(c)}
                >${c === "all" ? html `all ${n}`
            : html `<span class="rsw" style="background:${rm.col}"></span>${rm.label} ${n}`}</span>`;
    });
    // most on hand first within the view, then as the store is arranged: each
    // container, and what is in it a step in
    const depth = new Map();
    const shown = nest(shownRows.slice().sort((a, b) => b.onhand - a.onhand))
        .map(n => { depth.set(n.row, n.depth); return n.row; });
    list("#inventory", (shown.length ? shown : emptyRow("nothing on hand")), r => isEmpty(r) ? "·empty" : `${r.rail}/${r.spec}/${r.name}/${r.id ?? ""}`, r => {
        if (isEmpty(r))
            return drawEmpty(r);
        const rm = railMeta(r.rail);
        const qty = r.onhand ? quantity(r.onhand, r.unit) : "";
        const d = depth.get(r) ?? 0;
        return html `
           <li title="${r.name} · ${rm.label}${r.code ? ` · ${spoken(r.code)}` : ""}" style="${d ? `padding-left:${6 + d * 16}px` : ""}">
             <span class="iv-emoji">${r.emoji}</span>
             <div class="iv-body">
               <div class="iv-top">
                 <span class="iv-name">${r.name}</span>
                 <span class="iv-qty">${qty}</span>${r.id ? html `<span class="iv-count" title="count it: say how much is there" onclick=${() => countRow(r)}>count</span>` : ""}${r.id ? html `<span class="iv-count" title="the counts of this stock: say one was not done" onclick=${() => openCaptureContests({ id: r.id, name: r.name })}>history</span>` : ""}${r.id && mine.has(r.id) ? html `<span class="iv-count iv-contested" title="a member says your count was not done: attach your photograph" onclick=${() => openCaptureContests({ id: r.id, name: r.name })}>your count is contested</span>` : ""}
               </div>
               <div class="iv-sub">
                 <span class="iv-rail" style="color:${rm.col}">${rm.label}</span>
                 ${r.where ? ` · ${r.where}` : ""}${r.keeps ? ` · ${r.keeps}` : ""}${r.code ? ` · ${spoken(r.code)}` : ""}${rowFacts(r).map(f => ` · ${f}`).join("")}
               </div>
             </div>
           </li>`;
    });
}
// ── shopping: the acquisition list, derived from the plan's shortfalls ──────
// where/how to obtain a need: its PLACES, by rail. Falls back to the need's
// family (movement/*, learning/*) when the exact classification has no places.
function obtainSources(needId) {
    let ps = PLACES[needId];
    if (!ps || !ps.length) {
        const fam = String(needId).split("/")[0] + "/";
        ps = Object.entries(PLACES).filter(([k]) => k.startsWith(fam)).flatMap(([, v]) => v);
    }
    return ps || [];
}
// the items you've marked to obtain — a client-side checklist, keyed by need id.
const cart = signal(new Set());
function toggleCart(id) {
    cart.update(s => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; });
}
// a place, in the colour of the rail it offers the good on
const railTag = (p) => html `<b style="color:${MODES[p.mode]?.col || "#666"}">${p.name}</b>`;
// fragments concatenate bare, so a separator is interleaved rather than joined
const withSep = (items, sep, of) => items.flatMap((x, i) => i ? [sep, of(x)] : [of(x)]);
// where a shortfall comes from, in one line: the ways to RECEIVE it (commons /
// credit) before the way to MAKE it happen (contribute a work-intent).
function obtainLine(needId) {
    const src = obtainSources(needId);
    const receive = src.filter(p => p.mode === "common" || p.mode === "claim");
    const contribute = src.filter(p => p.mode === "work");
    if (receive.length)
        return html `obtain · ${withSep(receive.slice(0, 2), " · ", railTag)}${contribute.length ? ` · or ${contribute[0].emoji || ""} contribute a shift` : ""}`;
    if (contribute.length)
        return html `contribute · ${contribute[0].emoji || ""} ${railTag(contribute[0])}`;
    return html `<span style="color:${STATUS.strained}">no source yet — propose it</span>`;
}
function drawShopping() {
    const needs = (PLAN().needs || []).filter(n => (n.met ?? 1) < 0.95);
    const got = cart();
    if (!needs.length) {
        render("#shopledger", html `<b>nothing short</b> — the plan is provisioned`);
        list("#shopping", emptyRow("the commons has you covered"), () => "·empty", drawEmpty);
        return;
    }
    const inList = needs.filter(n => got.has(n.id)).length;
    render("#shopledger", inList
        ? html `<b>${inList}</b> to obtain · ${needs.length} short in the plan`
        : html `<b>${needs.length}</b> short in the plan · tap ＋ to add to your list`);
    // worst-off first — the biggest gaps sit at the top
    const shown = needs.slice().sort((a, b) => (a.met ?? 1) - (b.met ?? 1));
    list("#shopping", shown, need => need.id, need => {
        const met = need.met ?? 1;
        const on = got.has(need.id);
        return html `
      <li class="${on ? "got" : ""}" title="add to your list to obtain"
          onclick=${() => toggleCart(need.id)}>
        <span class="iv-emoji">${need.emoji || emojiFor(need.id)}</span>
        <div class="iv-body">
          <div class="iv-top">
            <span class="iv-name">${need.label || need.id}</span>
            <span class="iv-gap" style="color:${metCol(met)}">${Math.round((1 - met) * 100)}% short</span>
          </div>
          <div class="iv-sub iv-obtain">${obtainLine(need.id)}</div>
        </div>
        <span class="iv-get">${on ? "✓" : "＋"}</span>
      </li>`;
    });
}
// called once from main.js's boot: seed the stock and start the two effects that
// keep #inventory / #shopping in sync with the stock, plan and cart signals.
export function initInventory() {
    seedStock();
    effect(drawInventory); // stock + rail filter
    effect(drawShopping); // PLAN() shortfalls + cart
}
export { drawInventory, drawShopping };
