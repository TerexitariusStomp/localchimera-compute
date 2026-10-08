// app/events.ts — the day's events, and the window they are read through.
//
// The leaf half of the event model: the arrays the seam feeds (events,
// proposals, the eligible set), the derived `pending`, the willingness set, and
// `turnAnchor` — which window of time the dial is looking at, the question every
// face that shows a day has to ask.
//
// Split out of main.js so a face can ask what is happening today without
// importing the dial. What did NOT come with it is the half that is wired into
// the dial's own rendering: selectEvent (it flies the map camera), settle,
// goToDate, the event/availability rings, and widOf (it reads `earthLeaf`, the
// map's current node). That residue IS the map/dial seam — named here so the
// next split has somewhere to start.
//
// main.js re-exports all of these, so existing imports keep resolving.
import { S } from './state.js';
import { baseYear, hoursToFirst } from './timefmt.js';
import { EXT } from './core.js';
import { DEMO_DAY, DEMO_LIVED } from './demo.js';
// by compass bearing — the dial becomes a true bearing dial
// THE SEAM: real EconomicEvents arrive as EXT.events (a LIVE array —
// the host mutates it in place); standalone,
// the demo day below.
// The rows themselves live in app/demo.js with the rest of the offline
// seam — the file name is the answer to "is this demo?". Each list seeds
// from a COPY, so the demo constants stay pristine while these arrays are
// mutated in place (replaceDay refills them; a response flips a status).
const evs = EXT.events || DEMO_DAY.evs.map(e => ({ ...e }));
// proposals from other people — VF's middle temporal layer: an Intent
// someone has directed at you becomes a COMMITMENT when you accept it,
// and an EconomicEvent when it is lived. Work and free alike: a shift
// offered, a picnic proposed.
const proposals = EXT.proposals || DEMO_DAY.proposals.map(e => ({ ...e }));
const pending = () => proposals.filter(p => p.status === "proposed");
// CATCHMENT intersect (the work's catchment cell meets one you can reach).
// The gateway computes this set for your AID and feeds EXT.eligible; these
// are slots you could fill by OFFERING WILLINGNESS — not assignments, just
// where you are eligible. Standalone, a demo few.
const eligible = EXT.eligible || DEMO_DAY.eligible.map(e => ({ ...e }));
/**
 * The clock span a (possibly multi-day) event occupies on day DD, or null.
 *
 * ONE arithmetic for the three surfaces that clip by day — the week grid's
 * columns, the rim's per-day instances, the map's turn window — so a span
 * that crosses midnight (doy1) ends at the same two clock edges everywhere:
 * t0 counts on its first day, t1 on its last, and the days between are full.
 * An UNDATED event answers its whole span; which day it models is the
 * caller's question (the grid pins it to the anchor, the rim repeats it).
 */
function spanOnDay(e, dd) {
    if (e.doy == null)
        return { t0: e.t0, t1: e.t1 };
    const d1 = e.doy1 ?? e.doy;
    if (dd < e.doy || dd > d1)
        return null;
    return { t0: dd === e.doy ? e.t0 : 0, t1: dd === d1 ? e.t1 : 24 };
}
// boundary — this hour, today, today + the next N; the long scales snap to
// the real calendar period that contains now (this month, season, year).
// S.viewTurnOffset steps WHOLE windows from there (set by dragging the hand
// past 0∕τ, or ±-stepping); a tap on the node re-homes to the present.
function turnAnchor() {
    const k = S.viewTurnOffset, today = Math.floor(S.nowAbs / 24);
    if (S.turnH < 1.5)
        return Math.floor(S.nowAbs) + k * S.turnH; // hour: top of this hour
    if (S.turnH < 720)
        return today * 24 + k * S.turnH; // day…moon: today, forward
    const d = new Date(Date.UTC(baseYear, 0, 1 + today)), y = d.getUTCFullYear(), m = d.getUTCMonth();
    if (S.turnH < 1500)
        return hoursToFirst(y, m + k); // calendar month
    if (S.turnH < 4000)
        return hoursToFirst(y, Math.floor(m / 3) * 3 + 3 * k); // season (quarter)
    return hoursToFirst(y + k, 0); // year, from Jan 1
}
function ev_viewedDoy() { try {
    return Math.floor(turnAnchor() / 24);
}
catch (_) {
    return null;
} }
// from the classification + slot so the demo is self-consistent).
const offered = new Set();
/**
 * The ONE writing door for the day's server-truth lists.
 *
 * Identity is kept — importers hold these arrays, so they are refilled, never
 * reassigned — and THE WIRE'S ANSWER REPLACES: a list passed here replaces
 * even when it is empty, because the caller passes exactly the arms the
 * snapshot carried — a commune with no proposals shows none, not the demo's
 * rows standing in for them. A list not passed stays: the demo day stands
 * until a wire answers about that arm, and a snapshot that says nothing about
 * the schedule keeps the last one that did. Answers whether anything changed,
 * so the caller notifies once — writing through here is what makes forgetting
 * the repaint impossible to write in a new pass.
 */
function replaceDay(next) {
    let changed = false;
    const swap = (arr, rows) => {
        if (!rows)
            return;
        arr.length = 0;
        arr.push(...rows);
        changed = true;
    };
    swap(evs, next.evs);
    swap(proposals, next.proposals);
    swap(eligible, next.eligible);
    swap(sched, next.sched);
    swap(lived, next.lived);
    return changed;
}
// THE PRODUCTION SCHEDULE, as calendar events: every work and material row of
// the solve's plan.schedule, each on its own real day (doy) — the one event
// list that spans the whole horizon rather than modelling the dial's one day.
// Filled by ingestSchedule; empty offline (the plan face still reconstructs
// its own board from the wire, this is the calendar's reading of the same).
const sched = [];
// THE LIVED LAYER: every EconomicEvent the observer holds — what actually
// happened, beside the plan that asked for it. Dated like the schedule, with
// both ends of a move kept (loc → toLoc), which is what the journey arcs
// draw. Filled by ingestLived; offline, the demo's few days of other
// people's work, dated behind today by the civil calendar.
const todayDoy = Math.floor((Date.now() - Date.UTC(baseYear, 0, 1)) / 864e5);
const lived = EXT.events ? []
    : DEMO_LIVED.map(({ dayOff, ...e }) => ({ ...e, doy: todayDoy + dayOff }));
export { evs, proposals, pending, eligible, sched, lived, replaceDay, spanOnDay, turnAnchor, ev_viewedDoy, offered };
