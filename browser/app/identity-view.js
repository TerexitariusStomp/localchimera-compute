// app/identity-view.ts — the identity card: the one place an identity is made,
// opened, joined and shown.
//
// The onboarding checklist and the account sheet both mount it, so creating an
// account, signing in, and reading who you are look and behave the same
// wherever you meet them. Which face it wears follows from where this device
// stands (the door state and what it remembers) and from one choice the person
// makes (create or sign in):
//
//   create   terms, age, the one-key note, one tap
//   signin   a passcode (+ optional identifier), a recovery file, friends' pieces
//   unlock   this device remembers an identity — its passcode opens it
//   join     the commune has never met the identity this device holds
//   unlocked unlocked here, with no commune to take a seat at
//   reveal   the passcode, shown once, and the recovery file
//   held     seated: who you are, the identifier, signing out
//   demo     no commune is configured for this page
//
// The card renders when its FACE changes, never when a field does: a status
// flip while a passcode is half typed leaves the field alone. Typed values are
// read off the DOM at submit; errors are written into the card's own line.
// The acts themselves live in tabs/social/id.ts; this file is only the look.
import { html, raw, render } from './template.js';
import { signal, effect } from './reactive.js';
import { HANDLERS } from './core.js';
import { MIN_AGE } from './legal-product.js';
import { holdPasscode } from './passcode-held.js';
import { identity, identityState, consentCurrent, consentRecord, createIdentity, downloadIdentityFile, setMyName, signIn, unlockHere, joinHere, recoverFromPieces, openIdentityFile, signOutDevice, recordVoteConsent, CONSENT_SENTENCE, ONLY_KEY_NOTE, VOTE_CONSENT_SENTENCE, } from './tabs/social/id.js';
/** The one choice the person makes while nobody is signed in: make an identity, or open one. */
const mode = signal("create");
/** A passcode made here and not yet saved — shown once, held until the person says it is kept. */
const made = signal(null);
/** The act of creating is in flight: the card keeps its face until the passcode is ready to show. */
const creating = signal(false);
// What the person has ticked. Read at the act, never drawn from: a tick does not re-render the card.
const consentOn = signal(false);
const ageOn = signal(false);
const voteOn = signal(false);
/** Ask to open an existing identity: the card shows the sign-in face while nobody is signed in. */
export const showSignIn = () => mode.set("signin");
/** Back to making an identity. */
export const showCreate = () => mode.set("create");
/** The face this device's standing calls for; "busy" means a submit is in flight, so keep the one on screen. */
function derive() {
    const m = made(), me = identity(), st = identityState();
    if (m && (!me || me.aid === m.aid))
        return "reveal";
    if (creating() || st === "busy")
        return "busy";
    if (st === "authed")
        return "held";
    if (st === "unlocked")
        return "unlocked";
    if (st === "unregistered")
        return "join";
    if (mode() === "signin")
        return "signin";
    if (me)
        return "unlock";
    if (st === "standalone")
        return "demo";
    return "create";
}
const view = signal("create");
effect(() => { const v = derive(); if (v !== "busy")
    view.set(v); });
const TITLES = {
    create: "create your identity", signin: "sign in", unlock: "unlock", join: "join your commune",
    unlocked: "your identity", reveal: "identity created", held: "your identity", demo: "the demo day",
};
/** What a page showing the card is called — a tracked read, so a header follows the face. */
export const identityCardTitle = () => TITLES[view()];
// ── small parts ─────────────────────────────────────────────────────────────
const cardOf = (e) => e.target.closest(".idc");
/** Say a thing on the card's own error line; an empty string clears it. */
function sayIn(card, msg) {
    const p = card?.querySelector(".ob-err");
    if (p) {
        p.textContent = msg;
        p.hidden = !msg;
    }
}
const errLine = () => html `<p class="ob-err" role="alert" hidden></p>`;
/** A button that works while its act is in flight and answers again after. */
async function whileBusy(btn, act) {
    if (btn)
        btn.disabled = true;
    try {
        await act();
    }
    finally {
        if (btn)
            btn.disabled = false;
    }
}
const copyChip = (text) => html `<button type="button" class="ob-chip" onclick=${(e) => {
    if (navigator.clipboard)
        void navigator.clipboard.writeText(text);
    const b = e.target;
    b.textContent = "✓ copied";
    setTimeout(() => { b.textContent = "copy"; }, 1500);
}}>copy</button>`;
/** The passcode, shown once: masked, with show and copy. Named `password` so a manager files it. */
const passField = (bran) => html `
  <div class="ob-field"><span>passcode (your key)</span>
    <div class="ob-pass"><input class="ob-code" type="password" name="password" readonly spellcheck="false" autocomplete="new-password" value="${bran}">
      <button type="button" class="ob-chip" onclick=${(e) => {
    const b = e.target, input = b.parentElement.querySelector("input");
    const showing = input.type === "text";
    input.type = showing ? "password" : "text";
    b.textContent = showing ? "show" : "hide";
}}>show</button>${copyChip(bran)}</div>
  </div>`;
/** The identifier, whole and copiable. It names the identity and is not secret. `asUsername` files the passcode under it. */
const idField = (aid, asUsername = false, note) => html `
  <div class="ob-field"><span>identifier (names you — not secret)</span>
    <div class="ob-pass"><input class="ob-code ob-aid" type="text" ${asUsername ? raw('name="username" autocomplete="username"') : ""} readonly spellcheck="false" aria-label="your identifier" value="${aid}">${copyChip(aid)}</div>
    ${note ? html `<small>${note}</small>` : ""}</div>`;
/**
 * The terms tick. Creating (or signing in on a browser that may never have
 * seen the notices) always asks; unlocking asks only when the notices changed
 * since this member accepted them (terms §11).
 */
function consentTick(force) {
    if (!force && consentCurrent())
        return "";
    return html `<label class="ob-tick"><input type="checkbox" name="consent" ${consentOn.peek() ? "checked" : ""} onchange=${(e) => consentOn.set(e.target.checked)}><span>${consentRecord() ? "the terms have changed — " : ""}${CONSENT_SENTENCE.map(part => typeof part === "string" ? part : html `<a href="${part[1]}" target="_blank" rel="noopener" onclick=${(e) => e.stopPropagation()}>${part[0]}</a>`)}</span></label>`;
}
const consentOk = (force) => (!force && consentCurrent()) || consentOn.peek();
const NEEDS_CONSENT = "please accept the terms and the privacy notice first";
const SHORT_PASSCODE = "the passcode needs 21+ characters";
// ── the faces ───────────────────────────────────────────────────────────────
function create(lead) {
    const offline = !HANDLERS.signup;
    const noCommune = identityState.peek() === "offline";
    const make = async (e) => {
        const card = cardOf(e), btn = e.currentTarget;
        if (!consentOk(true))
            return sayIn(card, NEEDS_CONSENT);
        if (!ageOn.peek())
            return sayIn(card, `please confirm you are at least ${MIN_AGE}, or that a parent or guardian agrees on your behalf`);
        sayIn(card, "");
        await whileBusy(btn, async () => {
            creating.set(true);
            const r = await createIdentity();
            if ("err" in r) {
                creating.set(false);
                sayIn(card, r.err);
                return;
            }
            if (voteOn.peek())
                recordVoteConsent(r.aid);
            holdPasscode(true);
            made.set(r); // the passcode is on screen before the card lets go of the face it had
            creating.set(false);
        });
    };
    return html `
    ${lead ?? html `<p class="ob-lead-s">a passcode is generated for you — it's your only key. The moment you create, you'll see it once, and can save a recovery file that opens this identity on any device.</p>`}
    ${noCommune ? html `<p class="ob-state">No commune is reachable right now — an identity needs none to be made. It is minted and kept on this device, and takes a seat at a commune the moment one is reachable.</p>` : ""}
    ${consentTick(true)}
    <label class="ob-tick"><input type="checkbox" name="age" ${ageOn.peek() ? "checked" : ""} onchange=${(e) => ageOn.set(e.target.checked)}><span>I confirm I am at least ${MIN_AGE} years old, or that a parent or guardian agrees to this on my behalf.</span></label>
    <label class="ob-tick"><input type="checkbox" name="vote" ${voteOn.peek() ? "checked" : ""} onchange=${(e) => voteOn.set(e.target.checked)}><span>${VOTE_CONSENT_SENTENCE}</span></label>
    <small class="ob-hint">${ONLY_KEY_NOTE}</small>
    ${errLine()}
    ${offline ? html `<p class="ob-state">no commons in reach right now — an identity can be made once one answers; everything else you said is kept here meanwhile</p>`
        : html `<button type="button" class="ob-next ob-wide" onclick=${make}>create my identity</button>`}
    <div class="ob-opts"><button type="button" class="ob-chip" onclick=${showSignIn}>I already have one — sign in</button></div>`;
}
/** One passcode form, for both doors: the identity this device remembers (`unlock`), or any other (`signin`). */
function passcodeForm(kind) {
    const me = identity.peek();
    const submit = async (e) => {
        e.preventDefault();
        const form = e.currentTarget, card = cardOf(e);
        const bran = form.elements.namedItem("password").value;
        if (!bran || bran.length < 21)
            return sayIn(card, SHORT_PASSCODE);
        if (!consentOk(kind === "signin"))
            return sayIn(card, NEEDS_CONSENT);
        sayIn(card, "");
        const typed = form.elements.namedItem("username").value.trim();
        await whileBusy(form.querySelector("[type=submit]"), async () => {
            // a typed identifier left empty goes as "": the spine then opens the identity the passcode itself names
            const s = kind === "unlock" ? await unlockHere(bran) : await signIn(bran, typed, "", ["", ""]);
            if ("err" in s)
                sayIn(card, s.err);
            else
                mode.set("create");
        });
    };
    return html `
    <form class="idc-form" autocomplete="on" action="#" onsubmit=${submit}>
      ${kind === "unlock"
        ? html `<input type="text" name="username" autocomplete="username" readonly tabindex="-1" aria-hidden="true" class="idc-hidden" value="${me ? me.aid : ""}">`
        : html `<label class="ob-field"><span>identifier <span class="ob-opt">optional</span></span>
            <input type="text" name="username" autocomplete="username" spellcheck="false" placeholder="a password manager fills it"></label>`}
      <label class="ob-field"><span>passcode</span>
        <input type="password" name="password" autocomplete="current-password" placeholder="passcode — 21+ characters"></label>
      ${consentTick(kind === "signin")}
      ${errLine()}
      <button type="submit" class="ob-next ob-wide">${kind === "unlock" ? "unlock" : "sign in"}</button>
    </form>`;
}
function signin() {
    const pick = (e) => {
        const input = e.target, card = cardOf(e), f = input.files?.[0];
        if (!f)
            return;
        void (async () => {
            const bad = await openIdentityFile(await f.text());
            if (bad)
                sayIn(card, bad);
            else
                mode.set("create");
        })();
    };
    const together = async (e) => {
        const card = cardOf(e), btn = e.currentTarget;
        const lines = (card.querySelector("textarea[name=pieces]")?.value ?? "")
            .split("\n").map(l => l.trim()).filter(Boolean);
        if (!lines.length)
            return sayIn(card, "paste the pieces your friends sent you");
        sayIn(card, "");
        await whileBusy(btn, async () => {
            const d = await recoverFromPieces(lines);
            if ("err" in d)
                sayIn(card, d.err);
            else
                mode.set("create");
        });
    };
    return html `
    <p class="ob-lead-s">your passcode opens your identity: a commune that has met you finds it from the passcode alone. Add your identifier if you have it — a password manager fills both.</p>
    ${passcodeForm("signin")}
    <div class="ob-field"><span>or open your recovery file</span>
      <small>the file holds your passcode and your identity's log — open it and you are in, at any commune.</small>
      <input type="file" accept=".json,application/json" class="idc-hidden" name="recovery-file" onchange=${pick}>
      <button type="button" class="ob-chip" onclick=${(e) => e.target.parentElement.querySelector("input[type=file]").click()}>open recovery file</button></div>
    <div class="ob-field"><span>or with help from people you trusted</span>
      <small>if you split your passcode among people, ask them for their pieces and paste them here — one per line.</small>
      <textarea name="pieces" rows="3" spellcheck="false" placeholder="pnr1.… (one piece per line)"></textarea>
      <button type="button" class="ob-chip" onclick=${together}>put my passcode back together</button></div>
    <div class="ob-opts"><button type="button" class="ob-chip" onclick=${showCreate}>← make a new identity instead</button></div>`;
}
function unlock() {
    const me = identity.peek();
    const noCommune = identityState.peek() === "offline";
    return html `
    <p class="ob-state">${me?.name ? html `<b>${me.name}</b> is` : "your identity is"} on this device${noCommune
        ? " — nothing can reach the commune right now. Your passcode still opens this identity here, against the log this device keeps, though the day on screen stays this device's own until the commune answers again."
        : " — its passcode opens it."}</p>
    ${passcodeForm("unlock")}
    ${me ? idField(me.aid) : ""}
    <div class="ob-opts"><button type="button" class="ob-chip" onclick=${showSignIn}>another way in — recovery file, friends' pieces, a different identity</button></div>`;
}
function join() {
    const me = identity.peek();
    const go = async (e) => {
        const card = cardOf(e), btn = e.currentTarget;
        // a browser that holds a current acceptance is not asked again to join: the
        // notice is re-read on a change of terms (§11), not on every seat
        if (!consentOk(false))
            return sayIn(card, NEEDS_CONSENT);
        sayIn(card, "");
        await whileBusy(btn, async () => {
            const s = await joinHere();
            if ("err" in s)
                sayIn(card, s.err);
        });
    };
    return html `
    <p class="ob-state">this commune hasn't met you. Your identity was made elsewhere and this commune has never seen it. Your log — every key event you've signed — is on this device, and that is all a commune needs to seat you under your current key.</p>
    ${me ? idField(me.aid) : ""}
    ${consentTick(false)}
    ${errLine()}
    <button type="button" class="ob-next ob-wide" onclick=${go}>join as ${me?.name || "you"}</button>
    ${signOutChip()}`;
}
function unlocked() {
    const me = identity.peek();
    return html `
    <p class="ob-state">you are unlocked as <b>${me?.name || "an unnamed identity"}</b>, but nothing can reach the commune right now — so sharing where you are, lending a means, and claiming are all unavailable, and the day on screen is this device's own rather than the commune's. Your seat is taken the moment the commune is reachable again.</p>
    ${me ? idField(me.aid) : ""}
    ${signOutChip()}`;
}
function held() {
    const me = identity.peek();
    return html `
    <p class="ob-state">you are in as <b>${me?.name || "an unnamed identity"}</b> — seated at the commons</p>
    ${me ? idField(me.aid) : ""}
    ${signOutChip()}`;
}
function demo() {
    return html `
    <p class="ob-state">No commune is configured for this page, so there is no door to sign in through. The cards, the plan and the dial are local samples you can play with freely; sharing where you are, lending a means, and claiming all need a commune to reach.</p>
    <small class="ob-hint">Running it yourself? <code>make dev</code> serves the dial against a real local gateway.</small>`;
}
/** Signing out forgets this device's copy of your log — so it asks twice. */
function signOutChip() {
    const tap = (e) => {
        const b = e.currentTarget;
        if (b.classList.contains("arm")) {
            void signOutDevice();
            return;
        }
        b.classList.add("arm");
        b.textContent = "sign out — tap again";
        setTimeout(() => { b.classList.remove("arm"); b.textContent = "sign out of this device"; }, 12000);
    };
    return html `<div class="ob-opts"><button type="button" class="ob-chip ob-out" onclick=${tap}>sign out of this device</button></div>
    <small class="ob-hint">your passcode brings you back; keep your recovery file or identifier somewhere safe first.</small>`;
}
/** The passcode, once — and the recovery file, and a name to go by. A real credential form, so a manager offers to keep it. */
function reveal() {
    const m = made.peek();
    const saved = (e) => {
        const on = e.target.checked;
        const done = cardOf(e).querySelector("[type=submit]");
        if (done)
            done.disabled = !on;
        holdPasscode(!on);
    };
    const finish = async (e) => {
        e.preventDefault();
        const form = e.currentTarget;
        if (!form.querySelector("input[name=saved]")?.checked)
            return; // Enter cannot slip past
        const n = form.querySelector("input[name=nickname]")?.value.trim();
        if (n)
            await setMyName(n, "");
        holdPasscode(false);
        made.set(null);
    };
    return html `
    <form class="idc-form" autocomplete="on" action="#" onsubmit=${finish}>
      <p class="ob-state">identity created — this passcode is its only key, and this is the one time it is shown.</p>
      ${passField(m.bran)}
      ${idField(m.aid, true, "keep it with your passcode — or take the recovery file, which holds both.")}
      <button type="button" class="ob-next ob-wide" onclick=${() => downloadIdentityFile(m.aid, m.bran)}>⬇ download recovery file</button>
      <small class="ob-hint">the file holds the passcode and the identifier together with your identity's own signed log — it opens this identity on any device, and seats it at a commune that has never met you.</small>
      <label class="ob-tick"><input type="checkbox" name="saved" onchange=${saved}><span>I've saved my passcode. I understand it cannot be shown again.</span></label>
      <label class="ob-field"><span>what should people call you?</span>
        <input type="text" name="nickname" autocomplete="nickname" spellcheck="false" placeholder="a name — optional, and changeable any time"
               onchange=${(e) => { void setMyName(e.target.value.trim(), ""); }}>
        <small>please do not use your legal name — this is an early-stage demo; a nickname is fine.</small></label>
      <button type="submit" class="ob-next ob-wide" disabled>done</button>
    </form>`;
}
// ── the card ────────────────────────────────────────────────────────────────
/**
 * The identity card, as one element that follows the door. `lead` replaces the
 * sentence above the create face (the onboarding checklist says why it asks).
 * Mounting it twice is fine — the choice and the ticks are the module's, so
 * both cards stay in step.
 */
export function identityCard(opts = {}) {
    const el = document.createElement("div");
    el.className = "idc ob-expand";
    const dispose = effect(() => {
        const v = view();
        el.dataset.view = v;
        // the body reads signals with peek(): only the face's change redraws it
        render(el, v === "create" ? create(opts.lead) : v === "signin" ? signin() : v === "unlock" ? unlock()
            : v === "join" ? join() : v === "unlocked" ? unlocked() : v === "reveal" ? reveal() : v === "held" ? held() : demo());
    });
    return { el, dispose };
}
