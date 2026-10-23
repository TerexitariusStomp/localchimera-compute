// SPDX-License-Identifier: AGPL-3.0-or-later
// app/outbox.ts — what a person did with no gateway in reach, kept until one is.
//
// A person works the same way connected or not (docs/planning/faces/offline-outbox.md).
// An act that is theirs alone to make, and that nobody else can invalidate (a
// count, an observation, a need, an offer), is sent to the gateway; when the
// gateway is out of reach the act lands on the device's copy of the scope
// (scope-local.ts) and waits here, in order, until a gateway is reached.
//
// What makes waiting safe is the act's own identity. A count and an observation
// are of their instant: stated at an instant, each is the same act wherever and
// however often it lands (count-door.scm names it by who, what, when and the
// figure), so `stamp` gives a queued act the instant it was made. A need and an
// offer are named by who and what, and declaring one again restates it. So an
// act flushed twice lands once, and the gateway's answer is the one that stands.
//
// An act that depends on others (a claim, a vote, accepting an offer, a key
// event) is never queued: it waits for a connection.
//
// An act with no instant of its own (confirming a planned row, recording hours
// against a commitment) is named by a TOKEN instead: a door declared `#:keyed` takes
// one as its last argument (ui/app/keyed-doors.ts, generated from the declaration),
// the page mints it once per act before the first send, and a repeat of the request
// (a retry after a lost reply, a flush) carries the same token, so the books answer
// it with what it recorded and record nothing more (observation/landing.scm).
import { KEYED } from "./keyed-doors.js";
import { OFFLINE } from "./offline-doors.js";
/**
 * A door whose act waits for a gateway: the index of its instant among its arguments, or null
 * where its ids name it. Read off the doors declared `#:offline` (offline-doors.ts, generated),
 * so a door is queued by declaring it and by nothing written here.
 */
export const QUEUED = Object.fromEntries(Object.entries(OFFLINE).filter(([, d]) => d.kind === "act").map(([door, d]) => [door, d.at]));
/**
 * A reply that says no gateway answered, as against a gateway's own refusal:
 * the spine is not there, the planner did not answer, or the seat is not held
 * (the spine's words for a door asked with no session or no scope).
 */
export const unreached = (reply) => /^err:(offline|spine down|planner unreachable|no planner service|unavailable|sign in first|no scope yet)/.test(reply);
/** An instant as the doors state one: UTC to the second. */
export const instant = (t) => t.toISOString().slice(0, 19) + "Z";
/** A fresh token for one act of a keyed door: 1 to 64 letters, digits, `_` and `-`, the server's own check. */
export function freshKey() {
    const c = globalThis.crypto;
    if (c && typeof c.randomUUID === "function")
        return c.randomUUID();
    const b = new Uint8Array(16);
    if (c && typeof c.getRandomValues === "function")
        c.getRandomValues(b);
    else
        for (let i = 0; i < b.length; i++)
            b[i] = Math.floor(Math.random() * 256);
    return Array.from(b, x => x.toString(16).padStart(2, "0")).join("");
}
/**
 * HANDLER's arguments, every one a string, with the act's token minted where the door is
 * keyed and none was given. The one place a token is made: the bridge to the spine and
 * `ask` both come through here, so an act has the same token wherever it is sent from.
 */
export function keyed(handler, args) {
    const out = args.map(a => (a == null ? "" : String(a)));
    const at = KEYED[handler];
    if (at !== undefined) {
        while (out.length <= at)
            out.push("");
        if (!out[at])
            out[at] = freshKey();
    }
    return out;
}
/** DOOR's arguments, every one a string, with the act's instant stated where the door takes one and none was. */
export function stamp(door, args, now) {
    const out = args.map(a => (a == null ? "" : String(a)));
    const at = QUEUED[door];
    if (typeof at === "number") {
        while (out.length <= at)
            out.push("");
        if (!out[at])
            out[at] = instant(now);
    }
    return out;
}
/**
 * Send what waits, oldest first. An act a gateway answers is dropped, or kept
 * with the refusal where it refused it; the first act no gateway answers ends
 * the flush, and it and the rest wait on.
 */
export async function flush(box, send) {
    const waiting = await box.all();
    let landed = 0, refused = 0;
    const told = [];
    for (let i = 0; i < waiting.length; i++) {
        const [key, act] = waiting[i];
        if (act.refused) {
            refused++;
            continue;
        } // seen and refused already: it is the person's to drop or restate
        const reply = await send(act.door, act.args);
        if (unreached(reply))
            return { landed, refused, waiting: waiting.length - landed - refused, told };
        if (reply.startsWith("err:")) {
            await box.keep(key, { ...act, refused: reply.slice(4) });
            refused++;
            told.push(reply.slice(4));
        }
        else {
            await box.drop(key);
            landed++;
        }
    }
    return { landed, refused, waiting: 0, told };
}
/**
 * Ask DOOR. A gateway in reach answers, asked exactly as the face asked. Where
 * none is, the device's copy answers, and an act that may wait is stated at its
 * instant, landed on the copy and kept in the box for the next flush; an act
 * that may not wait is told so.
 */
export async function ask(ends, door, args, reads) {
    // a keyed act carries its token from the FIRST send, so a retry after a lost reply is the
    // same act; every other door is asked exactly as the face asked
    const first = door in KEYED ? keyed(door, args) : args;
    const reply = await ends.gateway(door, first);
    if (!unreached(reply))
        return reply;
    if (door in QUEUED) {
        // the act is now of the instant it was made: the copy lands it so, and so will the gateway
        const act = stamp(door, first, ends.now());
        const landed = await ends.device(door, act);
        if (!landed.startsWith("err:"))
            await ends.box?.add({ door, args: act, at: instant(ends.now()) });
        return landed;
    }
    if (reads.has(door))
        return ends.device(door, args.map(a => (a == null ? "" : String(a))));
    return "err:this waits for a connection";
}
