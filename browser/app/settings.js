// app/settings.ts — SETTINGS: one surface for every knob the site has.
//
// The knobs were scattered — a theme menu in the header, a ⚙ options box in the
// panel, a location mode behind the identity chip, calendars in the calendar
// rail — so there was no answer to "where do I change things". This is that
// answer, and it is a REGISTRY rather than a page: any module calls
// registerSettings() with its own sections, so a face that grows a setting grows
// it here too, in one line, without this file learning what the face does.
//
//   registerSettings({ id, title, order, sections: [{ id, title, note, rows }] })
//
// A row is data, not markup — `kind` says how it reads:
//   toggle  { label, note, get(), set(v) }
//   select  { label, note, options: [{value,label}], get(), set(v) }
//   text    { label, note, placeholder, get(), set(v) }        (commits on blur/Enter)
//   button  { label, note, action() }
//   link    { label, note, href }
//   list    { label, note, items(), remove(item), add… }       (a repeatable row)
//   swatch  { label, ink, get(), set(v) }                      (a coloured toggle)
//   note    { text }
//   adopt   { node() }        — MOVES an existing element in, handlers intact
//
// `adopt` is the honest way to bring an old control in: the dial's view toggles
// are real inputs that main.js already reads by id (#chords, #spirals, …), so
// settings moves those very nodes instead of mirroring them into a second source
// of truth that could drift.
//
// The room is the site's own two panes: the section list goes in the SIDE PANEL
// (its own railgrp, in place of whichever face's rail was showing) and the
// section itself takes the stage. The door is the ⚙ in the header, beside the
// theme dial — settings is not a face, it is a room you step into from anywhere
// and back out of into exactly the face you left.
//
// One subtlety about `adopt`: the pane is rebuilt on every redraw, so an adopted
// node must never be inside it when that happens — replaceChildren() would drop
// it from the DOCUMENT, and the dial's own `d3.select("#chords").property(...)`
// would then read a property off null. Adopted nodes are parked in a hidden stash
// (still in the document, still wired) whenever their section is not showing.
import { signal, effect } from './reactive.js';
import { holdPanelOpen, closePanelIfNarrow, isNarrow } from './panel.js';
import { mk } from './dom.js';
const GROUPS = [];
export const settingsOpen = signal(false);
const active = signal(null); // the section id showing on the right
export function registerSettings(group) {
    const i = GROUPS.findIndex(g => g.id === group.id);
    if (i >= 0)
        GROUPS[i] = group;
    else
        GROUPS.push(group);
    GROUPS.sort((a, b) => (a.order ?? 100) - (b.order ?? 100));
}
const sections = () => GROUPS.flatMap(g => (g.sections || []).map(s => ({ ...s, group: g })));
// ── rows ──────────────────────────────────────────────────────────────────
function rowEl(r, redraw) {
    if (r.kind === "note") {
        const n = mk("div", "set-note");
        if (r.html)
            n.innerHTML = r.html;
        else
            n.textContent = r.text || "";
        return n;
    }
    if (r.kind === "adopt") {
        const host = mk("div", "set-adopt");
        const node = r.node && r.node();
        if (node) {
            node.style.display = "";
            host.append(node);
        }
        return host;
    }
    if (r.kind === "custom")
        return r.build();
    const row = mk("div", "set-row");
    const lab = mk("div", "set-lab");
    lab.append(mk("span", "set-labt", r.label || ""));
    if (r.note)
        lab.append(mk("span", "set-labn", r.note));
    if (r.kind === "toggle" || r.kind === "swatch") {
        const box = document.createElement("input");
        box.type = "checkbox";
        box.checked = !!r.get();
        if (r.ink)
            box.style.accentColor = r.ink;
        box.onchange = () => { r.set(box.checked); if (r.redraws !== false)
            redraw(); };
        const wrap = mk("label", "set-check");
        wrap.append(box);
        if (r.ink) {
            const sw = mk("span", "set-swatch");
            sw.style.background = r.ink;
            wrap.append(sw);
        }
        wrap.append(lab);
        row.classList.add("set-row-check");
        row.append(wrap);
        return row;
    }
    row.append(lab);
    if (r.kind === "select") {
        const sel = document.createElement("select");
        sel.className = "set-in";
        for (const o of r.options()) {
            const op = document.createElement("option");
            op.value = o.value;
            op.textContent = o.label;
            sel.append(op);
        }
        sel.value = String(r.get() ?? "");
        sel.onchange = () => { r.set(sel.value); if (r.redraws !== false)
            redraw(); };
        row.append(sel);
    }
    else if (r.kind === "text") {
        const inp = document.createElement("input");
        inp.type = "text";
        inp.className = "set-in";
        inp.placeholder = r.placeholder || "";
        inp.value = r.get() ?? "";
        const commit = () => { r.set(inp.value); if (r.redraws !== false)
            redraw(); };
        inp.onblur = commit;
        inp.onkeydown = e => { if (e.key === "Enter") {
            e.preventDefault();
            commit();
        } };
        row.append(inp);
    }
    else if (r.kind === "button") {
        const b = mk("button", "set-btn", r.text || "do it");
        b.onclick = () => { r.action(); redraw(); };
        row.append(b);
    }
    else if (r.kind === "link") {
        const a = mk("a", "set-link", r.text || "open ↗");
        a.href = r.href;
        a.target = "_blank";
        a.rel = "noopener noreferrer";
        row.append(a);
    }
    return row;
}
// ── the surface ───────────────────────────────────────────────────────────
function face() {
    let el = document.getElementById("setface");
    if (el)
        return el;
    const wrap = document.getElementById("orbwrap");
    if (!wrap)
        return null;
    // No header bar of its own: the panel names the room and carries the way out,
    // and the stage is the section — saying "settings" on both sides said it twice.
    el = mk("div", null);
    el.id = "setface";
    // #setstrip is the room's own nav for a phone (CSS shows it only narrow):
    // there the rail is a drawer over the stage, and a list kept in it would cover
    // the very section it names.
    el.innerHTML = `<div id="setstrip"></div><div id="setpane"></div><div id="setstash" hidden></div>`;
    wrap.append(el);
    return el;
}
// Park every adopted node in the stash before the pane is rebuilt: it stays in
// the document (so id lookups elsewhere keep working) and hidden (so it does not
// show twice). Its handlers are untouched — the node itself never dies.
function stashAdopted(el) {
    const stash = el.querySelector("#setstash");
    if (!stash)
        return;
    for (const host of el.querySelectorAll(".set-adopt"))
        for (const node of [...host.children]) {
            node.style.display = "none";
            stash.append(node);
        }
}
// which railgrp the panel was showing when we stepped in, so stepping out puts
// the face's own rail back rather than guessing at the current face
let priorRail = null;
function panelNav(cur) {
    const host = document.getElementById("setnav");
    if (!host)
        return;
    host.replaceChildren();
    // the room's name and its door, on the same line: the panel is where you came
    // in, so it is where you leave from
    const top = mk("div", "set-navtop");
    const back = mk("a", null, "←");
    back.id = "setback";
    back.title = "back to what you were doing";
    back.onclick = () => closeSettings();
    top.append(back, mk("h3", null, "settings"));
    host.append(top);
    for (const g of GROUPS) {
        const secs = g.sections || [];
        if (!secs.length)
            continue;
        host.append(mk("div", "set-navh", g.title));
        for (const s of secs) {
            const a = mk("a", "set-navi" + (s.id === cur.id ? " on" : ""), s.title);
            // on a phone the rail is a drawer: a choice made in it puts it away, so the
            // section chosen is the thing on screen
            a.onclick = () => { active.set(s.id); closePanelIfNarrow(); };
            host.append(a);
        }
    }
}
// the same list, flat, inside the room — what a phone navigates by
function stripNav(el, cur) {
    const host = el.querySelector("#setstrip");
    if (!host)
        return;
    host.replaceChildren();
    const back = mk("a", null, "←");
    back.id = "setback";
    back.title = "back to what you were doing";
    back.onclick = () => closeSettings();
    host.append(back);
    for (const s of sections()) {
        const a = mk("a", "set-navi" + (s.id === cur.id ? " on" : ""), s.title);
        a.onclick = () => active.set(s.id);
        host.append(a);
    }
    const on = host.querySelector(".set-navi.on");
    if (on)
        on.scrollIntoView({ block: "nearest", inline: "center" });
}
function draw() {
    const el = face();
    if (!el)
        return;
    const on = !!settingsOpen();
    el.classList.toggle("on", on);
    // settings takes the stage the way the map face does: the time chrome (date,
    // scale, the social and priority toggles, the colour bar, the mic) steps aside,
    // #orbwrap grows into the space, and the share bar stays — it is chrome, and a
    // setting is often exactly what you want to change while declaring something.
    const main = document.getElementById("main");
    if (main)
        main.toggleAttribute("data-settings", on);
    // The room's two halves are the panel and the stage, so the panel has to be
    // there: its section list is the only nav, and the ← beside the title is the
    // only way out. Hold it open for the visit and give it back on the way out —
    // a rail you collapsed stays collapsed everywhere else.
    // Narrow, the rail is a drawer over the stage and the room navigates by its
    // own strip instead — holding the drawer open would hide the section.
    holdPanelOpen("settings", on && !isNarrow());
    // the panel becomes the section list; the face's own rail waits, unbuilt-over
    const grp = document.getElementById("setSecs");
    if (grp) {
        if (on) {
            if (!grp.classList.contains("on")) {
                const showing = [...document.querySelectorAll("#panel .railgrp.on")]
                    .filter(g => g.id !== "setSecs");
                priorRail = showing.map(g => g.id);
                showing.forEach(g => g.classList.remove("on"));
            }
            grp.classList.add("on");
        }
        else {
            grp.classList.remove("on");
            (priorRail || []).forEach(id => document.getElementById(id)?.classList.add("on"));
            priorRail = null;
        }
    }
    stashAdopted(el);
    if (!on)
        return;
    const all = sections();
    if (!all.length)
        return;
    const cur = all.find(s => s.id === active()) || all[0];
    panelNav(cur);
    stripNav(el, cur);
    // written by face() above, so it is present on every element that reaches here
    const pane = el.querySelector("#setpane");
    pane.replaceChildren();
    pane.append(mk("h2", "set-h", cur.title));
    if (cur.note)
        pane.append(mk("div", "set-note", cur.note));
    for (const r of (typeof cur.rows === "function" ? cur.rows() : cur.rows) || [])
        pane.append(rowEl(r, () => draw()));
    pane.scrollTop = 0;
}
// The face is taking the rail back for itself. Let go of the room's railgrp now
// (effects are batched to a microtask, and the face fills the rail in this tick)
// and forget the remembered one: that memory is for stepping OUT of the room
// onto the face you came from, never for landing on a different one.
export function releaseRail() {
    priorRail = null;
    document.getElementById("setSecs")?.classList.remove("on");
}
/**
 * One section as a free-standing element — its note and its rows — for a host
 * that is not the settings room (the account sheet shows sections as its own
 * pages). It redraws when what its rows read moves, and `dispose` stops that.
 * Null for an id nobody registered.
 */
export function sectionPane(id) {
    const sec = sections().find(x => x.id === id);
    if (!sec)
        return null;
    const el = mk("div", "set-embed");
    const paint = () => {
        el.replaceChildren();
        if (sec.note)
            el.append(mk("div", "set-note", sec.note));
        for (const r of (typeof sec.rows === "function" ? sec.rows() : sec.rows) || [])
            el.append(rowEl(r, paint));
    };
    const dispose = effect(paint);
    return { title: sec.title, el, dispose };
}
export function openSettings(sectionId) {
    if (sectionId)
        active.set(sectionId);
    settingsOpen.set(true);
}
export function closeSettings() { settingsOpen.set(false); }
let wired = false;
export function initSettings() {
    if (wired)
        return;
    wired = true;
    effect(draw);
    document.addEventListener("keydown", e => {
        if (e.key === "Escape" && settingsOpen.peek())
            closeSettings();
    });
}
