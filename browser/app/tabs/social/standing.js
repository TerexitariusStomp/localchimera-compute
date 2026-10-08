// app/tabs/social/standing.ts — the profile: where you are, what you can do,
// and how far the record bears it out.
//
// A skill is DECLARED or it is not — declare-skill, the door that puts your
// labour-power on the roster the plan may ask you for. Beside each declared
// skill stands what the record shows for it, in the one measure every reader
// of a skill uses, HOURS: the hours the people who received your work
// validated (the credit ledger's own gate — a recipient's word, or the
// scope's own silence over its lapse window, the very same fold ledger-gross
// reads), folded through the skill's own law to where its competence stands
// today (idle time wears it, satisfied practice renews it; planner/formulas/skill-law.scm).
// Witnessing is a second, separate fact, never a deeper tier of the first: peers
// may CO-SIGN a work event's credential, opt-in, after the fact, whether or
// not it was already validated its own way — shown as its own small note, not
// nested inside the hours it rides beside. Nothing here is graded by anyone:
// the record is made of what others did — received the work, stayed silent
// through its window, or chose to co-sign it — and the law makes the figure
// of it. A declared skill with no work behind it stands as your word alone.
//
// One record, two mounts — the inventory drawer's Skills view (share.ts:
// `skillsPanel`, chips to claim and the record beside each) and the settings'
// "your profile" group (`standingBlock`) — so the demo day shows it too.
// Offline the rows are demo/profile.ts, and an edit is kept on this device.
import { HANDLERS, askJSON } from '../../core.js';
import { mk } from '../../dom.js';
import { readJSON, writeJSON } from '../../store.js';
import { DEMO_STANDING, DEMO_WHERE } from '../../demo/profile.js';
import { locationSummary, openLocationSheet } from './location.js';
import { K } from "../../keys.js";
// "-3": the earlier offline rows carried a word; a row is now a skill and its record
const OFFLINE_KEY = K.standing;
// The demo stands until the wire answers with rows of its own — an absent
// handler, a closed door and a refused read all leave it standing, the same
// rule the share face keeps (a source serves demo only while its wire brings
// nothing). Edits follow the source: to the commons once it has answered, to
// this device until then.
let wired = false;
const live = () => wired;
let rows = [];
let said = "";
/** Every mounted view of the record, each with the way it draws itself. */
const hosts = new Map();
/** Skills offered as chips — the demo roster's own, plus the common hands a commune asks for first.
 *  "walk"/"cycle" are the plan's own ride-mode capabilities (engine.scm's mode-ok?, berlin-transit.scm) —
 *  real, declared skills like any other here, not a special profile flag; a fresh profile holds both by
 *  default (service.scm's set-profile bootstrap) and revokes them here the same way any skill is revoked. */
export const SUGGESTED_SKILLS = ["cooking", "childcare", "bike repair", "gardening", "carpentry", "facilitation", "driving", "nursing", "baking", "sewing", "bookkeeping", "teaching", "walk", "cycle"];
const num = (v) => { const n = parseFloat(String(v)); return isFinite(n) ? n : 0; };
const tidy = (r) => ({
    skill: String(r.skill || ""), held: !!r.held,
    hours: num(r.hours), competence: num(r.competence),
    events: num(r.events), witnessed: num(r.witnessed), attesters: num(r.attesters), witnessedHours: num(r.witnessedHours),
    pending: Array.isArray(r.pending) ? r.pending.map(p => ({ count: num(p.count), quorum: num(p.quorum) || 1 })) : [],
});
let refreshedAt = 0;
async function refresh() {
    refreshedAt = Date.now();
    const reply = await askJSON(() => HANDLERS.mySkillStanding?.(), null);
    wired = Array.isArray(reply);
    rows = (wired ? reply : readJSON(OFFLINE_KEY, DEMO_STANDING)).map(tidy);
    redrawAll();
}
/** Offline, the edit lands on this device; a row with no hold and no record is gone. */
function keepOffline() {
    rows = rows.filter(r => r.held || r.events > 0 || r.hours > 0);
    writeJSON(OFFLINE_KEY, rows);
    redrawAll();
}
const errOf = (r) => (typeof r === "string" && r.startsWith("err:")) ? r.slice(4) : "";
/** Declare a skill: onto the roster, through the one door. */
async function declare(skill) {
    skill = skill.trim();
    if (!skill)
        return;
    if (live()) {
        said = errOf(await HANDLERS.declareSkill?.(skill));
        return refresh();
    }
    const r = rows.find(x => x.skill === skill);
    if (r)
        r.held = true;
    else
        rows.push(tidy({ skill, held: true }));
    keepOffline();
}
/** Withdraw a skill from the roster; the record of the work stays. */
async function revoke(skill) {
    if (live()) {
        said = errOf(await HANDLERS.revokeSkill?.(skill));
        return refresh();
    }
    const r = rows.find(x => x.skill === skill);
    if (r)
        r.held = false;
    keepOffline();
}
/**
 * Declare several skills at once — the start face's last screen. The rows are
 * read first, so an offline write adds to what this device already holds
 * rather than standing in for it.
 */
export async function claimSkills(items) {
    if (items.length === 0)
        return;
    await refresh();
    for (const it of items)
        await declare(it.skill);
}
const levelOf = (r) => r.attesters > 0 ? "witnessed" : r.hours > 0 ? "practiced" : "word";
const h = (n) => `${Math.round(n * 10) / 10} h`;
const people = (n) => n === 1 ? "1 person" : `${n} people`;
/** The evidence, said in a sentence — what others did, never what you said. */
function evidence(r) {
    const parts = [];
    if (r.hours > 0) {
        parts.push(Math.abs(r.competence - r.hours) > 0.05
            ? `stands at ${h(r.competence)} today, of ${h(r.hours)} validated by the people who received the work`
            : `${h(r.hours)} validated by the people who received the work`);
        parts.push(r.attesters > 0
            ? `${people(r.attesters)} co-signed ${r.witnessed} of ${r.events} jobs, ${h(r.witnessedHours)} of it`
            : "no co-signer yet");
    }
    else if (r.events > 0)
        parts.push(`${r.events} jobs recorded, waiting on the people who received them`);
    else
        parts.push("nothing worked under this name yet");
    for (const p of r.pending)
        parts.push(`${p.count} of ${p.quorum} signing now`);
    return parts.join(" · ");
}
/** The bar's LENGTH alone: where the skill's competence stands today, against
 *  the most any of your skills stands at, so the list reads as one scale. */
function bar(r, scale) {
    const track = mk("span", "stand-bar");
    const reach = mk("span", "stand-bar-reach");
    reach.style.width = `${scale > 0 ? Math.round(100 * Math.min(1, r.competence / scale)) : 0}%`;
    track.append(reach);
    return track;
}
/** A skill, simply: its name, its validated hours, and — only when it
 *  applies — a small separate note that peers have co-signed some of the
 *  work behind it. The full evidence sentence rides the row's own tooltip,
 *  reachable, never the row's standing default text. */
function rowEl(r, scale) {
    const el = mk("div", `stand-row stand-${levelOf(r)}${r.held ? "" : " stand-unheld"}`);
    el.title = evidence(r);
    const head = mk("div", "stand-head");
    head.append(mk("span", "stand-name", r.skill));
    head.append(mk("span", "stand-hours", r.competence > 0 ? h(r.competence) : "—"));
    if (r.attesters > 0)
        head.append(mk("span", "stand-witness", `✓ ${people(r.attesters)} co-signed`));
    if (r.held) {
        const x = mk("a", "stand-x", "✕");
        x.title = "withdraw this skill from the roster — the record of the work stays";
        x.onclick = () => revoke(r.skill);
        head.append(x);
    }
    else {
        const d = mk("a", "vbtn", "declare it");
        d.title = "the record shows this work — put the skill on the roster";
        d.onclick = () => declare(r.skill);
        head.append(d);
    }
    el.append(head, bar(r, scale));
    return el;
}
function draw(host) {
    host.textContent = "";
    host.append(mk("div", "opt", "Declare what you can do; the plan may ask you for it. Beside each skill: the hours validated, folded through "
        + "the skill's own law to where it stands today — and, when peers have co-signed some of the work, a note of that too."));
    const sorted = [...rows].sort((a, b) => (Number(b.held) - Number(a.held)) || (b.competence - a.competence) || (b.hours - a.hours));
    const scale = Math.max(1, ...rows.map(r => Math.max(r.competence, r.hours)));
    const list = mk("div", "stand-list");
    for (const r of sorted)
        list.append(rowEl(r, scale));
    if (!sorted.length)
        list.append(mk("div", "opt", "nothing declared yet."));
    host.append(list);
    const add = mk("div", "stand-add");
    const inp = mk("input", "stand-add-in");
    inp.type = "text";
    inp.maxLength = 120;
    inp.placeholder = "a skill you can do…";
    const go = mk("a", "vbtn", "declare");
    const submit = () => { const s = inp.value.trim(); if (!s) {
        inp.focus();
        return;
    } declare(s); };
    go.onclick = submit;
    inp.onkeydown = ev => { if (ev.key === "Enter")
        submit(); };
    add.append(inp, go);
    host.append(add);
    if (said)
        host.append(mk("div", "err", said));
    if (!live())
        host.append(mk("div", "opt", "a demo profile, kept on this device — sign in and the commons keeps yours."));
}
// ── the drawer's Skills view ────────────────────────────────────────────────
// What the start face's skills screen asks — chips to claim, the claimed list
// beside the record — with the record standing beside each claim. No second
// name field here: the drawer's own express pill above already reads "Claim
// a skill…" under this rail and declares on ➕/↵ (share.ts submit()); a
// second "another skill…" input said the identical thing a few lines down.
function drawSkills(host) {
    const held = (skill) => rows.some(r => r.skill === skill && r.held);
    const claimed = rows.filter(r => r.held);
    const names = [...SUGGESTED_SKILLS, ...claimed.map(r => r.skill).filter(n => !SUGGESTED_SKILLS.includes(n))];
    host.textContent = "";
    host.append(mk("p", "sk-lead", "What you can do. The plan asks you only for work you claim; the hours other people validate stand beside each skill."));
    const chips = mk("div", "ob-opts sk-chips");
    for (const n of names) {
        const on = held(n);
        const c = mk("button", `ob-chip${on ? " on" : ""}`, n);
        c.type = "button";
        c.title = on ? "withdraw this skill from the roster — the record of the work stays" : "claim this skill";
        c.onclick = () => { on ? revoke(n) : declare(n); };
        chips.append(c);
    }
    host.append(chips);
    if (!claimed.length)
        host.append(mk("p", "ob-state", "nothing claimed yet — the plan asks you for no work until you do"));
    else {
        const scale = Math.max(1, ...rows.map(r => Math.max(r.competence, r.hours)));
        const list = mk("div", "stand-list");
        for (const r of [...claimed].sort((a, b) => (b.competence - a.competence) || (b.hours - a.hours)))
            list.append(rowEl(r, scale));
        host.append(list);
    }
    // a record with work behind it but no claim: one tap puts it back on the roster
    const lapsed = rows.filter(r => !r.held && (r.events > 0 || r.hours > 0));
    if (lapsed.length) {
        const list = mk("div", "stand-list");
        for (const r of lapsed)
            list.append(rowEl(r, 1));
        host.append(mk("div", "sk-sub", "worked, not claimed"), list);
    }
    if (said)
        host.append(mk("div", "err", said));
    if (!live())
        host.append(mk("div", "opt", "a demo roster, kept on this device — sign in and the commons keeps yours."));
}
/** The Skills view of the inventory drawer: claim, add, and read the record. Redraws itself as the record changes. */
export function skillsPanel() {
    const el = mk("div", "sk");
    hosts.set(el, drawSkills);
    if (!wired && !rows.length)
        rows = readJSON(OFFLINE_KEY, DEMO_STANDING).map(tidy);
    drawSkills(el);
    if (Date.now() - refreshedAt > 5000)
        queueMicrotask(() => { refresh(); });
    return el;
}
const whereHosts = new Map();
function drawWhere(el, beforeChange) {
    el.textContent = "";
    const w = wired ? locationSummary() : { ...DEMO_WHERE, modeName: "here, now" };
    el.append(mk("div", "stand-where-now", w.mode === "off" ? "📍 not shared — the plan uses your registered home"
        : w.place ? `📍 ${w.place} · ${w.modeName}`
            : `📍 ${w.modeName} · waiting for a fix`));
    for (const a of w.ahead)
        el.append(mk("div", "stand-where-ahead", `${a.day} · ${a.place}`));
    if (wired && beforeChange) {
        const c = mk("a", "vbtn", "change where you are");
        c.onclick = ev => { ev.stopPropagation(); beforeChange(); openLocationSheet(); };
        el.append(c);
    }
    el.append(mk("div", "opt", "what the commons holds is a place the scope already knows — your skills are reachable from there."));
}
function redrawAll() {
    for (const [el, drawIt] of [...hosts]) {
        if (el.isConnected)
            drawIt(el);
        else
            hosts.delete(el);
    }
    for (const [el, before] of [...whereHosts]) {
        if (el.isConnected)
            drawWhere(el, before);
        else
            whereHosts.delete(el);
    }
}
/** Mount the skills block under F — the sheet's and the settings' one implementation. */
export function standingBlock(f) {
    const el = mk("div", "stand");
    f.node().append(el);
    hosts.set(el, draw);
    if (!wired && !rows.length)
        rows = readJSON(OFFLINE_KEY, DEMO_STANDING).map(tidy);
    draw(el);
    // the host is appended by its caller after this returns, so the first
    // redraw finds it connected
    queueMicrotask(() => { refresh(); });
}
/**
 * Where you are, read from the location sheet's own state — a place, never a
 * coordinate; the demo's own places until the wire has answered. BEFORE-CHANGE,
 * when given, clears the way for the location sheet (the identity sheet closes
 * itself); a mount with no way to it draws no button.
 */
export function whereBlock(f, beforeChange) {
    const el = mk("div", "stand-where");
    f.node().append(el);
    whereHosts.set(el, beforeChange);
    drawWhere(el, beforeChange);
    queueMicrotask(() => { refresh(); });
}
