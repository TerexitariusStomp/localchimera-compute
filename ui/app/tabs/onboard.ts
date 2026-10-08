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
// row expands in place to the small form that makes it. The list lives in
// #onboardstage (an existing face overlay, app.html) and stays revisitable —
// there is no "finished" wizard state, only an "open the map" door at the
// foot for whenever you are ready to leave it.

import { html, render } from '../template.js';
import type { Fragment } from '../template.js';
import { signal, effect } from '../reactive.js';
import { readJSON, writeJSON } from '../store.js';
import { profile, setProfile, DIETS } from '../profile.js';
import { regionForLat } from '../nutrition.js';
import { locationSummary, home, homeName, positionForFloors, openLocationSheet } from './social/location.js';
import { revealSkills } from './social/share.js';
import { identity, identityState, consentCurrent, createIdentity, downloadIdentityFile, setMyName, openIdentityDoor, CONSENT_SENTENCE, ONLY_KEY_NOTE, VOTE_CONSENT_SENTENCE, recordVoteConsent } from './social/id.js';
import { MIN_AGE } from '../legal-product.js';
import { HANDLERS } from '../core.js';
import { currencyInForce } from '../money.js';
import { dwelling, dwellingSummary } from '../dwelling.js';
import { openAccountPage } from '../account.js';
import { installBlock } from '../install.js';
import { chip } from '../chips.js';
import { K } from "../keys.js";

/** What the walk keeps on this device: whether it has been opened once before. */
interface Walk { done: boolean; visited?: string[] }
const KEY = K.onboardWalk;
const walk = signal<Walk>({ done: false, ...readJSON<Partial<Walk>>(KEY, {}) });
const visited = (id: string): boolean => (walk().visited ?? []).includes(id);
const keep = (patch: Partial<Walk>): void => { const next = { ...walk(), ...patch }; walk.set(next); writeJSON(KEY, next); };

// ── live status lines, read off the real state each row is about ──────────

const dietStatus = (): string => {
  const p = profile();
  if (!p.stated) return "not yet set";
  return [(DIETS.find(d => d.id === p.diet) || DIETS[0]).label, ...p.extra, ...p.allergies.map(a => `no ${a}`)].join(", ");
};
const bodyStatus = (): string => {
  const p = profile();
  if (!p.stated) return "not yet set";
  return `${p.sex === "F" ? "female" : "male"}, ${p.age}${p.stage === "pregnant" || p.stage === "lactating" ? ", " + p.stage : ""}`;
};
const whereStatus = (): string => {
  const s = locationSummary();
  return s.mode === "off" ? (home() ? `not shared — the plan uses your home, ${homeName()}` : "not shared, and no home registered yet")
    : s.place || s.modeName;
};
const housingStatus = (): string => dwelling().stated ? `home ${homeName() || "not registered"} · ${dwellingSummary()}` : "not yet set";
const timeStatus = (): string => {
  const p = profile();
  return p.days.length ? `${p.labourHours} h × ${p.days.length} days a week, credit read in ${currencyInForce()}` : "no day given yet";
};

// ── the checklist's rows ────────────────────────────────────────────────────

/** One row: what it is called, what it is about, and the real place it opens. */
interface Task {
  id: string;
  glyph: string;
  title: string;
  sub: () => string;
  /** Lit when the real data behind this row exists — never tracked apart from that data itself. */
  done: () => boolean;
  go: () => void;
  /** The real tray control this row's door opens behind — flown to and pulsed on tap, so the row teaches where it lives. Absent for identity, which has no other real place to go. */
  tray?: string;
}

const TASKS: Task[] = [
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
function pulseTray(target: string): void {
  const el = document.querySelector<HTMLElement>(target);
  if (!el) return;
  el.classList.remove("ob-ping");
  void el.offsetWidth;            // restart the animation if it's already mid-pulse
  el.classList.add("ob-ping");
  window.setTimeout(() => el.classList.remove("ob-ping"), 650);
}

function flyToTray(origin: HTMLElement, target: string, glyph: string): void {
  const to = document.querySelector<HTMLElement>(target);
  if (!to || window.matchMedia("(prefers-reduced-motion: reduce)").matches) { pulseTray(target); return; }
  const a = origin.getBoundingClientRect(), b = to.getBoundingClientRect();
  if (a.width === 0 || b.width === 0) { pulseTray(target); return; }
  const ax = a.left + a.width / 2, ay = a.top + a.height / 2;
  const dx = (b.left + b.width / 2) - ax, dy = (b.top + b.height / 2) - ay;
  const dot = document.createElement("span");
  dot.className = "ob-fly";
  dot.textContent = glyph;
  dot.style.left = `${ax}px`; dot.style.top = `${ay}px`;
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
const taskRow = (t: Task): Fragment => {
  const has = t.done();
  const seen = visited(t.id);
  const tap = (e: Event) => {
    keep({ visited: [...new Set([...(walk().visited ?? []), t.id])] });
    if (t.tray) { const ic = (e.currentTarget as HTMLElement).querySelector<HTMLElement>(".acct-ic"); if (ic) flyToTray(ic, t.tray, t.glyph); }
    t.go();
  };
  const cls = has && seen ? " on" : has ? " part" : "";
  return html`
    <button type="button" class="acct-row ob-row" onclick=${tap}>
      <span class="acct-ic">${t.glyph}</span>
      <span class="acct-tx"><span class="acct-l">${t.title}</span><span class="acct-s">${t.sub()}</span></span>
      <span class="ob-check${cls}" title="${has && seen ? "set" : has ? "set — open it to confirm" : "not yet set"}">${has && seen ? "✓" : ""}</span>
    </button>`;
};

// ── the identity row — expands in place; there is no other real place for it ──
// Made here rather than sent elsewhere: everything else in the list is kept on
// the device and needs no key, and creating one leads naturally into what
// creation reveals — the passcode, once, and the recovery file. The terms are
// read at this collection moment and again only when they change.
const identityOpen = signal(false);
const made = signal<{ aid: string; bran: string; saved: boolean; shown: boolean } | null>(null);
const consentTick = signal(false);
// Age is a stated floor, not a hard check (terms §8): the declaration must be
// an act, not buried text, so it is its own tick, required like the terms'.
// A parent or guardian ticking on a younger person's behalf reads the same
// sentence and is responsible for that choice (terms §8).
const ageTick = signal(false);
// Vote consent is OFFERED here (optional — see id.ts) and ENFORCED again at
// the first real cast, so skipping it costs nothing but a later ask.
const voteTick = signal(false);
const idSaid = signal("");
/** Leaving the page with an unsaved passcode destroys the only key: the browser's one hook. */
const guard = (e: BeforeUnloadEvent): void => { e.preventDefault(); e.returnValue = ""; };

async function create(): Promise<void> {
  if (!consentCurrent() && !consentTick.peek()) { idSaid.set("please read and accept the terms and the privacy notice first"); return; }
  if (!ageTick.peek()) { idSaid.set(`please confirm you are at least ${MIN_AGE}, or that a parent or guardian agrees on your behalf`); return; }
  idSaid.set("");
  const r = await createIdentity();
  if ("err" in r) { idSaid.set(r.err); return; }
  if (voteTick.peek()) recordVoteConsent(r.aid);
  window.addEventListener("beforeunload", guard);
  made.set({ ...r, saved: false, shown: false });
}

const identityBody = (): Fragment => {
  const me = identity();
  const st = identityState();
  const m = made();
  const held = st === "authed" || st === "unlocked" || st === "unregistered";
  if (m && !(held && me && me.aid !== m.aid)) return html`
    <p class="ob-state">identity created — this passcode is its only key, and this is the one time it is shown.</p>
    <div class="ob-field"><span>passcode (your key)</span>
      <div class="ob-pass"><input class="ob-code" type="${m.shown ? "text" : "password"}" readonly spellcheck="false" autocomplete="new-password" value="${m.bran}">
        <button class="ob-chip" onclick=${() => made.set({ ...m, shown: !m.shown })}>${m.shown ? "hide" : "show"}</button>
        <button class="ob-chip" onclick=${(e: Event) => { if (navigator.clipboard) navigator.clipboard.writeText(m.bran); (e.target as HTMLElement).textContent = "✓ copied"; }}>copy</button></div>
    </div>
    <div class="ob-field"><span>identifier (names you — not secret)</span>
      <div class="ob-pass"><input class="ob-code ob-aid" type="text" readonly spellcheck="false" autocomplete="username" value="${m.aid}">
        <button class="ob-chip" onclick=${(e: Event) => { if (navigator.clipboard) navigator.clipboard.writeText(m.aid); (e.target as HTMLElement).textContent = "✓ copied"; }}>copy</button></div>
      <small>keep it with your passcode — or take the recovery file, which holds both.</small></div>
    <button class="ob-next ob-wide" onclick=${() => downloadIdentityFile(m.aid, m.bran)}>⬇ download recovery file</button>
    <small class="ob-hint">the file holds the passcode and the identifier together with your identity's own signed log — it opens this identity on any device, and seats it at a commune that has never met you.</small>
    <label class="ob-tick"><input type="checkbox" ${m.saved ? "checked" : ""} onchange=${(e: Event) => { const on = (e.target as HTMLInputElement).checked; made.set({ ...m, saved: on }); if (on) window.removeEventListener("beforeunload", guard); else window.addEventListener("beforeunload", guard); }}><span>I've saved my passcode. I understand it cannot be shown again.</span></label>
    <label class="ob-field"><span>what should people call you?</span>
      <input type="text" autocomplete="nickname" placeholder="a name — optional, and changeable any time" onchange=${(e: Event) => setMyName((e.target as HTMLInputElement).value.trim(), "")}></label>`;
  if (held && me) return html`
    <p class="ob-state">you are in as <b>${me.name || "an unnamed identity"}</b>${st === "authed" ? " — seated at the commons" : st === "unregistered" ? " — this commune has not met you yet; tap your name to join" : " — unlocked on this device, no commune in reach"}</p>
    <small class="ob-hint">identifier ${me.aid}</small>
    <div class="ob-opts">${chip(false, "not me — use another identity", openIdentityDoor)}</div>`;
  const offline = !HANDLERS.signup;
  return html`
    <p class="ob-lead-s">Everything else in this list is kept on this device. An identity is what lets the commons hold it for you and act on it: a key of your own, made here, never sent anywhere.</p>
    ${consentCurrent() ? "" : html`<label class="ob-tick"><input type="checkbox" ${consentTick() ? "checked" : ""} onchange=${(e: Event) => consentTick.set((e.target as HTMLInputElement).checked)}><span>${CONSENT_SENTENCE.map(part => typeof part === "string" ? part : html`<a href="${part[1]}" target="_blank" rel="noopener" onclick=${(e: Event) => e.stopPropagation()}>${part[0]}</a>`)}</span></label>`}
    <label class="ob-tick"><input type="checkbox" ${ageTick() ? "checked" : ""} onchange=${(e: Event) => ageTick.set((e.target as HTMLInputElement).checked)}><span>I confirm I am at least ${MIN_AGE} years old, or that a parent or guardian agrees to this on my behalf.</span></label>
    <label class="ob-tick"><input type="checkbox" ${voteTick() ? "checked" : ""} onchange=${(e: Event) => voteTick.set((e.target as HTMLInputElement).checked)}><span>${VOTE_CONSENT_SENTENCE}</span></label>
    <small class="ob-hint">${ONLY_KEY_NOTE}</small>
    ${offline ? html`<p class="ob-state">no commons in reach right now — an identity can be made once one answers; everything else you said is kept here meanwhile</p>`
              : html`<button class="ob-next ob-wide" onclick=${create}>${st === "busy" ? "…" : "create my identity"}</button>`}
    ${idSaid() ? html`<p class="ob-err">${idSaid()}</p>` : ""}
    <div class="ob-opts">${chip(false, "I already have one — sign in", openIdentityDoor)}</div>`;
};

const identityRow = (): Fragment => {
  const me = identity();
  const open = identityOpen();
  return html`
    <button type="button" class="acct-row ob-row" onclick=${() => identityOpen.set(!open)}>
      <span class="acct-ic">🔑</span>
      <span class="acct-tx"><span class="acct-l">your identity</span>
        <span class="acct-s">${me ? (me.name || "an unnamed identity") : "one tap makes it; the passcode is yours alone"}</span></span>
      <span class="ob-check${me ? " on" : ""}" title="${me ? "made" : "not yet made"}">${me ? "✓" : ""}</span>
    </button>
    ${open ? html`<div class="ob-expand">${identityBody()}</div>` : ""}`;
};

// ── the frame ───────────────────────────────────────────────────────────────

let mounted = false;
/** The face switch, handed in — so this module never imports faces.ts. */
let go: (face: string) => void = () => {};
let stageEl: HTMLElement | null = null;

function finish(): void {
  keep({ done: true });
  go("map");
}

/** The wordmark, spelt in the same colours as the account sheet's header (.acct-mark). */
const wordmark = (): Fragment => html`<span class="acct-mark">${[..."playnet"].map(c => html`<span class="wm-${c}">${c}</span>`)}</span>`;

function draw(): void {
  if (!stageEl) return;
  const me = identity();
  const real = !!me;
  render(stageEl, html`
    <div class="acct-card ob-list">
      <div class="ob-intro">
        <h2 class="ob-brand">${wordmark()}</h2>
        <p>a plan for meeting each other's needs.</p>
        <p class="ob-mode ${real ? "real" : "demo"}">${real
          ? `playing for real${me.name ? ` as ${me.name}` : ""}`
          : "demo — your answers stay on this device until you make an identity"}</p>
        ${identity() ? "" : html`<div class="ob-opts">${chip(false, "I already have an identity — sign in", openIdentityDoor)}</div>`}
      </div>      <div class="acct-group">${identityRow()}</div>
      <div class="acct-group">${TASKS.map(taskRow)}</div>
      ${installBlock()}
      <button class="ob-next ob-wide ob-play" onclick=${finish}>${real ? "let's play! 🌱" : "try the demo — let's play! 🎲"}</button>
    </div>`);
}

/** Mount the checklist into #onboardstage (an existing face overlay, app.html) — the frame follows the profile's own signals so every row's status line stays live. */
export function initOnboard(setFace: (face: string) => void): void {
  go = setFace;
  if (mounted) { draw(); return; }
  mounted = true;
  stageEl = document.getElementById("onboardstage");
  // the climate is read off the position, never asked: a fix arriving — or a home registered — sets the region the geography layer reads
  effect(() => {
    const f = positionForFloors();
    if (!f) return;
    const r = regionForLat(f.lat);
    // elevation rides the fix when the device gives one; a fix without one leaves the stated figure alone
    const alt = f.alt != null && isFinite(f.alt) ? Math.round(f.alt) : profile.peek().altitudeM;
    if (profile.peek().region !== r || profile.peek().altitudeM !== alt) setProfile({ region: r, altitudeM: alt });
  });
  effect(draw);
}

/** Whether this device has opened the checklist once before — main.ts may land here when it has not. */
export const onboarded = (): boolean => walk().done;
