// app/tabs/onboard.ts — the "start" face: a checklist of the few facts the
// plan needs from you, each row a door to the real place that holds it.
//
// Every row shows what is already set (its live status line) and a checkbox
// that is lit exactly when the real data behind it is there — nothing here
// is tracked separately from the fact itself. Tapping a row sends you to the
// real place for it: a settings section, the location sheet, the inventory
// drawer's skills screen. Nothing is reproduced here — the row is a summary
// and a door, never a copy of the fields themselves. Identity is the one
// exception: there is no other real place to make your first one, so its
// row expands in place to the identity card (app/identity-view.ts) — the same
// card the account sheet shows. The list lives in
// #onboardstage (an existing face overlay, app.html) and stays revisitable —
// there is no "finished" wizard state, only an "open the map" door at the
// foot for whenever you are ready to leave it.
import { html, render } from '../template.js';
import { signal, effect } from '../reactive.js';
import { readJSON, writeJSON } from '../store.js';
import { profile, setProfile, DIETS } from '../profile.js';
import { regionForLat } from '../nutrition.js';
import { locationSummary, home, homeName, positionForFloors, openLocationSheet } from './social/location.js';
import { revealSkills } from './social/share.js';
import { identity } from './social/id.js';
import { identityCard, showSignIn } from '../identity-view.js';
import { currencyInForce } from '../money.js';
import { dwelling, dwellingSummary } from '../dwelling.js';
import { openAccountPage } from '../account.js';
import { installBlock } from '../install.js';
import { chip } from '../chips.js';
import { K } from "../keys.js";
const KEY = K.onboardWalk;
const walk = signal({ done: false, ...readJSON(KEY, {}) });
const visited = (id) => (walk().visited ?? []).includes(id);
const keep = (patch) => { const next = { ...walk(), ...patch }; walk.set(next); writeJSON(KEY, next); };
// ── live status lines, read off the real state each row is about ──────────
const dietStatus = () => {
    const p = profile();
    if (!p.stated)
        return "not yet set";
    return [(DIETS.find(d => d.id === p.diet) || DIETS[0]).label, ...p.extra, ...p.allergies.map(a => `no ${a}`)].join(", ");
};
const bodyStatus = () => {
    const p = profile();
    if (!p.stated)
        return "not yet set";
    return `${p.sex === "F" ? "female" : "male"}, ${p.age}${p.stage === "pregnant" || p.stage === "lactating" ? ", " + p.stage : ""}`;
};
const whereStatus = () => {
    const s = locationSummary();
    return s.mode === "off" ? (home() ? `not shared — the plan uses your home, ${homeName()}` : "not shared, and no home registered yet")
        : s.place || s.modeName;
};
const housingStatus = () => dwelling().stated ? `home ${homeName() || "not registered"} · ${dwellingSummary()}` : "not yet set";
const timeStatus = () => {
    const p = profile();
    return p.days.length ? `${p.labourHours} h × ${p.days.length} days a week, credit read in ${currencyInForce()}` : "no day given yet";
};
const TASKS = [
    { id: "diet", glyph: "🥗", title: "your diet", sub: dietStatus, done: () => profile().stated, go: () => openAccountPage("diet"), tray: "#idrow .who" },
    { id: "body", glyph: "🫀", title: "your body", sub: bodyStatus, done: () => profile().stated, go: () => openAccountPage("body"), tray: "#idrow .who" },
    { id: "where", glyph: "📍", title: "where you are", sub: whereStatus, done: () => locationSummary().mode !== "off" || !!home(), go: openLocationSheet, tray: ".share-tog-where" },
    { id: "housing", glyph: "🏠", title: "your housing", sub: housingStatus, done: () => dwelling().stated, go: () => openAccountPage("housing"), tray: "#idrow .who" },
    { id: "time", glyph: "🕰️", title: "your time", sub: timeStatus, done: () => profile().days.length > 0, go: () => openAccountPage("time"), tray: "#idrow .who" },
    { id: "skills", glyph: "🛠️", title: "your skills", sub: () => "open it to see and claim what you can do", done: () => true, go: revealSkills, tray: ".sharebar-handle" },
];
// ── the fly: a row's icon rides to the tray control its door sits behind ──
// Purely cosmetic (never gates `go`), so a missing or offscreen target just
// skips it — the row's own navigation is the one thing that must never wait
// on an animation frame.
function pulseTray(target) {
    const el = document.querySelector(target);
    if (!el)
        return;
    el.classList.remove("ob-ping");
    void el.offsetWidth; // restart the animation if it's already mid-pulse
    el.classList.add("ob-ping");
    window.setTimeout(() => el.classList.remove("ob-ping"), 650);
}
function flyToTray(origin, target, glyph) {
    const to = document.querySelector(target);
    if (!to || window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
        pulseTray(target);
        return;
    }
    const a = origin.getBoundingClientRect(), b = to.getBoundingClientRect();
    if (a.width === 0 || b.width === 0) {
        pulseTray(target);
        return;
    }
    const ax = a.left + a.width / 2, ay = a.top + a.height / 2;
    const dx = (b.left + b.width / 2) - ax, dy = (b.top + b.height / 2) - ay;
    const dot = document.createElement("span");
    dot.className = "ob-fly";
    dot.textContent = glyph;
    dot.style.left = `${ax}px`;
    dot.style.top = `${ay}px`;
    document.body.appendChild(dot);
    const anim = dot.animate([
        { transform: "translate(-50%,-50%) scale(1)", opacity: 1, offset: 0 },
        { transform: `translate(${dx * .55}px, ${dy * .55 - 26}px) translate(-50%,-50%) scale(1.15)`, opacity: 1, offset: .55 },
        { transform: `translate(${dx}px, ${dy}px) translate(-50%,-50%) scale(.3)`, opacity: 0, offset: 1 },
    ], { duration: 460, easing: "cubic-bezier(.22,.7,.3,1)" });
    anim.onfinish = () => { dot.remove(); pulseTray(target); };
}
// A row's check is full only once the person has opened it: data already there
// (a demo default, or a device's earlier answer) shows a half-lit ring until then.
const taskRow = (t) => {
    const has = t.done();
    const seen = visited(t.id);
    const tap = (e) => {
        keep({ visited: [...new Set([...(walk().visited ?? []), t.id])] });
        if (t.tray) {
            const ic = e.currentTarget.querySelector(".acct-ic");
            if (ic)
                flyToTray(ic, t.tray, t.glyph);
        }
        t.go();
    };
    const cls = has && seen ? " on" : has ? " part" : "";
    return html `
    <button type="button" class="acct-row ob-row" onclick=${tap}>
      <span class="acct-ic">${t.glyph}</span>
      <span class="acct-tx"><span class="acct-l">${t.title}</span><span class="acct-s">${t.sub()}</span></span>
      <span class="ob-check${cls}" title="${has && seen ? "set" : has ? "set — open it to confirm" : "not yet set"}">${has && seen ? "✓" : ""}</span>
    </button>`;
};
// ── the identity row — expands in place; there is no other real place for it ──
// Made here rather than sent elsewhere: everything else in the list is kept on
// the device and needs no key, and creating one leads naturally into what
// creation reveals — the passcode, once, and the recovery file. The card is one
// persistent element, moved into the row each time the checklist redraws, so a
// half-typed passcode survives a redraw.
const identityOpen = signal(false);
let card = null;
const idLead = html `<p class="ob-lead-s">Everything else in this list is kept on this device. An identity is what lets the commons hold it for you and act on it: a key of your own, made here, never sent anywhere.</p>`;
/** Open the row on the sign-in face: "I already have an identity". */
const signInHere = () => { showSignIn(); identityOpen.set(true); };
const identityRow = () => {
    const me = identity();
    const open = identityOpen();
    return html `
    <button type="button" class="acct-row ob-row" onclick=${() => identityOpen.set(!open)}>
      <span class="acct-ic">🔑</span>
      <span class="acct-tx"><span class="acct-l">your identity</span>
        <span class="acct-s">${me ? (me.name || "an unnamed identity") : "one tap makes it; the passcode is yours alone"}</span></span>
      <span class="ob-check${me ? " on" : ""}" title="${me ? "made" : "not yet made"}">${me ? "✓" : ""}</span>
    </button>
    ${open ? html `<div data-idc></div>` : ""}`;
};
// ── the frame ───────────────────────────────────────────────────────────────
let mounted = false;
/** The face switch, handed in — so this module never imports faces.ts. */
let go = () => { };
let stageEl = null;
function finish() {
    keep({ done: true });
    go("map");
}
/** The wordmark, spelt in the same colours as the account sheet's header (.acct-mark). */
const wordmark = () => html `<span class="acct-mark">${[..."playnet"].map(c => html `<span class="wm-${c}">${c}</span>`)}</span>`;
function draw() {
    if (!stageEl)
        return;
    const me = identity();
    const real = !!me;
    render(stageEl, html `
    <div class="acct-card ob-list">
      <div class="ob-intro">
        <h2 class="ob-brand">${wordmark()}</h2>
        <p>a plan for meeting each other's needs.</p>
        <p class="ob-mode ${real ? "real" : "demo"}">${real
        ? `playing for real${me.name ? ` as ${me.name}` : ""}`
        : "demo — your answers stay on this device until you make an identity"}</p>
        ${identity() ? "" : html `<div class="ob-opts">${chip(false, "I already have an identity — sign in", signInHere)}</div>`}
      </div>      <div class="acct-group">${identityRow()}</div>
      <div class="acct-group">${TASKS.map(taskRow)}</div>
      ${installBlock()}
      <button class="ob-next ob-wide ob-play" onclick=${finish}>${real ? "let's play! 🌱" : "try the demo — let's play! 🎲"}</button>
    </div>`);
    const slot = stageEl.querySelector("[data-idc]");
    if (slot)
        slot.replaceWith((card ??= identityCard({ lead: idLead })).el);
}
/** Mount the checklist into #onboardstage (an existing face overlay, app.html) — the frame follows the profile's own signals so every row's status line stays live. */
export function initOnboard(setFace) {
    go = setFace;
    if (mounted) {
        draw();
        return;
    }
    mounted = true;
    stageEl = document.getElementById("onboardstage");
    // the climate is read off the position, never asked: a fix arriving — or a home registered — sets the region the geography layer reads
    effect(() => {
        const f = positionForFloors();
        if (!f)
            return;
        const r = regionForLat(f.lat);
        // elevation rides the fix when the device gives one; a fix without one leaves the stated figure alone
        const alt = f.alt != null && isFinite(f.alt) ? Math.round(f.alt) : profile.peek().altitudeM;
        if (profile.peek().region !== r || profile.peek().altitudeM !== alt)
            setProfile({ region: r, altitudeM: alt });
    });
    effect(draw);
}
/** Whether this device has opened the checklist once before — main.ts may land here when it has not. */
export const onboarded = () => walk().done;
