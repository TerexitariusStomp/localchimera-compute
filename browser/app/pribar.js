// app/pribar.ts — the priority bar: the hand, unrolled.
//
// At the now-sample the dial is showing, each child of the focus holds a share
// of the turn and is met up to some fraction of it. The bar is that reading
// laid out flat: one segment per band, widths in TRUE PROPORTION rather than
// area-true, the met part solid and the unmet part pale — exactly the rim's own
// split, read as a budget instead of as a clock.
//
// ── THE STACK IS THE NAVIGATION ─────────────────────────────────────────────
// priLevels[0] is the CURRENT bar: the focus's own children. Below it, thinner
// and dimmer, sit the ancestor levels — the path you took to get here, each
// marking which child you came through. That stack is the ONLY way through the
// taxonomy, in dial mode and on the earth alike, which is why the tap routing
// below is a small state machine rather than a click handler: where a tap goes
// depends on which level it landed on and whether the earth is open.
//
// ── HOLD TO LOOK, TAP TO GO ─────────────────────────────────────────────────
// Pressing a segment lights its band and previews its interior, exactly as
// hovering the dial band does; sliding follows the finger from segment to
// segment. Only a clean tap — under 350ms and under 8px of travel — navigates.
// So a reader can browse the whole level with one finger down and never move
// the dial, and the preview is free.
//
// ── WHY RAW DOM ─────────────────────────────────────────────────────────────
// The bar is flexbox, not SVG: the segments size themselves by flex-grow from
// the shares, and the browser does the layout arithmetic the dial would have to
// do by hand. That also means the paints here go through themed() explicitly,
// since they are style strings rather than d3 attribute writes.
import { paleCol } from './geom.js';
import { inkFor } from './core.js';
import { themed } from './theme.js';
import { stage } from './stage.js';
import { layout } from './bands.js';
let host;
/**
 * The stack, as last drawn. The pointer handler resolves a (level, k) address
 * against this, so it is kept rather than recomputed: the tap must land on the
 * bar the reader was actually looking at.
 */
let priLevels = [];
/** Draw the stack at now-sample `hi`. */
export function drawPriorityBar(hi) {
    const bar = document.getElementById("prioritybar");
    if (!bar)
        return;
    bar.replaceChildren();
    priLevels = buildStack();
    priLevels.forEach((lvl, li) => {
        const kids = lvl.node.children || [];
        // the current level uses the live now-slice; an ancestor is laid out fresh
        const lay = li === 0 ? stage.cums : layout(kids);
        const row = document.createElement("div");
        row.className = "pribar" + (li === 0 ? " current" : " ancestor");
        row.style.gap = kids.length > 14 ? "0px" : "2px";
        kids.forEach((d, k) => drawSeg(row, d, k, li, lay[hi], lvl));
        bar.appendChild(row);
    });
}
/**
 * The chain S.root..focus, current bar first.
 *
 * In earth mode the focus is the LEAF'S PARENT and `stage.leaf` is the open
 * leaf, so the current bar is still the leaf's siblings — which is what makes
 * swapping between two places on the earth a single tap.
 */
function buildStack() {
    const chain = [];
    for (let x = stage.focus; x; x = x.parent)
        chain.unshift(x);
    const levels = [{ node: stage.focus, pathChild: null }];
    for (let i = chain.length - 2; i >= 0; i--)
        levels.push({ node: chain[i], pathChild: chain[i + 1] });
    return levels;
}
/** One band's segment: its share as width, its met fraction as the gradient. */
function drawSeg(row, d, k, li, slice, lvl) {
    const share = slice.cum[k + 1] - slice.cum[k];
    if (share <= 0.0008)
        return; // a sliver: skip it, do not smear it
    const metFrac = Math.max(0, Math.min(1, (slice.met[k] - slice.cum[k]) / share));
    const pct = (metFrac * 100).toFixed(1);
    const active = stage.mode === "earth" && d === stage.leaf; // the leaf you are in
    const seg = document.createElement("div");
    seg.className = "priseg" + (d === lvl.pathChild ? " onpath" : "") +
        (active ? " active" : "");
    seg.style.flexGrow = share.toFixed(4);
    seg.style.background = themed(`linear-gradient(to right, ${d.col} 0 ${pct}%, ${paleCol(d.col)} ${pct}% 100%)`);
    seg.dataset.level = String(li);
    seg.dataset.k = String(k);
    // a narrow segment carries no label rather than a clipped one — except the
    // open leaf, which is named however thin it is, because it is where you are
    if (share > 0.085 || active) {
        const lab = document.createElement("span");
        lab.className = "pl";
        lab.style.color = themed(inkFor(d.col));
        lab.textContent = active ? `⌃ ${d.name}` : d.name;
        seg.appendChild(lab);
    }
    row.appendChild(seg);
}
// ── highlighting ────────────────────────────────────────────────────────────
/** The lit segment, so a re-highlight of the same one costs nothing. */
let priHot = null;
/**
 * Light a segment, and preview its interior.
 *
 * The preview is for the CURRENT bar only, and only in dial mode: an ancestor
 * bar's band is not on the dial to be previewed, and in earth mode the dial IS
 * the map, so there is no interior to show.
 */
export function priHighlight(sel) {
    const key = sel ? `${sel.level}:${sel.k}` : null;
    if (key === (priHot ? `${priHot.level}:${priHot.k}` : null))
        return;
    priHot = sel;
    document.querySelectorAll("#prioritybar .priseg").forEach(s => {
        const el = s;
        el.classList.toggle("hot", sel != null &&
            +el.dataset.level === sel.level && +el.dataset.k === sel.k);
    });
    host.clearPreview();
    if (sel == null || sel.level !== 0 || stage.mode !== "dial")
        return;
    const d = stage.focus.children?.[sel.k];
    if (!d)
        return;
    host.preview(d, sel.k);
}
/** Put the highlight and its preview away. */
export function priClear() { priHighlight(null); }
// ── tap routing ─────────────────────────────────────────────────────────────
/**
 * Where a clean tap goes.
 *
 * On the DIAL: the top bar zooms in, an ancestor bar jumps laterally.
 * On the EARTH: the open leaf is the way back to the dial, a sibling leaf swaps
 * which place the map is showing, and a category leaves the earth and lands on
 * its level. Every one of those exits the earth first, because the dial cannot
 * re-focus underneath an open map.
 */
export function priTap(sel) {
    if (stage.zooming)
        return;
    const lvl = priLevels[sel.level];
    const d = lvl && lvl.node.children?.[sel.k];
    if (!d)
        return;
    if (stage.mode === "earth") {
        if (d === stage.leaf) {
            host.exit();
            return;
        } // back to the dial
        if (sel.level === 0 && !d.children) // sibling leaf
         {
            host.exit(() => host.reveal(d, sel.k));
            return;
        }
        host.exit(() => host.goto(d));
        return; // a category
    }
    if (stage.mode !== "dial")
        return;
    if (sel.level === 0) {
        host.open(sel.k);
        return;
    }
    host.goto(d);
}
// ── the gesture ─────────────────────────────────────────────────────────────
/** A tap: short enough and still enough that it was not a hold or a slide. */
const TAP_MS = 350, TAP_PX = 8;
/**
 * Wire the bar's one pointer gesture.
 *
 * Hit-testing goes through elementFromPoint rather than the event target, so a
 * finger that slides off one segment and onto the next is followed — the target
 * would stay pinned to wherever the press began.
 */
export function initPriBar(h) {
    host = h;
    const bar = document.getElementById("prioritybar");
    if (!bar)
        return;
    /** {level,k} for a band segment, "back" for the earth-mode seg, else null. */
    const segAt = (x, y) => {
        const el = document.elementFromPoint(x, y);
        const seg = el && el.closest(".priseg");
        if (!seg || !bar.contains(seg))
            return null;
        return seg.dataset.back ? "back" : { level: +seg.dataset.level, k: +seg.dataset.k };
    };
    const isBand = (s) => !!s && s !== "back";
    let press = null;
    let startX = 0, startY = 0, t0 = 0, moved = false;
    bar.addEventListener("pointerdown", e => {
        const s = segAt(e.clientX, e.clientY);
        if (s == null)
            return;
        e.preventDefault();
        bar.setPointerCapture(e.pointerId);
        press = s;
        startX = e.clientX;
        startY = e.clientY;
        t0 = performance.now();
        moved = false;
        if (isBand(s))
            priHighlight(s); // the back seg has nothing to preview
    });
    bar.addEventListener("pointermove", e => {
        if (press == null) { // desktop hover, no button held
            if (e.pointerType === "mouse") {
                const s = segAt(e.clientX, e.clientY);
                if (isBand(s))
                    priHighlight(s);
            }
            return;
        }
        if (Math.hypot(e.clientX - startX, e.clientY - startY) > TAP_PX)
            moved = true;
        const s = segAt(e.clientX, e.clientY); // slide: follow the finger
        if (isBand(s))
            priHighlight(s);
    });
    const release = (e) => {
        if (press == null)
            return;
        const s = segAt(e.clientX, e.clientY);
        const tap = !moved && (performance.now() - t0) < TAP_MS;
        press = null;
        if (tap && s === "back")
            host.exit(); // the collapsed leaf is the way out
        else if (tap && isBand(s))
            priTap(s); // a clean tap navigates
        else
            priClear(); // a hold or a slide only highlighted
    };
    bar.addEventListener("pointerup", release);
    bar.addEventListener("pointercancel", () => { press = null; priClear(); });
    bar.addEventListener("pointerleave", () => { if (press == null)
        priClear(); });
}
