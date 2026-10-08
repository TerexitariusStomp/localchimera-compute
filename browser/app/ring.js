// app/ring.ts — the editable ring of arcs, and the hours it is drawn in.
//
// The dial carries two rings — availability (light blue, near the rim) and your
// personal events (yellow, just inside it) — and they are the SAME MACHINE:
// draw, drag, resize, select, a recurrence day-picker, and a this-day/every-day
// delete prompt. They differ only in configuration: colour, radius, the shape of
// an item, and what the editor puts in its body.
//
// So the machine is written once, here, and the two instances are two `cfg`
// objects in main. That was already true — makeRing has always been a factory —
// but it sat in the middle of five thousand lines beside the two things it
// makes, which is what made the sharing hard to see.
//
// STORAGE is localStorage, per identity: the ring works offline, and switching
// AID switches rings rather than merging them. A save also nudges a DEBOUNCE
// that both rings share, because what the planner is told — net availability —
// is a function of both of them together (an event carves a hole in a window),
// so either one changing has to re-send the pair.
//
// v1 renders and edits in the settled DAY view only. Off the day scale, or
// mid-scrub, or mid-morph, the geometry is not stable, so arcs stay read-only —
// dragging an arc whose angle means something different by the time you let go
// is not an edit anyone asked for.
import { R, U, TAU, ang, xy } from './geom.js';
import { AV_DAYS, AV_LBL } from './core.js';
import { ev_viewedDoy, turnAnchor } from './events.js';
import { dateOf, fmtClock } from './timefmt.js';
import { readJSON, writeJSON } from './store.js';
import { STATUS } from './palette.js';
// ── the hours a ring is drawn in ────────────────────────────────────────────
/**
 * An hour of the turn as a clock face — what the wire and the editor show.
 *
 * Snapped to the minute and wrapped into the turn BEFORE formatting: an arc
 * that runs past midnight carries hours past 24, and 25:30 is not a time.
 */
export const av_hhmm = (t) => fmtClock((Math.round(t * 60) / 60) % 24);
/** Snap to the 15-minute grid, and never off the turn. */
export const av_snap = (t) => Math.max(0, Math.min(24, Math.round(t * 4) / 4));
/** Which hour of the turn a point on the dial stands at. */
export const av_hourAt = (x, y) => {
    const t = (Math.PI / 2 - Math.atan2(-y, x)) / (TAU / 24);
    return ((t % 24) + 24) % 24;
};
/** Capitalise a weekday for the delete prompt ("this Tuesday"). */
export const av_cap = (s) => (s ? s[0].toUpperCase() + s.slice(1) : s);
/**
 * Drop `day` from a recurring item's days — or the item itself, if that was
 * its last day. Mutates `arr` in place.
 *
 * The one piece of `deletePrompt`'s "this day" branch that is a DECISION about
 * data rather than about a confirm dialog's chrome, so it is the piece the week
 * grid's own inline delete shares: narrowing an availability window from one
 * of its days is the same edit whether it is asked for from the dial's floating
 * editor or from a click on the grid's own band.
 */
export function dropRecurringDay(arr, item, day) {
    const days = item.days || AV_DAYS;
    item.days = days.filter(d => d !== day);
    if (!item.days.length) {
        const i = arr.indexOf(item);
        if (i >= 0)
            arr.splice(i, 1);
    }
}
/** JS getUTCDay order, so a weekday index reads straight out of it. */
const AV_JSDOW = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
/**
 * The weekday the dial is currently showing, or null when it cannot be known —
 * which every reader treats as always-on rather than as never.
 */
export function av_viewedDay() {
    try {
        return AV_JSDOW[dateOf(Math.floor(turnAnchor() / 24)).getUTCDay()];
    }
    catch (_) {
        return null;
    }
}
// ── interval algebra (hours) ────────────────────────────────────────────────
// Pure, and the reason net availability is exact rather than approximate.
/** Merge overlapping or touching intervals into a minimal covering set. */
export function av_merge(ivs) {
    const s = ivs.slice().sort((a, b) => a[0] - b[0]);
    const out = [];
    for (const iv of s) {
        if (out.length && iv[0] <= out[out.length - 1][1])
            out[out.length - 1][1] = Math.max(out[out.length - 1][1], iv[1]);
        else
            out.push([iv[0], iv[1]]);
    }
    return out;
}
/**
 * Subtract busy time from available time — your band practice carving a hole in
 * a window. A busy span strictly inside an available one SPLITS it, which is
 * why this returns a list rather than shrinking in place.
 *
 * Slivers below a millisecond are dropped: they are float residue, not offers.
 */
export function av_subtract(avail, busy) {
    let res = avail.map(a => a.slice());
    for (const b of busy) {
        const next = [];
        for (const a of res) {
            if (b[1] <= a[0] || b[0] >= a[1]) {
                next.push(a);
                continue;
            } // no overlap
            if (b[0] > a[0])
                next.push([a[0], b[0]]);
            if (b[1] < a[1])
                next.push([b[1], a[1]]);
        }
        res = next;
    }
    return res.filter(x => x[1] - x[0] > 1e-6);
}
/**
 * Give a recurring item a day set. Empty falls back to `fallback`: a window
 * with no day is not a window. The one rule both pickers — the dial's and the
 * grid's — apply, so it is stated once.
 */
export function av_setDays(item, days, fallback) {
    item.days = AV_DAYS.filter(d => days.includes(d));
    if (!item.days.length)
        item.days = [fallback];
}
const AV_SHORT = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]; // AV_DAYS order
/** The days a window recurs on, as a reader says them. */
export function av_daysLabel(days) {
    const on = AV_DAYS.map(d => days.includes(d));
    if (on.every(Boolean))
        return "every day";
    if (on.slice(0, 5).every(Boolean) && !on[5] && !on[6])
        return "Mon–Fri";
    return AV_SHORT.filter((_, i) => on[i]).join(" ");
}
/**
 * Unify availability windows that overlap or touch on a shared weekday, in
 * place. Two windows saying "I am free" over the same hour of the same day are
 * one statement, so they become one item. Where the two recur on different
 * day sets, the shared days take the union and each window keeps its own
 * remaining days — so a Sunday-only band drawn over a Sun+Mon band widens the
 * Sunday window and leaves Monday as it was.
 *
 * `keep` names the item whose id the merged window carries when it takes
 * part — the selection a hand is holding survives its own merge. Answers the
 * id the merged item ended up with for that selection, or `keep` unchanged.
 */
let splitSeq = 0; // a split remainder needs an id of its own; the lead keeps its
export function av_unify(arr, keep = null) {
    const daysOf = (it) => it.days || AV_DAYS;
    const touches = (a, b) => a.t0 <= b.t1 && b.t0 <= a.t1;
    /** The first pair sharing an hour and a day, or null when the set is unified. */
    const pair = () => {
        for (let i = 0; i < arr.length; i++)
            for (let j = i + 1; j < arr.length; j++) {
                if (!touches(arr[i], arr[j]))
                    continue;
                const shared = daysOf(arr[i]).filter(d => daysOf(arr[j]).includes(d));
                if (shared.length)
                    return [i, j, shared];
            }
        return null;
    };
    for (let hit = pair(); hit; hit = pair()) {
        const [i, j, shared] = hit, a = arr[i], b = arr[j];
        const lead = b.id === keep ? b : a;
        const merged = { ...lead, t0: Math.min(a.t0, b.t0), t1: Math.max(a.t1, b.t1),
            days: AV_DAYS.filter(d => shared.includes(d)) };
        const rest = [a, b].flatMap(it => {
            const left = daysOf(it).filter(d => !shared.includes(d));
            return left.length ? [{ ...it, id: it === lead ? `${it.id}_${++splitSeq}` : it.id, days: left }] : [];
        });
        arr.splice(j, 1);
        arr.splice(i, 1, merged, ...rest);
        if (keep && (a.id === keep || b.id === keep))
            keep = merged.id;
    }
    return keep;
}
// THE SHARED DEBOUNCE. Both rings save through it on purpose: what the planner
// is told is NET availability — windows minus committed recurring events — so a
// change to either ring re-sends the pair. One timer, so two edits in quick
// succession across both rings still send once.
let syncTimer = null;
let host;
/** Hand the rings the dial they are drawn on. Call once, before either is built. */
export function initRings(h) {
    host = h;
}
/**
 * Whether an edit is on offer at all — the settled day view. Exported because
 * the RIBBONS ask the same question: an event drawn on the rim is draggable
 * exactly when its arc on the ring would be, and answering it in two places is
 * how the two surfaces would come to disagree.
 */
export const steady = () => host.steady();
export function makeRing(cfg) {
    let items = null;
    let sel = null;
    let del = false;
    let edEl = null;
    const key = () => cfg.keyPrefix + (host.storageKey() || "local");
    const load = () => {
        if (items)
            return items;
        items = readJSON(key(), []);
        if (!Array.isArray(items))
            items = []; // an older store can hold anything
        settle(); // a store written before windows unified reads as unified
        return items;
    };
    const store = (arr) => { writeJSON(key(), arr); };
    const settle = () => { if (cfg.normalize && items)
        sel = cfg.normalize(items, sel); };
    const save = () => {
        settle();
        store(items || []);
        if (syncTimer)
            clearTimeout(syncTimer);
        syncTimer = setTimeout(() => host.sync(), 600);
    };
    // A full refresh: the events ring re-renders its ribbons through cfg.redraw;
    // availability just redraws its own ring. draw() is the bare ring renderer.
    const redraw = () => { cfg.redraw ? cfg.redraw() : draw(); };
    const setItems = (arr) => { items = arr; settle(); store(arr); redraw(); };
    const addAt = (hr) => {
        load();
        const item = cfg.newItem(hr);
        items.push(item);
        sel = item.id;
        del = false;
        if (cfg.onSelect)
            cfg.onSelect(); // drop the other ring's selection
        save();
        redraw();
    };
    const editor = () => {
        if (edEl)
            return edEl;
        const anchor = d3.select("#orbwrap");
        const at = anchor.empty() ? d3.select("body") : anchor;
        edEl = at.append("div").attr("id", cfg.editorId ?? null).style("display", "none")
            .style("position", "absolute").style("left", "50%").style("bottom", cfg.editorBottom ?? null)
            .style("transform", "translateX(-50%)").style("z-index", 8).style("background", "#fff")
            .style("border", "1px solid " + cfg.editorBorder).style("border-radius", "12px")
            .style("box-shadow", "0 2px 10px rgba(0,0,0,0.08)").style("padding", "7px 11px")
            .style("font-size", "12px").style("color", cfg.editorColor ?? null)
            .style("align-items", "center").style("gap", "9px").style("flex-wrap", "wrap");
        return edEl;
    };
    const dayPicker = (ed, item) => {
        const row = ed.append("span").style("display", "inline-flex").style("gap", "3px");
        AV_LBL.forEach((lbl, i) => {
            const name = AV_DAYS[i], on = (item.days || AV_DAYS).includes(name);
            row.append("span").text(lbl).attr("title", name).style("cursor", "pointer")
                .style("width", "18px").style("height", "18px").style("line-height", "18px")
                .style("text-align", "center").style("border-radius", "50%").style("font-size", "10.5px")
                .style("background", on ? cfg.pickerOn ?? null : cfg.pickerOff ?? null)
                .style("color", on ? "#fff" : cfg.pickerOffText ?? null)
                .on("click", () => {
                const s = new Set(item.days || AV_DAYS);
                s.has(name) ? s.delete(name) : s.add(name);
                av_setDays(item, [...s], name);
                del = false;
                save();
                drawEditor(item);
                redraw();
            });
        });
    };
    const deletePrompt = (ed, item) => {
        const vd = av_viewedDay(), days = item.days || AV_DAYS;
        const recurs = cfg.recurs ? cfg.recurs(item) : true;
        const delItem = () => {
            items = (items || []).filter(x => x !== item);
            sel = null;
            del = false;
            save();
            redraw();
        };
        if (!del) {
            ed.append("span").style("cursor", "pointer").style("color", STATUS.unmet)
                .style("margin-left", "4px").text("✕ delete")
                // ask this-day vs every-day only when it is a meaningful choice
                .on("click", () => {
                if (recurs && days.length > 1 && vd && days.includes(vd)) {
                    del = true;
                    drawEditor(item);
                }
                else
                    delItem();
            });
        }
        else {
            ed.append("span").style("color", "#9aa6b2").style("margin-left", "4px").text("delete");
            ed.append("span").style("cursor", "pointer").style("color", STATUS.unmet)
                .text(`this ${av_cap(vd || "")}`)
                .on("click", () => {
                const arr = items || [];
                dropRecurringDay(arr, item, vd);
                if (!arr.includes(item))
                    sel = null; // that was its last day
                del = false;
                save();
                redraw();
            });
            ed.append("span").style("cursor", "pointer").style("color", STATUS.unmet)
                .text("every day").on("click", delItem);
            ed.append("span").style("cursor", "pointer").style("color", "#9aa6b2")
                .text("cancel").on("click", () => { del = false; drawEditor(item); });
        }
    };
    const H = {
        dayPicker, deletePrompt, save,
        draw: () => redraw(),
        drawEditor: i => drawEditor(i),
        resetDel: () => { del = false; },
    };
    function drawEditor(item) {
        // An editOnly ring can route its editor into an external card (the
        // below-dial #evdetail) instead of a floating popover over the dial.
        if (cfg.externalEditor) {
            cfg.externalEditor(item);
            return;
        }
        const ed = editor();
        if (!item) {
            ed.style("display", "none");
            return;
        }
        ed.style("display", "flex").selectAll("*").remove();
        cfg.render(ed, item, H);
    }
    function draw() {
        cfg.group.selectAll("*").remove();
        if (!host.steady()) {
            drawEditor(null);
            return;
        }
        load();
        // editOnly rings (events) draw NOTHING here — they appear as ribbons and are
        // edited there; the ring is only the popover.
        if (cfg.editOnly) {
            drawEditor(items.find(x => x.id === sel) || null);
            return;
        }
        const vd = av_viewedDay(), doy = ev_viewedDoy();
        const r = R + cfg.radius, sw = 0.15 * U;
        cfg.group.append("circle").attr("r", r * U).attr("fill", "none").attr("stroke", cfg.ringColor)
            .attr("stroke-width", sw * 0.30).attr("opacity", 0.6).attr("pointer-events", "stroke")
            .style("cursor", "crosshair")
            .on("click", function (ev) {
            ev.stopPropagation();
            const [x, y] = d3.pointer(ev, this);
            addAt(av_hourAt(x, y));
        });
        items.forEach(item => {
            if (!cfg.shown(item, vd, doy))
                return;
            const isSel = item.id === sel;
            const a0 = ang(item.t1), a1 = ang(item.t0), span = item.t1 - item.t0;
            const laf = span > 12 ? 1 : 0; // the large-arc flag: over half the turn
            const path = `M${xy(r, a0)} A${r * U},${r * U} 0 ${laf} 0 ${xy(r, a1)}`;
            const p = cfg.group.append("path").attr("d", path).attr("fill", "none")
                .attr("stroke", cfg.strokeFor(item, isSel)).attr("stroke-width", sw)
                .attr("stroke-linecap", "round").style("cursor", "grab");
            if (cfg.dashed && cfg.dashed(item))
                p.attr("stroke-dasharray", "2,3");
            // click an arc to SELECT it (not toggle) — deselect by clicking elsewhere
            p.on("click", ev => {
                ev.stopPropagation();
                sel = item.id;
                del = false;
                if (cfg.onSelect)
                    cfg.onSelect();
                redraw();
            })
                // a stable container: draw() recreates the arc on every drag tick, so
                // the coordinates must be read against the <g>, not against the path
                .call(d3.drag().container(() => cfg.group.node())
                .on("start", () => { sel = item.id; })
                .on("drag", ev => {
                const cur = av_hourAt(ev.x, ev.y), ref = av_hourAt(ev.x - ev.dx, ev.y - ev.dy);
                let d = cur - ref;
                if (d > 12)
                    d -= 24;
                else if (d < -12)
                    d += 24; // unwrap across midnight
                let nt0 = item.t0 + d, nt1 = item.t1 + d;
                if (nt0 < 0) {
                    nt1 -= nt0;
                    nt0 = 0;
                }
                if (nt1 > 24) {
                    nt0 -= (nt1 - 24);
                    nt1 = 24;
                }
                item.t0 = av_snap(nt0);
                item.t1 = av_snap(item.t0 + span);
                draw(); // the live ring during a drag; the full redraw waits for the end
            })
                .on("end", () => { save(); redraw(); }));
            if (!cfg.editOnly) {
                const mid = ang((item.t0 + item.t1) / 2);
                if (cfg.label) {
                    const t = cfg.label(item);
                    if (t) {
                        const [lx, ly] = xy(r + 0.20, mid);
                        cfg.group.append("text").attr("x", lx).attr("y", ly).attr("text-anchor", "middle")
                            .attr("dominant-baseline", "middle").attr("font-size", "9")
                            .attr("fill", cfg.labelColor || "#9a7d2a").attr("pointer-events", "none").text(t);
                    }
                }
                if (cfg.mark)
                    cfg.mark(cfg.group, item, r, mid);
            }
            if (isSel)
                [["t0", a1], ["t1", a0]].forEach(([k, a]) => {
                    cfg.group.append("circle").attr("cx", xy(r, a)[0]).attr("cy", xy(r, a)[1]).attr("r", 5)
                        .attr("fill", "#fff").attr("stroke", cfg.handleColor).attr("stroke-width", 2)
                        .style("cursor", "ew-resize")
                        .call(d3.drag().container(() => cfg.group.node())
                        .on("drag", ev => {
                        const h = av_snap(av_hourAt(ev.x, ev.y));
                        // a quarter-hour floor, so a handle can never cross its partner
                        if (k === "t0")
                            item.t0 = Math.min(h, item.t1 - 0.25);
                        else
                            item.t1 = Math.max(h, item.t0 + 0.25);
                        draw();
                    })
                        .on("end", () => { save(); redraw(); }));
                });
        });
        drawEditor(items.find(x => x.id === sel) || null);
    }
    return {
        draw, items: load, setItems, save, addAt,
        // A hidden calendar (app/calendars.js) draws nothing and edits nothing:
        // the same wipe draw() opens with, plus the editor closed, so no popover
        // hangs over an arc that is no longer painted.
        clear: () => { cfg.group.selectAll("*").remove(); sel = null; del = false; drawEditor(null); },
        select: id => { sel = id; del = false; },
        clearSel: () => { const had = sel !== null; sel = null; del = false; return had; },
        selId: () => sel,
        editItem: () => load().find(x => x.id === sel) || null,
        renderEditorBody: d3sel => {
            const item = load().find(x => x.id === sel);
            if (!item)
                return null;
            cfg.render(d3sel, item, H);
            return item;
        },
    };
}
