// app/connect.ts — connecting with a person: a link read, a key checked, a
// yes, and they are in the book.
//
// Every way in ends at one proposal: a QR the camera read (capture-look.ts), a
// link pasted into the bar (tabs/social/share.ts), the address the page was
// opened with (main.ts), someone who connected with you (the connectAsk
// push). The Contacts view shows the proposal as a card — who, and whether this
// commune holds a checked key log for them — and one tap adds them.
import { HANDLERS, hint } from './core.js';
import { on } from './bus.js';
import { signal } from './reactive.js';
import { byAid } from './contact-book.js';
import { connectLink } from './connect-link.js';
import { encode, svg } from './qr.js';
import { idHint } from './tabs/social/id.js';
const asked = signal(null);
/** The standing proposal. A tracked read. */
export const proposal = () => asked();
// whoever shows the Contacts view registers how (share.ts), so a link read
// anywhere lands the person in front of its card
let show = () => { };
export const onPropose = (fn) => { show = fn; };
function check(aid) {
    const answer = (r) => {
        const p = asked.peek();
        if (!p || p.aid !== aid)
            return;
        const ok = typeof r === "string" && r.startsWith("ok:");
        asked.set({ ...p, asking: false, checked: ok ? r === "ok:checked" : null });
    };
    if (HANDLERS.contactCheck)
        HANDLERS.contactCheck(aid).then(answer);
    else
        answer("err:offline");
}
// a link read before the seat is taken is checked once it is
on("status", (s) => {
    const p = asked.peek();
    if (p && p.checked === null && typeof s === "string" && s.startsWith("ok:"))
        check(p.aid);
});
/** Ask about the person LINK names; REVEAL opens the Contacts view on the card. */
export function propose(link, reveal = true, back = false) {
    if (link.aid === idHint()?.aid) {
        hint("that is your own link — send it to someone else.", "notice");
        return;
    }
    asked.set({ ...link, name: link.name || byAid(link.aid)?.alias || "", checked: null, asking: true, back });
    check(link.aid);
    if (reveal)
        show();
}
/** Put the proposal down. */
export const decline = () => asked.set(null);
/** Add the proposed person to the book under ALIAS. */
export function accept(alias) {
    const p = asked.peek();
    if (!p)
        return;
    if (!HANDLERS.contactConnect) {
        hint("sign in to connect with people.", "warn");
        return;
    }
    const name = alias.trim() || p.name;
    HANDLERS.contactConnect(p.aid, name, p.origin ? `${p.origin}/oobi/${p.aid}` : "", idHint()?.name || "")
        .then(r => {
        const s = String(r ?? "err:offline");
        if (!s.startsWith("ok")) {
            hint(s.replace(/^err:/, ""), "error");
            return;
        }
        asked.set(null);
        hint(`connected with ${name || "them"}` + (s === "ok:checked" ? " — key checked" : ""), "success");
    });
}
// someone connected with you: a person already in the book needs nothing; a
// new one is proposed back, quietly — their act opens nothing on your screen
on("connectAsk", (aid, name) => {
    if (byAid(aid)) {
        HANDLERS.contactsRefresh?.();
        return;
    }
    if (asked.peek())
        return;
    propose({ aid, origin: "", name: String(name || "").slice(0, 60) }, false, true);
    hint(`${name || "someone"} connected with you — connect back in Contacts.`, "notice");
});
/** Your own link, and its QR as SVG ("" when the link is longer than a symbol holds). Null while you have no identity here. */
export function myLink() {
    const me = idHint();
    if (!me?.aid)
        return null;
    const base = location.origin + location.pathname;
    const named = connectLink(base, me.aid, me.name);
    const sym = encode(named) || encode(connectLink(base, me.aid));
    return { link: named, qr: sym ? svg(sym, 148) : "" };
}
