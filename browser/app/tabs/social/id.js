// app/tabs/id.ts — identity: the door into the plan.
//
// Panel subsystem: the KERI id chip + signup/unlock forms, the identity
// file download, personhood (fp*) vouching, and the settings sheet. Registers
// seam.status (day-boot reports gateway state through it). Talks to
// the gateway only through HANDLERS (signup/unlock/profile*/fp*) at call
// time; reads pending()/proposals/contacts and calls settle()/hint() from
// core — all runtime, so the main.js <-> id.js import cycle is benign.
import { HANDLERS, hint } from '../../core.js';
import { book, byAid, recoveryPicks, toggleRecoveryPick } from '../../contact-book.js';
import { revealContacts } from './share.js';
import { locationDoor, locationOff, locationResume } from './location.js';
import { whereBlock } from './standing.js';
import { readStr, writeStr, forget, readJSON, writeJSON } from '../../store.js';
import { signal, effect } from '../../reactive.js';
import { ensurePersistent } from '../../storage-health.js';
import { openSettings, closeSettings } from '../../settings.js';
import { LEGAL_VERSION, DOCUMENT_VERSION, TERMS_HREF, PRIVACY_HREF } from '../../legal-product.js';
import { on } from '../../bus.js';
import { K } from "../../keys.js";
const idHint = () => {
    const h = readStr(K.idHint);
    if (!h)
        return null;
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
 *            tap away, in the sheet.
 */
const idState = signal("standalone");
const who = signal(idHint());
const person = signal(null);
/** Whether this commune recognises you as a person; null while unread. A tracked read. */
export const recognised = () => person();
/** Ask the commune again whether it recognises you — recognition arrives while the page is open. */
export function rereadStanding() {
    if (!HANDLERS.fpStatus)
        return;
    HANDLERS.fpStatus().then(j => { try {
        person.set(!!JSON.parse(j).person);
    }
    catch (_) { /* unread stays unread */ } });
}
/**
 * Write what this device remembers about you: storage and chip in one move, so
 * they cannot drift. The passcode is never part of it — it IS the key, and it
 * lives only in the vat for as long as a tab is open.
 */
function remember(h) {
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
    if (e.key === null || e.key === K.idHint)
        who.set(idHint());
});
/**
 * What to call you. Your display name if you have set one, else a standing-in
 * "you" — every surface that says your name says it through here, so an
 * unnamed identity reads the same way everywhere and there is one place to
 * change what that reads.
 */
const myName = (h) => (h && h.name) || "you";
/** The name the lip and any other chrome wears — a live read of `who`. */
export const displayName = () => myName(who());
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
const HOLDS_IDENTITY = (st) => st === "authed" || st === "unlocked" || st === "unregistered";
on("status", (s) => {
    // a seat taken with the passcode (the spine reports it once the session
    // cap is in hand) authorizes this device's own key, so the next load
    // needs no passcode; a device's own seat has nothing to enrol
    if (s.startsWith("ok:") && HANDLERS.tier)
        HANDLERS.tier().then(t => { if (t === "root")
            autoEnrollDevice(); });
    if (s.startsWith("ok:"))
        syncName();
    const held = idState.peek();
    idState.set(s.startsWith("ok:") ? "authed" :
        s.startsWith("local:") ? "unlocked" :
            s.startsWith("unregistered:") ? "unregistered" :
                s === "connected" ? (HOLDS_IDENTITY(held) ? held : "idle") :
                    s === "connecting" ? (HOLDS_IDENTITY(held) ? held : "connecting") :
                        HOLDS_IDENTITY(held) ? "unlocked" : "offline");
});
/**
 * The device key signed in on its own (day-boot, at connect). A seat is a
 * seat; a refusal that names the authorization — revoked from another device,
 * or unknown to this commune — retires the key here too, so the next sign-in
 * is the passcode's and can authorize afresh. Any other refusal (the touch
 * was declined, the gateway hiccuped) leaves the key for a retry from the sheet.
 */
const DEVICE_WIRE = K.deviceWire;
/** the persona's mesh seed, sealed under this device's seal key (the spine writes it at enrolment) */
const DEVICE_MESH = K.deviceMesh;
/** an authorization whose key this browser no longer holds, kept until a root seat retires it */
const DEVICE_STALE = K.deviceStale;
async function forgetDeviceHere() {
    forget(DEVICE_WIRE);
    forget(DEVICE_MESH);
    if (HANDLERS.deviceForget)
        await HANDLERS.deviceForget();
}
on("deviceUnlock", (r) => {
    if (r.startsWith("ok:") || r.startsWith("local:") || r.startsWith("unregistered:")) {
        finishAuth(r, null, null, () => { });
        return;
    }
    // The browser cleared its key store under the record: the authorization
    // names a key nobody holds. The record goes, so the next passcode seat
    // authorizes a fresh key, and that seat retires the orphaned authorization.
    if (/missing from this browser/.test(r)) {
        const said = deviceSaidHere();
        if (said)
            writeStr(DEVICE_STALE, said);
        forgetDeviceHere().then(() => hint("this browser lost its device key — sign in with your passcode", "warn"));
        return;
    }
    if (/revoked|expired|not enrolled|unreadable/.test(r)) {
        forgetDeviceHere().then(() => hint("this device was signed out — sign in with your passcode", "warn"));
    }
});
/** the SAID of this device's own authorization, from the wire it keeps */
function deviceSaidHere() {
    try {
        const w = readStr(DEVICE_WIRE);
        return w ? (JSON.parse(w).said || null) : null;
    }
    catch {
        return null;
    }
}
/**
 * Stay signed in on this device. The software tier needs no gesture, so a
 * passcode sign-in enrols it on its own unless the person has said no here
 * before; the hardware tier (a passkey touch) is chosen in the sheet.
 */
const DECLINED = K.deviceDeclined;
let enrolling = false;
async function autoEnrollDevice() {
    if (enrolling)
        return;
    if (!HANDLERS.enrollDevice || !HANDLERS.deviceTiers)
        return;
    // a device key is HERE when both halves are: the key's record and the
    // root's authorization. One half alone signs nothing in — it is cleared,
    // and this seat authorizes afresh.
    const keyHere = !!(HANDLERS.deviceKeyHere && HANDLERS.deviceKeyHere());
    const wireHere = !!readStr(DEVICE_WIRE);
    if (keyHere && wireHere)
        return;
    if (readStr(DECLINED) === "1")
        return;
    const t = await HANDLERS.deviceTiers();
    if (!t.software)
        return;
    enrolling = true;
    try {
        if (keyHere || wireHere)
            await forgetDeviceHere();
        const stale = readStr(DEVICE_STALE);
        if (stale) {
            try {
                if (HANDLERS.revokeDevice)
                    await HANDLERS.revokeDevice(stale);
            }
            catch (_) { /* the list in settings still retires it */ }
            forget(DEVICE_STALE);
        }
        const r = await HANDLERS.enrollDevice(deviceLabel(), "software");
        if (r === "ok")
            hint("staying signed in on this device — settings has the switch", "success");
        // "sign in first" is create's early reply — its seat report enrols
        else if (!/sign in first/.test(String(r)))
            console.warn("[id] device enrolment:", r);
    }
    finally {
        enrolling = false;
    }
}
function deviceLabel() {
    const ua = navigator.userAgent;
    const os = /Android/.test(ua) ? "Android" : /iPhone|iPad/.test(ua) ? "iOS"
        : /Mac/.test(ua) ? "Mac" : /Windows/.test(ua) ? "Windows" : /Linux/.test(ua) ? "Linux" : "device";
    const br = /Firefox/.test(ua) ? "Firefox" : /Edg\//.test(ua) ? "Edge" : /Chrom/.test(ua) ? "Chrome"
        : /Safari/.test(ua) ? "Safari" : "browser";
    return `${br} on ${os}`;
}
// ── the sheet ──────────────────────────────────────────────────────────
// Every identity surface — the away notice, the join offer, sign-in, the
// created card, settings — is ONE popover wearing a different face. These
// four functions are the only code that knows it is called #idform, and the
// only code that opens or closes it.
const SHEET = "#idform";
/**
 * Close whatever sheet is open — unless it is HELD.
 *
 * A held sheet is one that must not be dismissed by accident, because
 * dismissing it destroys something unrecoverable: the created sheet holds
 * itself until the passcode has been saved, since it is shown exactly once
 * and there is no way to ask for it again. Tapping the chip, opening another
 * sheet, or a stray Enter all route through here, so the hold is honoured
 * everywhere without any of them knowing about it.
 */
function closeSheet(force = false) {
    const open = d3.select("#idrow").select(SHEET);
    // classed() as a GETTER reads .classList off node(), which is null when
    // nothing is open — so the empty case is checked first, not implied.
    if (open.empty())
        return;
    if (!force && open.classed("held"))
        return;
    open.remove();
}
/** Hold the open sheet against accidental dismissal, or release it. */
function holdSheet(on) {
    d3.select("#idrow").select(SHEET).classed("held", on);
}
/** A fresh empty sheet, replacing any open one (a held one stands). */
function openSheet(el, wide = false) {
    closeSheet();
    if (!el.select(SHEET).empty())
        return el.select(SHEET);
    const sheet = el.append("div").attr("id", "idform").classed("wide", wide);
    sheet.append("span").attr("class", "idclose").attr("role", "button").attr("aria-label", "close")
        .attr("title", "close").text("×").on("click", () => closeSheet());
    return sheet;
}
// The sheet is a modal over a dimmed page, so the dimmed page and Esc are ways
// out too; a HELD sheet (the passcode, shown once) stands through all of them.
document.addEventListener("pointerdown", ev => {
    const t = ev.target;
    if (!t || t.closest(SHEET) || t.closest("#idrow .who"))
        return;
    closeSheet();
});
document.addEventListener("keydown", ev => { if (ev.key === "Escape")
    closeSheet(); });
/**
 * Tap-again-to-close, for the sheets a chip tap opens directly. Returns null
 * when this tap CLOSED an open sheet, so the caller returns without drawing.
 */
function toggleSheet(el, wide = false) {
    return el.select(SHEET).empty() ? openSheet(el, wide) : (closeSheet(), null);
}
/**
 * The sheet outlives a chip re-render. #idform is a child of #idrow, so
 * renderId's wipe would take it — and the personhood check and the 45s poll
 * both re-render while a sheet is open. Detach the node (its subtree intact),
 * hand back the thunk that puts it in place again. A plain wipe would strip
 * the sheet's CHILDREN too, re-attaching an empty shell.
 */
function detachSheet(el) {
    const node = el.select(SHEET).node();
    if (node)
        node.remove(); // Element.remove: off the DOM, subtree kept
    return () => { if (node)
        el.node().appendChild(node); };
}
// STANDALONE is the only true dead end: no spine at all (the docs copy, a wasm
// that never booted), so nothing can be made here and the chip says so.
const STANDALONE_FACE = {
    cls: "off", dot: "off",
    label: () => "demo day",
    title: "No commune is configured for this page — the dial is a local sample.",
    sheet: renderAway,
};
// OFFLINE is not a dead end. An identity is minted and unlocked entirely on
// this device, so the corner offers the SAME act it would with a commune in
// reach — telling someone who has not signed in that infrastructure is
// missing tells them nothing they can act on. That the commune is unreachable
// is said once they are in, when it starts to matter.
const OFFLINE_FACE = {
    cls: "off", dot: "idle",
    label: h => h ? myName(h) : "create your identity",
    title: "Sign in — your passcode opens this identity on this device.",
    sheet: renderAway,
};
const CHIP = {
    // The header says your NAME and nothing else. Your AID in full and your
    // personhood standing — with what to do about either — live one tap away.
    authed: { cls: "on", dot: "live", label: h => myName(h),
        title: "Signed in, and seated at this commune.",
        sheet: renderSettings },
    unlocked: { dot: "warn", label: h => myName(h),
        title: "Unlocked on this device — the commune is unreachable.",
        sheet: renderAway },
    unregistered: { dot: "warn", label: h => myName(h),
        title: "This commune has not met you yet — tap to join.",
        sheet: renderJoin },
    // reaching one is neither open nor away, and saying so beats claiming there
    // is no commune while the wasm is still finding it. NOT inert: unlocking
    // and creating are entirely local acts, and a connect that hangs (a stale
    // sref in an old tab, a gateway mid-restart) must never lock a person out
    // of the door — that is exactly when they go looking for it.
    connecting: { dot: "wait", label: h => h ? myName(h) : "…",
        title: "Reaching the commune… tap to sign in meanwhile.",
        sheet: renderAway },
    // busy is ours, not the network's: a submit already in flight, over in a
    // beat — the one state where a tap genuinely has nothing to open.
    busy: { dot: "wait", label: () => "…", title: "A moment…" },
    idle: { dot: "idle", label: h => h ? myName(h) : "create your identity",
        title: "Sign in to this commune.",
        sheet: renderIdForm },
    offline: OFFLINE_FACE,
    standalone: STANDALONE_FACE,
};
// Anchors the door popover under whichever pill triggered it, rather than
// always the row's own right edge — with two chips in #idrow (name, then
// location) a fixed `right:0` only happens to line up under the one that is
// last in the row. Measured live at open time, since the popover isn't
// reparented into the chip (a redraw's detach/reattach always lands it back
// on #idrow — see detachSheet).
function anchorSheet(el, target) {
    const f = el.select(SHEET).node();
    const t = target.node(), r = el.node();
    if (!f || !t || !r)
        return;
    f.style.right = Math.max(0, r.getBoundingClientRect().right - t.getBoundingClientRect().right) + "px";
}
function drawChip() {
    const el = d3.select("#idrow");
    const reattach = detachSheet(el);
    el.selectAll("*").remove();
    // sharing a position needs an open door: the spine writes it against the
    // session AID, so the chip lives and dies with the identity chip beside it.
    const state = idState(), h = who();
    if (state !== "authed")
        locationOff();
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
    // session AID) and, when it cannot, where "sign in first" leads: the very
    // sheet tapping your name opens.
    const authed = state === "authed";
    // a tap on the person button opens the account sheet (app/account.ts); with
    // no account sheet mounted it opens the identity sheet directly
    if (face.sheet)
        chip.on("click", () => {
            // a held sheet (the passcode, shown once) stands: nothing opens over it
            const open = el.select(SHEET);
            if (!open.empty() && open.classed("held"))
                return;
            if (accountDoor)
                accountDoor();
            else
                openIdentitySheet();
        });
    locationDoor(authed, !authed && face.sheet ? () => { face.sheet(el, h); anchorSheet(el, chip); } : null);
    if (authed)
        locationResume();
    reattach();
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
function identifierRow(f, aid, asUsername = false) {
    const inp = f.append("input").attr("class", "aidfield").attr("type", "text")
        .attr("readonly", true).attr("spellcheck", "false").attr("aria-label", "your identifier")
        .property("value", aid);
    if (asUsername)
        inp.attr("name", "username").attr("autocomplete", "username");
    inp.on("focus", function () { this.select(); });
    f.append("div").attr("class", "genrow")
        .append("span").attr("class", "gen2").text("copy identifier").on("click", function () {
        if (navigator.clipboard)
            navigator.clipboard.writeText(aid);
        const t = d3.select(this);
        t.text("✓ copied");
        setTimeout(() => t.text("copy identifier"), 1500);
    });
}
// ── signing out ────────────────────────────────────────────────────────
// The HINT (aid|name|email|k0) and the KEL (this identity's own signed log)
// are local; the passcode never was. Signing out forgets both — which is
// why it asks twice and shows the identifier first: the passcode alone comes
// back at a commune that holds this identity's log, and anywhere else the
// way back also needs the identifier or the recovery file.
/** Forget this device's identity — its device key, the copy of the log, the vouches — and reload. */
export async function signOutDevice() {
    const said = deviceSaidHere();
    if (said && HANDLERS.revokeDevice) {
        try {
            await HANDLERS.revokeDevice(said);
        }
        catch (_) { }
    }
    await forgetDeviceHere();
    forget(K.idHint);
    forget(K.idKel);
    forget(K.idPhc);
    forget(VOUCHES_KEY);
    forget(NAME_PENDING);
    forget(DEVICE_STALE);
    location.reload();
}
function signOutRow(f) {
    const row = f.append("div").attr("class", "signoutrow");
    const btn = row.append("span").attr("class", "signout").text("sign out");
    btn.on("click", () => {
        if (btn.classed("arm")) {
            void signOutDevice();
            return;
        }
        btn.classed("arm", true).text("sign out — tap again");
        row.append("div").attr("class", "opt")
            .text("Your passcode is not stored here and never was, and signing out forgets this "
            + "device's copy of your log. Your passcode brings you back at this commune; "
            + "anywhere else you also need your recovery file or your identifier, shown "
            + "above — keep it somewhere safe first.");
        setTimeout(() => {
            if (btn.classed("arm")) {
                btn.classed("arm", false).text("sign out");
                row.selectAll(".opt").remove();
            }
        }, 20000);
    });
}
// the sheet behind a doors-shut chip: why nothing writes, and what still works
// from here. Two readings of the same state — with an identity stored it is
// YOUR commune that is unreachable; without one there is no commune configured
// at all, which is the demo day and worth saying plainly.
function renderAway(el, h) {
    const f = toggleSheet(el, true);
    if (!f)
        return;
    if (!h) {
        // STANDALONE is a page with no spine at all (the docs copy, a wasm that
        // never booted): nothing can make an identity here. OFFLINE is a spine
        // that found no commune — and an identity needs none to be made: it is
        // minted and kept on this device, and joins a commune when one appears.
        if (idState.peek() === "standalone") {
            f.append("div").attr("class", "lead").text("the demo day");
            f.append("div").attr("class", "opt")
                .text("No commune is configured for this page, so there is no door to sign in through. "
                + "The cards, the plan and the dial are local samples you can play with freely; "
                + "sharing where you are, lending a means, and claiming all need a commune to reach.");
            f.append("div").attr("class", "opt")
                .text("Running it yourself? `make dev` serves the dial against a real local gateway.");
            return;
        }
        f.classed("wide", false);
        // The heading and the button come FIRST. Someone who has not signed in
        // can act on "create your identity"; they can act on nothing in a report
        // about infrastructure, so that report follows the act rather than
        // standing in front of it.
        createForm(el, f, "No commune is reachable right now — an identity needs none to be made. "
            + "It is minted and kept on this device, and takes a seat at a commune "
            + "the moment one is reachable.");
        return;
    }
    f.append("div").attr("class", "lead").text("the commune is unreachable");
    if (idState.peek() === "unlocked") {
        f.append("div").attr("class", "opt")
            .text("You are unlocked as this identity, but nothing can reach the commune right now — "
            + "so sharing where you are, lending a means, and claiming are all unavailable, "
            + "and the day on screen is this device's own rather than the commune's. Your "
            + "seat is taken the moment the commune is reachable again.");
    }
    else {
        // the passcode opens the identity against the log this device holds —
        // no commune in the loop — so the door to the cached day stays open here
        f.append("div").attr("class", "opt")
            .text("Nothing can reach the commune right now. Your passcode still opens this identity "
            + "here, against the log this device keeps — though the day on screen stays this "
            + "device's own until the commune answers again.");
        loginForm(f, { aid: h.aid || "", k0: h.k0, store: [null, null], button: "unlock",
            consent: g => consentGate(g, {}) });
    }
    identifierRow(f, h.aid);
    signOutRow(f);
}
// the sheet behind an unregistered chip: the commune has never seen this AID,
// and the log in hand is everything it needs to seat it. One tap — the
// gateway verifies the whole chain (signup-with-kel) and the seat follows.
function renderJoin(el, h) {
    const f = toggleSheet(el, true);
    if (!f)
        return;
    f.append("div").attr("class", "lead").text("this commune hasn't met you");
    f.append("div").attr("class", "opt")
        .text("Your identity was made elsewhere and this commune has never seen it. Your log "
        + "— every key event you've signed — is on this device, and that is all a "
        + "commune needs to seat you under your current key.");
    if (h)
        identifierRow(f, h.aid);
    // a browser that holds a current acceptance is not asked again to join: the
    // notice is re-read on a change of terms (§11), not on every seat
    const consented = consentGate(f, {});
    const err = f.append("div").attr("class", "err");
    f.append("button").attr("class", "go").text(`join as ${myName(h)}`)
        .on("click", async () => {
        if (!consented()) {
            err.text("please accept the terms and the privacy notice first");
            return;
        }
        err.text("");
        idState.set("busy");
        finishAuth(await (HANDLERS.join ? HANDLERS.join(h ? h.name : "", h ? h.email : "") : "err:offline"), null, null);
    });
    signOutRow(f);
}
// pull personhood standing from the gateway into the `person` signal. The
// chip does not read it — standing lives in the sheet — so this settles the
// signal and schedules the poll, and draws nothing itself.
async function refreshPersonhood() {
    if (!HANDLERS.fpStatus) {
        person.set(null);
        return;
    }
    let recognised = false;
    try {
        recognised = !!JSON.parse(await HANDLERS.fpStatus()).person;
    }
    catch (_) {
        person.set(null);
        return;
    }
    // not recognised here, but we carry a PHC from another gateway? present it
    // (the gateway verifies the issuer's signature + that it's a federated
    // commune, then imports — PHC presentation, slice-2).
    if (!recognised && HANDLERS.fpPresent) {
        const carried = readStr(K.idPhc);
        if (carried && carried.startsWith("{")) {
            try {
                if ((await HANDLERS.fpPresent(carried)) === "ok")
                    recognised = !!JSON.parse(await HANDLERS.fpStatus()).person;
            }
            catch (_) { }
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
        try {
            const card = await HANDLERS.fpMyPhc();
            if (typeof card === "string" && card.startsWith("{"))
                writeStr(K.idPhc, card);
        }
        catch (_) { }
    }
    await carryVouches();
    if (recognised) {
        if (wasCollecting)
            hint("you've been recognised — welcome.", "success");
        ask.set({ state: "finalized", count: 0, quorum: 0, witnesses: [], vouchers: [] });
    }
    else {
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
async function carryVouches() {
    if (!HANDLERS.fpMyVouches)
        return;
    try {
        const b = await HANDLERS.fpMyVouches();
        if (typeof b === "string" && b.startsWith("{"))
            writeStr(VOUCHES_KEY, b);
    }
    catch (_) { }
}
async function presentCarriedVouches() {
    if (!HANDLERS.fpPresentBundle)
        return;
    const carried = readStr(VOUCHES_KEY);
    if (!carried || !carried.startsWith("{") || carried === vouchesPresented)
        return;
    try {
        const r = await HANDLERS.fpPresentBundle(carried);
        if (typeof r === "string" && r.startsWith("ok:"))
            vouchesPresented = carried;
    }
    catch (_) { }
}
const ask = signal(null);
async function refreshAsk() {
    if (!HANDLERS.fpMyCeremony) {
        ask.set(null);
        return;
    }
    try {
        const o = JSON.parse(await HANDLERS.fpMyCeremony());
        ask.set({ state: o.state === "collecting" ? "collecting" : o.state === "finalized" ? "finalized" : "none",
            count: Number(o.count) || 0, quorum: Number(o.quorum) || 0,
            witnesses: Array.isArray(o.witnesses) ? o.witnesses : [],
            vouchers: Array.isArray(o.vouchers) ? o.vouchers : [] });
    }
    catch (_) {
        ask.set(null);
    }
}
// while an ask is collecting, re-read it so the sheet's "n of k" and the badge
// follow each vouch as it lands, and flip to recognised the moment the
// credential issues — the ceremony is the truth, nothing on this device is
let _fpPoll = null;
function scheduleFpPoll() {
    if (_fpPoll) {
        clearTimeout(_fpPoll);
        _fpPoll = null;
    }
    if (person.peek() === false && ask.peek()?.state === "collecting")
        _fpPoll = setTimeout(refreshPersonhood, 30000);
}
/** How the quorum reads as a sentence — the recovery-friends idiom, one tap away. */
function askSaying(a) {
    const need = a.quorum, have = a.count;
    const who = (n) => n === 1 ? "one recognised person" : `${n} recognised people`;
    if (have >= need)
        return "enough people have signed — your credential is being issued.";
    const left = need - have;
    return have === 0
        ? `${who(need)} must sign that they have met you.`
        : `${have} of ${need} have signed — ${who(left)} more must sign that they have met you.`;
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
export const CONSENT_SENTENCE = ["I've read and accept the ", ["terms of use", TERMS_HREF], " and the ", ["privacy notice", PRIVACY_HREF], "."];
/** The one irreversible consequence, said at the point of decision. */
export const ONLY_KEY_NOTE = "your passcode is the only key: nobody can reset it for you.";
const consentRecord = () => readJSON(K.idConsent, null);
const consentCurrent = () => {
    const c = consentRecord();
    return !!(c && c.v === LEGAL_VERSION);
};
// Idempotent by design: the record means "this browser accepted version V on
// date D", so a later sign-in that was NOT asked again (because V is current)
// must not overwrite D with today. Only a fresh acceptance writes.
const recordConsent = (aid) => {
    if (consentCurrent())
        return;
    // storage disabled loses the record, never the gate — the tick already
    // stopped the action it was in front of
    writeJSON(K.idConsent, { v: LEGAL_VERSION, at: new Date().toISOString(), aid: aid || "" });
};
// The gate itself. Appends a checkbox + links to `f` and returns ok(), which
// the caller must consult BEFORE doing anything. Returns a permanently-true
// ok() and renders nothing when the current version is already accepted, so a
// returning member is not re-asked on every unlock.
function consentGate(f, opts) {
    if (!(opts && opts.force) && consentCurrent())
        return () => true;
    // A plain <div>, NOT a <label> wrapping the whole line: an <a> inside a label
    // both follows the link and toggles the box, so opening the terms would tick
    // "I have read them". The prose runs in <label for=…> spans instead, which
    // keeps a generous tap target while the two links stay inert to the checkbox.
    const boxId = "pnconsent" + (consentGate._n =
        (consentGate._n || 0) + 1);
    const row = f.append("div").attr("class", "consent");
    const box = row.append("input").attr("type", "checkbox").attr("id", boxId);
    const txt = row.append("span");
    const say = (s) => txt.append("label").attr("for", boxId).text(s);
    const link = (href, s) => txt.append("a").attr("href", href)
        .attr("target", "_blank").attr("rel", "noopener").text(s);
    if (consentRecord())
        say("the terms have changed — ");
    for (const part of CONSENT_SENTENCE)
        if (typeof part === "string")
            say(part);
        else
            link(part[1], part[0]);
    // The two consequences that are genuinely irreversible, said at the point of
    // decision rather than only in the linked document nobody opens.
    f.append("div").attr("class", "opt")
        .text(ONLY_KEY_NOTE);
    // a checkbox's `checked` is a boolean; property() answers unknown for the
    // general case, and this is not the general case.
    return () => box.property("checked");
}
// ── explicit consent to record a political opinion (Art 9(2)(a)) ─────────
// How you vote is recorded against your identity and read by the tallying
// scope (privacy notice §3.1). The notice's basis there is Art 9(2)(d), open
// only to an operator that IS a body with a political, philosophical,
// religious or trade-union aim — a legal-structure decision not yet made
// (docs/legal/README.md §10 row 7). Until it is, (a) is the fallback:
// explicit, specific consent, asked separately from the general terms tick so
// it is not bundled into a condition of having an identity at all — voting is
// optional, so consenting to its one special-category fact must be too.
// Collected here (offered once, at the same moment the terms are) AND
// enforced again at the first real cast (governance.ts), which covers an
// identity made before this ask existed, or a tick left unchecked.
export const VOTE_CONSENT_SENTENCE = "I agree that how I vote on a federation proposal is recorded against my identity, and read by whoever tallies it (privacy notice §3.1). You can vote without agreeing now — you will be asked again the first time you cast one.";
export const voteConsentGiven = (aid) => {
    const c = readJSON(K.voteConsent, null);
    return !!(aid && c && c.aid === aid);
};
export const recordVoteConsent = (aid) => {
    if (!aid || voteConsentGiven(aid))
        return;
    writeJSON(K.voteConsent, { aid, at: new Date().toISOString() });
};
// Withdrawal has to be as easy as giving it (Art 7(3)): one settings toggle,
// no contact form. Only clears THIS identity's record — a device that has
// used more than one identity never touches the other's.
export const forgetVoteConsent = (aid) => {
    if (aid && voteConsentGiven(aid))
        forget(K.voteConsent);
};
// a strong passcode: 120 bits from an unambiguous alphabet (no 0/o/1/l),
// hyphen-grouped so it is copyable. It is the ONLY key — no recovery.
function genPasscode() {
    const A = "abcdefghijkmnpqrstuvwxyz23456789"; // 32 chars
    const b = crypto.getRandomValues(new Uint8Array(24));
    let s = "";
    for (let i = 0; i < 24; i++) {
        s += A[b[i] & 31];
        if (i % 6 === 5 && i < 23)
            s += "-";
    }
    return s;
}
/**
 * Settle an auth / signup / join reply — the one place a door swings open.
 *
 * Everything that follows a success follows it HERE: remember the identity if
 * this reply carries new details, move the door state, record the acceptance
 * the gate collected, and close the sheet. `onSuccess` exists for the single
 * flow that has something else to show instead of closing (create, which
 * reveals the passcode). nameToStore/emailToStore are null on an unlock — the
 * hint already exists and the reply carries nothing newer.
 */
function finishAuth(r, nameToStore, emailToStore, onSuccess) {
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
            if (HANDLERS.tier)
                HANDLERS.tier().then(t => { if (t === "root")
                    autoEnrollDevice(); });
        }
        // The gate that let this through was an affirmative act; record it once,
        // here, rather than in each of the four flows that pass through a gate.
        // recordConsent is idempotent — a returning member who was not re-asked
        // keeps the date they actually accepted on.
        recordConsent(aid);
        if (onSuccess)
            onSuccess(aid, k0);
        else
            closeSheet();
    }
    else {
        idState.set("idle");
        d3.select("#idrow").select(".who").classed("off", false);
        hint(String(r || "err:no reply").replace(/^err:/, ""), "error");
    }
}
function renderIdForm(el, h) {
    const f = toggleSheet(el);
    if (!f)
        return;
    // returning identity — passcode only (the AID is the stored hint, supplied
    // to the password manager as a hidden username so it fills the right entry).
    if (h) {
        f.append("div").attr("class", "lead").text(`unlock ${h.name || "your identity"}`);
        // consentGate renders nothing here unless the notices changed since this
        // member last accepted them (§11 of the terms: re-accept on material change).
        loginForm(f, { aid: h.aid || "", k0: h.k0, store: [null, null], button: "unlock",
            consent: g => consentGate(g, {}) });
        f.append("div").attr("class", "gen2").style("margin-top", "7px")
            .text("another way in — recovery file, friends' pieces, a different identity")
            .on("click", () => renderOtherSignIn(el));
        return;
    }
    createForm(el, f);
}
// new identity — one tap. A passcode (your only key) is generated for you;
// the AID is the inception event's SAID, minted in the browser on create, so
// the COMPLETE identity — AID + passcode + a recovery file with both — is
// revealed AFTER create, in renderIdCreated. No passcode-first step: there is
// nothing complete to save until the AID exists, and showing only the
// passcode first invites saving a half-identity. No name, no email — those
// are optional, added in settings. The same form with a commune reachable
// and without: the identity is made here either way, and a commune is
// something it joins.
function createForm(el, f, note) {
    f.append("div").attr("class", "lead").text("create your identity");
    f.append("div").attr("class", "opt")
        .text("a passcode is generated for you — it's your only key. The moment you create, you'll "
        + "see it once, and can save a recovery file that opens this identity on any device.");
    // the caller's condition, said after the act it does not prevent
    if (note)
        f.append("div").attr("class", "opt").text(note);
    // acceptance is required to create — always shown on this path, even to a
    // browser that already holds a current record, because creating an identity
    // IS the collection moment Article 13 is about.
    const consented = consentGate(f, { force: true });
    const err = f.append("div").attr("class", "err");
    f.append("button").attr("class", "go").text("create your identity").on("click", async () => {
        if (!consented()) {
            err.text("please accept the terms and the privacy notice first");
            return;
        }
        err.text("");
        const bran = genPasscode(); // 120-bit client-side key; never stored or sent
        idState.set("busy");
        // on success the AID exists — reveal AID + passcode + recovery file so
        // sign-in on another device is possible (renderIdCreated). On error the
        // form stays for retry; no orphan key was shown.
        finishAuth(await (HANDLERS.signup ? HANDLERS.signup("", "", bran) : "err:offline"), "", "", (aid) => renderIdCreated(el, aid, bran));
    });
    f.append("div").attr("class", "gen2").style("margin-top", "7px")
        .text("I already have an identity — sign in")
        .on("click", () => renderOtherSignIn(el));
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
async function setMyName(name, email) {
    const cur = who.peek();
    if (cur)
        remember({ ...cur, name, email });
    const r = String(await (HANDLERS.profileSet
        ? HANDLERS.profileSet(name, email) : "err:offline"));
    if (r === "ok")
        forget(NAME_PENDING);
    else
        writeStr(NAME_PENDING, "1");
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
async function syncName() {
    if (nameSyncing)
        return;
    nameSyncing = true;
    try {
        const cur = who.peek();
        if (!cur)
            return;
        if (readStr(NAME_PENDING) === "1") {
            if (HANDLERS.profileSet && (await HANDLERS.profileSet(cur.name, cur.email)) === "ok")
                forget(NAME_PENDING);
            return;
        }
        if (!HANDLERS.profileGet)
            return;
        const o = JSON.parse(await HANDLERS.profileGet());
        const now = who.peek();
        if (now && now.aid === cur.aid && o.name && o.name !== now.name)
            remember({ ...now, name: o.name, email: now.email || o.email || "" });
    }
    catch (_) { /* unread stays as this device has it */ }
    finally {
        nameSyncing = false;
    }
}
async function downloadIdentityFile(aid, bran) {
    const h = idHint();
    let kel = null;
    try {
        const raw = HANDLERS.kelExport ? await HANDLERS.kelExport() : "";
        if (typeof raw === "string" && raw.startsWith("{"))
            kel = JSON.parse(raw);
    }
    catch (_) {
        kel = null;
    }
    const file = {
        "playnet-identity": 1,
        note: "keep this file private and durable — the passcode is your only key and cannot be recovered; the kel is your identity's own signed log, which any commune can verify",
        aid, name: h ? h.name : "", email: h ? h.email : "", passcode: bran, kel,
    };
    const blob = new Blob([JSON.stringify(file, null, 2)], { type: "application/json" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "playnet-identity.json";
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(a.href);
}
// a recovery file opened on this device: its log becomes this device's log
// (kelImport), its name/email the hint, and its passcode unlocks at once.
// A file without a log (one written before the browser kept its KEL) still
// carries AID + passcode, which is the "sign in with a passcode" path.
async function openIdentityFile(text, err) {
    let file;
    try {
        file = JSON.parse(text);
    }
    catch (_) {
        err.text("that is not a playnet identity file");
        return;
    }
    if (!file || file["playnet-identity"] !== 1 || typeof file.passcode !== "string") {
        err.text("that is not a playnet identity file");
        return;
    }
    let aid = typeof file.aid === "string" ? file.aid : "", k0 = "";
    if (file.kel && typeof file.kel === "object" && HANDLERS.kelImport) {
        const r = await HANDLERS.kelImport(JSON.stringify(file.kel));
        if (typeof r !== "string" || !r.startsWith("ok:")) {
            err.text(String(r || "err:no reply").replace(/^err:/, ""));
            return;
        }
        [aid, k0] = r.slice(3).split("|");
    }
    if (!aid) {
        err.text("the file names no identity");
        return;
    }
    err.text("");
    idState.set("busy");
    finishAuth(await (HANDLERS.unlock ? HANDLERS.unlock(file.passcode, aid, k0) : "err:offline"), typeof file.name === "string" ? file.name : "", typeof file.email === "string" ? file.email : "");
}
// post-create: the identity exists and its passcode is on screen for the ONE
// time it will ever be shown. Dismissing this sheet without saving it locks
// the person out of their own identity permanently, so the sheet HOLDS itself
// open — the chip, a stray Enter, another sheet, and the tab's own close all
// route through closeSheet/beforeunload and are refused until they confirm
// they have it. Same contract a wallet's seed phrase gets, for the same
// reason: there is no reset, no support desk, no second chance.
//
// The identifier is shown beside the passcode, whole and copiable. It is the
// username a password manager files the passcode under, and it is what a
// device that holds nothing needs beside the passcode at a commune that has
// never met this identity — so a person who writes the passcode down writes
// the identifier with it, or takes the recovery file, which carries both.
function renderIdCreated(el, aid, bran) {
    const f = openSheet(el, true);
    holdSheet(true);
    // The tab itself is a way out, and the browser owns that door — so take the
    // only hook it offers. Released the moment the passcode is confirmed saved.
    const guard = (e) => { e.preventDefault(); e.returnValue = ""; };
    window.addEventListener("beforeunload", guard);
    const release = () => {
        window.removeEventListener("beforeunload", guard);
        holdSheet(false);
        closeSheet();
    };
    f.append("div").attr("class", "lead").text("identity created");
    f.append("div").attr("class", "opt")
        .text("this passcode is the only key to it, and this is the one time it is shown. "
        + "Keep it with your identifier — or take the recovery file, which holds both.");
    // A real credential <form>: username = the identifier, password = the
    // passcode, with the autocomplete hints password managers read. Submitting
    // is the gesture the browser's built-in manager watches for; extensions
    // detect the new-password field directly.
    const form = f.append("form").attr("autocomplete", "on").attr("action", "#");
    form.append("label").attr("class", "sublead").text("passcode (your key)");
    const pass = form.append("input").attr("class", "pcode")
        .attr("type", "password").attr("name", "password")
        .attr("autocomplete", "new-password")
        .attr("readonly", true).attr("spellcheck", "false").property("value", bran);
    const row = form.append("div").attr("class", "genrow");
    row.append("span").attr("class", "gen2").text("show").on("click", function () {
        const showing = pass.attr("type") === "text";
        pass.attr("type", showing ? "password" : "text");
        d3.select(this).text(showing ? "show" : "hide");
    });
    row.append("span").attr("class", "gen2").text("copy").on("click", function () {
        if (navigator.clipboard)
            navigator.clipboard.writeText(bran);
        const t = d3.select(this);
        t.text("✓ copied");
        setTimeout(() => t.text("copy"), 1500);
    });
    form.append("label").attr("class", "sublead").text("identifier (names you — not secret)");
    identifierRow(form, aid, true);
    form.append("button").attr("class", "go").attr("type", "button").style("margin-top", "8px")
        .text("⬇ download recovery file").on("click", () => downloadIdentityFile(aid, bran));
    form.append("div").attr("class", "opt")
        .text("the file holds the passcode and the identifier together with your identity's own "
        + "signed log — it opens this identity on any device, and seats it at a commune "
        + "that has never met you.");
    // THE GATE. Nothing below is reachable until this is ticked, and the sheet
    // cannot be dismissed while it is not. Deliberately an affirmative act: a
    // person who has written it on paper is as safe as one who downloaded, so
    // this asks what they know rather than watching what they clicked.
    const gateId = "pnsaved" + (renderIdCreated._n =
        (renderIdCreated._n || 0) + 1);
    const gate = form.append("div").attr("class", "consent");
    const box = gate.append("input").attr("type", "checkbox").attr("id", gateId);
    gate.append("label").attr("for", gateId)
        .text("I've saved my passcode. I understand it cannot be shown again.");
    form.append("label").attr("class", "sublead").style("margin-top", "10px")
        .text("what should people call you?");
    const nameIn = form.append("input").attr("type", "text")
        .attr("name", "nickname").attr("autocomplete", "nickname")
        .attr("spellcheck", "false")
        .attr("placeholder", "a name — optional, and changeable any time");
    form.append("div").attr("class", "opt")
        .text("please do not use your legal name — this is an early-stage demo; a nickname is fine.");
    // on blur, so the name is in the hint before the recovery file is written
    // (downloadIdentityFile reads it from there) and the chip says it at once
    nameIn.on("change", () => { setMyName(nameIn.property("value").trim(), ""); });
    const done = form.append("button").attr("class", "go").attr("type", "submit")
        .style("margin-top", "6px").attr("disabled", true).style("opacity", "0.45")
        .text("done");
    // a button that is dead must LOOK dead — an enabled-looking one that
    // silently does nothing reads as a broken page, which is worse than a
    // greyed one that explains itself by being greyed
    box.on("change", () => {
        const ok = box.property("checked");
        done.attr("disabled", ok ? null : true).style("opacity", ok ? "1" : "0.45");
    });
    form.on("submit", async function (e) {
        e.preventDefault();
        if (!box.property("checked"))
            return; // Enter cannot slip past
        const n = nameIn.property("value").trim();
        if (n)
            await setMyName(n, "");
        release();
    });
}
// sign in to an EXISTING identity on a device that holds nothing of it. Three
// doors, in the order people reach for them.
//   The passcode. It derives the identity's inception key, and a commune that
//   holds the log under that key hands it over (find-icp); the spine checks
//   the log is this passcode's own and keeps it. The identifier is asked for
//   only as an option: it names the identity outright, which is what a
//   commune that has never met it — or a password manager — goes by.
//   A recovery file. It brings the passcode and the log together, so it
//   opens the identity anywhere, with no commune in reach.
//   The people you trusted. Their pieces give the passcode back.
function renderOtherSignIn(el) {
    const f = openSheet(el);
    f.append("div").attr("class", "lead").text("sign in");
    f.append("div").attr("class", "opt")
        .text("your passcode opens your identity: a commune that has met you finds it from the "
        + "passcode alone. Add your identifier if you have it — a password manager fills both.");
    // aid:null ⇒ a typed, optional identifier; empty k0 skips the same-identity
    // guard so handle-unlock signs in as the identity found and the reply
    // stores a complete hint. force:true — this browser may never have seen
    // the notices even though the identity predates it, so ask here too.
    loginForm(f, { aid: null, k0: "", store: ["", ""], button: "sign in",
        consent: g => consentGate(g, { force: true }) });
    f.append("div").attr("class", "lead").style("margin-top", "12px").text("or open your recovery file");
    f.append("div").attr("class", "opt")
        .text("the file holds your passcode and your identity's log — open it and you are in, "
        + "at any commune.");
    const fileErr = f.append("div").attr("class", "err");
    const pick = f.append("input").attr("type", "file").attr("accept", ".json,application/json")
        .style("display", "none")
        .on("change", async function () {
        const files = this.files;
        if (!files || !files[0])
            return;
        await openIdentityFile(await files[0].text(), fileErr);
    });
    f.append("button").attr("class", "go").attr("type", "button")
        .text("open recovery file").on("click", () => pick.node().click());
    // ── the third door: the people you trusted ──
    // Someone who lost their passcode has no file and nothing to type — what
    // they have is friends holding pieces. This asks for those, works out whose
    // identity they open and whether there are enough, and then walks the very
    // same unlock the other two doors do.
    f.append("div").attr("class", "lead").style("margin-top", "12px")
        .text("or with help from people you trusted");
    f.append("div").attr("class", "opt")
        .text("if you split your passcode among people, ask them for their pieces and "
        + "paste them here — one per line.");
    const pieces = f.append("textarea").attr("class", "pcode").attr("rows", "3")
        .attr("spellcheck", "false")
        .attr("placeholder", "pnr1.… (one piece per line)");
    const pErr = f.append("div").attr("class", "err");
    f.append("button").attr("class", "go").attr("type", "button")
        .text("put my passcode back together").on("click", async () => {
        const lines = String(pieces.property("value") || "")
            .split("\n").map(l => l.trim()).filter(Boolean);
        if (!lines.length) {
            pErr.text("paste the pieces your friends sent you");
            return;
        }
        pErr.text("");
        const r = String(await (HANDLERS.guardianRecover
            ? HANDLERS.guardianRecover(JSON.stringify(lines))
            : "err:offline"));
        if (!r.startsWith("ok:")) {
            pErr.text(r.replace(/^err:/, ""));
            return;
        }
        // the pieces gave back the identifier and the passcode — from here it is
        // an ordinary unlock, so a recovered identity lands exactly where a
        // remembered one does
        const [aid, bran] = r.slice(3).split("|");
        idState.set("busy");
        finishAuth(await (HANDLERS.unlock ? HANDLERS.unlock(bran, aid, "") : "err:offline"), "", "");
    });
    f.append("div").attr("class", "gen2").style("margin-top", "10px").text("← back")
        .on("click", () => { closeSheet(); renderIdForm(el, idHint()); });
}
// One login <form> for both sign-in paths — password managers autofill via the
// username(AID)/current-password fields, then submit calls unlock. opts:
//   aid    a known AID (rendered as a hidden username), or null for a typed,
//          OPTIONAL one: left empty, the passcode alone names the identity
//   k0     the same-identity guard value passed to unlock
//   store  [name, email] written to the localStorage hint on success
//   button submit-button label
//   consent optional (form) => ok(); submit is blocked until ok() is true.
//           finishAuth records the acceptance on success. Omitted ⇒ ungated.
function loginForm(parent, opts) {
    const form = parent.append("form").attr("autocomplete", "on").attr("action", "#");
    let typed = null;
    if (opts.aid == null) {
        typed = form.append("input").attr("type", "text").attr("name", "username")
            .attr("autocomplete", "username").attr("spellcheck", "false")
            .attr("placeholder", "identifier — optional");
    }
    else {
        // hidden username = the known AID, so the manager fills the matching entry
        form.append("input").attr("type", "text").attr("name", "username")
            .attr("autocomplete", "username").property("value", opts.aid)
            .attr("readonly", true).attr("tabindex", "-1").attr("aria-hidden", "true")
            .style("position", "absolute").style("width", "1px").style("height", "1px")
            .style("opacity", "0").style("pointer-events", "none");
    }
    const pass = form.append("input").attr("type", "password").attr("name", "password")
        .attr("autocomplete", "current-password").attr("placeholder", "passcode — 21+ characters");
    // the gate sits between the credentials and the submit button, where it is
    // read, rather than above the form where it scrolls out of mind
    const consented = opts.consent ? opts.consent(form) : (() => true);
    const err = form.append("div").attr("class", "err");
    form.on("submit", async (e) => {
        e.preventDefault();
        const a = typed ? typed.property("value").trim() : opts.aid;
        const bran = pass.property("value");
        if (!bran || bran.length < 21) {
            err.text("the passcode needs 21+ characters");
            return;
        }
        if (!consented()) {
            err.text("please accept the terms and the privacy notice first");
            return;
        }
        err.text("");
        idState.set("busy");
        // a typed identifier left empty goes as "": the spine then opens the
        // identity the passcode itself names (the log held here, or the one the
        // commune holds under the passcode's inception key)
        finishAuth(await (HANDLERS.unlock ? HANDLERS.unlock(bran, a || "", opts.k0) : "err:offline"), opts.store[0], opts.store[1]);
    });
    form.append("button").attr("class", "go").attr("type", "submit").text(opts.button);
    return form;
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
export function devicesSection(f) {
    const sec = f.append("div").attr("class", "devsec");
    sec.append("div").attr("class", "sublead").text("this device");
    const here = sec.append("div");
    const list = sec.append("div").attr("class", "vlist");
    const err = sec.append("div").attr("class", "err");
    const fail = (r) => err.text(String(r || "err").replace(/^err:/, ""));
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
            let armed = null;
            stop.on("click", async () => {
                if (!stop.classed("arm")) {
                    stop.classed("arm", true).text("tap again to stop — the passcode will be asked next time");
                    armed = setTimeout(() => { stop.classed("arm", false).text("stop staying signed in here"); }, 8000);
                    return;
                }
                if (armed)
                    clearTimeout(armed);
                const said = deviceSaidHere();
                if (said && HANDLERS.revokeDevice) {
                    const r = await HANDLERS.revokeDevice(said);
                    if (r !== "ok") {
                        fail(r);
                        return;
                    }
                }
                await forgetDeviceHere();
                writeStr(DECLINED, "1");
                hint("this device will ask for your passcode next time", "warn");
                await drawHere();
                await drawList();
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
        const enrol = async (tierName) => {
            err.text("");
            const r = await (HANDLERS.enrollDevice ? HANDLERS.enrollDevice(deviceLabel(), tierName) : "err:offline");
            if (r === "ok") {
                forget(DECLINED);
                await drawHere();
                await drawList();
            }
            else
                fail(r);
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
        if (!HANDLERS.devices)
            return;
        let ds = [];
        try {
            ds = JSON.parse(String(await HANDLERS.devices()));
        }
        catch {
            return;
        }
        const live = ds.filter(d => !d.revokedAt);
        if (!live.length)
            return;
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
                if (r !== "ok") {
                    fail(r);
                    return;
                }
                if (d.said === mine)
                    await forgetDeviceHere();
                hint(d.said === mine ? "this device will ask for your passcode next time"
                    : `${d.label || "that device"} will ask for the passcode next time`, "warn");
                await drawHere();
                await drawList();
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
    const OUTSIDE_PRESETS = [
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
        if (tier !== "root" || !HANDLERS.enrollExternalDevice)
            return;
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
            if (!/^B[A-Za-z0-9_-]{43}$/.test(a)) {
                fail("err:a device identifier is 44 characters and starts with B");
                return;
            }
            const i = Number(preset.property("value") || 0);
            const doors = i === 2 ? String(custom.property("value") || "") : OUTSIDE_PRESETS[i].doors;
            const r = await HANDLERS.enrollExternalDevice(a, String(label.property("value") || "").trim(), doors);
            if (r === "ok") {
                hint(`${label.property("value") || "that interface"} may now sign for you`, "success");
                aid.property("value", "");
                label.property("value", "");
                custom.property("value", "");
                await drawList();
            }
            else
                fail(String(r));
        });
    };
    const outside = f.append("div").style("margin-top", "10px");
    drawHere();
    drawList();
    drawOutside();
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
export function passcodeSection(f) {
    const sec = f.append("div");
    const guard = (e) => { e.preventDefault(); e.returnValue = ""; };
    const clear = () => { sec.selectAll("*").remove(); };
    const say = (text) => { sec.append("div").attr("class", "opt").text(text); };
    // 1 ── the current passcode
    const ask = () => {
        clear();
        window.removeEventListener("beforeunload", guard);
        const h = who.peek();
        if (!h || !HOLDS_IDENTITY(idState.peek())) {
            say("sign in to change your passcode.");
            return;
        }
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
            const current = cur.property("value");
            if (!current || current.length < 21) {
                err.text("the passcode needs 21+ characters");
                return;
            }
            err.text("");
            const r = String(await (HANDLERS.passcodeCheck ? HANDLERS.passcodeCheck(current) : "err:offline"));
            if (r !== "ok") {
                err.text(r.replace(/^err:/, ""));
                return;
            }
            review(h, current, genPasscode());
        });
    };
    // 2 ── the new passcode, saved before anything changes
    const review = (h, current, next) => {
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
            if (navigator.clipboard)
                navigator.clipboard.writeText(next);
            const t = d3.select(this);
            t.text("✓ copied");
            setTimeout(() => t.text("copy"), 1500);
        });
        form.append("label").attr("class", "sublead").text("identifier (stays the same)");
        identifierRow(form, h.aid, true);
        form.append("div").attr("class", "warn")
            .text("When you make the change: the current passcode stops opening your identity, here and "
            + "everywhere. Every device is signed out and this one is signed back in. Pieces you gave "
            + "to recovery friends, and your old recovery file, stop working. Cards people gave you "
            + "before now need giving again.");
        const gateId = "pnchanged" + (passcodeSection._n = (passcodeSection._n || 0) + 1);
        const gate = form.append("div").attr("class", "consent");
        const box = gate.append("input").attr("type", "checkbox").attr("id", gateId);
        gate.append("label").attr("for", gateId)
            .text("I've saved the new passcode. I understand it cannot be shown again.");
        const err = form.append("div").attr("class", "err");
        const go = form.append("button").attr("class", "go").attr("type", "submit")
            .attr("disabled", true).style("opacity", "0.45").text("change passcode");
        box.on("change", () => {
            const ok = box.property("checked");
            go.attr("disabled", ok ? null : true).style("opacity", ok ? "1" : "0.45");
        });
        form.append("div").attr("class", "gen2").style("margin-top", "8px").text("cancel — keep the current passcode")
            .on("click", ask);
        let busy = false;
        form.on("submit", async (e) => {
            e.preventDefault();
            if (busy || !box.property("checked"))
                return;
            busy = true;
            err.text("");
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
    const changed = (h, next, retired) => {
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
    effect(() => { const now = !!who(); if (now !== seen) {
        seen = now;
        ask();
    } });
}
/**
 * Retire every device key this identity authorized — a passcode change's
 * second half: a device someone else enrolled with the old passcode goes with
 * the rest. This device's own key goes too and is authorized afresh, under
 * the key now in force. Answers how many OTHER devices were retired.
 */
async function retireEveryDevice() {
    let others = 0;
    try {
        const mine = deviceSaidHere();
        const all = JSON.parse(String(HANDLERS.devices ? await HANDLERS.devices() : "[]"));
        for (const d of all.filter(x => !x.revokedAt)) {
            const r = HANDLERS.revokeDevice ? await HANDLERS.revokeDevice(d.said) : "err:offline";
            if (r === "ok" && d.said !== mine)
                others++;
        }
    }
    catch (_) { /* the list in settings still retires them one by one */ }
    await forgetDeviceHere();
    await autoEnrollDevice();
    return others;
}
export function recoveryFriends(f) {
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
    const chosenNames = () => people.filter(c => recoveryPicks().has(c.aid)).map(c => c.alias || c.aid);
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
    const need = (n) => Math.max(2, Math.ceil(n / 2));
    const saying = (n) => n === 0 ? "choose the people you would ask for help."
        : n === 1 ? "choose at least one more — a single piece is just your passcode in someone else's hands."
            : `any ${need(n)} of these ${n} could bring your passcode back. Fewer than ${need(n)} could not.`;
    const count = sec.append("div").attr("class", "opt").text(saying(chosenNames().length));
    const err = sec.append("div").attr("class", "err");
    const out = sec.append("div");
    const makePieces = async () => {
        const names = chosenNames();
        err.text("");
        out.selectAll("*").remove();
        const k = need(names.length);
        const r = await (HANDLERS.guardianSplit
            ? HANDLERS.guardianSplit(String(k), String(names.length))
            : "err:offline");
        let lines = [];
        try {
            lines = JSON.parse(String(r));
        }
        catch (_) { /* not JSON ⇒ an error string */ }
        if (!Array.isArray(lines) || lines.length !== names.length) {
            err.text(String(r).replace(/^err:/, ""));
            return;
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
                if (navigator.clipboard)
                    navigator.clipboard.writeText(lines[i]);
                const t = d3.select(this);
                t.text("✓ copied");
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
    const askPasscode = () => {
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
            const bran = pass.property("value");
            if (!bran || bran.length < 21) {
                err.text("the passcode needs 21+ characters");
                return;
            }
            err.text("");
            const r = String(await (HANDLERS.unlock && h ? HANDLERS.unlock(bran, h.aid, h.k0) : "err:offline"));
            if (!/^(ok|local|unregistered):/.test(r)) {
                err.text(r.replace(/^err:/, ""));
                return;
            }
            await makePieces();
        });
    };
    sec.append("button").attr("class", "go").text("make the pieces")
        .on("click", async () => {
        if (chosenNames().length < 2) {
            err.text("choose at least two people");
            return;
        }
        const tier = HANDLERS.tier ? String(await HANDLERS.tier()) : "";
        if (tier === "root")
            await makePieces();
        else
            askPasscode();
    });
}
// the profile/settings popover for a signed-in identity: a display name
// (for discovery) and an email (for notifications). Both optional, neither
// touches recovery. Read/written through the AID-bound session.
async function renderSettings(el, h) {
    const f = toggleSheet(el, true);
    if (!f)
        return;
    f.append("div").attr("class", "lead").text("your identity");
    // ── where you are ── the profile leads: this sheet is opened by tapping
    // your own name, so what you came to look at and change comes first — the
    // place the commons holds for you. Skills live in the inventory drawer's
    // Skills view. Standing follows; told first, "provisional" reads as a verdict.
    f.append("div").attr("class", "sublead").text("where you are");
    whereBlock(f, closeSheet);
    // ── personhood standing (First-Person) ──
    const ps = f.append("div").attr("class", "phcrow").text("checking standing…");
    // ── keys, devices, recovery: their own settings group ──
    // The sheet you open by tapping your name says who you are and lets you
    // sign out; the device keys and the recovery pieces are settings, reached
    // from here by one button so the sheet stays short.
    f.append("div").attr("class", "sublead").text("keys and devices");
    f.append("span").attr("class", "vbtn keysbtn")
        .text("stay signed in, change passcode, recovery friends → settings")
        .on("click", () => { closeSheet(); openSettings("device"); });
    // ── the people you know: each person's row in Contacts holds what stands
    // between you and every act on it (vouch, withdraw, witness, introduce)
    f.append("div").attr("class", "sublead").text("people you know");
    f.append("span").attr("class", "vbtn keysbtn")
        .text("vouch, witness, introduce → contacts")
        .on("click", () => { closeSheet(); revealContacts(); });
    // ── name ── LAST of the profile: one optional field a person sets once,
    // under the parts they come back to — where they are and what they can do.
    // How to reach you (an email, a handle, a number) is its own list, in
    // settings: yours, and told to the commune or a contact by your own act.
    f.append("div").attr("class", "sublead").text("name");
    // Seeded from the local hint, which is what this device believes and what the
    // chip is already saying — a name set with no commune in reach lives here and
    // nowhere else yet. The commune's own answer refines it below.
    const pair = f.append("div").attr("class", "idpair");
    const name = pair.append("input").attr("type", "text")
        .attr("placeholder", "name — so others can find you")
        .property("value", h ? h.name : "");
    const err = f.append("div").attr("class", "err");
    const saveRow = f.append("div").attr("class", "idsave");
    saveRow.append("span").attr("class", "opt")
        .text("optional, and not used for recovery — please do not use your legal name while this is a demo.");
    saveRow.append("span").attr("class", "vbtn").text("save").on("click", async () => {
        // the email the member record holds stays as it is
        const r = await setMyName(name.property("value").trim(), who.peek()?.email || "");
        if (r === "ok") {
            closeSheet();
            idState.set("authed");
        }
        else
            err.text(r.replace(/^err:/, ""));
    });
    f.append("div").attr("class", "sublead").text("how to reach you");
    f.append("span").attr("class", "vbtn keysbtn")
        .text("your addresses, and who you have told → settings")
        .on("click", () => { closeSheet(); openSettings("reach"); });
    if (h) {
        f.append("div").attr("class", "sublead").style("margin-top", "10px")
            .text("your identifier");
        identifierRow(f, h.aid);
    }
    // the notices stay reachable after signup — Article 13 information has to be
    // available, not just flashed once at the door — with the recorded acceptance
    // beside them so a member can see what they agreed to and when.
    const legal = f.append("div").attr("class", "legalrow");
    legal.append("a").attr("href", TERMS_HREF).attr("target", "_blank")
        .attr("rel", "noopener").text("terms of use");
    legal.append("span").text(" · ");
    legal.append("a").attr("href", PRIVACY_HREF).attr("target", "_blank")
        .attr("rel", "noopener").text("privacy notice");
    const c = consentRecord();
    if (c && c.at)
        legal.append("div").attr("class", "opt")
            .text(`accepted v${DOCUMENT_VERSION} (effective ${c.v}) on ${String(c.at).slice(0, 10)}`);
    signOutRow(f);
    // async fills ----------------------------------------------------------
    if (HANDLERS.fpStatus) {
        try {
            const o = JSON.parse(await HANDLERS.fpStatus());
            person.set(!!o.person);
            ps.html("");
            if (o.person) {
                ps.append("span").attr("class", "phc yes").text("✓ recognised person");
                const phc = readStr(K.idPhc);
                if (phc) {
                    try {
                        const c = JSON.parse(phc);
                        ps.append("div").attr("class", "phccard")
                            .text("credential " + (c.d || "").slice(0, 14) + "… · issued by "
                            + (c.i || "").slice(0, 12) + "… — carried, presentable to other communes");
                    }
                    catch (_) { }
                }
            }
            else {
                // your standing, read from the ceremony itself — the same on every
                // device: no ask, or an ask collecting its n of k
                await refreshAsk();
                const a = ask.peek();
                const collecting = a?.state === "collecting";
                const nobody = !o.bootstrapped;
                ps.append("span").attr("class", "phc " + (collecting ? "wait" : "no"))
                    .text(collecting ? `pending · ${a.count} of ${a.quorum}` : "provisional");
                ps.append("div").attr("class", "opt")
                    .text(nobody
                    ? "no one is recognised here yet — the founder's first act makes the first person."
                    : collecting
                        ? askSaying(a) + (a.vouchers.length
                            ? ` ${a.vouchers.length === 1 ? "one of them" : `${a.vouchers.length} of them`} already vouch${a.vouchers.length === 1 ? "es" : ""} for you.`
                            : "")
                        : "recognition keeps out spam: recognised people who have met you sign that they have. Ask, and every recognised member sees it.");
                if (!collecting && !nobody)
                    ps.append("span").attr("class", "vbtn").text("request recognition")
                        .on("click", async function () {
                        const r = await (HANDLERS.fpEnroll ? HANDLERS.fpEnroll() : "err:offline");
                        if (r === "ok") {
                            await refreshAsk();
                            scheduleFpPoll();
                        }
                        const a2 = ask.peek();
                        d3.select(this).text(r === "ok"
                            ? `✓ asked — ${a2?.state === "collecting" ? askSaying(a2) : "recognised people will see it"}`
                            : String(r || "err").replace(/^err:/, ""))
                            .classed("done", r === "ok");
                    });
                if (collecting)
                    scheduleFpPoll();
                // the founder's genesis act: only while no one is recognised
                if (nobody && o.governor && HANDLERS.fpGrant && who.peek()?.aid)
                    ps.append("span").attr("class", "vbtn").text("recognise myself — the first person")
                        .on("click", async function () {
                        const r = await HANDLERS.fpGrant(who.peek().aid);
                        d3.select(this).text(r === "ok" ? "✓ recognised" : String(r || "err").replace(/^err:/, ""))
                            .classed("done", r === "ok");
                        if (r === "ok")
                            refreshPersonhood();
                    });
            }
        }
        catch (_) {
            ps.text("");
        }
    }
    else {
        ps.text("");
    }
    // The commune is authoritative for the profile it holds — but only where it
    // HOLDS one. An empty answer must not wipe a name this device set with no
    // seat to push it through; that name is pending, not absent.
    if (HANDLERS.profileGet) {
        try {
            const o = JSON.parse(await HANDLERS.profileGet());
            if (o.name)
                name.property("value", o.name);
        }
        catch (_) { }
    }
    // The standing asks from people outside your contacts — for RECOGNISED
    // members, who are the ones who can answer them. (Someone in your book
    // carries their ask on their own Contacts row.) Each row is a newcomer's
    // ceremony with its n of k; the one act is the ✍ witness the calendar rail
    // offers (your signature over the statement). The ecosystem's quorum does
    // the rest.
    if (HANDLERS.fpPending && person.peek() === true) {
        try {
            const all = JSON.parse(await HANDLERS.fpPending());
            const arr = Array.isArray(all) ? all.filter((row) => !byAid(row.candidate)) : [];
            if (arr.length) {
                f.append("div").attr("class", "sublead").text("asking to be recognised");
                const pl = f.append("div").attr("class", "vlist");
                const me = who.peek()?.aid;
                arr.forEach((row) => {
                    const r = pl.append("div").attr("class", "vrow");
                    r.append("span").attr("class", "vname").text(row.candidate.slice(0, 18) + "…");
                    r.append("span").attr("class", "vcount").text(`${row.count} of ${row.quorum}`);
                    if (me && (row.vouchers || []).includes(me))
                        r.append("span").attr("class", "phc-note").text(" you vouch for them");
                    r.append("span").attr("class", "vbtn").text("✍ witness")
                        .attr("title", "sign that you have met this person — your signature becomes an edge on their credential")
                        .on("click", async function () {
                        const reply = await (HANDLERS.witnessAttest ? HANDLERS.witnessAttest(row.said) : "err:offline");
                        const ok = typeof reply === "string" && reply.startsWith("ok:");
                        d3.select(this).text(ok ? (reply === "ok:finalized" ? "✓ recognised" : "✓ signed")
                            : String(reply || "err").replace(/^err:/, ""))
                            .classed("done", ok);
                    });
                });
            }
        }
        catch (_) { }
    }
}
export { idHint };
/**
 * Settings' own view of who this device is signed in as: the identifier,
 * whole and copiable, or the plain fact that nobody is.
 */
export function identifierBlock(f) {
    const draw = () => {
        f.selectAll("*").remove();
        const h = who();
        if (h)
            identifierRow(f, h.aid);
        else
            f.append("div").attr("class", "opt").text("nobody is signed in on this device.");
    };
    effect(draw);
}
// ── the start face's door ──────────────────────────────────────────────
// The onboarding walk ends in an identity, and it makes one through the same
// three acts the sheet does — generate the passcode, sign up, record the
// acceptance — with its own screen around them. What it needs is exported
// here, so the walk never rebuilds the sheet's logic and the sheet stays the
// one place that knows a reply's shape.
export const identity = who;
export const identityState = idState;
export { consentCurrent, downloadIdentityFile, setMyName };
/** Open the identity sheet — sign in, unlock, or create; once in, your name, standing and sign out. */
export function openIdentitySheet() {
    const el = d3.select("#idrow"), chip = el.select(".who");
    const face = CHIP[idState.peek()];
    if (chip.empty() || !face.sheet)
        return;
    face.sheet(el, who.peek());
    anchorSheet(el, chip);
}
export { openIdentitySheet as openIdentityDoor };
/** The person button's door: app/account.ts registers the account sheet here. */
let accountDoor = null;
export function onAccountDoor(fn) { accountDoor = fn; }
/**
 * Create an identity in one act. The passcode is minted here and handed back
 * ONCE with the AID; the caller's screen shows it and gates on its being
 * saved, as renderIdCreated does. A refusal comes back as its text.
 */
export async function createIdentity() {
    const bran = genPasscode();
    idState.set("busy");
    const r = await (HANDLERS.signup ? HANDLERS.signup("", "", bran) : "err:offline");
    const made = { aid: "" };
    finishAuth(r, "", "", aid => { made.aid = aid; });
    return made.aid ? { aid: made.aid, bran } : { err: String(r || "err:no reply").replace(/^err:/, "") };
}
