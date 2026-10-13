// app/tabs/shop.ts — the "shop" face: what you can get, and how.
//
// Three roads to a good, each shown as itself (playnet.typ §What is free):
//   READY FOR YOU — what the plan holds for you: take it.
//   FREE TO YOU   — by need (your meals, closed from the commons every day),
//                   in common (the clinic, childcare, shelter — go), and in
//                   plenty (a good the plan says is abundant — the rule is
//                   stated, not yet built, so the shelf names it and stays empty).
//   BY YOUR HOURS — the individual portion, priced in the hours each
//                   thing cost society: say what you want, and the next plan
//                   answers; your asks sit on this shelf until it does.
// Beneath those, the means you USE (an oven, a field) reach you through the
// rota, never a claim.
//
// The shop is the face of the INDIVIDUAL RAIL (playnet.typ §Two rails / §The
// credit identity): the individual portion after the deductions, priced
// in the hours they cost society, with your certificate above. Nothing here is
// a sale, and nothing here is taken on sight. The loop has three steps:
//
//   ASK   — "want this": a demand row `spec~aid` (session/declare-need, kind
//           `des`). A want, never a need: what a need takes leaves by the eat
//           recipe from the portion the plan keeps back and is not on this rail.
//   HELD  — the plan answers: it ranks wants over the leftover among the plans
//           each certificate admits and registers each answered row as a
//           transfer commitment (service plan-claims!). YOUR ROWS shows every
//           want as asked (no row yet), held (with what remains) or taken.
//   TAKE  — confirm a held row, partial or whole (session/claim resolves the
//           plan's own commitment; the ledger records the transfer against it).
//           A good the plan did not set aside for you has no button.
//
// LIVE PATH: EXT.inventory (specs carry categories + snlt; resources carry
// distribution-mode + claimable ids), EXT.credit (the certificate, derived
// server-side), HANDLERS.myClaims (the order book: session/my-claims),
// HANDLERS.declareNeed (ask), HANDLERS.claim (take). Standalone, the demo
// carries the design. FOLKSONOMY: goods shelve under the commune's live
// taxonomy cut, the same descendant index the work-intent `serves` match uses.
import { EXT, HANDLERS } from '../core.js';
import { S } from '../state.js';
import { signal, effect } from '../reactive.js';
import { colorFor } from '../palette.js';
import { termNode, termOf, DEMO_SPECS, DEMO_RESOURCES, DEMO_KEPT_BY_SPEC } from '../desire-projection.js';
import { esc } from '../template.js';
import { readJson } from '../seam.js';
import { specOf } from '../slots/model.js';
import { on } from '../bus.js';
import { creditNow, DEMO_CREDIT } from '../credit.js';
import { scopeSig, scopeChain, goToScope } from '../scope.js';
import { F, declare, retire, myNeeds, myMeans, ourFold, refreshSocial } from './social/share.js';
import { grantOf, lendControl } from '../lend.js';
import { untilWords } from '../lend-core.js';
import { num, figure } from '../count.js';
import { emojiFor } from '../glyphs.js';
import { PLAN } from '../core.js';
import { mk } from '../dom.js';
import { countMode, countTab, heldCard, heldGlyphs, wireHeld } from '../shop-count.js';
import { isCountUnit } from '../units-catalogue.js';
const fmtH = (h) => (h >= 100 ? Math.round(h) : Math.round(h * 10) / 10) + " h";
// ── demo data (the design, standalone) ─────────────────────────────────────
// What waits for you waits at a place of the demo world (demo/world.ts): the
// bakery the store holds loaves at, the market hall on the map.
const DEMO = {
    specs: DEMO_SPECS,
    resources: DEMO_RESOURCES,
    communal: [
        { id: "medical", name: "medical care", cats: ["care/medical"], emoji: "🩺" },
        { id: "childcare", name: "childcare", cats: ["care/children"], emoji: "🧸" },
        { id: "shelter", name: "public shelter", cats: ["housing"], emoji: "🏠" },
    ],
    rows: [
        { id: "claim|bread|me|town|0", spec: "bread", name: "bread", place: "Bakery Vitosha", when: "Thu", total: "3", fulfilled: "0", remaining: "3", snlt: "0.3", state: "held" },
        { id: "claim|cheese|me|town|0", spec: "cheese", name: "cheese", place: "central market hall", when: "", total: "0.5", fulfilled: "0", remaining: "0.2", snlt: "2", state: "held" },
        { id: "claim|salmon|me|town|1", spec: "salmon", name: "salmon", place: "central market hall", when: "Sat", total: "1", fulfilled: "1", remaining: "0", snlt: "6", state: "taken" },
    ],
};
// ── reactive seams ─────────────────────────────────────────────────────────
const bump = signal(0); // inventory or credit moved → redraw
const rows = signal(null); // the order book (null = demo)
const qty = signal(1);
// a held row can be taken only up to what remains: the first take defaults to a
// whole unit, or to the whole remainder when less than one unit waits
const takeStart = (r) => r ? Math.min(1, num(r.remaining)) : 1;
const note = signal(""); // transient feedback in the card
const busy = signal(false); // an RPC is in flight — no double fire
const focusId = signal(null); // folksonomy term the pool is narrowed to
// a deferred alias, not F.query itself: share.ts imports resourcesPanel from
// here, so this module is on the other side of a real import cycle — reading
// F only inside the call, never at load time, keeps evaluation-order safe
const query = () => F.query();
const whereSel = signal("");
const whenSel = signal(null);
const offerMode = signal(false); // the open card's want/offer toggle
// ── data assembly ──────────────────────────────────────────────────────────
const liveInv = () => {
    const inv = EXT.inventory;
    return inv && Array.isArray(inv.resources) && inv.resources.length ? inv : null;
};
const isExternal = (cats) => (cats || []).some(c => /^external\b|^external\//.test(String(c)));
function orderBook() {
    const inv = liveInv();
    if (!inv) {
        const claim = DEMO.specs.map(s => {
            const rs = DEMO.resources.filter(r => r.spec === s.id);
            return { id: s.id, name: s.name, unit: s.unit, snlt: s.snlt, emoji: s.emoji,
                onhand: rs.reduce((a, r) => a + r.onhand, 0), term: termOf(s.cats),
                external: !!s.external, rids: rs.map(r => r.id) };
        });
        const communal = DEMO.communal.map(c => ({ id: c.id, name: c.name, emoji: c.emoji, term: termOf(c.cats), communal: true }));
        return { claim, communal, demo: true };
    }
    const specs = {};
    (inv.specs || []).forEach(s => { specs[s.id] = s; });
    const byRail = (mode) => {
        const by = new Map();
        for (const r of inv.resources || []) {
            if ((r["distribution-mode"] || "") !== mode)
                continue;
            const sid = r["conforms-to"] || r.spec || "";
            if (!by.has(sid))
                by.set(sid, []);
            by.get(sid).push(r);
        }
        return by;
    };
    const entry = (sid, rs, communal) => {
        const s = specs[sid] || {};
        const cats = Array.from(s.categories || []);
        return { id: sid, name: s.name || (rs[0] && rs[0].name) || sid,
            unit: s.unit || (rs[0] && rs[0].unit) || "",
            snlt: s.snlt != null ? parseFloat(String(s.snlt)) : null,
            onhand: rs.reduce((a, r) => a + (parseFloat(String(r.onhand)) || 0), 0),
            term: termOf(cats), external: isExternal(cats), communal,
            rids: rs.map(r => String(r.id ?? "")),
            locs: [...new Set(rs.map(r => String(r.location ?? "")).filter(Boolean))] };
    };
    const claim = [], communal = [];
    for (const [sid, rs] of byRail("individual-claimable"))
        claim.push(entry(sid, rs, false));
    for (const [sid, rs] of byRail("communal"))
        communal.push(entry(sid, rs, true));
    return { claim, communal, demo: false };
}
/** The order book as the face reads it: the wire's rows; standalone, the
 *  demo's held and taken rows with each need you declared as an asked one —
 *  an ask IS a declared need (share.ts `declare`), so the two cannot drift. */
const bookRows = () => rows() || (orderBook().demo
    ? DEMO.rows.concat(myNeeds().filter(n => Number(n.qty) > 0).map(n => ({
        id: n.id || `need:me:${n.spec}`, spec: n.spec, name: n.name || n.spec, place: n.where || "", when: "",
        total: String(n.qty), fulfilled: "0", remaining: "0", snlt: "", state: "asked"
    })))
    : []);
function fetchRows() {
    if (!HANDLERS.myClaims || !scopeSig()) {
        rows.set(null);
        return;
    }
    HANDLERS.myClaims().then(r => {
        try {
            const j = readJson(r);
            rows.set(j && Array.isArray(j.rows) ? j.rows : []);
        }
        catch {
            rows.set([]);
        }
    });
}
// ── the social reading: the fold at the scope, per good ────────────────────
// Everyone's asks and offers summed (share.ts `ourFold`, the one read of
// session/our-slots). Standalone the fold is a fixture that never moves, so
// your own share of each cell is read off your slots as they stand now.
function summed(cells, mine, demo) {
    const by = new Map();
    const add = (spec, q) => { if (q)
        by.set(spec, (by.get(spec) || 0) + q); };
    for (const c of cells)
        add(c.spec, demo ? c.qty - c.mine : c.qty);
    if (demo)
        for (const m of mine)
            add(m.spec, Number(m.qty) || 0);
    return by;
}
// what the demo commune asks, per good, against the demo pool
const DEMO_ASKS = { bread: 60, vegetables: 80, tea: 4, fabric: 20, "winter coat": 6, chair: 2, euros: 30, monero: 3 };
// what the demo scope keeps of a good for production and the reserve, by the good's name (desire-projection.ts states it by spec)
const DEMO_KEPT = Object.fromEntries(DEMO_SPECS.flatMap(s => (DEMO_KEPT_BY_SPEC[s.id] ? [[s.name, DEMO_KEPT_BY_SPEC[s.id]]] : [])));
// ── where & when: the order's two coordinates ──────────────────────────────
function whereOptions() {
    const locs = (EXT.snapshot && EXT.snapshot.locations) || [];
    const live = locs.filter(l => l && l.name).map(l => ({ id: String(l.id || l.name), name: String(l.name) }));
    return live;
}
const WHEN_CHIPS = [
    { key: "morning", label: "morning", day: 0, hour: 9 },
    { key: "midday", label: "midday", day: 0, hour: 13 },
    { key: "evening", label: "evening", day: 0, hour: 19 },
    { key: "tomorrow", label: "tomorrow", day: 1, hour: 12 },
];
function chipIso(chip) {
    const d = new Date();
    d.setDate(d.getDate() + chip.day);
    d.setHours(chip.hour, 0, 0, 0);
    return d.toISOString();
}
// term label + hue from the live spine node
const termLabel = (tid) => termNode(tid)?.name || String(tid).split("/").pop() || String(tid);
const termColor = (tid) => termNode(tid)?.col || colorFor(tid, termLabel(tid));
/** A good's tint IS its band's colour — the spine node's, else the shared
 *  palette's, else a neutral grey. */
const goodTint = (tid) => termColor(tid) || "#8f8f8f";
// ── the filter: focus term + search ────────────────────────────────────────
const inFocus = (term) => {
    const f = focusId();
    if (!f)
        return true;
    if (term === f)
        return true;
    const d = S.desc && S.desc.get(f);
    return !!(term && d && d.has(term));
};
const matchesQuery = (e) => {
    const q = query().trim().toLowerCase();
    if (!q)
        return true;
    return (e.name || "").toLowerCase().includes(q) || termLabel(e.term).toLowerCase().includes(q);
};
const openId = signal(null); // the good whose ask/take card is open
// where the open good's card sits: in its row under YOURS, or under its tile among the goods
const openAt = signal("goods");
const openRow = signal(null); // …and the held row being taken, if a take
function goods() {
    const book = orderBook();
    const plan = PLAN && PLAN();
    const idOf = new Map();
    for (const e of book.claim)
        idOf.set(e.name.toLowerCase(), e.id);
    const keptBy = new Map();
    if (book.demo)
        for (const [k, v] of Object.entries(DEMO_KEPT))
            keptBy.set(idOf.get(k) || k, v);
    else
        for (const k of (plan && plan.kept) || [])
            keptBy.set(k.spec, num(k.q));
    const fold = ourFold(), standalone = fold.demo || !!book.demo;
    const askBy = summed(fold.needs, myNeeds(), standalone);
    const offerBy = summed(fold.means, myMeans(), standalone);
    if (standalone)
        for (const [k, v] of Object.entries(DEMO_ASKS)) {
            const id = idOf.get(k) || k;
            askBy.set(id, (askBy.get(id) || 0) + v);
        }
    const rs = bookRows();
    const list = book.claim.map(e => ({
        spec: e.id, name: e.name, emoji: e.emoji || emojiFor(e.name, e.term), unit: e.unit || "", snlt: e.snlt ?? null, term: e.term,
        external: e.external, rids: e.rids, locs: e.locs,
        kept: keptBy.get(e.id) || 0, left: e.onhand || 0, asked: askBy.get(e.id) || 0, offered: offerBy.get(e.id) || 0,
        mine: rs.filter(r => r.spec === e.id), offer: null,
    }));
    // a row of yours on a good the pool no longer lists (taken out, or a demo name)
    for (const r of rs)
        if (!list.some(g => g.spec === r.spec)) {
            const g = list.find(x => x.name.toLowerCase() === r.name.toLowerCase());
            if (g)
                g.mine.push(r);
            else
                list.push({ spec: r.spec, name: r.name || r.spec, emoji: emojiFor(r.name || r.spec), unit: "", snlt: num(r.snlt) || null, kept: 0, left: 0, asked: askBy.get(r.spec) || 0, offered: offerBy.get(r.spec) || 0, mine: [r], offer: null });
        }
    // your offers: each rides the good it is an offer of; one the pool has never listed gets a tile of its own
    for (const m of myMeans()) {
        if (!(Number(m.qty) > 0))
            continue;
        const low = String(m.name || "").toLowerCase();
        const g = list.find(x => x.spec === m.spec) || list.find(x => !!low && x.name.toLowerCase() === low);
        if (g)
            g.offer = m;
        else
            list.push({ spec: m.spec, name: m.name || m.spec, emoji: m.emoji || emojiFor(m.name || m.spec), unit: m.unit || "", snlt: null,
                kept: 0, left: 0, asked: askBy.get(m.spec) || 0, offered: offerBy.get(m.spec) || 0, mine: [], offer: m });
    }
    return { list, communal: book.communal, demo: !!book.demo };
}
const held = (g) => g.mine.filter(r => r.state === "held");
const askd = (g) => g.mine.filter(r => r.state === "asked");
const taken = (g) => g.mine.filter(r => r.state === "taken");
const contention = (g) => g.asked - g.left;
/** The unit a good is offered in: its own, or the slot's default when it is counted in itself. */
const unitOf = (g) => { const u = g.offer?.unit || g.unit; return u && !isCountUnit(u) ? u : ""; };
function myLine(g) {
    const h = held(g), a = askd(g), t = taken(g);
    const parts = [];
    for (const r of h)
        parts.push(`<b>${figure(num(r.remaining))}</b> ${esc(g.unit)} waiting for you${r.place ? ` at ${esc(r.place)}` : ""}`);
    for (const r of a)
        parts.push(`you asked for <b>${figure(num(r.total))}</b> ${esc(g.unit)} · <span class="sg-none">the plan answers on its next run</span>`);
    for (const r of t)
        parts.push(`<span class="sg-taken">${figure(num(r.fulfilled))} ${esc(g.unit)} taken ✓</span>`);
    if (g.offer) {
        const lent = grantOf(g.offer);
        parts.push(`you have <b>${figure(num(g.offer.qty))}</b> ${esc(unitOf(g))}` + (lent
            ? ` · <span class="sg-taken">lent ${esc(untilWords(lent.until))}</span>` : ""));
    }
    return parts.join("<br>");
}
function myButton(g) {
    const h = held(g);
    if (h.length)
        return `<button class="sg-take" data-spec="${esc(g.spec)}" data-id="${esc(h[0].id)}">take</button>`;
    if (askd(g).length)
        return `<a class="sg-withdraw" data-spec="${esc(g.spec)}">never mind</a>`;
    return `<button class="sg-want" data-spec="${esc(g.spec)}">want this</button>`;
}
// ── the card's parts: each act on a good, as its own block ─────────────────
// The goods popover and a row of YOURS compose the same blocks, so a take, an
// ask and a lend read and behave the same wherever the good is opened.
const stepper = (unit, cost, sign) => `<div class="sg-qty">
    <button class="sg-step" data-d="-1">−</button><span class="sg-q">${figure(qty())} ${esc(unit)}</span><button class="sg-step" data-d="1">＋</button>
    ${cost != null ? `<span class="sg-cost">${sign} ${fmtH(cost)}</span>` : ""}</div>`;
const whereField = () => `<div class="sg-ww"><label>where</label><select class="sg-where">${whereOptions().map(o => `<option value="${esc(o.id)}"${o.id === whereSel() ? " selected" : ""}>${esc(o.name)}</option>`).join("")}</select></div>`;
const whenField = () => `<div class="sg-ww"><label>when</label><span class="sg-chips">${WHEN_CHIPS.map(c => `<a class="sg-chip${(whenSel() || WHEN_CHIPS[0].key) === c.key ? " on" : ""}" data-when="${c.key}">${c.label}</a>`).join("")}</span></div>`;
const said = () => note() ? `<div class="sg-msg">${esc(note())}</div>` : "";
/** TAKE: the held row R, partial or whole, with where and when you collect it. */
function takeCard(g, r) {
    const K = creditNow(), q = qty();
    const rem = num(r.remaining), p = num(r.snlt), cost = p > 0 ? q * p : null;
    const can = !busy() && q <= rem + 1e-9 && (cost == null || cost <= Number(K.drawable) + 1e-9);
    return `<div class="sg-card">
    ${stepper(g.unit, cost, "=")}${whereField()}${whenField()}
    <button class="sg-go" ${can ? "" : "disabled"}>${busy() ? "taking…" : "take"}</button>${said()}</div>`;
}
/** HAVE: what you hold of the good. The quantity edits in place (editing IS
 *  declaring) and the lend (app/lend.ts) composes right under it. */
const haveCard = (g) => !g.offer ? "" : `<div class="sg-card">
    <div class="sg-qty"><button class="sg-ostep" data-d="-1">−</button><span class="sg-q">${figure(num(g.offer.qty))} ${esc(unitOf(g))}</span><button class="sg-ostep" data-d="1">＋</button>
      <a class="sg-unoffer">remove</a></div>
    <div class="sg-lend"></div></div>`;
/** The card under a good's tile: the take when something waits, else ask ⇄ have. */
function inlineCard(g) {
    const r = openRow();
    if (r)
        return takeCard(g, r);
    const modeTabs = `<div class="sg-mode-tabs">
      <a class="sg-mode-tab${!offerMode() && !countMode() ? " on" : ""}" data-mode="want">want this</a>
      <a class="sg-mode-tab${offerMode() ? " on" : ""}" data-mode="offer">I have this</a>
      ${countTab(g.spec)}
    </div>`;
    // "count it": the good's stocks place by place, each counted through the capture sheet
    if (countMode())
        return `<div class="sg-card">${modeTabs}${heldCard(g.spec)}</div>`;
    if (offerMode())
        return g.offer ? modeTabs + haveCard(g)
            : `<div class="sg-card">${modeTabs}${stepper(g.unit, null, "")}<button class="sg-go">add to yours</button></div>`;
    const cost = g.snlt != null ? qty() * g.snlt : null;
    return `<div class="sg-card">${modeTabs}
    ${stepper(g.unit, cost, "≈")}${whereField()}${whenField()}
    <button class="sg-go" ${busy() ? "disabled" : ""}>${busy() ? "asking…" : "want this"}</button>${said()}</div>`;
}
/** The body of an open row of YOURS: every act that applies to what you hold. */
function yoursCard(g) {
    const r = openRow();
    return `<div class="sy-open">
    ${r ? takeCard(g, r) : ""}
    ${askd(g).length ? `<a class="sg-withdraw" data-spec="${esc(g.spec)}">never mind the ask</a>` : ""}
    ${g.offer ? haveCard(g) : `<a class="sg-have">I have some of this</a>`}
  </div>`;
}
function shortVerdict(g) {
    if (g.left <= 0 && g.kept > 0)
        return { cls: "st-kept", text: "all social" };
    if (g.left <= 0 && g.asked > 0)
        return { cls: "st-contested", text: "voice decides" };
    if (g.left <= 0)
        return { cls: "st-kept", text: "none individual" };
    if (g.asked > g.left + 1e-9)
        return { cls: "st-contested", text: "voice decides" };
    if (g.asked <= 0)
        return { cls: "st-ok", text: "unasked" };
    if (g.asked <= g.left * 0.5)
        return { cls: "st-plenty", text: "in plenty" };
    return { cls: "st-ok", text: "covered" };
}
/** A tile: the inventory's cell. The glyph, the name, the price, the thin
 *  bar, and a corner badge for what is yours. The whole
 *  tile is the tap; the full card opens across the row. */
function goodHtml(g) {
    const v = shortVerdict(g);
    const col = goodTint(g.term);
    const open = openId() === g.spec && openAt() === "goods";
    const h = held(g), a = askd(g), t = taken(g);
    const rem = h.reduce((x, r) => x + num(r.remaining), 0);
    const badge = h.length ? `<span class="sg-badge b-held">${figure(rem)} waiting</span>`
        : a.length ? `<span class="sg-badge b-asked">asked</span>`
            : t.length ? `<span class="sg-badge b-taken">✓</span>` : "";
    const max = Math.max(g.kept + g.left, g.kept + g.asked, 1e-9);
    const w = (q) => (100 * q / max).toFixed(1) + "%";
    return `<div class="sg ${v.cls}${open ? " open" : ""}${h.length ? " has-held" : ""}" data-spec="${esc(g.spec)}" style="--tint:${col}">
    <div class="sg-tile">
      ${badge}
      <div class="sg-emoji">${g.emoji || emojiFor(g.name, g.term)}</div>
      <div class="sg-name">${esc(g.name)}${g.external ? ` <span class="shop-ext">⇄</span>` : ""}${heldGlyphs(g.spec)}</div>
      <div class="sg-price">${g.snlt != null ? `${fmtH(g.snlt)} / ${esc(g.unit || "unit")}` : ""}</div>
      <div class="sg-bar"><div class="sg-kept" style="width:${w(g.kept)}"></div><div class="sg-left" style="width:${w(g.left)}"></div><div class="sg-ask" style="left:${w(g.kept)}; width:${w(g.asked)}"></div></div>
      <div class="sg-tri"><span class="n-kept" title="social: kept for production and the reserve">${figure(g.kept)}</span><span class="n-left" title="individual: shared out">${figure(g.left)}</span><span class="n-ask" title="asked">${figure(g.asked)}</span></div>
      <div class="sg-verdict ${v.cls}">${v.text}</div>
    </div>
    ${open ? `<div class="sg-pop">
      <div class="sg-pop-h"><span>${g.emoji || emojiFor(g.name, g.term)} <b>${esc(g.name)}</b> <small>${g.snlt != null ? `${fmtH(g.snlt)} / ${esc(g.unit || "unit")}` : ""}</small></span><a class="sg-close">×</a></div>
      <div class="sg-nums"><span class="n-kept">${figure(g.kept)} social</span><span class="n-left">${figure(g.left)} individual</span><span class="n-ask">${figure(g.asked)} asked</span>${g.offered > 0 ? `<span class="n-offer">${figure(g.offered)} offered</span>` : ""}</div>
      <div class="sg-mine${myLine(g) ? "" : " none"}"><div class="sg-mine-line">${myLine(g)}</div>${held(g).length > 1 || askd(g).length ? `<div class="sg-mine-act">${askd(g).length ? myButton(g) : ""}</div>` : ""}</div>
      ${inlineCard(g)}
    </div>` : ""}
  </div>`;
}
// every live mount of the stage — the full face's #shopstage, and any number
// of drawer panels (resourcesPanel) — redraws off the SAME data read, each
// from its own opts; a detached host prunes itself on the next tick rather
// than going stale forever
const stageHosts = new Map();
function redrawStages() {
    for (const [el, getOpts] of [...stageHosts])
        if (el.isConnected)
            drawStage(el, getOpts());
        else
            stageHosts.delete(el);
}
function drawStage(container, opts = {}) {
    const stage = container;
    if (!stage)
        return;
    const { list, communal } = goods();
    const chain = scopeChain();
    const bySpec = new Map();
    for (const g of list)
        bySpec.set(g.spec, g);
    // one sort: waiting for you, then your asks, then the rest by contention, taken last
    const rank = (g) => held(g).length ? 0 : askd(g).length ? 1 : taken(g).length ? 3 : 2;
    const shown = list.filter(g => inFocus(g.term) && matchesQuery({ name: g.name, term: g.term }) && F.passesPlaces(g.locs || []))
        .sort((x, y) => rank(x) - rank(y) || contention(y) - contention(x) || y.asked - x.asked);
    const crumb = chain.map((c, i) => `<a class="shop-crumb${i === chain.length - 1 ? " on" : ""}" data-scope="${esc(c.scope ?? "")}" data-root="${c.id === "earth" ? "1" : ""}">${esc(c.name)}</a>`).join(`<span class="shop-crumb-sep">›</span>`);
    const sub = (t) => opts.compact ? "" : `<span class="shop-sec-sub">${t}</span>`;
    const legend = `<div class="sg-legend">under each bar, in its order: <i class="l-kept"></i><b class="n-kept">social</b> <i class="l-left"></i><b class="n-left">individual</b> <i class="l-ask"></i><b class="n-ask">asked</b> · sorted: yours first, then the most contested</div>`;
    const empty = `<div class="shop-rows-empty">${focusId() || query().trim() ? "nothing here" : "the plan left nothing over — production fills the pool"}</div>`;
    // the drawer's own compact reading of the certificate — once worn small on
    // the express bar's lip, now the top of Resources instead: the number and
    // the bar alone, no explainer text (that stayed the lip's own tap-to-read)
    const creditStrip = () => {
        const K = creditNow();
        const cap = Number(K.capacity) || 0, pend = Number(K.pending) || 0;
        const tot = cap + pend || 1;
        const cw = (q) => (100 * Math.max(0, Math.min(q, tot)) / tot).toFixed(1) + "%";
        return `<div class="shop-res-cred">
      <div class="shop-res-cred-head">
        <span class="shop-res-cred-big">⬡ ${fmtH(Number(K.drawable))}</span>
        <span class="shop-res-cred-cap">to draw · ${fmtH(pend)} in the window · taken ${fmtH(Number(K.claimed))} of ${fmtH(cap)}
          · voice ${(Number(K.voice) * 100).toFixed(1)}% · free time ${(Number(K.freeTime) * 100).toFixed(0)}%</span>
      </div>
      <div class="shop-res-cred-bar"><i class="shop-res-cred-fill" style="width:${cw(Number(K.drawable))}"></i>${pend > 0 ? `<i class="shop-res-cred-pend" style="left:${cw(cap)}; width:${cw(pend)}"></i>` : ""}</div>
    </div>`;
    };
    // compact (the drawer): one flowing grid, held goods still sorted first —
    // and still their own colour (.sg.has-held) and badge — but never forced
    // onto a row of their own; the full face keeps its own two sections, the
    // held one set apart with its own heading and blurb
    // yours, above the goods: every good you hold something of — waiting, asked,
    // taken, had — each row opening in place on the acts that apply to it, and
    // the last one the door for a thing of yours the list has never seen
    const mine = list.filter(g => (g.mine.length || g.offer) && inFocus(g.term) && matchesQuery({ name: g.name, term: g.term }));
    const yoursOpen = (g) => openId() === g.spec && openAt() === "yours";
    const yoursBlock = `<div class="shop-sec shop-yours">
      <div class="shop-sec-head"><span class="shop-h">yours</span>${sub("what waits for you, what you asked and took, what you have — lend any of it from here")}</div>
      <div class="sy-list">${mine.map(g => `<div class="sy${yoursOpen(g) ? " open" : ""}" data-spec="${esc(g.spec)}">
        <div class="sy-head">
          <div class="sy-emoji">${g.emoji || emojiFor(g.name, g.term)}</div>
          <div class="sy-body"><div class="sy-name">${esc(g.name)}</div><div class="sy-line">${myLine(g)}</div></div>
          ${held(g).length && !yoursOpen(g) ? `<button class="sg-take sy-take" data-spec="${esc(g.spec)}" data-id="${esc(held(g)[0].id)}">take</button>` : ""}
        </div>
        ${yoursOpen(g) ? yoursCard(g) : ""}</div>`).join("")}
        <div class="sy sy-add"><input class="sy-add-in" placeholder="add something you have…"><button class="sy-add-go" title="add it to yours">＋</button></div>
      </div>
    </div>`;
    const goodsBlock = opts.compact
        ? `<div class="shop-sec">
        <div class="shop-sec-head"><span class="shop-h">the goods</span></div>
        <div class="sg-list">${shown.map(goodHtml).join("") || empty}</div>
      </div>`
        : `      <div class="shop-sec">
        <div class="shop-sec-head"><span class="shop-h">the goods</span>
          ${sub("the individual portion, by the hours each good cost. One part of the product is social, another individual. The scope's reading beside yours; say what you want, and the next plan answers")}</div>
        ${legend}
        <div class="sg-list">${shown.map(goodHtml).join("") || empty}</div>
      </div>`;
    // the drawer shows one good at a time: opened, it is a page of its own (hero, the scope's reading, yours,
    // then the act that applies) in place of the lists, with a way back — the lists return when it is shut
    const pageOf = (g) => {
        const v = shortVerdict(g);
        return `<div class="shop-one rs-detail">
      <a class="sg-close rs-back">← resources</a>
      <div class="rs-hero" style="--tint:${goodTint(g.term)}">
        <div class="rs-emoji">${g.emoji || emojiFor(g.name, g.term)}</div>
        <div class="rs-hero-text"><div class="rs-name">${esc(g.name)}${g.external ? ` <span class="shop-ext">⇄</span>` : ""}</div>
          <div class="rs-sub">${g.snlt != null ? `${fmtH(g.snlt)} / ${esc(g.unit || "unit")}` : "&nbsp;"}</div></div>
        <span class="rs-verdict ${v.cls}">${v.text}</span>
      </div>
      <div class="rs-nums">
        <div class="rs-num"><b class="n-kept">${figure(g.kept)}</b><span>social</span></div>
        <div class="rs-num"><b class="n-left">${figure(g.left)}</b><span>individual</span></div>
        <div class="rs-num"><b class="n-ask">${figure(g.asked)}</b><span>asked</span></div>
        ${g.offered > 0 ? `<div class="rs-num"><b class="n-offer">${figure(g.offered)}</b><span>offered</span></div>` : ""}
      </div>
      ${myLine(g) ? `<div class="rs-mine"><div class="sg-mine-line">${myLine(g)}</div>${held(g).length > 1 || askd(g).length ? `<div class="sg-mine-act">${askd(g).length ? myButton(g) : ""}</div>` : ""}</div>` : ""}
      <div class="rs-act">${inlineCard(g)}${askd(g).length ? `<a class="sg-withdraw" data-spec="${esc(g.spec)}">never mind the ask</a>` : ""}</div>
    </div>`;
    };
    const openG = opts.compact && openId() ? bySpec.get(openId()) : null;
    stage.innerHTML = openG ? pageOf(openG) : `<div class="shop-one">
    ${opts.compact ? "" : `<div class="sh-top">
      <div class="sh-row1">
        <div class="shop-crumbs">${crumb}</div>
      </div>
    </div>`}

    ${opts.compact ? creditStrip() : ""}
    ${yoursBlock}
    ${opts.compact ? legend : ""}
    ${goodsBlock}

    ${(() => {
        const cells = `
        ${[["🍲", "meals", "everyone's, every day, from what the scope grows"], ["🛏", "a place to sleep", "a berth every night"]]
            .filter(([, n]) => matchesQuery({ name: n }))
            .map(([e2, n, how]) => `<div class="shop-free-card by-need"><div class="sic-emoji">${e2}</div><div class="sic-name">${n}</div><div class="shop-free-how">${how}</div><div class="shop-free-tag">by need</div></div>`).join("")}
        ${communal.filter(c => inFocus(c.term) && matchesQuery(c)).map(c => `<div class="shop-free-card in-common"><div class="sic-emoji">${c.emoji || emojiFor(c.name, c.term)}</div><div class="sic-name">${esc(c.name)}</div><div class="shop-free-how">open to all — go</div><div class="shop-free-tag">in common</div></div>`).join("")}
        ${query().trim() ? "" : `<div class="shop-free-card in-plenty empty"><div class="sic-emoji">🌾</div><div class="sic-name">in plenty</div><div class="shop-free-how">a good with more than anyone asks is free — none this season</div><div class="shop-free-tag">in plenty</div></div>`}`;
        return cells.trim() ? `<div class="shop-sec">
      <div class="shop-sec-head"><span class="shop-h">free to everyone</span>${sub("met before anything is shared out — no hours, no asking")}</div>
      <div class="shop-free-grid strip">${cells}
      </div>
    </div>` : "";
    })()}
    ${opts.compact ? "" : `<div class="shop-sec"><div class="shop-sec-head"><span class="shop-h">to use</span><span class="shop-sec-sub">the oven, the workshop, the field — the commons' means, through the rota, never claimed · see the calendar</span></div></div>
    <div class="shop-send" id="shopsend"></div>`}
    <div class="shop-foot">a claim is an internal transfer, never a sale · what you take is yours; what you use stays the commons' · nobody's name travels above their own commune</div>
  </div>`;
    // wiring
    stage.querySelectorAll(".shop-crumb").forEach(a => a.addEventListener("click", () => goToScope(a.dataset.root ? null : (a.dataset.scope || null))));
    // a good's card opens on what you hold of it: the take when something waits,
    // the have when that is all you hold here, else the ask
    const openGood = (g, at) => {
        const r = held(g)[0] || null;
        qty.set(takeStart(r));
        note.set("");
        whereSel.set(r?.place || "");
        whenSel.set(null);
        openRow.set(r);
        openAt.set(at);
        openId.set(g.spec);
        offerMode.set(!!g.offer && !g.mine.length);
        countMode.set(false);
    };
    const shut = () => { openId.set(null); openRow.set(null); offerMode.set(false); countMode.set(false); };
    stage.querySelectorAll(".sg-tile").forEach(tile => tile.addEventListener("click", () => {
        const el = tile.parentElement;
        const g = bySpec.get(el.dataset.spec || "");
        if (!g)
            return;
        if (openId() === g.spec && openAt() === "goods")
            shut();
        else
            openGood(g, "goods");
    }));
    // a row of YOURS opens in place
    stage.querySelectorAll(".sy-head").forEach(head => head.addEventListener("click", () => {
        const g = bySpec.get(head.parentElement.dataset.spec || "");
        if (!g)
            return;
        if (openId() === g.spec && openAt() === "yours")
            shut();
        else
            openGood(g, "yours");
    }));
    stage.querySelectorAll(".sy-open").forEach(b => b.addEventListener("click", ev => ev.stopPropagation()));
    // a thing of yours, named: it joins YOURS as a declared means, open on its lend
    const addIn = stage.querySelector(".sy-add-in");
    const addMine = () => {
        const name = (addIn?.value || "").trim();
        if (!name)
            return;
        const g = list.find(x => x.name.toLowerCase() === name.toLowerCase());
        const spec = g ? g.spec : specOf(name);
        if (!(g && g.offer))
            declare("capacity", { id: `cap:me:${spec}`, spec, name: g ? g.name : name, emoji: g?.emoji || emojiFor(name),
                qty: 1, unit: g?.unit || "each", where: "", arcs: [], note: "" });
        qty.set(1);
        note.set("");
        openRow.set(null);
        offerMode.set(false);
        countMode.set(false);
        openAt.set("yours");
        openId.set(spec);
    };
    addIn?.addEventListener("keydown", ev => { if (ev.key === "Enter")
        addMine(); });
    stage.querySelector(".sy-add-go")?.addEventListener("click", addMine);
    stage.querySelector(".sg-have")?.addEventListener("click", () => {
        const g = bySpec.get(openId() || "");
        if (g)
            doOffer(g, 1);
    });
    stage.querySelectorAll(".sg-want").forEach(b => b.addEventListener("click", ev => {
        ev.stopPropagation();
        const g = bySpec.get(b.dataset.spec || "");
        if (!g)
            return;
        openRow.set(null);
        openAt.set("goods");
        openId.set(g.spec);
        offerMode.set(false);
        countMode.set(false);
    }));
    stage.querySelectorAll(".sg-take").forEach(b => b.addEventListener("click", ev => {
        ev.stopPropagation();
        const g = bySpec.get(b.dataset.spec || "");
        if (g)
            openGood(g, b.closest(".sy") ? "yours" : "goods");
    }));
    stage.querySelectorAll(".sg-withdraw").forEach(a => a.addEventListener("click", () => {
        const spec = a.dataset.spec || "";
        retire("need", { spec });
    }));
    stage.querySelectorAll(".sg-close").forEach(a => a.addEventListener("click", () => { openId.set(null); openRow.set(null); offerMode.set(false); countMode.set(false); }));
    stage.querySelectorAll(".sg-mode-tab").forEach(a => a.addEventListener("click", ev => {
        ev.stopPropagation();
        offerMode.set(a.dataset.mode === "offer");
        countMode.set(a.dataset.mode === "count");
        note.set("");
    }));
    wireHeld(stage);
    // the open good's offer: its quantity re-declares on every step, withdraw
    // retires it, and the lend control mounts over the same slot
    const og = bySpec.get(openId() || "");
    if (og && og.offer) {
        const offer = og.offer;
        stage.querySelectorAll(".sg-ostep").forEach(b => b.addEventListener("click", () => declare("capacity", { ...offer, qty: Math.max(1, num(offer.qty) + Number(b.dataset.d)) })));
        stage.querySelector(".sg-unoffer")?.addEventListener("click", () => retire("capacity", offer));
        stage.querySelector(".sg-lend")?.append(lendControl({ spec: offer.spec, name: offer.name || og.name, unit: offer.unit, qty: num(offer.qty) || 1 }));
    }
    const pop = stage.querySelector(".sg-pop");
    if (pop) {
        const host = pop.parentElement, sr = stage.getBoundingClientRect(), hr = host.getBoundingClientRect();
        if (hr.left + 352 > sr.right)
            pop.classList.add("flip");
        pop.addEventListener("click", ev => ev.stopPropagation());
    }
    stage.querySelectorAll(".sg-step").forEach(b => b.addEventListener("click", () => {
        const r = openRow(), hi = r ? num(r.remaining) : Infinity;
        qty.set(Math.min(hi, Math.max(takeStart(r), qty() + Number(b.dataset.d))));
    }));
    stage.querySelectorAll(".sg-chip").forEach(c => c.addEventListener("click", () => whenSel.set(c.dataset.when ?? null)));
    const sel2 = stage.querySelector(".sg-where");
    if (sel2)
        sel2.addEventListener("change", () => whereSel.set(sel2.value));
    const go = stage.querySelector(".sg-go");
    if (go)
        go.addEventListener("click", () => {
            const g = bySpec.get(openId() || "");
            if (!g)
                return;
            const r = openRow();
            if (!r && offerMode()) {
                doOffer(g, qty());
                return;
            }
            const chip = WHEN_CHIPS.find(c => c.key === (whenSel() || WHEN_CHIPS[0].key)) || WHEN_CHIPS[0];
            const entry = { id: g.spec, name: g.name, emoji: g.emoji, unit: g.unit, snlt: g.snlt, onhand: g.left, rids: g.rids, term: g.term };
            if (r)
                doTake(r, qty(), sel2 ? sel2.value : "", chipIso(chip));
            else
                doWant(entry, qty(), sel2 ? sel2.value : "", chipIso(chip));
        });
    drawSend(); // the send/buy block mounts inside the full stage only (#shopsend is absent when compact)
}
// ── the drawer's own mount: the shop's goods, inside the drawer ────────────
let resRefreshedAt = 0;
/** The drawer's Resources view — a second, compact mount of the same data
 *  drawStage already reads for the full face, never a copy of it. Every
 *  card already carries its own status (in common / by need / in plenty,
 *  voice decides / covered / …), so this adds no second filter on top. */
export function resourcesPanel() {
    ensureWired();
    if (Date.now() - resRefreshedAt > 5000) { // throttled like standing.ts's own record refresh
        resRefreshedAt = Date.now();
        fetchPayouts();
        fetchRows();
        refreshSocial();
        bump.update(n => n + 1);
    }
    const el = mk("div", "shop-res");
    const stageEl = mk("div", "shop-res-stage");
    el.append(stageEl);
    stageHosts.set(stageEl, () => ({ compact: true }));
    drawStage(stageEl, { compact: true });
    return el;
}
// ── the panel: a short standing note; the actions live inline in the stage ──
function drawPanel() {
    const panel = document.getElementById("shoppanel");
    if (!panel)
        return;
    panel.innerHTML = `<h3>shop</h3><div class="railnote">what you can get, and how — every good with the scope's reading (social · individual · asked) beside yours (waiting · asked · take). Walk the crumb to read another scope. Needs are met before any of it, free.</div>`;
}
/** ASK: a demand row for the good — the plan answers on its next solve. */
function doWant(e, q, where, when) {
    declare("need", { id: `need:me:${e.id}`, spec: e.id, name: e.name, emoji: e.emoji || "", qty: q, unit: e.unit || "each",
        where: where || "", arcs: [], note: "", from: when });
    note.set("");
    openId.set(null);
}
/** TAKE: confirm the plan's row — the ledger records the transfer against it. */
function doTake(r, q, where, when) {
    if (busy())
        return;
    const entry = orderBook().claim.find(x => x.id === r.spec);
    const rid = entry?.rids && entry.rids[0];
    if (HANDLERS.claim && rid && !orderBook().demo) {
        busy.set(true);
        note.set("taking…");
        HANDLERS.claim(rid, q, where || "", when || "", reply => {
            busy.set(false);
            if (typeof reply === "string" && reply.startsWith("err:")) {
                note.set(reply.slice(4));
                return;
            }
            let j = {};
            try {
                j = JSON.parse(String(reply));
            }
            catch (_) { /* keep the empty reply */ }
            note.set(`taken — ${fmtH(num(j.claimed))} drawn, ${fmtH(num(j.balance))} left`);
            openId.set(null);
            openRow.set(null);
            fetchRows();
        });
    }
    else {
        const p = num(r.snlt), cost = p * q;
        DEMO_CREDIT.claimed = Number(DEMO_CREDIT.claimed) + cost;
        DEMO_CREDIT.drawable = Math.max(0, Number(DEMO_CREDIT.drawable) - cost);
        const rem = Math.max(0, num(r.remaining) - q), done = num(r.fulfilled) + q;
        DEMO.rows = DEMO.rows.map(x => x.id === r.id
            ? { ...x, remaining: String(rem), fulfilled: String(done), state: rem <= 1e-9 ? "taken" : "held" } : x);
        const res = DEMO.resources.find(x => (entry?.rids || []).includes(x.id));
        if (res)
            res.onhand = Math.max(0, res.onhand - q);
        note.set(`taken — ${fmtH(cost)} drawn`);
        openId.set(null);
        openRow.set(null);
        bump.update(n => n + 1);
    }
}
const payouts = signal(null);
const sendNote = signal("");
let sendDraft = { address: "", xmr: "", note: "" };
let buyDraft = { what: "", qty: "1", unit: "each", cost: "", receipt: "", donation: false };
const buyOpen = signal(false);
function fetchPayouts() {
    if (!HANDLERS.myPayouts || !scopeSig()) {
        payouts.set(null);
        return;
    }
    HANDLERS.myPayouts().then(r => {
        const j = readJson(r);
        payouts.set(j && isFinite(Number(j.available)) ? j : null);
    });
}
const debtLabel = (d) => {
    const rem = Number(d.remaining), amt = Number(d.amount);
    const paid = rem < amt - 1e-9 ? ` — ${(amt - rem).toFixed(4)} already paid` : "";
    return `owed — payable as a payout${d.due ? ` · due ${d.due}` : ""}${paid}`;
};
const stateLabel = (s) => s === "pending" ? "waiting for the next run" :
    s === "sending" ? "on its way" :
        s.startsWith("sent:") ? `sent · tx ${s.slice(5, 15)}…` :
            s.startsWith("failed:") ? `not sent — ${s.slice(7)}` :
                s.startsWith("unsettled:") ? "being checked by hand — the commons lost sight of it mid-transfer; your claim stays reserved" : s;
function drawSend() {
    const book = payouts();
    sendNote();
    buyOpen();
    const owed = book?.owed || [];
    const box = document.getElementById("shopsend");
    if (!box)
        return;
    if (!book) {
        box.innerHTML = "";
        box.classList.remove("on");
        return;
    }
    box.classList.add("on");
    const avail = Number(book.available) || 0;
    const list = (book.payouts || []).slice().reverse().map(p => `
      <div class="shop-send-row ${p.state.startsWith("failed") ? "bad" : p.state.startsWith("sent") ? "done" : ""}">
        <b>${Number(p.xmr)} XMR</b> → <code title="${esc(p.address)}">${esc(p.address.slice(0, 8))}…${esc(p.address.slice(-6))}</code>
        <span class="shop-send-st">${esc(stateLabel(p.state))}${p.note ? " · " + esc(p.note) : ""}</span>
        ${p.state === "pending" ? `<a class="shop-send-x" data-id="${esc(p.id)}">cancel</a>` : ""}
      </div>`).join("");
    box.innerHTML = `
      <div class="shop-send-head">
        <span class="shop-send-big">${avail.toFixed(4)} XMR</span>
        <span class="shop-send-cap">yours to send — a claim on the commons' wallet; it sends, you never hold a key</span>
      </div>
      <div class="shop-send-form">
        <input id="sendaddr" placeholder="Monero address (4… or 8…)" spellcheck="false" autocomplete="off" value="${esc(sendDraft.address)}">
        <input id="sendxmr" type="number" min="0" step="0.0001" placeholder="XMR" value="${esc(sendDraft.xmr)}">
        <input id="sendnote" placeholder="note (yours)" value="${esc(sendDraft.note)}">
        <button id="sendgo" ${avail <= 0 ? "disabled" : ""}>send from the commons</button>
      </div>
      ${sendNote() ? `<div class="shop-send-note">${esc(sendNote())}</div>` : ""}
      ${list ? `<div class="shop-send-list">${list}</div>` : ""}
      <div class="shop-buy">
        <a class="shop-buy-toggle">${buyOpen() ? "▾" : "▸"} I bought something for the commons</a>
        ${buyOpen() ? `
        <div class="shop-send-form">
          <input id="buywhat" placeholder="what (e.g. flour)" value="${esc(buyDraft.what)}">
          <input id="buyqty" type="number" min="0" step="any" placeholder="qty" value="${esc(buyDraft.qty)}">
          <input id="buyunit" placeholder="unit" value="${esc(buyDraft.unit)}">
          <input id="buycost" type="number" min="0" step="0.01" placeholder="€ paid" value="${esc(buyDraft.cost)}">
          <input id="buyrcpt" placeholder="receipt ref" value="${esc(buyDraft.receipt)}">
          <label class="shop-buy-gift"><input id="buygift" type="checkbox" ${buyDraft.donation ? "checked" : ""}> a gift — owe me nothing</label>
          <button id="buygo">record it</button>
        </div>
        <div class="shop-send-cap">The thing becomes the commons' now. What you paid is owed to you — at once if the plan had asked for it, after the commune accepts if not — and comes back as a payout.</div>` : ""}
        ${owed.length ? `<div class="shop-send-list">${owed.slice().reverse().map(k => `
          <div class="shop-send-row">
            <b>${Number(k.remaining)} ${esc(k.unit)}</b> <span class="shop-send-st">${esc(debtLabel(k))}</span>
          </div>`).join("")}</div>` : ""}
      </div>`;
    const addr = box.querySelector("#sendaddr");
    const xmr = box.querySelector("#sendxmr");
    const noteIn = box.querySelector("#sendnote");
    const keep = () => { sendDraft = { address: addr.value, xmr: xmr.value, note: noteIn.value }; };
    [addr, xmr, noteIn].forEach(i => i.addEventListener("input", keep));
    box.querySelector("#sendgo").addEventListener("click", () => {
        keep();
        const amt = parseFloat(sendDraft.xmr);
        if (!(amt > 0)) {
            sendNote.set("how much?");
            return;
        }
        if (amt > avail) {
            sendNote.set(`you hold ${avail.toFixed(4)} XMR claimable`);
            return;
        }
        sendNote.set("asking…");
        HANDLERS.requestPayout(sendDraft.address.trim(), amt, "", sendDraft.note.trim()).then(r => {
            if (r === "ok") {
                sendDraft = { address: "", xmr: "", note: "" };
                sendNote.set("queued — the commons sends it on its next run");
            }
            else
                sendNote.set(String(r).replace(/^err:/, ""));
            fetchPayouts();
        });
    });
    box.querySelector(".shop-buy-toggle").addEventListener("click", () => buyOpen.update(v => !v));
    const bgo = box.querySelector("#buygo");
    if (bgo) {
        const g = (id) => box.querySelector("#" + id);
        const keepBuy = () => {
            buyDraft = { what: g("buywhat").value, qty: g("buyqty").value, unit: g("buyunit").value,
                cost: g("buycost").value, receipt: g("buyrcpt").value, donation: g("buygift").checked };
        };
        ["buywhat", "buyqty", "buyunit", "buycost", "buyrcpt", "buygift"].forEach(id => g(id).addEventListener("input", keepBuy));
        bgo.addEventListener("click", () => {
            keepBuy();
            const what = buyDraft.what.trim();
            const cost = parseFloat(buyDraft.cost);
            if (!what) {
                sendNote.set("what did you buy?");
                return;
            }
            if (!buyDraft.donation && !(cost > 0)) {
                sendNote.set("what did it cost?");
                return;
            }
            sendNote.set("recording…");
            const wasDonation = buyDraft.donation;
            const spec = specOf(what), q = parseFloat(buyDraft.qty) || 1;
            const ref = buyDraft.receipt.trim() || String(Date.now());
            HANDLERS.recordPurchase(spec, q, buyDraft.unit.trim() || "each", "spec-eur", wasDonation ? 0 : cost, "", what, buyDraft.receipt.trim(), wasDonation)
                .then(r => {
                if (String(r).startsWith("err:")) {
                    sendNote.set(String(r).slice(4));
                    return;
                }
                const trig = r === "ok" ? "" : String(r);
                buyDraft = { what: "", qty: "1", unit: "each", cost: "", receipt: "", donation: false };
                if (wasDonation || !HANDLERS.purchaseClaim || !scopeSig()) {
                    sendNote.set(wasDonation ? "recorded — thank you" : "recorded — it is in the commons' book");
                    fetchPayouts();
                    return;
                }
                sendNote.set("signing your claim…");
                HANDLERS.purchaseClaim(scopeSig(), "spec-eur", cost, "EUR", "", "", ref, trig)
                    .then(cr => {
                    sendNote.set(String(cr).startsWith("err:")
                        ? `recorded, but the claim failed to sign — ${String(cr).slice(4)}`
                        : "recorded and claimed — awaiting the commune's acceptance");
                    fetchPayouts();
                });
            });
        });
    }
    box.querySelectorAll(".shop-send-x").forEach(a => a.addEventListener("click", () => {
        HANDLERS.retirePayout(a.dataset.id || "").then(r => {
            sendNote.set(r === "ok" ? "" : String(r).replace(/^err:/, ""));
            fetchPayouts();
        });
    }));
}
// ── wiring ─────────────────────────────────────────────────────────────────
let wired = false;
function ensureWired() {
    if (wired)
        return;
    wired = true;
    const stage = document.getElementById("shopstage");
    if (stage)
        stageHosts.set(stage, () => ({})); // the full face: host #1, no opts
    on("inventory", () => { bump.update(n => n + 1); fetchPayouts(); fetchRows(); });
    on("credit", () => { bump.update(n => n + 1); fetchPayouts(); fetchRows(); });
    on("plan", () => { fetchRows(); refreshSocial(); }); // a landed solve re-answers every want
    on("slotsChanged", () => { fetchRows(); refreshSocial(); });
    // your own declarations move the book: an ask or a withdrawal lands as a slot change
    effect(() => { myNeeds(); fetchRows(); });
    effect(() => {
        bump();
        rows();
        scopeSig();
        focusId();
        query();
        openId();
        openRow();
        qty();
        note();
        busy();
        whereSel();
        whenSel();
        offerMode();
        countMode();
        openAt();
        redrawStages();
    });
    effect(drawPanel);
    // a click anywhere else puts the open item away
    document.addEventListener("click", ev => {
        if (!openId())
            return;
        // the tile that was tapped may already be detached by the re-render — a
        // click inside ANY tile or popover is the face's own, never "outside"
        const t = ev.target;
        if (t && t.closest(".sg, .sg-pop, .sy"))
            return;
        openId.set(null);
        openRow.set(null);
        offerMode.set(false);
        countMode.set(false);
    });
    effect(() => { payouts(); sendNote(); buyOpen(); drawSend(); });
}
export function initShop() {
    ensureWired();
    fetchPayouts();
    fetchRows();
    bump.update(n => n + 1);
}
/** OFFER: declare a standing capacity for the good — the ownership half. The
 *  card stays on the offer, where the lend (app/lend.ts) composes next. */
function doOffer(g, q) {
    declare("capacity", { id: `cap:me:${g.spec}`, spec: g.spec, name: g.name, emoji: g.emoji || "🤲",
        qty: q, unit: g.unit || "each", where: "", arcs: [], note: "" });
}
