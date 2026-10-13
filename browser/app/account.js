// app/account.ts — the account sheet: what the person button opens.
//
// One sheet holds everything that belongs to YOU rather than to a face: who
// you are and whether the commune can see you, your profile, keys and
// devices, the commune's channel, settings, the look of the site, help and
// the notices. Each row is a door to a place that already exists (the identity
// card, a settings section, the channel room, the scroll); the sheet
// itself keeps no state but its own openness.
//
// On a phone it is a bottom sheet over a dimmed page; on a wide screen it sits
// above the bar at the person button's side. The ✕, the dimmed page and Esc
// put it away, and so does choosing a row.
import { mk } from './dom.js';
import { effect } from './reactive.js';
import { identity, identityState, onAccountDoor, signOutDevice } from './tabs/social/id.js';
import { identityCard, identityCardTitle, showSignIn, showCreate } from './identity-view.js';
import { passcodeUnsaved } from './passcode-held.js';
import { openSettings, sectionPane } from './settings.js';
import { openScroll } from './scroll.js';
import { openSheetView, closeSheetView, sheetViewIs, revealContacts } from './tabs/social/share.js';
import { TERMS_HREF, PRIVACY_HREF, ACCESSIBILITY_HREF } from './legal-product.js';
const SHORT = (aid) => aid.length > 14 ? `${aid.slice(0, 8)}…${aid.slice(-4)}` : aid;
/** What the connection state says, in a sentence a person can use. */
function standing() {
    switch (identityState()) {
        case "authed": return "signed in · connected to your commune";
        case "unlocked": return "unlocked on this device · your commune is unreachable";
        case "unregistered": return "your commune has not met you yet · tap to join";
        case "connecting": return "reaching your commune…";
        default: return "on this device";
    }
}
function row(r, close, wire = true, enter) {
    const b = mk("button", "acct-row" + (r.tone ? " " + r.tone : ""));
    b.type = "button";
    const ic = mk("span", "acct-ic", r.icon);
    if (r.live)
        ic.classList.add("live");
    const text = mk("span", "acct-tx");
    text.append(mk("span", "acct-l", r.label));
    if (r.sub)
        text.append(mk("span", "acct-s", r.sub));
    b.append(ic, text);
    if (enter) {
        b.append(mk("span", "acct-chev", "›"));
        b.addEventListener("click", enter);
    }
    else if (wire)
        b.addEventListener("click", () => { close(); r.go(); });
    return b;
}
const PAGES = {
    // the one place an identity is made, opened and read: the same card the onboarding checklist shows
    identity: { title: identityCardTitle, sections: [], build: () => identityCard() },
    profile: { title: "your profile", sections: ["profile-who", "reach"] },
    bodies: { title: "legal bodies", sections: ["bodies"] },
    diet: { title: "diet", sections: ["diet"] },
    body: { title: "body", sections: ["body"] },
    health: { title: "health", sections: ["self", "away"] },
    keys: { title: "keys and devices", sections: ["device", "passcode", "recovery", "recognition", "forget"] },
    // the map one keeps for a place sits with the place
    where: { title: "where you are", sections: ["where", "places", "maps"] },
    housing: { title: "your housing", sections: ["housing"] },
    time: { title: "your time", sections: ["time"] },
    look: { title: "look and feel", sections: ["look", "places"] },
    clocks: { title: "calendars and clocks", sections: ["calendars", "clocks"] },
    faces: { title: "faces", sections: ["tabs"] },
    // erasure sits where a person looks for it: with their keys, and with their data
    notices: { title: "your data and the notices", sections: ["notices", "storage", "maps", "forget"] },
    report: { title: "report a concern", sections: ["report"] },
};
let stack = []; // the pages entered, outermost first; empty is the menu
let disposers = [];
let card = null;
function header(close) {
    const head = mk("div", "acct-head");
    const page = stack.length ? PAGES[stack[stack.length - 1]] : null;
    if (page) {
        const back = mk("button", "acct-back", "←");
        back.type = "button";
        back.title = "back";
        back.setAttribute("aria-label", "back");
        back.addEventListener("click", goBack);
        const title = mk("span", "acct-title");
        // a title that follows the state (the identity card's face) is read inside an effect
        disposers.push(effect(() => { title.textContent = typeof page.title === "function" ? page.title() : page.title; }));
        head.append(back, title);
    }
    else {
        const mark = mk("span", "acct-mark");
        for (const c of "playnet")
            mark.append(mk("span", "wm-" + c, c));
        head.append(mark);
    }
    const x = mk("button", "acct-x", "✕");
    x.type = "button";
    x.title = "close";
    x.setAttribute("aria-label", "close");
    x.addEventListener("click", close);
    head.append(x);
    return head;
}
/** A page's body: each section's rows, under its own title when there are several. */
function pageBody(page) {
    const body = mk("div", "acct-page");
    if (page.build) {
        const built = page.build();
        disposers.push(built.dispose);
        const group = mk("div", "acct-group acct-sect");
        group.append(built.el);
        body.append(group);
        return body;
    }
    page.sections.forEach(id => {
        const pane = sectionPane(id);
        if (!pane)
            return;
        disposers.push(pane.dispose);
        const group = mk("div", "acct-group acct-sect");
        if (page.sections.length > 1)
            group.append(mk("div", "acct-gh", pane.title));
        group.append(pane.el);
        body.append(group);
    });
    return body;
}
function goTo(id) { stack.push(id); draw(); card?.scrollTo({ top: 0 }); }
function goBack() { stack.pop(); draw(); card?.scrollTo({ top: 0 }); }
/** The menu's rows: some enter a page of their own, some open a place that is not settings. */
function menu(close) {
    const door = (r) => row(r, close);
    const into = (icon, label, sub, page, before, tone) => row({ icon, label, sub, go: () => { }, tone }, close, false, () => { before?.(); goTo(page); });
    const me = identity();
    const g1 = mk("div", "acct-group");
    if (me) {
        const who = mk("button", "acct-row acct-who");
        who.type = "button";
        const av = mk("span", "acct-av", (me.name || "you").trim().charAt(0).toUpperCase() || "·");
        av.append(mk("span", "acct-dot " + (identityState() === "authed" ? "live" : "warn")));
        const tx = mk("span", "acct-tx");
        tx.append(mk("span", "acct-l", me.name || "you"), mk("span", "acct-s", standing()), mk("span", "acct-s acct-aid", SHORT(me.aid)));
        who.append(av, tx);
        who.addEventListener("click", () => goTo("identity"));
        g1.append(who);
        // signing out asks twice: it forgets this device's copy of your log
        const out = row({ icon: "↪", label: "sign out of this device", go: () => { } }, () => { }, false);
        const outL = out.querySelector(".acct-l"), outTx = out.querySelector(".acct-tx");
        out.addEventListener("click", () => {
            if (out.classList.contains("arm")) {
                void signOutDevice();
                return;
            }
            out.classList.add("arm");
            outL.textContent = "sign out — tap again";
            outTx.append(mk("span", "acct-s", "your passcode brings you back; keep your recovery file or identifier somewhere safe first"));
            setTimeout(() => { out.classList.remove("arm"); outL.textContent = "sign out of this device"; outTx.querySelector(".acct-s")?.remove(); }, 12000);
        });
        g1.append(out);
    }
    else {
        g1.append(into("＋", "create your identity", "a passcode, made here — nothing to register", "identity", showCreate, "primary"), into("👤", "sign in", "your passcode, a recovery file, or friends' pieces", "identity", showSignIn));
    }
    const net = document.getElementById("netbtn");
    const g2 = mk("div", "acct-group");
    g2.append(into("✎", "your profile", "your name, how to reach you", "profile"), into("🥗", "diet", "what you eat, and what you refuse", "diet"), into("🧍", "body", "what your floors are read from", "body"), into("❤️", "health", "private — conditions, and days away", "health"), into("🔑", "keys and devices", "stay signed in, change your passcode, recovery, recognition", "keys"), into("📍", "where you are", "your place, sharing it, places on the map, offline maps", "where"), into("🏠", "your housing", "your home, and what the night gives you", "housing"), into("🕰️", "your time", "hours a day, which days, what it earns", "time"), into("🏛", "legal bodies", "an association, a cooperative — declared, stewarded, signed", "bodies"), ...(me ? [door({ icon: "🤝", label: "people you know", sub: "vouch, witness, introduce — your contacts", go: revealContacts })] : []), door({ icon: "📻", label: "the commune's channel",
        sub: net?.classList.contains("live") ? "you are on air" : "chat, and live audio with whoever is in it",
        live: !!net?.classList.contains("live"), go: () => net?.click() }));
    const g3 = mk("div", "acct-group");
    g3.append(into("🎨", "look and feel", "theme, ambient sound, the week, credit", "look"), into("🗓", "calendars and clocks", "which calendars show, and the world clock", "clocks"), into("🧭", "faces", "which faces show in the bar", "faces"), into("🛡", "your data and the notices", "what is kept, the terms, and forget me", "notices"), into("🚩", "report a concern", "unlawful or harmful content, a child at risk", "report"), door({ icon: "⚙", label: "all settings", sub: "dial views, the gateway's doors, developer", go: () => openSettings() }), door({ icon: "?", label: "help and about", sub: "what playnet is, the code, the chat, keeping it running", go: openScroll }));
    const foot = mk("div", "acct-foot");
    for (const [text, href] of [["Privacy Policy", PRIVACY_HREF], ["Terms of Service", TERMS_HREF], ["Accessibility Statement", ACCESSIBILITY_HREF]]) {
        const a = mk("a", null, text);
        a.href = href;
        a.target = "_blank";
        a.rel = "noopener";
        foot.append(a);
    }
    foot.insertBefore(mk("span", "acct-sep", "•"), foot.lastChild);
    return [g1, g2, g3, foot];
}
/** Draw the current view — the menu, or the page on top of the stack — into the card. */
function draw() {
    if (!card)
        return;
    disposers.forEach(d => d());
    disposers = [];
    card.replaceChildren(header(closeAccount));
    const top = stack.length ? PAGES[stack[stack.length - 1]] : null;
    card.append(...(top ? [pageBody(top)] : menu(closeAccount)));
}
const OWNER = "account";
/** Leave the view: the sheet calls this however the view goes (✕, a row, the grip, another view). */
function gone() {
    disposers.forEach(d => d());
    disposers = [];
    card = null;
    stack = [];
    document.getElementById("idrow")?.querySelector(".who")?.setAttribute("aria-expanded", "false");
}
export function closeAccount() { closeSheetView(OWNER); }
function ensureOpen() {
    if (sheetViewIs(OWNER))
        return;
    card = mk("div", "acct-card");
    card.setAttribute("role", "region");
    card.setAttribute("aria-label", "your account");
    openSheetView(OWNER, card, gone, { full: true }); // the account opens at the whole height: it is a page to read, not a glance
}
/** The account menu, in the sheet the inventory rises in; the person button again puts it away. */
export function openAccount() {
    if (sheetViewIs(OWNER)) {
        closeAccount();
        return;
    }
    // a passcode shown once and not yet saved is where the sheet reopens: closing it never loses the key
    stack = passcodeUnsaved.peek() ? ["identity"] : [];
    ensureOpen();
    draw();
    document.getElementById("idrow")?.querySelector(".who")?.setAttribute("aria-expanded", "true");
}
/** The sheet, straight to one of its own pages — the same compact page a row's chevron leads to, never the two-pane settings room (`openSettings`). For a caller outside the menu (the onboarding checklist's own rows) that wants the nicer page, not the room. */
export function openAccountPage(id) {
    ensureOpen();
    stack = PAGES[id] ? [id] : [];
    draw();
    card?.scrollTo({ top: 0 });
    document.getElementById("idrow")?.querySelector(".who")?.setAttribute("aria-expanded", "true");
}
/** The sheet on its identity page — make, open or read an identity. A second call leaves it there. */
export function openAccountIdentity() { openAccountPage("identity"); }
let wired = false;
export function initAccount() {
    if (wired)
        return;
    wired = true;
    onAccountDoor(openAccount, openAccountIdentity, openAccountPage);
    // Esc steps back out of a page, then puts the sheet away
    document.addEventListener("keydown", e => {
        if (e.key !== "Escape" || !sheetViewIs(OWNER))
            return;
        e.preventDefault();
        if (stack.length)
            goBack();
        else
            closeAccount();
    });
    // the menu names the state it was opened in; a state change while it shows redraws it (a page tracks its own)
    effect(() => { identityState(); identity(); if (sheetViewIs(OWNER) && !stack.length)
        queueMicrotask(draw); });
}
