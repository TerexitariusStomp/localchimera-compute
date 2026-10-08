// app/reach-view.ts — settings › "how to reach you": your list, and what this
// commune has been told of it.
//
// Each row is one way to reach you. A kind a commune can deliver on carries
// the disclosure to this commune beside it: "notify me here" tells it (the
// commune sends a code to the address), the code said back confirms it, and
// "stop" takes it back. Rows of every kind can go on a card for a contact,
// from that contact's row in Contacts.
import { hint } from './core.js';
import { html } from './template.js';
import { armer } from './arm.js';
import { signal } from './reactive.js';
import { REACH_KINDS } from './reach-catalogue.js';
import { reach, addReach, removeReach, kindOfReach, delivers, toldState, tell, confirm, untell, readCommune } from './reach.js';
import { attached } from './books.js';
import { pushState, enablePush, disablePush } from './push.js';
const guard = armer();
// a draft changed in a way the block shows (the kind picked, a point added)
const drafted = signal(0);
const redraft = () => drafted.update(n => n + 1);
// the add row's and each code field's text, kept outside the signals so typing redraws nothing
let draftKind = REACH_KINDS[0].id;
let draftValue = "";
const codes = new Map();
const keyOf = (p) => `${p.kind}|${p.value}`;
const said = (r, done) => hint(r.startsWith("ok") ? done : r.replace(/^err:/, ""), r.startsWith("ok") ? "success" : "error");
const btn = (label, title, fn, cls = "") => html `<button type="button" class="slot-btn${cls}" title="${title}" onclick=${fn}>${label}</button>`;
// what stands beside a row of a kind a commune may be told
function communeSide(p) {
    const kind = kindOfReach(p.kind);
    if (!kind.commune)
        return "";
    if (!attached())
        return html `<span class="reach-note">sign in, and this commune can notify you here</span>`;
    const state = toldState(p), key = keyOf(p);
    if (state === "bound")
        return html `<span class="reach-on">✓ this commune notifies you here</span>
      ${btn(guard.armed() === key + "|stop" ? "stop?" : "stop", "take this address back from the commune — tap twice", () => guard.arm(key + "|stop", () => void untell(p).then(r => said(r, "the commune no longer holds that address"))), guard.armed() === key + "|stop" ? " arm" : "")}`;
    if (state === "pending")
        return html `<span class="reach-note">a code is on its way there</span>
      <input class="reach-code" type="text" inputmode="numeric" maxlength="6" placeholder="code" aria-label="the code sent to ${p.value}"
             value="${codes.get(key) || ""}"
             oninput=${(e) => { codes.set(key, e.currentTarget.value); }}>
      ${btn("confirm", "say the code back", () => void confirm(p, codes.get(key) || "").then(r => {
            if (r.startsWith("ok"))
                codes.delete(key);
            said(r, "confirmed — this commune notifies you there");
        }), " on")}
      ${btn("cancel", "put this down", () => void untell(p).then(() => codes.delete(key)))}`;
    if (!delivers(p.kind))
        return html `<span class="reach-note">this commune does not deliver to ${kind.label} yet</span>`;
    return btn("notify me here", "tell this commune; it sends a code to the address to confirm it is yours", () => void tell(p).then(r => said(r, `a code is on its way to ${p.value}`)));
}
// This device, as a way to be reached: the browser shows a notification the
// commune sends it, with the page closed. It stands ahead of the list and is
// no entry of it — there is no address to write down or put on a card.
function deviceRow() {
    const st = pushState();
    if (st === "unsupported")
        return "";
    const side = () => {
        if (st === "blocked")
            return html `<span class="reach-note">notifications are blocked for this site, in the browser's settings</span>`;
        if (!attached())
            return html `<span class="reach-note">sign in, and this commune can notify this device</span>`;
        if (st === "on")
            return html `<span class="reach-on">✓ this commune notifies this device</span>
        ${btn(guard.armed() === "device|stop" ? "stop?" : "stop", "end notifications on this device — tap twice", () => guard.arm("device|stop", () => void disablePush().then(r => said(r, "this device is no longer notified"))), guard.armed() === "device|stop" ? " arm" : "")}`;
        return btn("notify this device", "the browser asks your permission, then this commune can notify you here", () => void enablePush().then(r => said(r, "this commune notifies this device")));
    };
    return html `<ul class="reach-list"><li class="reach-row">
      <span class="reach-kind">this device</span>
      <span class="reach-value">browser notifications</span>
      <span class="reach-side">${side()}</span>
    </li></ul>`;
}
function rowOf(p) {
    const kind = kindOfReach(p.kind);
    const key = keyOf(p) + "|remove";
    return html `
    <li class="reach-row">
      <span class="reach-kind">${kind.label}</span>
      <span class="reach-value">${p.value}</span>
      <span class="reach-side">${communeSide(p)}</span>
      ${btn(guard.armed() === key ? "remove?" : "remove", "take this off your list, and back from the commune — tap twice", () => guard.arm(key, () => removeReach(p)), guard.armed() === key ? " slot-btn-delete arm" : " slot-btn-delete")}
    </li>`;
}
function add() {
    const fault = addReach(draftKind, draftValue);
    if (fault) {
        hint(fault, "warn");
        return;
    }
    draftValue = "";
    redraft();
}
let asked = false;
/** The settings block. A Fragment over signals: mount it once (settings-sections.ts mountFragment). */
export function reachBlock() {
    if (!asked) {
        asked = true;
        readCommune();
    }
    const points = reach();
    drafted();
    const kind = kindOfReach(draftKind) || REACH_KINDS[0];
    return html `
    <div class="reach">
      ${deviceRow()}
      ${points.length
        ? html `<ul class="reach-list">${points.map(rowOf)}</ul>`
        : html `<p class="reach-note">nothing here yet — add an address, a handle or a number below.</p>`}
      <div class="reach-add">
        <select aria-label="kind" onchange=${(e) => { draftKind = e.currentTarget.value; redraft(); }}>
          ${REACH_KINDS.map(k => html `<option value="${k.id}" ${k.id === draftKind ? "selected" : ""}>${k.label}</option>`)}
        </select>
        <input type="text" maxlength="200" placeholder="${kind.example}" aria-label="where"
               value="${draftValue}"
               oninput=${(e) => { draftValue = e.currentTarget.value; }}
               onkeydown=${(e) => { if (e.key === "Enter")
        add(); }}>
        ${btn("add", "put this on your list", add, " on")}
      </div>
    </div>`;
}
