// app/willingness.ts — raising your hand for work.
//
// Willingness is the skill rail's one act. You do not claim a work-intent and
// you are not assigned one: you say you are WILLING, and the solver matches over
// everyone who did — the offers-first labour loop. So this is deliberately
// over-subscribable, and offering is not a commitment.
//
// ── ONE ID FOR THE SAME SLOT SEEN FOUR WAYS ─────────────────────────────────
// A work-intent shows up on the map as a dot, on the rim as a proposal, in the
// places list as a row, and in its own card. Those are four renderings of ONE
// thing, and the only way they can agree about whether you have raised your hand
// is to agree about what it is called. `widOf` is that name: the planner's own
// id when the wire supplies one, and a stable synthesis otherwise.
//
// ── THE OPTIMISTIC TOGGLE ───────────────────────────────────────────────────
// The set flips FIRST and every surface repaints from it, then the handler runs.
// A failure puts it back. That is deliberate: raising your hand should feel
// immediate, and the cost of being briefly wrong about a non-commitment is
// nothing. A demo slot carries no `spec`, so there is nothing to call and the
// local state simply stands.
import { HANDLERS, MODES, markDayChanged } from './core.js';
import { offered } from './events.js';
import { STATUS } from './palette.js';
let host;
export function initWillingness(h) {
    host = h;
}
/**
 * A stable work-intent id for anything offerable.
 *
 * The planner's own id when the host supplied one; otherwise synthesised from
 * what the slot SERVES and what it is called — which is stable across redraws
 * because neither changes, and unique enough because a classification does not
 * hold two work-intents of the same name.
 */
export const widOf = (x) => x.wid || x.vfId ||
    `${x.serves || host.lensId() || "?"}/${x.name || x.label}`;
/** Whether you have raised your hand for this slot. */
export const isWilling = (x) => offered.has(widOf(x));
/** Raise your hand, or lower it. */
export async function offerWillingness(x) {
    const wid = widOf(x);
    const have = offered.has(wid);
    if (have)
        offered.delete(wid);
    else
        offered.add(wid); // optimistic toggle
    // THE REAL PATH: willingness is over (skill, cell) in the planner —
    // express-willingness. The SAME handler the proposals' "✋ willing" uses, so an
    // eligible work-intent and a proposed one opt into one candidate field rather
    // than two that would have to be reconciled.
    try {
        if (x.spec && HANDLERS.willing)
            await HANDLERS.willing(x.scope || "", x.spec, x.cell || "", !have);
    }
    catch (_) {
        if (have)
            offered.add(wid);
        else
            offered.delete(wid); // revert on failure
    }
    host.afterToggle();
    // the WEEK GRID reads `offered` too (calendar.ts: an open work-intent's
    // .willing class) but isn't one of host.afterToggle's surfaces — it
    // listens for `day`, same as every other data-driven repaint.
    markDayChanged();
}
/** A place's rail, and — for a work-intent — whether you have offered. */
export function tagHtml(p) {
    const m = MODES[p.mode] || MODES.own;
    const ok = p.mode === "work" && isWilling(p);
    return `<span style="color:${m.col}">${m.label}</span>` +
        (ok ? ` <span style="color:${STATUS.sound}">· willing ✓</span>` : "");
}
