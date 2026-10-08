// app/contact-book.ts — the contact book, as every face reads it.
//
// The book is the people you know: the spine pushes it (EXT.contacts) with what
// the two of you have signed about each other, and while no seat is taken the
// demo book stands in (demo/contacts.ts). The Contacts view, the slot pickers,
// the calendar rail, the log and the identity sheet each ask here, so a name, a
// kind and an invitation read the same wherever they appear, and every reader
// inside an effect redraws when the book changes.
import { EXT, HANDLERS, hint } from './core.js';
import { on } from './bus.js';
import { signal } from './reactive.js';
import { attached } from './books.js';
import { gateHint } from './day/respond.js';
import { DEMO_CONTACTS } from './demo/contacts.js';
import { REL_KINDS, DEFAULT_REL } from './rel-catalogue.js';
// a push, a seat taken or left, a tag changed in place: each turns the page
const turned = signal(0);
const turn = () => turned.update(n => n + 1);
on("contacts", turn);
on("status", turn);
/** Whether the book shown is the demo's: nothing pushed, no seat taken. */
export const bookIsDemo = () => !EXT.contacts && !attached();
/** The book. A tracked read: an effect that calls it redraws when the book changes. */
export function book() {
    turned();
    return EXT.contacts || (attached() ? [] : DEMO_CONTACTS);
}
/** The contact with this AID, if they are in the book. */
export const byAid = (aid) => book().find(c => c.aid === aid);
/** A person's name as the book has it, else the head of their AID. */
export const nameOf = (aid) => byAid(aid)?.alias || aid.slice(0, 8) + "…";
/** The kind a rel names: a listed kind, or the person's own word as a kind of its own. */
export function kindOf(rel) {
    const id = rel || DEFAULT_REL;
    return REL_KINDS.find(k => k.id === id)
        || { id, plural: id, colour: REL_KINDS[0].colour };
}
/** The kinds the book uses, each once, in the order the book meets them. */
export const kindsInBook = () => [...new Set(book().map(c => c.rel || DEFAULT_REL))];
/** Tag a contact with a kind. The tag is your own label; the gateway keeps the book's copy. */
export function setRel(c, rel) {
    c.rel = rel;
    if (HANDLERS.setContactRel) {
        try {
            HANDLERS.setContactRel(c.aid, rel);
        }
        catch (_) { }
    }
    turn();
}
// ── recovery friends: the people you would ask to bring your passcode back ──
// The pick lives for the visit, in memory: the Contacts row marks it and the
// settings sheet makes the pieces from it. Who holds a piece is written nowhere.
const picks = signal(new Set());
/** The AIDs picked as recovery friends. A tracked read. */
export const recoveryPicks = () => picks();
/** Pick a contact as a recovery friend, or take the pick back. */
export function toggleRecoveryPick(aid) {
    const next = new Set(picks.peek());
    if (!next.delete(aid))
        next.add(aid);
    picks.set(next);
}
/** Invite a contact to something with a label and a window; the outcome is said in a hint. */
export function invite(c, label, t0, t1) {
    if (!(c.aid && HANDLERS.invite)) {
        hint("can't invite — not connected", "warn");
        return;
    }
    HANDLERS.invite(c.aid, label, t0.toISOString(), t1.toISOString())
        .then(r => {
        if (gateHint(String(r)))
            return;
        hint(r === "ok" ? `invited ${c.alias || "them"} — “${label}”`
            : String(r || "err").replace(/^err:/, ""), r === "ok" ? "success" : "error");
    });
}
