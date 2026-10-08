// app/mytime.ts — your own time: when you are free, and what you have on.
//
// Two rings, one machine (app/ring.js). What differs is what an arc MEANS:
//
//   AVAILABILITY (light blue, near the rim) is an offer. It always recurs, has
//     no title and nothing to commit to — you are free then, or you are not.
//   PERSONAL EVENTS (yellow, just inside) are yours. They carry a title, they
//     are once or repeating, and they can be COMMITTED — which is the only one
//     of the two that changes what the planner may do.
//
// ── WHAT THE PLANNER IS TOLD IS THE DIFFERENCE ─────────────────────────────
// Not your availability, but your NET availability: the windows minus the time
// taken by committed recurring events. Your band practice carves a hole in
// Tuesday evening. That is why saving either ring re-sends the pair, and why
// the interval algebra behind it is tested rather than trusted (test-ring).
//
// The two selections are MUTUALLY EXCLUSIVE, and so is the event card's: an arc
// being dragged and a card being read are not the same gesture, so selecting in
// one clears both others.
import { S } from '../state.js';
import { xy } from '../geom.js';
import { AV_DAYS, HANDLERS } from '../core.js';
import { fmtDur, baseYear } from '../timefmt.js';
import { evs, ev_viewedDoy } from '../events.js';
import { calOn } from '../calendars.js';
import { L } from '../layers.js';
import { makeRing, av_snap, av_hhmm, av_viewedDay, av_merge, av_subtract, av_unify, } from '../ring.js';
import { STATUS } from '../palette.js';
import { K } from "../keys.js";
let host;
/** A fresh id that cannot collide with one made in the same millisecond. */
const freshId = (prefix) => prefix + Date.now() + "_" + Math.floor(Math.random() * 1e4);
/** A new arc at this hour: an hour before it, two long, snapped to the grid. */
const newSpan = (hr) => {
    const t0 = av_snap(Math.max(0, hr - 1));
    return { t0, t1: av_snap(Math.min(24, Math.max(t0 + 0.5, t0 + 2))) };
};
/**
 * The −/+ time stepper both editors are built from.
 *
 * It was written twice, identically but for two hex codes, which is exactly the
 * kind of duplication that drifts: a quarter-hour step in one and a half-hour
 * step in the other would have been a plausible edit and an invisible bug.
 */
function stepper(row, item, H, ink, get, set) {
    const w = row.append("span").style("display", "inline-flex")
        .style("align-items", "center").style("gap", "3px");
    const nudge = (glyph, by) => {
        w.append("span").text(glyph).style("cursor", "pointer").style("padding", "0 6px")
            .style("border", "1px solid " + ink.border).style("border-radius", "5px")
            .style("user-select", "none")
            .on("click", () => { set(get() + by); H.save(); H.drawEditor(item); H.draw(); });
    };
    nudge("−", -0.25);
    w.append("span").style("font-weight", "600").style("min-width", "42px")
        .style("color", ink.text).style("text-align", "center").text(av_hhmm(get()));
    nudge("+", 0.25);
}
/** Both ends of a span, as steppers that cannot cross each other. */
function spanRow(ed, item, H, ink) {
    const tRow = ed.append("div").style("display", "flex").style("align-items", "center")
        .style("gap", "5px").style("margin", "4px 0 2px");
    stepper(tRow, item, H, ink, () => item.t0, v => { item.t0 = av_snap(Math.max(0, Math.min(v, item.t1 - 0.25))); });
    tRow.append("span").style("color", "#9aa6b2").text("–");
    stepper(tRow, item, H, ink, () => item.t1, v => { item.t1 = av_snap(Math.min(24, Math.max(v, item.t0 + 0.25))); });
    return tRow;
}
// ── the two rings ───────────────────────────────────────────────────────────
export let availRing;
export let eventRing;
/** Everything committed on the viewed day, from both the plan and your own. */
export function committedToday() {
    const out = [];
    const vd = av_viewedDay(), doy = ev_viewedDoy();
    evs.forEach(e => { if (e.status !== "proposed" && e.status !== "declined")
        out.push(e); });
    eventRing.items().forEach(e => {
        if (e.committed && (e.repeat ? (vd && (e.days || AV_DAYS).includes(vd)) : e.doy === doy))
            out.push(e);
    });
    return out;
}
const tOverlap = (a0, a1, b0, b1) => a0 < b1 && b0 < a1;
/** The names of everything committed that clashes with this item. */
export function eventConflicts(item) {
    return committedToday()
        .filter(c => c !== item && tOverlap(item.t0, item.t1, c.t0, c.t1))
        .map(c => (c.label || c.title || "an event"));
}
/**
 * Your personal events, shaped as ribbons so they look like any other event.
 * `_pid` links a ribbon back to its ring item, so clicking one edits the arc —
 * which is what makes the rim and the ring one surface rather than two.
 */
export function personalEvs() {
    const vd = av_viewedDay(), doy = ev_viewedDoy();
    return eventRing.items()
        .filter(e => e.repeat ? (vd && (e.days || AV_DAYS).includes(vd)) : (e.doy === doy))
        .map(e => ({ label: e.title || "event", t0: e.t0, t1: e.t1, kind: "free", lane: 0,
        action: "use", status: e.committed ? "committed" : "proposed",
        _pid: e.id, _pref: e }));
}
// ── the ring is the person's clock; the wire is universal time ──────────────
// A person paints hours as they live them. The planner counts on the one clock
// (civil UTC at the boundary), so what leaves here is converted with the
// offset in force now, weekday and all: 23:00–01:00 local east of Greenwich
// is one arc on the wire that ends the day before it starts. A one-time
// committed event is not recurring, so it cannot be a hole in the week — it
// is a DATED exception: the day's whole net offer, stated outright for every
// UTC date that local day touches (a stated day beats the week).
const DAY_IDX = Object.fromEntries(AV_DAYS.map((d, i) => [d, i]));
const tzOffsetHours = () => -new Date().getTimezoneOffset() / 60; // local = UTC + offset
/** A local [t0,t1) on weekday DAY → the UTC arcs it is, each on its own weekday. */
function localToUtcWeekly(day, t0, t1) {
    const off = tzOffsetHours(), a = t0 - off, b = t1 - off, di = DAY_IDX[day] ?? 0;
    const out = [];
    const push = (shift, x0, x1) => {
        if (x1 > x0)
            out.push({ day: AV_DAYS[(di + shift + 7) % 7], t0: x0, t1: x1 });
    };
    push(-1, a + 24, Math.min(b, 0) + 24);
    push(0, Math.max(a, 0), Math.min(b, 24));
    push(1, Math.max(a, 24) - 24, b - 24);
    return out;
}
/** The inverse, for hydrating the ring from the wire. */
function utcToLocalWeekly(day, t0, t1) {
    const off = tzOffsetHours(), a = t0 + off, b = t1 + off, di = DAY_IDX[day] ?? 0;
    const out = [];
    const push = (shift, x0, x1) => {
        if (x1 > x0)
            out.push({ day: AV_DAYS[(di + shift + 7) % 7], t0: x0, t1: x1 });
    };
    push(-1, a + 24, Math.min(b, 0) + 24);
    push(0, Math.max(a, 0), Math.min(b, 24));
    push(1, Math.max(a, 24) - 24, b - 24);
    return out;
}
const yearStartMs = () => new Date(baseYear, 0, 1).getTime();
const localDayOf = (doy) => new Date(baseYear, 0, 1 + doy);
const doyOf = (d) => Math.round((d.getTime() - yearStartMs()) / 86400000);
const utcDateStr = (ms) => new Date(ms).toISOString().slice(0, 10);
const utcHours = (ms, day0) => (ms - day0) / 3600000;
/** The net offer on one LOCAL calendar day, in local hours: the ring's arcs for
 *  its weekday, less committed recurring events on that weekday, less every
 *  committed one-time event that falls on it. */
function netOfferLocal(day, avail, events) {
    const wd = AV_DAYS[(day.getDay() + 6) % 7], doy = doyOf(day);
    const a = av_merge(avail.filter(x => (x.days || AV_DAYS).includes(wd))
        .map(x => [x.t0, x.t1]));
    if (!a.length)
        return [];
    const busy = av_merge(events
        .filter(e => e.committed && (e.repeat ? (e.days || AV_DAYS).includes(wd) : e.doy === doy))
        .map(e => [e.t0, e.t1]));
    return busy.length ? av_subtract(a, busy) : a;
}
/** The offer within one UTC date, in UTC hours: every local day overlapping it
 *  contributes its net offer, clipped to the date. */
function offerWithinUtcDate(utcDate, avail, events) {
    const [y, m, d] = utcDate.split("-").map(Number);
    const D0 = Date.UTC(y, m - 1, d), D1 = D0 + 86400000;
    const out = [];
    // local days that can overlap this UTC date: the one holding its start, and its neighbours
    const mid = new Date(D0 + 43200000);
    for (const k of [-1, 0, 1]) {
        const L = new Date(mid.getFullYear(), mid.getMonth(), mid.getDate() + k);
        const L0 = L.getTime();
        for (const [t0, t1] of netOfferLocal(L, avail, events)) {
            const s = Math.max(L0 + t0 * 3600000, D0), e = Math.min(L0 + t1 * 3600000, D1);
            if (e > s)
                out.push([utcHours(s, D0), utcHours(e, D0)]);
        }
    }
    return av_merge(out);
}
/**
 * Push the offer to the planner, in universal time: the week (the ring's arcs
 * per weekday, less committed recurring events) as recurring arcs, and every
 * UTC date a committed one-time event touches as dated arcs carrying that
 * date's whole net offer — an empty day as a zero-length dated arc.
 */
function av_sync() {
    if (!HANDLERS.setAvailability)
        return; // no-op offline / standalone
    const avail = availRing.items(), events = eventRing.items();
    const wire = [];
    AV_DAYS.forEach(d => {
        const a = av_merge(avail.filter(x => (x.days || AV_DAYS).includes(d))
            .map(x => [x.t0, x.t1]));
        if (!a.length)
            return;
        const busy = av_merge(events
            .filter(e => e.committed && e.repeat && (e.days || AV_DAYS).includes(d))
            .map(e => [e.t0, e.t1]));
        (busy.length ? av_subtract(a, busy) : a)
            .forEach(iv => localToUtcWeekly(d, iv[0], iv[1])
            .forEach(u => wire.push({ start: av_hhmm(u.t0), end: av_hhmm(u.t1), days: [u.day] })));
    });
    // the dated exceptions: every UTC date a committed one-time event's local day touches
    const dates = new Set();
    events.filter(e => e.committed && !e.repeat && typeof e.doy === "number").forEach(e => {
        const L = localDayOf(e.doy), L0 = L.getTime();
        const L1 = new Date(L.getFullYear(), L.getMonth(), L.getDate() + 1).getTime();
        dates.add(utcDateStr(L0));
        dates.add(utcDateStr(L1 - 1));
    });
    [...dates].sort().forEach(D => {
        const ivs = offerWithinUtcDate(D, avail, events);
        if (!ivs.length)
            wire.push({ start: "00:00", end: "00:00", dates: [D] });
        ivs.forEach(iv => wire.push({ start: av_hhmm(iv[0]), end: av_hhmm(iv[1]), dates: [D] }));
    });
    try {
        HANDLERS.setAvailability(JSON.stringify(wire));
    }
    catch (_) { /* the door shut */ }
}
/** Hydrate availability from the gateway snapshot — universal time on the
 *  wire, the person's clock on the ring. LOCAL EDITS WIN. */
export function av_hydrateFromSnapshot(windows) {
    if (availRing.items().length)
        return;
    const arcs = [];
    const p = (v) => {
        const [h, m] = String(v).split(":").map(Number);
        return h + (m || 0) / 60;
    };
    (windows || []).forEach(ds => {
        if (ds.dates)
            return; // exceptions live in the events ring, which is local-first
        (ds.time_ranges || ds["time-ranges"] || []).forEach(tr => {
            (ds.days || AV_DAYS).forEach(day => {
                utcToLocalWeekly(day, p(tr.start), p(tr.end)).forEach(l => arcs.push({ id: "av" + arcs.length + "_" + Date.now(), t0: l.t0, t1: l.t1, days: [l.day] }));
            });
        });
    });
    if (arcs.length)
        availRing.setItems(arcs);
}
/**
 * A hidden calendar clears its ring rather than drawing it, so the dial agrees
 * with the grid and the panel about what is showing.
 */
export function drawAvail() { calOn("avail") ? availRing.draw() : availRing.clear(); }
export function drawMyEvents() { calOn("mine") ? eventRing.draw() : eventRing.clear(); }
/**
 * Click anywhere that is not an arc, a handle or a ribbon → deselect. Those all
 * stopPropagation, so this only fires for empty space, and ONE click drops the
 * selection rather than needing a second on the same thing.
 */
export function deselectRings() {
    const cleared = [availRing.clearSel(), eventRing.clearSel()].some(Boolean);
    if (cleared) {
        host.redrawRibbons();
        host.redrawCard();
    }
}
/** A fresh personal event at roughly now, opened for editing. */
export function newEventNow() {
    eventRing.addAt(((S.nowAbs % 24) + 24) % 24);
}
const BLUE = { border: "#cfe7f5", text: "#2c4a6e" };
const GOLD = { border: "#e6d6a8", text: "#7a6526" };
/** Build both rings. Call once, after the dial's layers exist. */
export function initMyTime(h) {
    host = h;
    // availability (light blue) — always recurring; no title, nothing to commit.
    availRing = makeRing({
        group: L.avail, keyPrefix: K.ringAvail, radius: 0.30,
        ringColor: "#d8ecf7", handleColor: "#57a8d8",
        newItem: hr => ({ id: freshId("av"), ...newSpan(hr), days: AV_DAYS.slice() }),
        // no weekday in view (a multi-day turn) means every arc shows
        shown: (it, vd) => !vd || (it.days || AV_DAYS).includes(vd),
        // availability has one look; only selection changes it
        strokeFor: (_it, sel) => sel ? "#57a8d8" : "#9fd0ea",
        recurs: () => true,
        // two windows over the same hour of the same day are one window
        normalize: av_unify,
        editorId: "availedit", editorBorder: "#cfe7f5", editorColor: "#2c4a6e", editorBottom: "10px",
        externalEditor: () => host.redrawCard(), // the editor is in #evdetail, not a popover
        onSelect: () => { eventRing.clearSel(); host.clearEventCard(); },
        pickerOn: "#57a8d8", pickerOff: "#eef4fb", pickerOffText: "#9aa6b2",
        // Rendered into the below-dial #evdetail card. The arc still lives and drags
        // on the ring; this is only its editable detail, on the same surface events
        // use — so a reader learns one card, not two.
        render: (ed, item, H) => {
            ed.append("div").style("font-size", "13px").style("font-weight", "700")
                .style("color", "#2c4a6e").style("margin-bottom", "3px").text("available for work");
            const tRow = spanRow(ed, item, H, BLUE);
            tRow.append("span").style("color", "#999").text(`· ${fmtDur(item.t0, item.t1)}`);
            const recRow = ed.append("div").style("display", "flex").style("align-items", "center")
                .style("gap", "7px").style("flex-wrap", "wrap").style("margin-top", "6px");
            recRow.append("span").style("color", "#6a7686").style("font-size", "11px").text("repeats");
            H.dayPicker(recRow, item);
            H.deletePrompt(ed.append("div").style("margin-top", "8px"), item);
        },
    });
    // personal events (yellow) — title, once or repeating, and commit→busy-block.
    eventRing = makeRing({
        group: L.myEvents, keyPrefix: K.ringEvents, radius: 0.50,
        editOnly: true, // they show as ribbons; the ring is the edit handle
        redraw: () => { host.redrawRibbons(); host.redrawCard(); },
        externalEditor: () => host.redrawCard(),
        onSelect: () => { availRing.clearSel(); host.clearEventCard(); },
        ringColor: "#efe2bf", handleColor: "#cf962a", labelColor: "#9a7d2a",
        newItem: hr => ({ id: freshId("ev"), title: "", ...newSpan(hr),
            repeat: false, days: AV_DAYS.slice(), doy: ev_viewedDoy(),
            committed: false }),
        shown: (item, vd, doy) => item.repeat ? Boolean(vd && (item.days || AV_DAYS).includes(vd))
            : (item.doy === doy),
        strokeFor: (item, sel) => sel ? "#cf962a" : (item.committed ? "#e3a72f" : "#eccf94"),
        dashed: item => !item.committed, // tentative reads as dashed
        recurs: item => !!item.repeat,
        label: item => item.title || "",
        // committed AND clashing → a red dot on the arc. Only a commitment can
        // clash, because only a commitment claims the time.
        mark: (g, item, r, mid) => {
            if (item.committed && eventConflicts(item).length) {
                const [dx, dy] = xy(r, mid);
                g.append("circle").attr("cx", dx).attr("cy", dy).attr("r", 3.5)
                    .attr("fill", "#d23").attr("stroke", "#fff").attr("stroke-width", 1)
                    .attr("pointer-events", "none");
            }
        },
        editorId: "myeventedit", editorBorder: "#e6d6a8", editorColor: "#7a6526", editorBottom: "44px",
        pickerOn: "#e3a72f", pickerOff: "#f4ecd6", pickerOffText: "#9a8a5a",
        // Mirrors the invited-event card: an editable title, the time row, the kind
        // line, recurrence, and a respond row.
        render: (ed, item, H) => {
            ed.append("input").attr("type", "text").attr("placeholder", "name this event")
                .property("value", item.title || "")
                .style("font-size", "13px").style("font-weight", "700").style("color", "#222")
                .style("border", "none").style("border-bottom", "1px solid #e6d6a8")
                .style("background", "transparent").style("padding", "1px 0").style("width", "65%")
                .style("outline", "none")
                .on("input", function () {
                item.title = this.value;
                H.save();
            })
                .on("keydown", function (e) {
                if (e.key === "Enter")
                    this.blur();
            });
            const tRow = spanRow(ed, item, H, GOLD);
            tRow.append("span").style("color", "#999").text(`· ${fmtDur(item.t0, item.t1)}`);
            ed.append("div").html(`<span class="kf">free time</span>` +
                `<span style="color:#999"> — τ∕${(24 / (item.t1 - item.t0)).toFixed(1)} of the turn</span>`);
            const recRow = ed.append("div").style("display", "flex").style("align-items", "center")
                .style("gap", "7px").style("flex-wrap", "wrap").style("margin-top", "6px");
            const seg = recRow.append("span").style("display", "inline-flex").style("gap", "2px");
            [["once", false], ["repeats", true]].forEach(([lbl, rep]) => {
                seg.append("span").text(lbl).style("cursor", "pointer").style("font-size", "10.5px")
                    .style("padding", "2px 8px").style("border-radius", "9px")
                    .style("background", item.repeat === rep ? "#e3a72f" : "#f4ecd6")
                    .style("color", item.repeat === rep ? "#fff" : "#9a8a5a")
                    .on("click", () => {
                    item.repeat = rep;
                    // switching to repeating with no weekday set means every day;
                    // switching to once pins it to the day you are looking at
                    if (rep && !(item.days && item.days.length))
                        item.days = AV_DAYS.slice();
                    if (!rep)
                        item.doy = ev_viewedDoy();
                    H.resetDel();
                    H.save();
                    H.drawEditor(item);
                    H.draw();
                });
            });
            if (item.repeat)
                H.dayPicker(recRow, item);
            const respond = ed.append("div").style("display", "flex").style("align-items", "center")
                .style("gap", "9px").style("flex-wrap", "wrap").style("margin-top", "8px");
            respond.append("span").text(item.committed ? "✓ committed" : "◇ tentative")
                .attr("title", item.committed ? "busy time — the planner won't book work here"
                : "tap to commit — blocks work during this event")
                .style("cursor", "pointer").style("font-size", "11px").style("padding", "2px 10px")
                .style("border", "1px solid").style("border-radius", "9px")
                .style("border-color", item.committed ? "#bcd9c4" : "#dfe6ee")
                .style("background", item.committed ? "#e2efe2" : "#eef4fb")
                .style("color", item.committed ? STATUS.sound : "#6a7686")
                .on("click", () => { item.committed = !item.committed; H.save(); H.drawEditor(item); H.draw(); });
            H.deletePrompt(respond, item);
            if (item.committed) {
                const clash = eventConflicts(item);
                if (clash.length)
                    ed.append("div").style("color", STATUS.unmet).style("font-size", "11px")
                        .style("margin-top", "5px").attr("title", "overlaps another commitment")
                        .text(`⚠ overlaps ${clash.join(", ")}`);
            }
        },
    });
}
/** The planner seam both rings save through. Handed to initRings by main. */
export const syncAvailability = av_sync;
