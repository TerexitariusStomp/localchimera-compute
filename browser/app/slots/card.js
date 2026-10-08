// app/slots/card.ts — one slot, one card, everything inline.
//
// The free-association slotCard grammar (ResourceSlots.svelte): the top row
// IS the form — [emoji][name][qty][unit] as bordered inline inputs — followed
// on the SAME row by the compact buttons, each one rendering its own current
// value as its label (🕐 weekdays 09:00–17:00 · 📍 the courtyard · 💬 · ✎ ·
// 🤲 · 🗑️): you read the state and tap the same pixel to change it; the
// tapped one opens its editor section under the row, one at a time; delete is
// two taps, no modal; a fill indicator behind the whole card makes fulfilment
// felt, not read.
import { fmtArcs, fmtWhere, humanDate } from './model.js';
import { goToMapPlace, goToCalendarTime, hereOfSlot } from '../gohere.js';
import { inlineText, arcsEditor, whereEditor, armTwice } from './editors.js';
import { divisibilityEditor, ruleEditor, priorityEditor, fmtDivisibility, fmtRule, fmtPriority, tensionEditor, fmtTension } from './criteria.js';
import { mk as el } from '../dom.js';
import { figure } from '../count.js';
// which section each card has open, by rail + slot — see the accordion below
const openSections = new Map();
// ── the same card, READ-ONLY ────────────────────────────────────────────────
// Someone else's slot, or your own seen from a face that doesn't edit it: the
// ring's hover tooltip, its pool list and its match list all show a slot, and
// they show it in the ONE grammar the share bar taught — emoji · name · qty ·
// unit over the 🕐/📍/✎ summaries. Same classes, so a slot reads the same
// everywhere and a card restyle lands everywhere at once; the sections are
// plain text here because nothing on this card is editable.
//
// slot: the wire object. cfg: { kind, locs, who (a line under the head —
// "ana offers", "you ask"), tint (the term colour the ring gave it), chips
// (nodes appended under the summaries — badges, dimension scores), onClick }.
export function slotFace(slot, cfg = {}) {
    const card = el("div", `slot-card slot-${cfg.kind || "need"} slot-ro`);
    card.dataset.spec = slot.spec || "";
    if (cfg.tint)
        card.style.borderLeft = `3px solid ${cfg.tint}`;
    if (cfg.onClick) {
        card.classList.add("slot-tap");
        card.addEventListener("click", cfg.onClick);
    }
    const head = el("div", "slot-head");
    head.append(el("span", "slot-emoji", slot.emoji || (cfg.kind === "need" ? "▪" : "●")), el("span", "slot-name", slot.name || slot.spec || "—"), el("span", "slot-qty-ro", fmtQty(slot)), el("span", "slot-unit", slot.unit || ""));
    card.appendChild(head);
    if (cfg.who)
        card.appendChild(el("div", "slot-who", cfg.who));
    const sums = el("div", "slot-sums");
    // the 🕐 and 📍 summaries are the card's two navigation gestures: a time
    // opens the calendar at the slot's next occurrence, a place opens the map
    // there at that time — the same three-way door every event surface uses
    const sum = (icon, text, go) => {
        if (!text)
            return;
        const s = el("span", "slot-sum slot-sum-ro", `${icon} ${text}`);
        if (go) {
            s.classList.add("slot-sum-go");
            s.addEventListener("click", e => { e.stopPropagation(); go(); });
        }
        sums.appendChild(s);
    };
    sum("🕐", fmtArcs(slot.arcs), () => goToCalendarTime(hereOfSlot(slot, cfg.locs)));
    sum("📍", slot.where ? fmtWhere(slot.where, cfg.locs) : "", () => goToMapPlace(hereOfSlot(slot, cfg.locs)));
    sum("✎", slot.note || "");
    if (sums.childElementCount)
        card.appendChild(sums);
    if (cfg.chips && cfg.chips.length) {
        const row = el("div", "slot-chips");
        cfg.chips.forEach(c => row.appendChild(c));
        card.appendChild(row);
    }
    return card;
}
const fmtQty = (slot) => {
    const q = Number(slot.qty);
    return isFinite(q) && q > 0 ? figure(q) : "";
};
// slot: the wire object. cfg: { kind: "need"|"capacity", locs, here (the place
// id a shared position resolved to, or null), fill (0..1|null),
// onChange(patch), onDelete(), lend (a capacity's lend-into-the-commons
// control — app/lend.ts; absent for needs) }. Returns the card element;
// the caller re-renders the list on data change (the slot is server-truth).
export function slotCard(slot, cfg) {
    const card = el("div", `slot-card slot-${cfg.kind}`);
    card.dataset.spec = slot.spec || ""; // the map's tap-through finds its card by spec
    // the fill indicator, in two washes: communal provision first, then what
    // credit could cover — the same left-to-right order the commons prefers
    const pct = (f) => `${Math.min(100, Math.max(0, f * 100)).toFixed(0)}%`;
    if (cfg.met) {
        const c = el("div", "slot-fill");
        c.style.width = pct(cfg.met.communal.frac);
        const k = el("div", "slot-fill slot-fill-credit");
        k.style.left = pct(cfg.met.communal.frac);
        k.style.width = pct(cfg.met.credit.frac);
        card.append(c, k);
    }
    else if (cfg.fill != null) {
        const bar = el("div", "slot-fill");
        bar.style.width = pct(cfg.fill);
        card.appendChild(bar);
    }
    // ── the main row IS the form ─────────────────────────────────────────
    const main = el("div", "slot-main");
    const emoji = inlineText(slot.emoji || "", {
        placeholder: "🙂", cls: "slot-emoji",
        onCommit: v => cfg.onChange({ emoji: v }),
    });
    const name = inlineText(slot.name || "", {
        placeholder: cfg.kind === "need" ? "what do you need?" : "what do you offer?",
        cls: "slot-name",
        onCommit: v => cfg.onChange({ name: v }),
    });
    // an offer at zero is no offer — the server drops it from my-slots — so the
    // input floors at one and the trash stays the one way to withdraw it
    const qty = el("input", "slot-qty");
    qty.type = "number";
    qty.min = String(cfg.kind === "capacity" ? 1 : 0);
    qty.step = "1";
    qty.value = String(slot.qty);
    qty.addEventListener("change", () => {
        const n = Math.max(+qty.min, Number(qty.value) || 0);
        qty.value = String(n);
        cfg.onChange({ qty: n });
    });
    qty.addEventListener("keydown", ev => { if (ev.key === "Enter")
        qty.blur(); });
    const unit = inlineText(slot.unit || "", {
        placeholder: "unit", cls: "slot-unit",
        onCommit: v => cfg.onChange({ unit: v }),
    });
    main.append(emoji, name, qty, unit);
    // ── the compact buttons, each its own summary; one editor open at a time ──
    // The open section OUTLIVES the card. Editing is declaring, so every day
    // pill and every stepper tap re-declares, the slot list refreshes, and this
    // card is rebuilt from server truth — while the hand that tapped is still on
    // the editor. `openSections` (module scope, keyed by rail + slot) carries
    // which one was open across that rebuild, so a rhythm can be composed pill
    // by pill instead of collapsing after each one.
    const okey = `${cfg.kind}:${slot.id || slot.spec}`;
    const body = el("div", "slot-body");
    const builders = new Map();
    let open = openSections.get(okey) || null;
    const show = (key) => {
        open = key;
        if (key)
            openSections.set(okey, key);
        else
            openSections.delete(okey);
        body.replaceChildren();
        body.className = "slot-body";
        main.querySelectorAll(".slot-btn").forEach(b => b.classList.remove("on"));
        const s = key && builders.get(key);
        if (s) {
            s.btn.classList.add("on");
            body.classList.add(s.cls || "editor-section");
            body.appendChild(s.build());
        }
        card.classList.toggle("expanded", !!s);
    };
    const section = (key, icon, summaryText, build, cls, btn_) => {
        const btn = el("button", "slot-btn" + (btn_?.cls ? " " + btn_.cls : ""), summaryText ? `${icon} ${summaryText}` : icon);
        btn.type = "button";
        if (btn_?.title)
            btn.title = btn_.title;
        builders.set(key, { btn, build, cls });
        btn.addEventListener("click", () => show(open === key ? null : key));
        main.appendChild(btn);
    };
    // the matcher-only sidecar: ⚙️ divisibility and 🔒 eligibility, both a
    // patch of the slot's criteria — merged here so the card sends the whole
    // object, absent fields dropped (an empty sidecar declares as none)
    const crit = (patch) => {
        const next = { ...(slot.criteria || {}), ...patch };
        for (const k of Object.keys(next))
            if (next[k] === undefined || next[k] === null || next[k] === "")
                delete next[k];
        cfg.onChange({ criteria: Object.keys(next).length ? next : null });
    };
    section("when", "🕐", fmtArcs(slot.arcs), () => arcsEditor(slot.arcs, { onCommit: arcs => cfg.onChange({ arcs }) }));
    const link = slot.criteria && slot.criteria["online-link"];
    section("where", "📍", (link ? "🌐 " : "") + fmtWhere(slot.where, cfg.locs), () => whereEditor(slot.where, cfg.locs, { here: cfg.here, onCommit: where => cfg.onChange({ where }),
        online: link || null,
        onOnline: l => crit({ "online-link": l || undefined }),
        onNewPlace: cfg.onNewPlace }));
    // 💬 opens the conversation about this slot — the chat sheet, keyed by the
    // slot's id, the same door every event uses (app/tabs/chat.ts showChat)
    if (cfg.onChat) {
        const chat = el("button", "slot-btn slot-btn-chat", "💬");
        chat.type = "button";
        chat.title = `chat about ${slot.name || "this"}`;
        if (cfg.unread) {
            chat.appendChild(el("span", "slot-unread", String(cfg.unread)));
            chat.title += ` — ${cfg.unread} unread`;
        }
        chat.addEventListener("click", cfg.onChat);
        main.appendChild(chat);
    }
    section("note", "✎", slot.note ? slot.note.slice(0, 28) : "", () => inlineText(slot.note || "", {
        placeholder: "a word for the humans who provision this…",
        cls: "slot-notein",
        onCommit: v => cfg.onChange({ note: v }),
    }));
    section("div", "⚙️", fmtDivisibility(slot.criteria), () => divisibilityEditor(slot.criteria, crit));
    section("rule", "🔒", fmtRule(slot.criteria && slot.criteria["filter-rule"]), () => ruleEditor(slot.criteria, crit));
    if (slot.criteria && slot.criteria["filter-rule"] !== undefined && slot.criteria["filter-rule"] !== true)
        builders.get("rule").btn.classList.add("locked");
    // ⚖️ on a need only: a right, a need or a want, and its attached voice —
    // what the solve may sacrifice and in what order when the commons is short
    if (cfg.kind === "need" && cfg.onChange)
        section("tension", "⚖️", fmtTension(slot.tension, slot.voice), () => tensionEditor(slot.tension, slot.voice, patch => cfg.onChange(patch), cfg.displacementOf, cfg.gate, cfg.handShare));
    // ⭐ on a capacity only, as theirs: who it serves first
    if (cfg.kind === "capacity")
        section("prio", "⭐", fmtPriority(slot.criteria), () => priorityEditor(slot.criteria, crit));
    // a capacity carries a fourth section: lend it into the commons. Declaring
    // the offer is the first half of socialization (you own it, this much); the
    // grant is the second (for this long), and it belongs on the same card.
    if (cfg.lend) {
        const g = cfg.lend.grant, build = cfg.lend.build;
        if (g)
            card.classList.add("slot-lent");
        section("lend", "🤲", g ? `lent · ${g.until ? (humanDate(g.until) || g.until) : "open-ended"}`
            : "", build, "lend-section");
    }
    // how it's met — their allocation badge, read as the three tiers of a
    // standing order: the plan's provision, the credit fallback, the gap
    if (cfg.met && cfg.met.any) {
        const m = cfg.met;
        const tiers = (m.communal.qty > 0 ? 1 : 0) + (m.credit.sources.length ? 1 : 0);
        section("met", String(tiers), "", () => metSection(m, cfg), "met-section", { cls: "slot-btn-alloc", title: "how it's met — communal first, credit as fallback" });
    }
    // two-tap delete, no modal
    const del = el("button", "slot-btn slot-btn-delete");
    del.type = "button";
    del.title = "delete — tap twice";
    armTwice(del, { rest: "🗑️", armed: "sure?", onConfirm: () => { openSections.delete(okey); cfg.onDelete?.(); } });
    main.appendChild(del);
    card.append(main, body);
    if (open)
        show(open); // re-open whatever this card had open before
    return card;
}
// ── how it's met: the section under the badge ──────────────────────────────
function metSection(m, cfg) {
    const box = el("div", "met-box");
    const covered = m.communal.qty + m.credit.qty;
    box.appendChild(el("h4", "met-title", `💫 ${figure(covered)} of ${figure(m.want)} ${m.unit} met — communal first, credit as fallback`));
    const list = el("div", "met-list");
    const item = (cls, head, amount, meta, verbs = []) => {
        const it = el("div", `met-item ${cls}`);
        const h = el("div", "met-head");
        h.append(el("span", "met-name", head), el("span", "met-amount", amount));
        it.appendChild(h);
        const mt = el("div", "met-meta");
        mt.appendChild(el("span", `met-badge ${cls}`, meta));
        for (const v of verbs)
            if (v) {
                const a = el("a", "met-verb", v[0]);
                a.addEventListener("click", v[1]);
                mt.appendChild(a);
            }
        it.appendChild(mt);
        list.appendChild(it);
    };
    if (m.communal.qty > 0)
        item("communal", "the plan provisions it", `${figure(m.communal.qty)} ${m.unit}`, `🌱 communal${m.communal.via ? " · via " + m.communal.via : ""}`);
    for (const s of m.credit.sources)
        item("credit", s.at, `${figure(s.onhand)} ${s.unit}`, "🪙 credit — claimable", [cfg.onClaim ? ["claim at the shop →", () => cfg.onClaim(s.rid)] : null]);
    if (m.gap.qty > 0)
        item("gap", "still short", `${figure(m.gap.qty)} ${m.unit}`, "◌ gap", [cfg.onContribute ? ["contribute a shift", cfg.onContribute] : null,
            cfg.onPropose ? ["propose it", cfg.onPropose] : null]);
    box.appendChild(list);
    return box;
}
