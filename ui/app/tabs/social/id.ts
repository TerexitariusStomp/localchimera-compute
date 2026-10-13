// app/tabs/id.ts — identity: the door into the plan.
//
// Panel subsystem: the KERI id chip, the acts a sign-in surface performs
// (signup, unlock, join, recovery — app/identity-view.ts draws them), the
// identity file download, personhood (fp*) vouching, and the settings sections
// for keys, devices and recovery. Registers
// seam.status (day-boot reports gateway state through it). Talks to
// the gateway only through HANDLERS (signup/unlock/profile*/fp*) at call
// time; reads pending()/proposals/contacts and calls settle()/hint() from
// core — all runtime, so the main.js <-> id.js import cycle is benign.
import { HANDLERS, hint } from '../../core.js';
import { book, byAid, recoveryPicks, toggleRecoveryPick } from '../../contact-book.js';
import { revealContacts } from './share.js';
import { locationDoor, locationOff, locationResume } from './location.js';
import { readStr, writeStr, forget, readJSON, writeJSON } from '../../store.js';
import { signal, effect } from '../../reactive.js';
import { ensurePersistent } from '../../storage-health.js';
import { openSettings, closeSettings } from '../../settings.js';
import { LEGAL_VERSION, DOCUMENT_VERSION, TERMS_HREF, PRIVACY_HREF } from '../../legal-product.js';

import { on } from '../../bus.js';
import { K } from "../../keys.js";
// ── identity: the door into the plan ───────────────────────────────────
// day-boot.js reports gateway state through seam.status and
// supplies HANDLERS.signup / HANDLERS.unlock; the page owns the look.
// Standalone (no spine at all) the row stays empty — the demo day needs
// no door. The hint (aid|name|email|k0) lives in localStorage; the
// passcode never does — it IS the key.
type IdState = "standalone" | "offline" | "connecting" | "idle" | "busy"
             | "unlocked" | "unregistered" | "authed";
/**
 * passcodeSection and forgetSection keep their checkbox counters ON THEMSELVES,
 * so every gate they build gets a unique id without a module-level variable.
 * Naming the shape is what lets that stay written the way it is.
 */
type Counted = { _n?: number };

/** What this device remembers about you, unpacked from one storage line. */
interface IdHint { aid: string; name: string; email: string; k0: string }

const idHint = (): IdHint | null => {
  const h = readStr(K.idHint);
  if (!h) return null;
  const [aid, name, email, k0] = h.split("|");
  return { aid, name, email, k0: k0 || "" };
};

/**
 * Where this device stands, as SIGNALS. The chip is an effect over them (see
 * drawChip), so nothing pokes it: set the state and the corner catches up on
 * the next microtask, coalescing a burst of writes into one paint.
 *
 *   idState  the door — the gateway connection, read from the spine's report
 *   who      what this device remembers about you; the chip says its name
 *   person   whether the commune recognises you. A TRISTATE: null is "not
 *            asked yet / could not ask", which the sheet draws differently
 *            from a plain no. The chip does not read it — standing lives one
 *            tap away, under keys and devices.
 */
const idState = signal<IdState>("standalone");
const who = signal<IdHint | null>(idHint());
const person = signal<boolean | null>(null);
/** Whether this commune recognises you as a person; null while unread. A tracked read. */
export const recognised = (): boolean | null => person();
/** Ask the commune again whether it recognises you — recognition arrives while the page is open. */
export function rereadStanding(): void {
  if (!HANDLERS.fpStatus) return;
  HANDLERS.fpStatus().then(j => { try { person.set(!!JSON.parse(j as string).person); } catch (_) { /* unread stays unread */ } });
}

/**
 * Write what this device remembers about you: storage and chip in one move, so
 * they cannot drift. The passcode is never part of it — it IS the key, and it
 * lives only in the vat for as long as a tab is open.
 */
function remember(h: IdHint): void {
  writeStr(K.idHint, `${h.aid}|${h.name}|${h.email}|${h.k0}`);
  who.set(h);
  // an identity now lives on this device: ask the browser to keep its storage
  void ensurePersistent();
}

// What this device remembers is now held in a signal rather than re-read on
// every paint, so ANOTHER TAB signing out (or in, or renaming) has to be able
// to say so: the storage event fires in every other tab, and a null key is the
// clear(). Without this the corner would go on naming someone who has left.
window.addEventListener("storage", e => {
  if (e.key === null || e.key === K.idHint) who.set(idHint());
});

/**
 * What to call you. Your display name if you have set one, else a standing-in
 * "you" — every surface that says your name says it through here, so an
 * unnamed identity reads the same way everywhere and there is one place to
 * change what that reads.
 */
const myName = (h: IdHint | null): string => (h && h.name) || "you";

/** The name the lip and any other chrome wears — a live read of `who`. */
export const displayName = (): string => myName(who());

/**
 * The spine's report, read as a door state.
 *
 * Unlocking and taking a seat are two acts. The passcode against the log this
 * device holds opens the identity with no commune in the loop; the seat is the
 * challenge at a reachable gateway. So three reports carry an identity:
 *   ok:<aid>            seated — authed
 *   local:<aid>         unlocked, no commune reachable — the cached day
 *   unregistered:<aid>  unlocked, this commune has never seen the AID — join
 * An unlocked identity stays unlocked through a door shutting: it is still
 * you, with nowhere to sit. CONNECTING IS NOT AWAY: the chip saying "no
 * commune here" while one is being found would assert there is none.
 * Everything that genuinely means the door is shut lands on offline:
 * no-gateway, any error:…, and anything unrecognised.
 */
const HOLDS_IDENTITY = (st: IdState) =>
  st === "authed" || st === "unlocked" || st === "unregistered";
on("status", (s: string) => {
  // a seat taken with the passcode (the spine reports it once the session
  // cap is in hand) authorizes this device's own key, so the next load
  // needs no passcode; a device's own seat has nothing to enrol
  if (s.startsWith("ok:") && HANDLERS.tier)
    HANDLERS.tier().then(t => { if (t === "root") autoEnrollDevice(); });
  if (s.startsWith("ok:")) syncName();
  const held = idState.peek();
  idState.set(
    s.startsWith("ok:")           ? "authed" :
    s.startsWith("local:")        ? "unlocked" :
    s.startsWith("unregistered:") ? "unregistered" :
    s === "connected"   ? (HOLDS_IDENTITY(held) ? held : "idle") :
    s === "connecting"  ? (HOLDS_IDENTITY(held) ? held : "connecting") :
    HOLDS_IDENTITY(held) ? "unlocked" : "offline");
});
/**
 * The device key signed in on its own (day-boot, at connect). A seat is a
 * seat; a refusal that names the authorization — revoked from another device,
 * or unknown to this commune — retires the key here too, so the next sign-in
 * is the passcode's and can authorize afresh. Any other refusal (the touch
 * was declined, the gateway hiccuped) leaves the key for a retry from keys and devices.
 */
const DEVICE_WIRE = K.deviceWire;
/** the persona's mesh seed, sealed under this device's seal key (the spine writes it at enrolment) */
const DEVICE_MESH = K.deviceMesh;
/** an authorization whose key this browser no longer holds, kept until a root seat retires it */
const DEVICE_STALE = K.deviceStale;
async function forgetDeviceHere(): Promise<void> {
  forget(DEVICE_WIRE);
  forget(DEVICE_MESH);
  if (HANDLERS.deviceForget) await HANDLERS.deviceForget();
}
on("deviceUnlock", (r: string) => {
  if (r.startsWith("ok:") || r.startsWith("local:") || r.startsWith("unregistered:")) {
    settleAuth(r, null, null);
    return;
  }
  // The browser cleared its key store under the record: the authorization
  // names a key nobody holds. The record goes, so the next passcode seat
  // authorizes a fresh key, and that seat retires the orphaned authorization.
  if (/missing from this browser/.test(r)) {
    const said = deviceSaidHere();
    if (said) writeStr(DEVICE_STALE, said);
    forgetDeviceHere().then(() => hint("this browser lost its device key — sign in with your passcode", "warn"));
    return;
  }
  if (/revoked|expired|not enrolled|unreadable/.test(r)) {
    forgetDeviceHere().then(() => hint("this device was signed out — sign in with your passcode", "warn"));
  }
});
/** the SAID of this device's own authorization, from the wire it keeps */
function deviceSaidHere(): string | null {
  try { const w = readStr(DEVICE_WIRE); return w ? (JSON.parse(w).said || null) : null; }
  catch { return null; }
}
/**
 * Stay signed in on this device. The software tier needs no gesture, so a
 * passcode sign-in enrols it on its own unless the person has said no here
 * before; the hardware tier (a passkey touch) is chosen under keys and devices.
 */
const DECLINED = K.deviceDeclined;
let enrolling = false;
async function autoEnrollDevice(): Promise<void> {
  if (enrolling) return;
  if (!HANDLERS.enrollDevice || !HANDLERS.deviceTiers) return;
  // a device key is HERE when both halves are: the key's record and the
  // root's authorization. One half alone signs nothing in — it is cleared,
  // and this seat authorizes afresh.
  const keyHere = !!(HANDLERS.deviceKeyHere && HANDLERS.deviceKeyHere());
  const wireHere = !!readStr(DEVICE_WIRE);
  if (keyHere && wireHere) return;
  if (readStr(DECLINED) === "1") return;
  const t = await HANDLERS.deviceTiers();
  if (!t.software) return;
  enrolling = true;
  try {
    if (keyHere || wireHere) await forgetDeviceHere();
    const stale = readStr(DEVICE_STALE);
    if (stale) {
      try { if (HANDLERS.revokeDevice) await HANDLERS.revokeDevice(stale); } catch (_) { /* the list in settings still retires it */ }
      forget(DEVICE_STALE);
    }
    const r = await HANDLERS.enrollDevice(deviceLabel(), "software");
    if (r === "ok") hint("staying signed in on this device — settings has the switch", "success");
    // "sign in first" is create's early reply — its seat report enrols
    else if (!/sign in first/.test(String(r))) console.warn("[id] device enrolment:", r);
  } finally { enrolling = false; }
}
function deviceLabel(): string {
  const ua = navigator.userAgent;
  const os = /Android/.test(ua) ? "Android" : /iPhone|iPad/.test(ua) ? "iOS"
           : /Mac/.test(ua) ? "Mac" : /Windows/.test(ua) ? "Windows" : /Linux/.test(ua) ? "Linux" : "device";
  const br = /Firefox/.test(ua) ? "Firefox" : /Edg\//.test(ua) ? "Edge" : /Chrom/.test(ua) ? "Chrome"
           : /Safari/.test(ua) ? "Safari" : "browser";
  return `${br} on ${os}`;
}

/**
 * How each door state shows itself in the corner. A tap opens the account
 * sheet (app/account.ts); its identity card says the rest.
 *
 * THE CORNER IS A GLANCE, NOT A SENTENCE. A dot carries the connection —
 * seated, holding an identity with nowhere to sit, reaching, shut — and the
 * words beside it are your name and nothing else. "— the commune is
 * unreachable" as a label grew the pill until it sat on top of the header's
 * own controls, and it told someone at a glance what they can only act on in
 * the sheet. So the sentence moved: `title` says it on hover, the identity
 * card says it in full, and the chip stays the size of a name.
 *
 * ONE ROW PER STATE. `label` is a function because three states name you and
 * three read differently with no identity stored here. An `inert` state is one
 * where tapping means nothing (we are mid-flight), and it mounts no location
 * chip either.
 */
type Dot = "live" | "warn" | "wait" | "idle" | "off";
interface ChipFace {
  /** what the chip says: your name, or the act to take when there is none */
  label: (h: IdHint | null) => string;
  /** the status light */
  dot: Dot;
  /** the sentence the dot stands for, on hover */
  title: string;
  /** a submit is in flight: a tap has nothing to open */
  inert?: boolean;
  /** extra class on .who — "on" is seated, "off" is no commune to reach */
  cls?: string;
}
// STANDALONE is the only true dead end: no spine at all (the docs copy, a wasm
// that never booted), so nothing can be made here and the chip says so.
const STANDALONE_FACE: ChipFace = {
  cls: "off", dot: "off",
  label: () => "demo day",
  title: "No commune is configured for this page — the dial is a local sample.",
};
// OFFLINE is not a dead end. An identity is minted and unlocked entirely on
// this device, so the corner offers the SAME act it would with a commune in
// reach — telling someone who has not signed in that infrastructure is
// missing tells them nothing they can act on. That the commune is unreachable
// is said once they are in, when it starts to matter.
const OFFLINE_FACE: ChipFace = {
  cls: "off", dot: "idle",
  label: h => h ? myName(h) : "create your identity",
  title: "Sign in — your passcode opens this identity on this device.",
};
const CHIP: Record<IdState, ChipFace> = {
  // The header says your NAME and nothing else. Your AID in full and your
  // personhood standing — with what to do about either — live one tap away.
  authed:       { cls: "on", dot: "live", label: h => myName(h),
                  title: "Signed in, and seated at this commune." },
  unlocked:     { dot: "warn", label: h => myName(h),
                  title: "Unlocked on this device — the commune is unreachable." },
  unregistered: { dot: "warn", label: h => myName(h),
                  title: "This commune has not met you yet — tap to join." },
  // reaching one is neither open nor away, and saying so beats claiming there
  // is no commune while the wasm is still finding it. NOT inert: unlocking
  // and creating are entirely local acts, and a connect that hangs (a stale
  // sref in an old tab, a gateway mid-restart) must never lock a person out
  // of the door — that is exactly when they go looking for it.
  connecting:   { dot: "wait", label: h => h ? myName(h) : "…",
                  title: "Reaching the commune… tap to sign in meanwhile." },
  // busy is ours, not the network's: a submit already in flight, over in a
  // beat — the one state where a tap genuinely has nothing to open.
  busy:         { dot: "wait", label: () => "…", title: "A moment…", inert: true },
  idle:         { dot: "idle", label: h => h ? myName(h) : "create your identity",
                  title: "Sign in to this commune." },
  offline:      OFFLINE_FACE,
  standalone:   STANDALONE_FACE,
};

function drawChip(): void {
  const el = d3.select("#idrow");
  el.selectAll("*").remove();
  // sharing a position needs an open door: the spine writes it against the
  // session AID, so the chip lives and dies with the identity chip beside it.
  const state = idState(), h = who();
  if (state !== "authed") locationOff();
  const face = CHIP[state];
  const chip = el.append("span")
    .attr("class", "who" + (face.cls ? " " + face.cls : ""))
    .attr("title", face.title + " — " + face.label(h))
    .attr("role", "button").attr("aria-label", face.label(h));
  // a round user icon (CSS ::before) wearing the status dot; the name stays in
  // the DOM, read aloud and on hover, and drawn nowhere
  chip.append("span").attr("class", "dot " + face.dot);
  chip.append("span").attr("class", "lbl").text(face.label(h));
  // Sharing a position lives in the bottom bar's location popover; this door
  // tells it whether the session can act (setPositionHere writes against the
  // session AID) and, when it cannot, where "sign in first" leads: the
  // identity card.
  const authed = state === "authed";
  // a tap on the person button opens the account sheet (app/account.ts); a
  // passcode shown once and not yet saved is where that sheet reopens
  if (!face.inert) chip.on("click", () => { if (accountDoor) accountDoor(); });
  locationDoor(authed, !authed && !face.inert ? openIdentityDoor : null);
  if (authed) locationResume();
}

// effect() runs its body once, now, and then on every change to a signal it
// read. That first run is what draws the corner on load: the spine calls
// seam.status when it has news, and STANDALONE it never has any — no
// gateway configured, or a wasm that never booted — so without this the row
// would sit empty. The initial state is truthful (no door open yet).
effect(drawChip);

/**
 * Your identifier, whole and copiable: a read-only field and the tap that
 * copies it. It names your identity and is not secret — the passcode is the
 * key. `asUsername` makes it the username a password manager files the
 * passcode under.
 */
function identifierRow(f: d3.Selection, aid: string, asUsername = false): void {
  const inp = f.append("input").attr("class", "aidfield").attr("type", "text")
    .attr("readonly", true).attr("spellcheck", "false").attr("aria-label", "your identifier")
    .property("value", aid);
  if (asUsername) inp.attr("name", "username").attr("autocomplete", "username");
  inp.on("focus", function () { (this as HTMLInputElement).select(); });
  f.append("div").attr("class", "genrow")
   .append("span").attr("class", "gen2").text("copy identifier").on("click", function () {
     if (navigator.clipboard) navigator.clipboard.writeText(aid);
     const t = d3.select(this); t.text("✓ copied"); setTimeout(() => t.text("copy identifier"), 1500);
   });
}

// ── signing out ────────────────────────────────────────────────────────
// The HINT (aid|name|email|k0) and the KEL (this identity's own signed log)
// are local; the passcode never was. Signing out forgets both — which is
// why it asks twice and shows the identifier first: the passcode alone comes
// back at a commune that holds this identity's log, and anywhere else the
// way back also needs the identifier or the recovery file.
/** Forget this device's identity — its device key, the copy of the log, the vouches — and reload. */
export async function signOutDevice(): Promise<void> {
  const said = deviceSaidHere();
  if (said && HANDLERS.revokeDevice) { try { await HANDLERS.revokeDevice(said); } catch (_) {} }
  await forgetDeviceHere();
  forget(K.idHint);
  forget(K.idKel);
  forget(K.idPhc);
  forget(VOUCHES_KEY);
  forget(NAME_PENDING);
  forget(DEVICE_STALE);
  location.reload();
}
// pull personhood standing from the gateway into the `person` signal. The
// chip does not read it — standing lives under keys and devices — so this settles the
// signal and schedules the poll, and draws nothing itself.
async function refreshPersonhood(): Promise<void> {
  if (!HANDLERS.fpStatus) { person.set(null); return; }
  let recognised = false;
  try { recognised = !!JSON.parse(await HANDLERS.fpStatus() as string).person; }
  catch (_) { person.set(null); return; }
  // not recognised here, but we carry a PHC from another gateway? present it
  // (the gateway verifies the issuer's signature + that it's a federated
  // commune, then imports — PHC presentation, slice-2).
  if (!recognised && HANDLERS.fpPresent) {
    const carried = readStr(K.idPhc);
    if (carried && carried.startsWith("{")) {
      try {
        if ((await HANDLERS.fpPresent(carried)) === "ok")
          recognised = !!JSON.parse(await HANDLERS.fpStatus!() as string).person;
      } catch (_) {}
    }
  }
  // the vouches we carry — for us and by us, with what makes them checkable
  // — are presented once per session wherever we are, recognised or not:
  // Alice's word for Tia counts at a commune whose store never held it
  await presentCarriedVouches();
  const wasCollecting = ask.peek()?.state === "collecting";
  person.set(recognised);
  // recognised → carry our PHC so the next gateway can recognise us too
  if (recognised && HANDLERS.fpMyPhc) {
    try { const card = await HANDLERS.fpMyPhc();
          if (typeof card === "string" && card.startsWith("{"))
            writeStr(K.idPhc, card); }
    catch (_) {}
  }
  await carryVouches();
  if (recognised) {
    if (wasCollecting) hint("you've been recognised — welcome.", "success");
    ask.set({ state: "finalized", count: 0, quorum: 0, witnesses: [], vouchers: [] });
  } else {
    await refreshAsk();
  }
  scheduleFpPoll();
}
/**
 * The bundle beside the PHC: the vouches for and by you, each voucher's
 * personhood, and the key logs a gateway that never saw them needs. Refreshed
 * whenever a gateway knows you; presented once per session to any gateway,
 * so what was spoken about you elsewhere counts here.
 */
const VOUCHES_KEY = K.idVouches;
let vouchesPresented = "";
async function carryVouches(): Promise<void> {
  if (!HANDLERS.fpMyVouches) return;
  try {
    const b = await HANDLERS.fpMyVouches();
    if (typeof b === "string" && b.startsWith("{")) writeStr(VOUCHES_KEY, b);
  } catch (_) {}
}
async function presentCarriedVouches(): Promise<void> {
  if (!HANDLERS.fpPresentBundle) return;
  const carried = readStr(VOUCHES_KEY);
  if (!carried || !carried.startsWith("{") || carried === vouchesPresented) return;
  try {
    const r = await HANDLERS.fpPresentBundle(carried);
    if (typeof r === "string" && r.startsWith("ok:")) vouchesPresented = carried;
  } catch (_) {}
}

/**
 * Your own ask, read from the ceremony — the same on every device. `null` is
 * "not read yet"; "none" is no ask standing; "collecting" carries n of k and
 * who already signed or vouches.
 */
export interface Ask { state: "none" | "collecting" | "finalized"; count: number; quorum: number;
                witnesses: string[]; vouchers: string[] }
export const ask = signal<Ask | null>(null);
async function refreshAsk(): Promise<void> {
  if (!HANDLERS.fpMyCeremony) { ask.set(null); return; }
  try {
    const o = JSON.parse(await HANDLERS.fpMyCeremony() as string);
    ask.set({ state: o.state === "collecting" ? "collecting" : o.state === "finalized" ? "finalized" : "none",
              count: Number(o.count) || 0, quorum: Number(o.quorum) || 0,
              witnesses: Array.isArray(o.witnesses) ? o.witnesses : [],
              vouchers: Array.isArray(o.vouchers) ? o.vouchers : [] });
  } catch (_) { ask.set(null); }
}
// while an ask is collecting, re-read it so the recognition block's "n of k" and the badge
// follow each vouch as it lands, and flip to recognised the moment the
// credential issues — the ceremony is the truth, nothing on this device is
let _fpPoll: ReturnType<typeof setTimeout> | null = null;
function scheduleFpPoll(): void {
  if (_fpPoll) { clearTimeout(_fpPoll); _fpPoll = null; }
  if (person.peek() === false && ask.peek()?.state === "collecting")
    _fpPoll = setTimeout(refreshPersonhood, 30000);
}
/** How the quorum reads as a sentence — the recovery-friends idiom, one tap away. */
export function askSaying(a: Ask): string {
  const need = a.quorum, have = a.count;
  const who = (n: number) => n === 1 ? "one recognised person" : `${n} recognised people`;
  if (have >= need) return "enough people have signed — your credential is being issued.";
  const left = need - have;
  return have === 0
    ? `${who(need)} must sign that they have met you.`
    : `${have} of ${need} have signed — ${who(left)} more must sign that they have met you.`;
}
// ── recognition: the acts a standing surface performs ───────────────────
/** What the commune says of you as a person, with the credential this device carries. */
export interface Standing {
  person: boolean;
  /** whether anyone at all is recognised here yet — before the first, the founder's act makes the first person */
  bootstrapped: boolean;
  /** whether this seat may make the first person */
  governor: boolean;
  /** the personhood credential carried from another gateway: its SAID and issuer */
  carried: { d: string; i: string } | null;
  /** your own ask, read from the ceremony (never set once recognised) */
  ask: Ask | null;
}
/** Read where you stand from the commune; null when it cannot be asked. */
export async function readStanding(): Promise<Standing | null> {
  if (!HANDLERS.fpStatus) return null;
  try {
    const o = JSON.parse(await HANDLERS.fpStatus() as string);
    person.set(!!o.person);
    let carried: Standing["carried"] = null;
    if (o.person) {
      const phc = readStr(K.idPhc);
      if (phc) { try { const c = JSON.parse(phc); carried = { d: c.d || "", i: c.i || "" }; } catch (_) {} }
    } else {
      // your standing, read from the ceremony itself — the same on every
      // device: no ask, or an ask collecting its n of k
      await refreshAsk();
      if (ask.peek()?.state === "collecting") scheduleFpPoll();
    }
    return { person: !!o.person, bootstrapped: !!o.bootstrapped, governor: !!o.governor, carried,
             ask: o.person ? null : ask.peek() };
  } catch (_) { return null; }
}
/** What an act came to: whether it landed, and a sentence to say so. */
export interface Done { ok: boolean; said: string }
/** Ask the recognised members to sign that they have met you. */
export async function requestRecognition(): Promise<Done> {
  const r = await (HANDLERS.fpEnroll ? HANDLERS.fpEnroll() : "err:offline");
  if (r === "ok") { await refreshAsk(); scheduleFpPoll(); }
  const a = ask.peek();
  return r === "ok"
    ? { ok: true, said: `✓ asked — ${a?.state === "collecting" ? askSaying(a) : "recognised people will see it"}` }
    : { ok: false, said: String(r || "err").replace(/^err:/, "") };
}
/** The founder's genesis act: recognise yourself as the first person. */
export async function recogniseMyself(): Promise<Done> {
  const aid = who.peek()?.aid;
  if (!aid || !HANDLERS.fpGrant) return { ok: false, said: "offline" };
  const r = await HANDLERS.fpGrant(aid);
  if (r === "ok") refreshPersonhood();
  return r === "ok" ? { ok: true, said: "✓ recognised" } : { ok: false, said: String(r || "err").replace(/^err:/, "") };
}
/** A newcomer's ceremony, as the recognised see it: who asks, how many have signed of how many. */
export interface PendingAsk { said: string; candidate: string; count: number; quorum: number; vouchers: string[] }
/** The asks from people outside your contacts, for a RECOGNISED member — the ones who can answer them. Someone in your book carries their ask on their own Contacts row. */
export async function pendingAsks(): Promise<PendingAsk[]> {
  if (!HANDLERS.fpPending || person.peek() !== true) return [];
  try {
    const all = JSON.parse(await HANDLERS.fpPending() as string);
    return Array.isArray(all) ? all.filter((row: PendingAsk) => !byAid(row.candidate)) : [];
  } catch (_) { return []; }
}
/** Sign that you have met a newcomer — your signature becomes an edge on their credential. */
export async function witness(said: string): Promise<Done> {
  const reply = await (HANDLERS.witnessAttest ? HANDLERS.witnessAttest(said) : "err:offline");
  const ok = typeof reply === "string" && reply.startsWith("ok:");
  return ok ? { ok, said: reply === "ok:finalized" ? "✓ recognised" : "✓ signed" }
            : { ok, said: String(reply || "err").replace(/^err:/, "") };
}
// ── consent (terms + privacy notice) ───────────────────────────────────
// Article 13 GDPR wants the notice AT COLLECTION, and the terms are worth
// nothing as a liability shield unless acceptance is an affirmative act. So
// the create button is GATED on a ticked box, not on a "by continuing you
// agree" line. LEGAL_VERSION is the product's own (legal-product.ts, from
// knowledge/product-law.scm): raise it there whenever browser/terms.html or
// browser/privacy.html change materially, and a stored acceptance of an older
// version stops counting — the box comes back on the next sign-in.
//
// Where the record lives. Today it is local only — {v, at} in localStorage.
// That proves nothing to a regulator (Art 7(1) wants the CONTROLLER able to
// demonstrate consent) and it is deliberately not oversold: the durable form
// is a self-issued acceptance credential presented over IPEX, the same shape
// as the contact-point credential in governance/credentials.scm. Until that
// exists, the honest claim is "the user was shown the notice and had to tick
// a box", which is exactly what this enforces.
/** The consent sentence, as words and links — said the same wherever a member
 *  is asked: a string is text, a pair is [label, href]. */
export const CONSENT_SENTENCE: (string | [string, string])[] =
  ["I've read and accept the ", ["terms of use", TERMS_HREF], " and the ", ["privacy notice", PRIVACY_HREF], "."];
/** The one irreversible consequence, said at the point of decision. */
export const ONLY_KEY_NOTE = "your passcode is the only key: nobody can reset it for you.";

/** "this browser accepted version V on date D", as it sits in the store. */
interface Consent { v: string; at: string; aid: string; }
const consentRecord = (): Consent | null =>
  readJSON<Consent | null>(K.idConsent, null);
const consentCurrent = () => {
  const c = consentRecord();
  return !!(c && c.v === LEGAL_VERSION);
};
// Idempotent by design: the record means "this browser accepted version V on
// date D", so a later sign-in that was NOT asked again (because V is current)
// must not overwrite D with today. Only a fresh acceptance writes.
const recordConsent = (aid: string) => {
  if (consentCurrent()) return;
  // storage disabled loses the record, never the gate — the tick already
  // stopped the action it was in front of
  writeJSON(K.idConsent,
            { v: LEGAL_VERSION, at: new Date().toISOString(), aid: aid || "" });
};
// ── explicit consent to record a political opinion (Art 9(2)(a)) ─────────
// How you vote is recorded against your identity and read by the tallying
// scope (privacy notice §3.1). The notice's basis there is Art 9(2)(d), open
// only to an operator that IS a body with a political, philosophical,
// religious or trade-union aim — a legal-structure decision not yet made
// (docs/legal/operator.md §10 row 7). Until it is, (a) is the fallback:
// explicit, specific consent, asked separately from the general terms tick so
// it is not bundled into a condition of having an identity at all — voting is
// optional, so consenting to its one special-category fact must be too.
// Collected here (offered once, at the same moment the terms are) AND
// enforced again at the first real cast (governance.ts), which covers an
// identity made before this ask existed, or a tick left unchecked.
export const VOTE_CONSENT_SENTENCE =
  "I agree that how I vote on a federation proposal is recorded against my identity, and read by whoever tallies it (privacy notice §3.1). You can vote without agreeing now — you will be asked again the first time you cast one.";
interface VoteConsent { aid: string; at: string; }
export const voteConsentGiven = (aid: string): boolean => {
  const c = readJSON<VoteConsent | null>(K.voteConsent, null);
  return !!(aid && c && c.aid === aid);
};
export const recordVoteConsent = (aid: string): void => {
  if (!aid || voteConsentGiven(aid)) return;
  writeJSON(K.voteConsent, { aid, at: new Date().toISOString() });
};
// Withdrawal has to be as easy as giving it (Art 7(3)): one settings toggle,
// no contact form. Only clears THIS identity's record — a device that has
// used more than one identity never touches the other's.
export const forgetVoteConsent = (aid: string): void => {
  if (aid && voteConsentGiven(aid)) forget(K.voteConsent);
};

// a strong passcode: 120 bits from an unambiguous alphabet (no 0/o/1/l),
// hyphen-grouped so it is copyable. It is the ONLY key — no recovery.
function genPasscode(): string {
  const A = "abcdefghijkmnpqrstuvwxyz23456789";   // 32 chars
  const b = crypto.getRandomValues(new Uint8Array(24));
  let s = "";
  for (let i = 0; i < 24; i++) { s += A[b[i] & 31]; if (i % 6 === 5 && i < 23) s += "-"; }
  return s;
}
/** What a settled auth reply came to: the identity it carries, or the words for a refusal. */
export type Settled = { aid: string; k0: string } | { err: string };

/**
 * Settle an auth / signup / join reply — the one place a door swings open.
 *
 * Everything that follows a success follows it HERE: remember the identity if
 * this reply carries new details, move the door state, and record the
 * acceptance the gate collected. What the surface does next (close a sheet,
 * reveal the passcode, show the error inline) is the caller's. nameToStore /
 * emailToStore are null on an unlock — the hint already exists and the reply
 * carries nothing newer.
 */
function settleAuth(r: unknown, nameToStore: string | null, emailToStore: string | null): Settled {
  // the three replies that carry an identity (see seam.status): seated,
  // unlocked with no commune reachable, unlocked at a commune that never saw it
  const carried = typeof r === "string"
    ? (r.startsWith("ok:") ? "authed" : r.startsWith("local:") ? "unlocked"
       : r.startsWith("unregistered:") ? "unregistered" : null)
    : null;
  if (typeof r === "string" && carried) {
    const [aid, k0] = r.slice(r.indexOf(":") + 1).split("|");
    if (nameToStore !== null)
      remember({ aid, name: nameToStore, email: emailToStore || "", k0 });
    idState.set(carried);
    if (carried === "authed") {
      refreshPersonhood();
      syncName();
      // a passcode LOGIN answers here with the seat already taken (the
      // spine replies after the session cap is in hand), so this is where
      // it authorizes the device; create's reply comes before its seat, and
      // seam.status carries that one
      if (HANDLERS.tier) HANDLERS.tier().then(t => { if (t === "root") autoEnrollDevice(); });
    }
    // The gate that let this through was an affirmative act; record it once,
    // here, rather than in each of the flows that pass through a gate.
    // recordConsent is idempotent — a returning member who was not re-asked
    // keeps the date they actually accepted on.
    recordConsent(aid);
    return { aid, k0 };
  }
  idState.set("idle");
  return { err: String(r || "err:no reply").replace(/^err:/, "") };
}
// ── the acts a sign-in surface performs ────────────────────────────────
// Each is one reply settled: the identity it opened, or the words for why not.
// No surface is named here — the card in app/identity-view.ts calls them.

/** Open an identity with a passcode — `aid` empty lets the passcode name it; `store` is the [name, email] to remember. */
export async function signIn(passcode: string, aid: string, k0: string,
                             store: [string | null, string | null]): Promise<Settled> {
  idState.set("busy");
  return settleAuth(await (HANDLERS.unlock ? HANDLERS.unlock(passcode, aid, k0) : "err:offline"), store[0], store[1]);
}
/** Unlock the identity this device remembers, by its passcode. */
export function unlockHere(passcode: string): Promise<Settled> {
  const h = who.peek();
  return signIn(passcode, h ? h.aid : "", h ? h.k0 : "", [null, null]);
}
/** Take a seat at a commune that has never met the identity this device holds. */
export async function joinHere(): Promise<Settled> {
  const h = who.peek();
  idState.set("busy");
  return settleAuth(await (HANDLERS.join ? HANDLERS.join(h ? h.name : "", h ? h.email : "") : "err:offline"), null, null);
}
/** Put a passcode back together from friends' pieces (one per line), then unlock with it. */
export async function recoverFromPieces(lines: string[]): Promise<Settled> {
  const r = String(await (HANDLERS.guardianRecover ? HANDLERS.guardianRecover(JSON.stringify(lines)) : "err:offline"));
  if (!r.startsWith("ok:")) return { err: r.replace(/^err:/, "") };
  // the pieces gave back the identifier and the passcode — from here it is an
  // ordinary unlock, so a recovered identity lands exactly where a remembered one does
  const [aid, bran] = r.slice(3).split("|");
  return signIn(bran, aid, "", ["", ""]);
}
// a recovery file holding everything an identity needs on a fresh device: the
// passcode (proves the key) and the KEL (the identity's own signed log — the
// AID is its inception's SAID, and the rotations say which key signs now).
// The passcode is on no server; the log is public and this device wrote it.
// Together they open the identity anywhere, and seat it at a commune that has
// never seen it.
/** the recovery file, as it sits on disk */
interface IdentityFile {
  "playnet-identity": 1;
  note: string;
  aid: string;
  name: string;
  email: string;
  passcode: string;
  kel: unknown;
}
/**
 * Set the display name (and email) for this identity. THE LOCAL HINT FIRST:
 * that is what the chip reads, and with no commune in reach it is the only
 * copy there is — so naming yourself works offline, like everything else
 * about an identity. Then the commune's own profile, whose reply is handed
 * back so a caller that has somewhere to show it can. A name set with no seat
 * lands locally, marked pending, and the next seat pushes it (syncName).
 */
const NAME_PENDING = K.idNamePending;
async function setMyName(name: string, email: string): Promise<string> {
  const cur = who.peek();
  if (cur) remember({ ...cur, name, email });
  const r = String(await (HANDLERS.profileSet
                          ? HANDLERS.profileSet(name, email) : "err:offline"));
  if (r === "ok") forget(NAME_PENDING); else writeStr(NAME_PENDING, "1");
  return r;
}
/**
 * The name, levelled at every seat. A name this device set with no seat to
 * push it through — typed on the created sheet while the seat was still being
 * taken, or with no commune in reach — goes to the commune now. Otherwise the
 * commune's name for this identity becomes this device's: a second device
 * signs in with an AID and a passcode, and says the name the first one set.
 */
let nameSyncing = false;
async function syncName(): Promise<void> {
  if (nameSyncing) return;
  nameSyncing = true;
  try {
    const cur = who.peek();
    if (!cur) return;
    if (readStr(NAME_PENDING) === "1") {
      if (HANDLERS.profileSet && (await HANDLERS.profileSet(cur.name, cur.email)) === "ok")
        forget(NAME_PENDING);
      return;
    }
    if (!HANDLERS.profileGet) return;
    const o = JSON.parse(await HANDLERS.profileGet() as string) as { name?: string; email?: string };
    const now = who.peek();
    if (now && now.aid === cur.aid && o.name && o.name !== now.name)
      remember({ ...now, name: o.name, email: now.email || o.email || "" });
  } catch (_) { /* unread stays as this device has it */ }
  finally { nameSyncing = false; }
}

async function downloadIdentityFile(aid: string, bran: string): Promise<void> {
  const h = idHint();
  let kel: unknown = null;
  try {
    const raw = HANDLERS.kelExport ? await HANDLERS.kelExport() : "";
    if (typeof raw === "string" && raw.startsWith("{")) kel = JSON.parse(raw);
  } catch (_) { kel = null; }
  const file: IdentityFile = {
    "playnet-identity": 1,
    note: "keep this file private and durable — the passcode is your only key and cannot be recovered; the kel is your identity's own signed log, which any commune can verify",
    aid, name: h ? h.name : "", email: h ? h.email : "", passcode: bran, kel,
  };
  const blob = new Blob([JSON.stringify(file, null, 2)], { type: "application/json" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob); a.download = "playnet-identity.json";
  document.body.appendChild(a); a.click(); a.remove(); URL.revokeObjectURL(a.href);
}
// a recovery file opened on this device: its log becomes this device's log
// (kelImport), its name/email the hint, and its passcode unlocks at once.
// A file without a log (one written before the browser kept its KEL) still
// carries AID + passcode, which is the "sign in with a passcode" path.
/** Open a recovery file's text: null once the identity is in, else the words for why not. */
export async function openIdentityFile(text: string): Promise<string | null> {
  let file: Partial<IdentityFile>;
  try { file = JSON.parse(text) as Partial<IdentityFile>; }
  catch (_) { return "that is not a playnet identity file"; }
  if (!file || file["playnet-identity"] !== 1 || typeof file.passcode !== "string")
    return "that is not a playnet identity file";
  let aid = typeof file.aid === "string" ? file.aid : "", k0 = "";
  if (file.kel && typeof file.kel === "object" && HANDLERS.kelImport) {
    const r = await HANDLERS.kelImport(JSON.stringify(file.kel));
    if (typeof r !== "string" || !r.startsWith("ok:")) return String(r || "err:no reply").replace(/^err:/, "");
    [aid, k0] = r.slice(3).split("|");
  }
  if (!aid) return "the file names no identity";
  const s = await signIn(file.passcode, aid, k0,
                         [typeof file.name === "string" ? file.name : "", typeof file.email === "string" ? file.email : ""]);
  if ("err" in s) { hint(s.err, "error"); return s.err; }
  return null;
}

/**
 * RECOVERY FRIENDS. The passcode is the only key and cannot be reset, so the
 * answer to losing it is other people: split it into pieces, give one to each
 * of a few you trust, and any k of them together can hand it back. Fewer than
 * k learn nothing — that is Shamir's guarantee, not a rule we enforce.
 *
 * The pieces never touch a commune. They are made here, shown here, and
 * carried to each person however you already talk to them; a gateway holding
 * every piece could reconstitute your passcode, which is exactly the thing
 * this identity design exists to prevent. So delivery is yours to do, and the
 * trust sits where you put it.
 *
 * Built on the same rows as the vouch list beside it — a person is a person,
 * whether you are vouching for them or trusting them with a piece of your key.
 */
/**
 * STAY SIGNED IN. The passcode is the root and stays cold; a key of this
 * device's own, authorized by the root once, signs everyday acts and signs
 * in on its own after a refresh. Held in hardware (a passkey touch on every
 * load) or in this browser's non-extractable store. Every device the root
 * authorized is listed and can be retired from any of them.
 */
export function devicesSection(f: d3.Selection): void {
  const sec = f.append("div").attr("class", "devsec");
  sec.append("div").attr("class", "sublead").text("this device");
  const here = sec.append("div");
  const list = sec.append("div").attr("class", "vlist");
  const err = sec.append("div").attr("class", "err");
  const fail = (r: unknown) => err.text(String(r || "err").replace(/^err:/, ""));

  const drawHere = async () => {
    here.html("");
    const keyHere = !!(HANDLERS.deviceKeyHere && HANDLERS.deviceKeyHere());
    const tier = HANDLERS.tier ? String(await HANDLERS.tier()) : "";
    if (keyHere) {
      here.append("div").attr("class", "opt")
          .text("✓ staying signed in here — this device holds its own key, which you authorized; "
                + "refreshes keep your seat without the passcode.");
      // retiring is armed like sign-out: one tap says what the second does
      const stop = here.append("span").attr("class", "vbtn").text("stop staying signed in here");
      let armed: ReturnType<typeof setTimeout> | null = null;
      stop.on("click", async () => {
        if (!stop.classed("arm")) {
          stop.classed("arm", true).text("tap again to stop — the passcode will be asked next time");
          armed = setTimeout(() => { stop.classed("arm", false).text("stop staying signed in here"); }, 8000);
          return;
        }
        if (armed) clearTimeout(armed);
        const said = deviceSaidHere();
        if (said && HANDLERS.revokeDevice) { const r = await HANDLERS.revokeDevice(said); if (r !== "ok") { fail(r); return; } }
        await forgetDeviceHere();
        writeStr(DECLINED, "1");
        hint("this device will ask for your passcode next time", "warn");
        await drawHere(); await drawList();
      });
      return;
    }
    if (tier !== "root") {
      here.append("div").attr("class", "opt")
          .text("sign in with your passcode to let this device stay signed in.");
      return;
    }
    const t = HANDLERS.deviceTiers ? await HANDLERS.deviceTiers() : { hardware: false, software: false };
    here.append("div").attr("class", "opt")
        .text("stay signed in here: your passcode stays out of this browser; a key of this device's own, "
              + "which you authorize now, signs for you and can be retired from any other device.");
    const enrol = async (tierName: string) => {
      err.text("");
      const r = await (HANDLERS.enrollDevice ? HANDLERS.enrollDevice(deviceLabel(), tierName) : "err:offline");
      if (r === "ok") { forget(DECLINED); await drawHere(); await drawList(); } else fail(r);
    };
    if (t.hardware)
      here.append("span").attr("class", "vbtn").text("with a passkey (touch to sign in)")
          .on("click", () => enrol("hardware"));
    if (t.software)
      here.append("span").attr("class", "vbtn").style("margin-left", "6px").text("in this browser")
          .on("click", () => enrol("software"));
    if (!t.hardware && !t.software)
      here.append("div").attr("class", "opt").text("this browser cannot hold a key — the passcode each time.");
  };

  const drawList = async () => {
    list.html("");
    if (!HANDLERS.devices) return;
    let ds: Array<{ said: string; label: string; tier: string; enrolledAt: number; revokedAt: number | null;
                    doors: string[] | null }> = [];
    try { ds = JSON.parse(String(await HANDLERS.devices())); } catch { return; }
    const live = ds.filter(d => !d.revokedAt);
    if (!live.length) return;
    list.append("div").attr("class", "sublead").text("devices signed in without the passcode");
    const mine = deviceSaidHere();
    live.forEach(d => {
      const row = list.append("div").attr("class", "vrow");
      row.append("span").attr("class", "vname")
         .text(`${d.label || "device"} · ${d.tier}${d.said === mine ? " · this one" : ""}`
               + ` · since ${new Date(d.enrolledAt * 1000).toISOString().slice(0, 10)}`
               + (d.doors ? ` · ${d.doors.length} door${d.doors.length === 1 ? "" : "s"}` : ""));
      if (d.doors)
        row.attr("title", "may call only: " + d.doors.join(", "));
      const retire = row.append("span").attr("class", "vbtn").text("retire");
      retire.on("click", async () => {
        if (!retire.classed("arm")) {
          retire.classed("arm", true).text("tap again to retire");
          setTimeout(() => { retire.classed("arm", false).text("retire"); }, 8000);
          return;
        }
        const r = await (HANDLERS.revokeDevice ? HANDLERS.revokeDevice(d.said) : "err:offline");
        if (r !== "ok") { fail(r); return; }
        if (d.said === mine) await forgetDeviceHere();
        hint(d.said === mine ? "this device will ask for your passcode next time"
                             : `${d.label || "that device"} will ask for the passcode next time`, "warn");
        await drawHere(); await drawList();
      });
    });
  };
  /**
   * An OUTSIDE interface — a bot, a script, another app — enrolled as a
   * device of this person. It made its own key and shows its device AID;
   * the passcode here signs the authorization, with the doors it may call.
   * From then on it signs its own requests (the HTTP door, /api/docs/), and
   * it is retired from the list above like any device. Root tier only:
   * authorizing a device is the root's act.
   */
  const OUTSIDE_PRESETS: Array<{ name: string; doors: string; note: string }> = [
    { name: "read only", note: "sees what you see, changes nothing",
      doors: "whoami,tier,profile,my-slots,our-slots,slots-at,my-skills,my-grants,my-titles,my-payouts,"
           + "list-proposals,list-delegations,my-voice,voice-in,list-uc-proposals,get-result,"
           + "list-log,list-pins,our-pin-lists,our-pins,list-taxonomy,folksonomy-template,"
           + "ratified-kinds,audits,externality-history,need-displacement,my-contact-points,my-devices" },
    { name: "everyday", note: "every device-level door, like a phone", doors: "" },
    { name: "custom", note: "name the doors yourself, comma-separated", doors: "" },
  ];
  const drawOutside = async () => {
    outside.html("");
    const tier = HANDLERS.tier ? String(await HANDLERS.tier()) : "";
    if (tier !== "root" || !HANDLERS.enrollExternalDevice) return;
    // folded: most people never authorize a program, and the ones who do
    // come looking for it
    const box = outside.append("details");
    box.append("summary").text("an outside interface — a bot, a script, another app");
    box.append("div").attr("class", "opt")
       .text("a program that made its own key: paste its device identifier, name it, and choose the doors "
             + "it may call. It signs for you within those doors until you retire it.");
    const aid = box.append("input").attr("type", "text").attr("placeholder", "device identifier (B…, 44 characters)")
                   .attr("maxlength", "44");
    const label = box.append("input").attr("type", "text").attr("placeholder", "what to call it");
    const preset = box.append("select");
    OUTSIDE_PRESETS.forEach((p, i) => preset.append("option").attr("value", String(i)).text(`${p.name} — ${p.note}`));
    const custom = box.append("input").attr("type", "text").attr("placeholder", "door names, comma-separated")
                      .style("display", "none");
    preset.on("change", () => custom.style("display", preset.property("value") === "2" ? "block" : "none"));
    const go = box.append("span").attr("class", "vbtn").style("margin-top", "8px").style("display", "inline-block").text("authorize");
    go.on("click", async () => {
      err.text("");
      const a = String(aid.property("value") || "").trim();
      if (!/^B[A-Za-z0-9_-]{43}$/.test(a)) { fail("err:a device identifier is 44 characters and starts with B"); return; }
      const i = Number(preset.property("value") || 0);
      const doors = i === 2 ? String(custom.property("value") || "") : OUTSIDE_PRESETS[i].doors;
      const r = await HANDLERS.enrollExternalDevice!(a, String(label.property("value") || "").trim(), doors);
      if (r === "ok") {
        hint(`${label.property("value") || "that interface"} may now sign for you`, "success");
        aid.property("value", ""); label.property("value", ""); custom.property("value", "");
        await drawList();
      } else fail(String(r));
    });
  };
  const outside = f.append("div").style("margin-top", "10px");
  drawHere(); drawList(); drawOutside();
}

/**
 * CHANGE YOUR PASSCODE. The passcode is the root of the identity's keys, so
 * changing it hands the identity to a new one: the spine makes the two key
 * events as one act (changePasscode), and from then on the old passcode opens
 * nothing. It reads as a password change anywhere reads — the current one,
 * then the new one — with what this context adds:
 *
 *   the new passcode is made here, shown once, and confirmed saved BEFORE the
 *   change is made, because after it the old one is no way back;
 *   every device's own key is retired, this device's too, and this device is
 *   authorized afresh under the new passcode — a thief's device goes with
 *   the rest;
 *   the identifier, the name and everything the commune holds stay as they are.
 */
export function passcodeSection(f: d3.Selection): void {
  const sec = f.append("div");
  const guard = (e: BeforeUnloadEvent) => { e.preventDefault(); e.returnValue = ""; };
  const clear = (): void => { sec.selectAll("*").remove(); };
  const say = (text: string): void => { sec.append("div").attr("class", "opt").text(text); };

  // 1 ── the current passcode
  const ask = (): void => {
    clear();
    window.removeEventListener("beforeunload", guard);
    const h = who.peek();
    if (!h || !HOLDS_IDENTITY(idState.peek())) { say("sign in to change your passcode."); return; }
    const form = sec.append("form").attr("autocomplete", "on").attr("action", "#");
    form.append("input").attr("type", "text").attr("name", "username").attr("autocomplete", "username")
      .property("value", h.aid).attr("readonly", true).attr("tabindex", "-1").attr("aria-hidden", "true")
      .style("display", "none");
    const cur = form.append("input").attr("type", "password").attr("name", "password")
      .attr("autocomplete", "current-password").attr("placeholder", "current passcode");
    const err = form.append("div").attr("class", "err");
    form.append("button").attr("class", "go").attr("type", "submit").text("continue");
    form.on("submit", async (e) => {
      e.preventDefault();
      const current = cur.property("value") as string;
      if (!current || current.length < 21) { err.text("the passcode needs 21+ characters"); return; }
      err.text("");
      const r = String(await (HANDLERS.passcodeCheck ? HANDLERS.passcodeCheck(current) : "err:offline"));
      if (r !== "ok") { err.text(r.replace(/^err:/, "")); return; }
      review(h, current, genPasscode());
    });
  };

  // 2 ── the new passcode, saved before anything changes
  const review = (h: IdHint, current: string, next: string): void => {
    clear();
    window.addEventListener("beforeunload", guard);
    say("this is your new passcode. Nothing has changed yet: save it first, then make the change.");
    const form = sec.append("form").attr("autocomplete", "on").attr("action", "#");
    form.append("label").attr("class", "sublead").text("new passcode (your key)");
    const pass = form.append("input").attr("class", "pcode").attr("type", "password").attr("name", "password")
      .attr("autocomplete", "new-password").attr("readonly", true).attr("spellcheck", "false")
      .property("value", next);
    const row = form.append("div").attr("class", "genrow");
    row.append("span").attr("class", "gen2").text("show").on("click", function () {
      const showing = pass.attr("type") === "text";
      pass.attr("type", showing ? "password" : "text");
      d3.select(this).text(showing ? "show" : "hide");
    });
    row.append("span").attr("class", "gen2").text("copy").on("click", function () {
      if (navigator.clipboard) navigator.clipboard.writeText(next);
      const t = d3.select(this); t.text("✓ copied"); setTimeout(() => t.text("copy"), 1500);
    });
    form.append("label").attr("class", "sublead").text("identifier (stays the same)");
    identifierRow(form, h.aid, true);

    form.append("div").attr("class", "warn")
      .text("When you make the change: the current passcode stops opening your identity, here and "
            + "everywhere. Every device is signed out and this one is signed back in. Pieces you gave "
            + "to recovery friends, and your old recovery file, stop working. Cards people gave you "
            + "before now need giving again.");
    const gateId = "pnchanged" + ((passcodeSection as Counted)._n = ((passcodeSection as Counted)._n || 0) + 1);
    const gate = form.append("div").attr("class", "consent");
    const box = gate.append("input").attr("type", "checkbox").attr("id", gateId);
    gate.append("label").attr("for", gateId)
        .text("I've saved the new passcode. I understand it cannot be shown again.");
    const err = form.append("div").attr("class", "err");
    const go = form.append("button").attr("class", "go").attr("type", "submit")
      .attr("disabled", true).style("opacity", "0.45").text("change passcode");
    box.on("change", () => {
      const ok = box.property("checked") as boolean;
      go.attr("disabled", ok ? null : true).style("opacity", ok ? "1" : "0.45");
    });
    form.append("div").attr("class", "gen2").style("margin-top", "8px").text("cancel — keep the current passcode")
      .on("click", ask);
    let busy = false;
    form.on("submit", async (e) => {
      e.preventDefault();
      if (busy || !(box.property("checked") as boolean)) return;
      busy = true; err.text("");
      go.attr("disabled", true).style("opacity", "0.45").text("changing…");
      const r = String(await (HANDLERS.changePasscode ? HANDLERS.changePasscode(current, next) : "err:offline"));
      if (!r.startsWith("ok:")) {
        busy = false;
        go.attr("disabled", null).style("opacity", "1").text("change passcode");
        err.text(r.replace(/^err:/, ""));
        return;
      }
      // the identity is the same one, opened by another first key
      const [, k0] = r.slice(3).split("|");
      const cur = who.peek() || h;
      remember({ ...cur, k0: k0 || "" });
      idState.set("authed");
      const retired = await retireEveryDevice();
      changed(h, next, retired);
    });
  };

  // 3 ── done: the new recovery file, and what follows from the change
  const changed = (h: IdHint, next: string, retired: number): void => {
    clear();
    sec.append("div").attr("class", "saved").text("✓ passcode changed — the new one is the only key now.");
    sec.append("button").attr("class", "go").attr("type", "button").style("margin-top", "8px")
       .text("⬇ download the new recovery file").on("click", () => downloadIdentityFile(h.aid, next));
    say("it replaces the old file, which no longer opens your identity.");
    say(retired === 0 ? "no other device was signed in."
        : retired === 1 ? "one other device was signed out; it asks for the new passcode next time."
        : `${retired} other devices were signed out; each asks for the new passcode next time.`);
    const again = sec.append("div").attr("class", "genrow");
    again.append("span").attr("class", "vbtn").text("make new pieces for recovery friends")
         .on("click", () => openSettings("recovery"));
    again.append("span").attr("class", "vbtn").text("done")
         .on("click", () => { window.removeEventListener("beforeunload", guard); ask(); });
    window.removeEventListener("beforeunload", guard);
  };

  ask();
  // signing in or out while the section stands redraws its first step
  let seen = !!who.peek();
  effect(() => { const now = !!who(); if (now !== seen) { seen = now; ask(); } });
}

/**
 * FORGET ME. The commune erases every record of its own keyed by this
 * identity — the link between identity and person last — and replies a
 * receipt; then this device forgets what it held (signOutDevice). What stays
 * is said before the act, because it is the design and not a gap: the key
 * log (signed, digest-chained; a hole would break everything ever signed as
 * it), the credentials and the scope's records, as data about an identifier
 * nobody can resolve to a person. It asks for the passcode — a device key
 * alone cannot erase its person — and offers to retire the identity first:
 * a last key event naming no next key, after which nothing signs as it
 * again, anywhere.
 */
export function forgetSection(f: d3.Selection): void {
  const sec = f.append("div");
  const clear = (): void => { sec.selectAll("*").remove(); };
  const say = (text: string): void => { sec.append("div").attr("class", "opt").text(text); };
  const n = ((forgetSection as Counted)._n = ((forgetSection as Counted)._n || 0) + 1);

  const ask = (): void => {
    clear();
    const h = who.peek();
    if (!h || !HOLDS_IDENTITY(idState.peek())) { say("sign in to be forgotten."); return; }
    say("Your commune erases every record of its own about you — your handle, name and email, "
        + "the ways to reach you, your cards, contacts, pins, taxonomy, log, mailboxes and "
        + "spooled mail — the link between your identity and you last, and retires every device "
        + "of yours. Your signed key log, your credentials and your devices' authorizations stay "
        + "as they are: records about an identifier nobody can resolve to you. Encrypted backups "
        + "hold the erased records for up to 30 days.");
    const form = sec.append("form").attr("autocomplete", "on").attr("action", "#");
    form.append("input").attr("type", "text").attr("name", "username").attr("autocomplete", "username")
      .property("value", h.aid).attr("readonly", true).attr("tabindex", "-1").attr("aria-hidden", "true")
      .style("display", "none");
    const cur = form.append("input").attr("type", "password").attr("name", "password")
      .attr("autocomplete", "current-password").attr("placeholder", "your passcode");
    const retireRow = form.append("div").attr("class", "consent");
    const retire = retireRow.append("input").attr("type", "checkbox").attr("id", `pnretire${n}`);
    retireRow.append("label").attr("for", `pnretire${n}`)
      .text("also retire this identity: a last key event names no next key, closing its log for "
            + "good — no rotation, no recovery, no new key can ever take it over (the key it "
            + "reveals stays your passcode's). Leave this off to keep the identity and only be "
            + "forgotten here.");
    const sureRow = form.append("div").attr("class", "consent");
    const sure = sureRow.append("input").attr("type", "checkbox").attr("id", `pnsure${n}`);
    sureRow.append("label").attr("for", `pnsure${n}`)
      .text("I understand what stays, and that this cannot be undone.");
    const err = form.append("div").attr("class", "err");
    const go = form.append("button").attr("class", "go").attr("type", "submit")
      .attr("disabled", true).style("opacity", "0.45").text("forget me");
    sure.on("change", () => {
      const ok = sure.property("checked") as boolean;
      go.attr("disabled", ok ? null : true).style("opacity", ok ? "1" : "0.45");
    });
    let busy = false;
    form.on("submit", async (e) => {
      e.preventDefault();
      if (busy || !(sure.property("checked") as boolean)) return;
      const passcode = cur.property("value") as string;
      if (!passcode || passcode.length < 21) { err.text("the passcode needs 21+ characters"); return; }
      busy = true; err.text("");
      go.attr("disabled", true).style("opacity", "0.45").text("forgetting…");
      const r = String(await (HANDLERS.forgetMe
        ? HANDLERS.forgetMe(passcode, (retire.property("checked") as boolean) ? "retire" : "")
        : "err:offline"));
      if (r.startsWith("err:")) {
        busy = false;
        go.attr("disabled", null).style("opacity", "1").text("forget me");
        err.text(r.slice(4));
        return;
      }
      let receipt: { dropped?: Record<string, number>; kept?: string[] } = {};
      try { receipt = JSON.parse(r) as typeof receipt; } catch (_) { /* a receipt is shown when it parses */ }
      done(receipt, retire.property("checked") as boolean);
    });
  };

  const done = (receipt: { dropped?: Record<string, number>; kept?: string[] }, retired: boolean): void => {
    clear();
    sec.append("div").attr("class", "saved")
       .text(retired ? "✓ forgotten, and the identity is retired." : "✓ forgotten.");
    const went = Object.entries(receipt.dropped || {}).filter(([, v]) => v > 0);
    say(went.length
        ? "what went: " + went.map(([k, v]) => `${k.replace(/-/g, " ")} ${v}`).join(", ")
        : "nothing of yours was held here.");
    if (receipt.kept?.length) say("what stays: " + receipt.kept.map(k => k.replace(/-/g, " ")).join(", ")
                                  + " — records about an identifier, not about you.");
    say("this device forgets you next.");
    sec.append("button").attr("class", "go").attr("type", "button").style("margin-top", "8px")
       .text("done").on("click", () => { void signOutDevice(); });
  };

  ask();
  let seen = !!who.peek();
  effect(() => { const now = !!who(); if (now !== seen) { seen = now; ask(); } });
}

/**
 * Retire every device key this identity authorized — a passcode change's
 * second half: a device someone else enrolled with the old passcode goes with
 * the rest. This device's own key goes too and is authorized afresh, under
 * the key now in force. Answers how many OTHER devices were retired.
 */
async function retireEveryDevice(): Promise<number> {
  let others = 0;
  try {
    const mine = deviceSaidHere();
    const all = JSON.parse(String(HANDLERS.devices ? await HANDLERS.devices() : "[]")) as
      Array<{ said: string; revokedAt: number | null }>;
    for (const d of all.filter(x => !x.revokedAt)) {
      const r = HANDLERS.revokeDevice ? await HANDLERS.revokeDevice(d.said) : "err:offline";
      if (r === "ok" && d.said !== mine) others++;
    }
  } catch (_) { /* the list in settings still retires them one by one */ }
  await forgetDeviceHere();
  await autoEnrollDevice();
  return others;
}

export function recoveryFriends(f: d3.Selection): void {
  const sec = f.append("div");
  const intro = sec.append("div").attr("class", "opt")
    .text("Choose people you trust; each gets one piece. At least half of them together — "
          + "never fewer than two — can hand your passcode back, and fewer learn nothing.");
  const people = book().filter(c => c.aid);
  if (!people.length) {
    sec.append("div").attr("class", "opt")
       .text("The people you can choose are the ones in your Contacts, and there is nobody there yet.");
    sec.append("span").attr("class", "vbtn").text("open contacts")
       .on("click", () => { closeSettings(); revealContacts(); });
    return;
  }
  // pick who: the same pick a Contacts row marks (contact-book.ts), so a
  // recovery friend chosen there is already chosen here
  const list = sec.append("div").attr("class", "vlist");
  const chosenNames = (): string[] =>
    people.filter(c => recoveryPicks().has(c.aid)).map(c => c.alias || c.aid);
  people.forEach(c => {
    const row = list.append("div").attr("class", "vrow");
    row.append("span").attr("class", "vname").text(c.alias || c.aid);
    const pick = row.append("span").attr("class", "vbtn");
    const paint = () => {
      const on = recoveryPicks().has(c.aid);
      pick.text(on ? "✓ trusted" : "trust").classed("done", on);
    };
    paint();
    pick.on("click", () => { toggleRecoveryPick(c.aid); paint(); count.text(saying(chosenNames().length)); });
  });
  // How many are needed follows from how many you chose — a majority, which is
  // the shape people already understand from every other quorum in here. Saying
  // it as a sentence beats asking someone to pick a k out of the air.
  const need = (n: number) => Math.max(2, Math.ceil(n / 2));
  const saying = (n: number) =>
    n === 0 ? "choose the people you would ask for help."
    : n === 1 ? "choose at least one more — a single piece is just your passcode in someone else's hands."
    : `any ${need(n)} of these ${n} could bring your passcode back. Fewer than ${need(n)} could not.`;
  const count = sec.append("div").attr("class", "opt").text(saying(chosenNames().length));
  const err = sec.append("div").attr("class", "err");
  const out = sec.append("div");
  const makePieces = async (): Promise<void> => {
    const names = chosenNames();
    err.text(""); out.selectAll("*").remove();
    const k = need(names.length);
    const r = await (HANDLERS.guardianSplit
                     ? HANDLERS.guardianSplit(String(k), String(names.length))
                     : "err:offline");
    let lines: string[] = [];
    try { lines = JSON.parse(String(r)); } catch (_) { /* not JSON ⇒ an error string */ }
    if (!Array.isArray(lines) || lines.length !== names.length) {
      err.text(String(r).replace(/^err:/, "")); return;
    }
    intro.text("One piece each. Send each person THEIR line, however you "
               + "normally talk — these never went through the commune, and "
               + "this is the only time they are shown.");
    // one row per person, each carrying the line meant for them
    const box = out.append("div").attr("class", "vlist");
    names.forEach((name, i) => {
      const row = box.append("div").attr("class", "vrow");
      row.append("span").attr("class", "vname").text(name);
      row.append("span").attr("class", "vbtn").text("copy their piece")
        .on("click", function () {
          if (navigator.clipboard) navigator.clipboard.writeText(lines[i]);
          const t = d3.select(this); t.text("✓ copied");
          setTimeout(() => t.text("copy their piece"), 1500);
        });
    });
    out.append("div").attr("class", "warn")
       .text(`Any ${k} of these ${names.length} pieces will open this identity. `
             + "Keep none of them yourself — if you could gather them alone, "
             + "so could anyone who took this device. Making pieces again "
             + "retires these: pieces from two makings refuse to combine.");
  };
  // Splitting the passcode is the passcode's own act. A device that stays
  // signed in signs with a key of its own and never kept the passcode, so
  // there it is asked for once, here, and the split follows.
  const askPasscode = (): void => {
    out.selectAll("*").remove();
    const h = who.peek();
    out.append("div").attr("class", "opt")
       .text("Splitting your passcode needs the passcode itself — this device signs with a key "
             + "of its own and never kept it. Enter it once to make the pieces.");
    const form = out.append("form").attr("action", "#");
    const pass = form.append("input").attr("type", "password").attr("autocomplete", "current-password")
      .attr("placeholder", "passcode — 21+ characters");
    form.append("button").attr("class", "go").attr("type", "submit").text("continue");
    form.on("submit", async (e) => {
      e.preventDefault();
      const bran = pass.property("value") as string;
      if (!bran || bran.length < 21) { err.text("the passcode needs 21+ characters"); return; }
      err.text("");
      const r = String(await (HANDLERS.unlock && h ? HANDLERS.unlock(bran, h.aid, h.k0) : "err:offline"));
      if (!/^(ok|local|unregistered):/.test(r)) { err.text(r.replace(/^err:/, "")); return; }
      await makePieces();
    });
  };
  sec.append("button").attr("class", "go").text("make the pieces")
    .on("click", async () => {
      if (chosenNames().length < 2) { err.text("choose at least two people"); return; }
      const tier = HANDLERS.tier ? String(await HANDLERS.tier()) : "";
      if (tier === "root") await makePieces(); else askPasscode();
    });
}

export { idHint };

// ── the surfaces' door ─────────────────────────────────────────────────
// Every surface that shows an identity (the identity card, the onboarding
// checklist, the account sheet) reaches it through what is exported here, so
// this file stays the one place that knows a reply's shape.
export const identity = who;
export const identityState = idState;
export { consentCurrent, consentRecord, downloadIdentityFile, setMyName, DOCUMENT_VERSION, refreshPersonhood };

/**
 * The person button's two doors, registered by app/account.ts: the account
 * sheet, and the account sheet on its identity page (make, open or read an
 * identity). id.ts cannot import account.ts, so the sheet hands itself in.
 */
let accountDoor: (() => void) | null = null;
let identityDoor: (() => void) | null = null;
export function onAccountDoor(open: () => void, openIdentity: () => void): void { accountDoor = open; identityDoor = openIdentity; }
/** Open the identity card: sign in, unlock or create; once in, who you are. */
export function openIdentityDoor(): void { if (identityDoor) identityDoor(); }

/**
 * Create an identity in one act. The passcode is minted here and handed back
 * ONCE with the AID; the caller's screen shows it and gates on its being
 * saved (app/identity-view.ts). A refusal comes back as its text.
 */
export async function createIdentity(): Promise<{ aid: string; bran: string } | { err: string }> {
  const bran = genPasscode();
  idState.set("busy");
  const r = await (HANDLERS.signup ? HANDLERS.signup("", "", bran) : "err:offline");
  const s = settleAuth(r, "", "");
  return "err" in s ? s : { aid: s.aid, bran };
}
