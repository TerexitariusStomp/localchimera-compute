// app/lend.ts — lending a thing into the commons: the act, and its one control.
//
// Socialization has two halves. Declaring a means says you own it and how much;
// the LEND says for how long the commons may use it, and who may be assigned to
// work on it. Custody moves, the right stays. This module is the second half,
// whole: `lend` and `recall` are the doors to the grant (a custody-attestation
// ACDC signed by the owner's own key — economy/socialization.scm), `grants`
// is the list in force, and `lendControl` is the element any face mounts to
// compose, read and recall a lend — the offer card, the Resources card, and
// whatever else holds a thing of yours.
//
// THE SENTENCE IS THE FORM. The grant reads as one sentence and each bold word
// is the control for itself: the amount, the span, the people. One tap on the
// word opens its picker beneath; the default sentence is already a whole grant,
// so the common lend is one tap on the button.
//
// WHO MAY WORK ON IT is the owner's steward rule (the grant's `eligible` claim),
// read over the owner's own contact book and signed vouches by the one evaluator
// (planner/matching/filter-rule.scm). The picker is the contact book itself,
// embedded: the people you vouch for, each kind you tag people with, and every
// person by name — picked together, any of them admits. The rule stays live: a
// vouch signed or a tag changed tomorrow moves who it admits, with the grant
// untouched.
//
// With no seat taken the grant is local to the page, so the walk reads whole.
import { HANDLERS, hint } from './core.js';
import { seam } from './seam.js';
import { signal } from './reactive.js';
import { on } from './bus.js';
import { scopeSig, scopeName } from './scope.js';
import { attached } from './books.js';
import { readJSON, writeJSON } from './store.js';
import { SPANS, spanUntilISO, humanDate, isMoneyUnit } from './slots/model.js';
import { fmtRule, audiencePicker } from './slots/criteria.js';
import { lendThrough, recallThrough, lentSays, grantAmount, untilWords, counted as countedUnit } from './lend-core.js';
import { qtyStepper, inlineText, armTwice, standsRow } from './slots/editors.js';
import { idHint } from './tabs/social/id.js';
import { mk as el } from './dom.js';
import { K } from "./keys.js";
// ── the grants in force ────────────────────────────────────────────────────
// The gateway pushes your live custody attestations; with no seat taken the
// lends made on this page stand in.
const pushed = signal((seam.data && seam.data.grants) || null);
on("grants", gs => pushed.set(gs || []));
const local = signal([]);
/** Your live grants. A tracked read: an effect that calls it redraws when a grant lands or ends. */
export const grants = () => pushed() || local();
/** The grant in force over this thing, if it is lent. */
export const grantOf = (t) => grants().find(g => g.spec === t.spec) || null;
/** A grant as one line: how much, until when, and who may work on it. */
export function grantLine(g, t) {
    let who = "";
    try {
        const c = g.eligible ? JSON.parse(g.eligible) : null;
        const r = c && fmtRule(c["filter-rule"]);
        if (r)
            who = ` · ${r} may work on it`;
    }
    catch (_) { /* an unreadable rule shows nothing rather than a wrong word */ }
    return `${grantAmount(g, t)}, ${untilWords(g.until)}${who}`;
}
// ── the acts ───────────────────────────────────────────────────────────────
/** Lend T into the commons you stand in, on TERMS. With no seat taken the grant is local to the page. */
export async function lend(t, terms) {
    if (!attached()) {
        local.set([...local().filter(g => g.spec !== t.spec),
            { id: `local:${t.spec}`, spec: t.spec, qty: terms.qty, until: terms.until || null,
                kind: terms.kind, eligible: terms.eligible || "" }]);
        return { ok: true, says: lentSays(t, terms, scopeName()) };
    }
    return lendThrough({ socialize: HANDLERS.socialize, commune: scopeSig(), communeName: scopeName(),
        me: (idHint() || {}).aid }, t, terms);
}
/** End a lend now: custody comes home. */
export async function recall(g) {
    if (local().some(x => x.id === g.id)) {
        local.set(local().filter(x => x.id !== g.id));
        return { ok: true, says: "recalled — custody is yours again" };
    }
    return recallThrough(HANDLERS.recall, g);
}
const drafts = new Map();
// the span and the audience of your last lend open the next one
const LAST = K.lendLast;
const spanById = (id) => SPANS.find(s => s.id === id && s.id !== "date") || SPANS.find(s => s.id === "month");
function draftOf(t) {
    let d = drafts.get(t.spec);
    if (!d) {
        const last = readJSON(LAST, {});
        d = { qty: t.qty || 1, span: spanById(last.span), datePick: "", rule: last.rule,
            movable: false, returnTo: "", conditionFloor: "", retain: "", open: null, busy: false, says: "" };
        drafts.set(t.spec, d);
    }
    d.qty = Math.min(d.qty, t.qty || d.qty);
    return d;
}
const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);
/**
 * The lend control for T: the grant as a sentence whose bold words are its
 * pickers, or — once lent — the grant in force and its recall. A plain
 * element; a host inside an effect redraws it when a grant lands or ends
 * (`grants` and the contact book are tracked reads).
 */
export function lendControl(t, opts = {}) {
    const box = el("div", "sl-soc ld");
    const unit = t.unit || "";
    // a PURSE is lent to be spent; everything else is lent to be used and returned
    const consume = isMoneyUnit(unit);
    // a thing counted in itself reads by its own name: "1 bicycle", "2 hours of your oven"
    const counted = countedUnit(unit);
    const g = grantOf(t);
    // ALREADY LENT — the grant in force, and the one power that ends it early
    if (g) {
        drafts.delete(t.spec);
        box.appendChild(el("div", "sl-soc-live", `🤲 ${g.kind === "consume" ? "in the commons' purse" : "lent to the commons"} — ${grantLine(g, t)}`)); // verb-meant: a grant's kind, not an act
        const rec = el("a", "sl-soc-recall");
        armTwice(rec, { rest: "recall", armed: "sure? this strands what the plan met through it",
            onConfirm: () => { recall(g).then(r => hint(r.says, r.ok ? "success" : "error")); } });
        box.appendChild(rec);
        return box;
    }
    const d = draftOf(t);
    const draw = () => {
        const iso = spanUntilISO(d.span, d.datePick);
        const openEnded = d.span.id === "open";
        const ready = openEnded || !!iso;
        const tok = (k, text) => {
            const a = el("a", "ld-tok" + (d.open === k ? " on" : ""), text);
            a.addEventListener("click", () => { d.open = d.open === k ? null : k; draw(); });
            return a;
        };
        const txt = (s) => document.createTextNode(s);
        const say = el("div", "sl-soc-say" + (openEnded ? " warn" : ""));
        say.append(txt(consume ? "The plan may spend up to " : "Lend "), tok("amount", `${d.qty} ${counted ? t.name : unit}`), txt(consume ? ` of your ${t.name} for ${scopeName()}, ` : counted ? ` to ${scopeName()} ` : ` of your ${t.name} to ${scopeName()} `), tok("span", openEnded ? "with no return-by" : d.span.id === "date" ? (iso ? `until ${humanDate(iso) || iso}` : "until a day you pick") : `for ${d.span.label}`), txt("."));
        if (!consume)
            say.append(txt(" "), tok("who", cap(fmtRule(d.rule) || "anyone")), txt(" may work on it."));
        if (d.movable)
            say.append(txt(" They may move it."));
        if (d.returnTo)
            say.append(txt(` Back to ${d.returnTo}.`));
        if (d.conditionFloor)
            say.append(txt(` In condition no worse than ${d.conditionFloor}.`));
        if (d.retain.trim())
            say.append(txt(` Kept back: ${d.retain.trim()}.`));
        const body = el("div", "sl-soc-body");
        if (d.open === "amount") {
            const r = el("div", "sl-soc-row");
            r.append(qtyStepper(d.qty, { min: 1, onCommit: v => { d.qty = Math.min(v, t.qty || v); draw(); } }), el("span", "sl-soc-of", `of the ${t.qty} ${counted ? "" : unit + " "}you declared`));
            body.appendChild(r);
        }
        else if (d.open === "span") {
            const row = el("div", "sl-presets");
            for (const s of SPANS) {
                const c = el("a", "sl-chip" + (s.id === "open" ? " sl-custom" : "") + (d.span.id === s.id ? " on" : ""), s.label);
                c.addEventListener("click", () => { d.span = s; draw(); });
                row.appendChild(c);
            }
            body.appendChild(row);
            if (d.span.id === "date") {
                const day = el("input", "sl-time");
                day.type = "date";
                day.value = d.datePick;
                day.addEventListener("change", () => { d.datePick = day.value; draw(); });
                body.appendChild(day);
            }
        }
        else if (d.open === "who") {
            body.appendChild(audiencePicker(d.rule, r => { d.rule = r; draw(); }));
        }
        else if (d.open === "more") {
            // the widenings and the care terms: each a deliberate word, none of them
            // needed for the lend to stand
            const mv = el("label", "sl-soc-check");
            const mvIn = el("input");
            mvIn.type = "checkbox";
            mvIn.checked = d.movable;
            mvIn.addEventListener("change", () => { d.movable = mvIn.checked; draw(); });
            mv.append(mvIn, el("span", null, "they may move it from where it sits"));
            const care = el("div", "sl-soc-care");
            care.append(inlineText(d.returnTo, { placeholder: "return it to…", cls: "sl-soc-in", onCommit: v => { d.returnTo = v; draw(); } }), inlineText(d.conditionFloor, { placeholder: "in condition no worse than…", cls: "sl-soc-in", onCommit: v => { d.conditionFloor = v; draw(); } }), inlineText(d.retain, { placeholder: "kept back, comma-separated… (the radio, the locked study)", cls: "sl-soc-in",
                onCommit: v => { d.retain = v; draw(); } }));
            body.append(mv, care);
        }
        const go = el("button", "sl-soc-go", d.busy ? "lending…" : !ready ? "pick the day it comes back" : consume ? "put into the commons' purse" : "lend");
        go.disabled = d.busy || !ready;
        go.addEventListener("click", () => {
            if (go.disabled)
                return;
            d.busy = true;
            d.says = "";
            draw();
            const eligible = d.rule !== undefined ? JSON.stringify({ "filter-rule": d.rule }) : "";
            writeJSON(LAST, { span: d.span.id, rule: d.rule });
            lend(t, { kind: consume ? "consume" : "use", qty: d.qty, until: iso, movable: d.movable, returnTo: d.returnTo,
                conditionFloor: d.conditionFloor, retain: d.retain, eligible })
                .then(r => {
                d.busy = false;
                if (r.ok) {
                    hint(r.says, "success");
                    return;
                } // the grant's arrival redraws the host
                d.says = r.says;
                draw();
            });
        });
        const foot = el("div", "ld-foot");
        foot.appendChild(go);
        if (!consume)
            foot.appendChild(tok("more", "more terms"));
        box.replaceChildren(say, body, foot);
        if (d.says)
            box.appendChild(el("div", "share-err", d.says));
        if (opts.span && !consume)
            box.appendChild(standsRow(t.name || t.spec, opts.span));
    };
    draw();
    return box;
}
