import { dropRecurringDay, av_setDays, av_daysLabel } from '../ring.js';
import { stage } from '../stage.js';
import { signal, effect } from '../reactive.js';
import { S } from '../state.js';
import { evs, pending, eligible, sched, lived, spanOnDay, turnAnchor } from '../events.js';
import { eventRing, availRing } from '../day/mytime.js';
import { selectEvent, selectedEv, showEventOnMap } from '../ribbons.js';
import { actionsFor, vfLine } from '../day/respond.js';
import { recipeById } from '../recipe-graph.js';
import { skyAt } from '../sky.js';
import { cWarm, cYea, AV_DAYS, AV_LBL, day, markDayChanged } from '../core.js';
import { dateOf, WD, MON, MON_DOT, FULLMON, hoursToFirst, fmtClock, fmtDur } from '../timefmt.js';
import { pick, calsRev } from '../calendars.js';
import { USER } from '../core.js';
import { havKm } from '../geom.js';
import { passesFacets, facetsRev } from '../facets.js';
import { myNeeds, revealSlot } from './social/share.js';
import { slotArcsOn } from '../gohere.js';
import { showSpecOnMap } from './map/mapsearch.js';
import { weekStart } from '../prefs.js';
import { isWilling } from '../willingness.js';
import { html, render, raw } from '../template.js';
import { awayOn } from '../away.js';
import { AWAY_KINDS } from '../rest.js';
import { openSettings } from '../settings.js';
const H = 42; // pixels per hour (grid row height)
// Whether title + time + place read left to right on one line, or stack, is
// decided by ACTUAL text width at the size that row would render, not a
// guessed pixel cutoff — a short title next to a long one needs a different
// answer at the very same box size, and a threshold can only ever be right
// for one of them. One canvas, reused: measureText is cheap, a fresh
// <canvas> per call is not.
const measureCtx = document.createElement("canvas").getContext("2d");
const SANS = '"Inter", system-ui, -apple-system, "Segoe UI", sans-serif';
function textW(s, weight, px) {
    measureCtx.font = `${weight} ${px}px ${SANS}`;
    return measureCtx.measureText(s).width;
}
// matches the .t1–.t5 CSS tiers exactly (font-size and padding both) — the
// row/stack decision below has to measure at the size the box will actually
// use, or an accurate-looking width check would still be guessing.
const TIER_PX = { "": 9.5, t1: 10.5, t2: 11.5, t3: 13, t4: 14.5, t5: 16 };
const TIER_PAD = { "": 10, t1: 10, t2: 10, t3: 14, t4: 16, t5: 18 };
const ROW_GAP = 10;
// the view: a day / 3-day / week window, stepped by whole windows from the day
// the dial is looking at. Local signals so the view's own nav re-renders through
// the same effect the shared `day` signal drives.
// How many days the window opens on: as many as the width gives a readable column — a wide desk shows the
// week rather than one stretched day. Once the reader picks a view that choice stands (setCalView / the select).
const fitView = () => {
    const w = window.innerWidth;
    return w >= 1700 ? "week" : w >= 1400 ? "5day" : w >= 1100 ? "3day" : "day";
};
let viewPicked = false;
const viewMode = signal(fitView());
const viewOff = signal(0); // whole windows ahead(+)/behind(−) of the dial's day
const editAvail = signal(false); // availability paint-mode (like the repl calendar)
const monthPop = signal(null); // month view: the day-of-year a "+N more" popover is open for
const flowPop = signal(null); // day grid: the material-flow group expanded in place
const offerGroupPop = signal(null); // day grid: which offer group's LOCATION PICKER is open
const COUNT = { day: 1, "2day": 2, "3day": 3, "4day": 4, "5day": 5, week: 7 };
const snap = (t) => Math.max(0, Math.min(24, Math.round(t * 4) / 4)); // 15-min grid (av_snap)
const jsdowOf = (doy) => dateOf(doy).getUTCDay(); // 0=Sun..6=Sat
const avNameOf = (doy) => AV_DAYS[(jsdowOf(doy) + 6) % 7]; // planner weekday name (mon..sun)
const evColor = (e) => e.kind === "work" ? cWarm : cYea;
// where the window starts (day-of-year), given the dial's anchor day + the view.
function windowStart() {
    const anchor = Math.floor(turnAnchor() / 24);
    const count = COUNT[viewMode()];
    // rewind to the week's first day — which one that is, is the reader's own
    // preference (app/prefs.js), shared with the rail's mini-month so the two
    // week-shaped surfaces agree about which column a day belongs in.
    const home = viewMode() === "week"
        ? anchor - ((jsdowOf(anchor) - weekStart() + 7) % 7)
        : anchor;
    return { start: home + viewOff() * count, count, anchor };
}
/** day-of-year of the 1st of (y, m) — the inverse of dateOf, month-grained. */
const doyOfMonth = (y, m) => hoursToFirst(y, m) / 24;
/**
 * The month grid's own window: which (y, m) viewOff() lands on, and the run
 * of days that fills it — leading days from the month before, back to the
 * reader's own week-start, through trailing days from the month after, so
 * every row is a full week the way Google's month view draws it. Sized to
 * exactly the weeks the month needs (4–6), not a fixed 6, since a responsive
 * grid should not carry a blank row a 28-day February never asked for.
 */
function monthWindow() {
    const anchor = dateOf(Math.floor(turnAnchor() / 24));
    const mi = anchor.getUTCMonth() + viewOff();
    const y = anchor.getUTCFullYear() + Math.floor(mi / 12);
    const m = ((mi % 12) + 12) % 12;
    const first = doyOfMonth(y, m);
    const daysInMonth = Math.round(doyOfMonth(m === 11 ? y + 1 : y, (m + 1) % 12) - first);
    const lead = (jsdowOf(first) - weekStart() + 7) % 7;
    const rows = Math.ceil((lead + daysInMonth) / 7);
    return { y, m, gridStart: first - lead, gridCount: rows * 7 };
}
// ── the shared day's events, placed on real dates ──────────────────────────
// planner events (evs / proposals / eligible) model the dial's ONE day, so they
// land on the anchor column. An event that STATES its own day (doy — the
// schedule's rows all do) lands on that column instead, which is what makes a
// week view of the real horizon possible. Personal events carry their own
// recurrence (weekday set) or one-time day-of-year, so they populate the week
// directly.
// DIRECTED WORK OFFERS name their district in the label the seed writes as
// "<act> in <place>: <skill>" — the only place the district lives (the
// festival pools every district's pits at ONE SpatialThing, so `place`
// itself reads "berlin-festival" for all of them; DayEvent.place is no
// help here). Offers on DOY sharing a span and an action group together;
// EVENTS is the day's own offer rows, already filtered to `offer: true`.
function offerGroupsOn(doy, events) {
    // ONE action, MANY places: a shift's place is its own record field — the
    // recipe is location-agnostic and the engine tiles it over the districts,
    // so the label reads the same at every one of them and the place rides
    // beside it. A group is a label sharing a day and a span; its members
    // name where.
    const groups = new Map();
    for (const e of events) {
        if (!e.place)
            continue;
        const title = e.label;
        const k = `${doy}|${e.t0}|${e.t1}|${title}`;
        if (!groups.has(k))
            groups.set(k, { title, members: [] });
        groups.get(k).members.push({ place: e.place, e });
    }
    return groups;
}
// ── ORDER OF OPTIMALITY: what the PLAN gains from THIS person at each place ──
//
// A shift's locations are ordered by the plan's own valuation, not by what is
// nearest. Each open shift carries `pull` — λ(skill, place@period), the dual
// of the located labour balance it was minted from: what one more hour of
// this skill at that place is worth to the plan. The gain from this person
// taking it is that pull over the hours they actually work there, which is
// the shift's hours less what they spend getting there from where they will
// BE — so a sole surgeon stands first at the far cell (its pull dwarfs the
// ride), and the twelfth gardener at the near one (equal pulls; the ride
// decides). No pull on the wire (no solve has priced it) leaves the ride
// alone to order, which is the nearest-first reading.
//
// EXPECTED POSITION at the window: where this person's own commitments put
// them — the last one ending by t0 that day (else the first one starting
// after t1), else the live position every map feature reads (USER: GPS once
// resolved). A commitment names its venue through `loc`, the same field the
// candidates carry. The ride back to the next commitment counts too, where
// there is one: the plan pays for that hour as well.
//
// RIDE_KMH is the dial's reckoning of a city ride (bicycle / transit pace)
// while the solve's own arc times ride no wire field; the ledger carries
// that thread.
const RIDE_KMH = 15;
const locOf = (e) => e.loc && e.loc.lat != null && e.loc.lng != null ? { lat: e.loc.lat, lng: e.loc.lng } : null;
function expectedAround(doy, t0, t1) {
    const mine = evs.filter(e => e.doy === doy && !!locOf(e));
    const prev = mine.filter(e => e.t1 <= t0).sort((a, b) => b.t1 - a.t1)[0];
    const next = mine.filter(e => e.t0 >= t1).sort((a, b) => a.t0 - b.t0)[0];
    return { before: (prev && locOf(prev)) || (next && locOf(next)) || USER,
        after: (next && locOf(next)) || null };
}
/** The plan's gain from this person at member M, given where they will be. */
function planGain(m, at, hours) {
    const here = locOf(m.e);
    const km = here ? havKm(at.before, here) + (at.after ? havKm(here, at.after) : 0) : Infinity;
    const worked = isFinite(km) ? Math.max(0, hours - km / RIDE_KMH) : 0;
    const pull = m.e.pull;
    // with a pull: the plan's gain; without: the ride alone (negated, so that
    // "more is better" holds for both and one sort serves)
    return { gain: pull != null ? pull * worked : -km, km };
}
function byPlanGain(members, doy, t0, t1) {
    const at = expectedAround(doy, t0, t1);
    return members.map((m, i) => ({ m, i, ...planGain(m, at, t1 - t0) }))
        .sort((a, b) => b.gain - a.gain || a.km - b.km || a.i - b.i)
        .map(x => ({ ...x.m, km: x.km }));
}
// the picker's own read: OPENGROUP is "doy|t0|t1|title" (drawn from the
// block's own key, above) — re-derived from the LIVE day every render, so
// a re-solve or an accept mid-pick can never hand back a stale event.
function currentOfferGroupMembers(openGroup) {
    const [doyStr, t0s, t1s] = openGroup.split("|");
    const doy = Number(doyStr);
    const offered = pending().filter(p => p.kind === "work" && p.doy === doy);
    const g = offerGroupsOn(doy, offered).get(openGroup);
    return g ? byPlanGain(g.members, doy, Number(t0s), Number(t1s)) : [];
}
/**
 * The pills of an offer group, laid into its block. MEMBERS come in order of
 * optimality (byPlanGain). The block is the budget: pills are laid in full,
 * then every pill the block's own height cannot hold is taken back and a
 * "+N" pill (which opens the picker, GROUPKEY) stands where the first of
 * them stood — so what shows is exactly what fits, in order, and nothing is
 * clipped mid-pill. Measured after layout, not estimated from font sizes: a
 * wide column holds several pills a row, a narrow one holds one.
 */
function drawOfferPills(blk, members, groupKey) {
    const box = document.createElement("div");
    box.className = "calev-picks";
    blk.appendChild(box);
    const pill = (text, title, onclick) => {
        const p = document.createElement("span");
        p.className = "calev-pick";
        p.textContent = text;
        p.title = title;
        p.addEventListener("click", (ev) => { ev.stopPropagation(); onclick(ev); });
        return p;
    };
    for (const m of members) {
        const why = (m.e.pull != null ? `pull ${m.e.pull.toPrecision(2)}/h · ` : "")
            + (isFinite(m.km) ? `${m.km.toFixed(1)} km` : "no coordinates");
        box.appendChild(pill(`📍 ${m.place}`, why, () => selectEvent(m.e)));
    }
    // take back what the block cannot hold — a pill is IN if its bottom edge
    // lies within the block's inner height
    const room = blk.clientHeight - box.offsetTop - 2;
    const fits = (el) => el.offsetTop - box.offsetTop + el.offsetHeight <= room;
    const pills = Array.from(box.children);
    let keep = pills.findIndex(p => !fits(p));
    if (keep < 0)
        return;
    const hidden = () => pills.length - keep;
    const more = pill(`+${hidden()} more`, "every location, in order — opens the picker", () => offerGroupPop.set(groupKey));
    pills.slice(keep).forEach(p => p.remove());
    box.appendChild(more);
    // the "+N" itself needs a place: cede one more pill until it fits (or none are left)
    while (keep > 0 && !fits(more)) {
        keep -= 1;
        pills[keep].remove();
        more.textContent = `+${hidden()} more`;
    }
    if (!fits(more))
        more.remove(); // a block too short for even one line shows its title alone
}
function eventsForColumn(doy, anchor) {
    const out = [];
    // the clock span this event occupies ON THIS COLUMN, or null: an undated
    // event models the dial's ONE day, so it lands on the anchor column; a
    // dated one clips through the shared spanOnDay arithmetic
    const spanOn = (e) => {
        if (!passesFacets(e))
            return null;
        if (e.doy == null)
            return doy === anchor ? { t0: e.t0, t1: e.t1 } : null;
        return spanOnDay(e, doy);
    };
    const put = (e, tone, extra) => {
        // an UNCLOCKED row is dated in its day, at no fabricated hour — the
        // lists and the month place it; the hour grid does not
        if (e.unclocked)
            return;
        const s = spanOn(e);
        if (s)
            out.push({ title: e.label, t0: s.t0, t1: s.t1, kind: e.kind, tone,
                orig: e, interactive: true, ...extra });
    };
    const schedFrom = out.length;
    // the SCOPE'S PLAN is its own standing — never the solid ink of a
    // commitment someone made: a plan cell binds nobody until an accept
    for (const e of pick("sched", sched))
        put(e, "plan");
    // the sched lane's MATERIAL flows collapse per span: the solve emits one
    // row per recipe process, and forty half-hour chips sharing a band say
    // less than one chip that counts them (work columns already merged at
    // ingest). A tap expands the group in place — every member stays its own
    // recordable row — and the dashed "collapse" chip folds it back.
    {
        const flows = new Map();
        for (let i = out.length - 1; i >= schedFrom; i--) {
            const b = out[i];
            if (b.orig && b.orig.action !== "work") {
                const k = `${doy}|${b.t0}|${b.t1}`;
                if (!flows.has(k))
                    flows.set(k, []);
                flows.get(k).push(b);
            }
        }
        flows.forEach((grp, k) => {
            if (grp.length < 4)
                return;
            if (flowPop() === k) {
                out.push({ title: "⇄ collapse", t0: grp[0].t0, t1: grp[0].t1,
                    kind: "work", tone: "open", groupKey: k });
                return;
            }
            for (const b of grp)
                out.splice(out.indexOf(b), 1);
            out.push({ title: `⇄ ${grp.length} flows`, t0: grp[0].t0, t1: grp[0].t1,
                kind: "work", tone: "plan", groupKey: k });
        });
    }
    for (const e of pick("plan", evs))
        put(e, "committed");
    const propsFrom = out.length;
    for (const p of pick("props", pending()))
        put(p, "open");
    // WORK ROWS sharing a day, a span and a label collapse into one block
    // (offerGroupsOn, below) — both the shapes this lane carries: an OPEN
    // shift (persist-open-shifts!'s ni| intents, unbound, visible to anyone
    // with the skill — kind:"work", no suggested provider) and a DIRECTED
    // OFFER (present-offers, addressed to one citizen — kind:"work",
    // offer:true). The label is the recipe's own ("Grow salad: Gardening")
    // and the place is the row's own field, so twelve districts' shifts of
    // one act are one block naming the choice. A SOCIAL invite is
    // kind:"free" and never enters this pass. A lone row draws as itself.
    {
        const offered = [];
        for (let i = out.length - 1; i >= propsFrom; i--) {
            const b = out[i];
            if (b.orig && b.orig.kind === "work") {
                offered.push(b.orig);
                out.splice(i, 1);
            }
        }
        offerGroupsOn(doy, offered).forEach((g) => {
            if (g.members.length < 2) { // a lone offer draws as it always has
                const one = g.members[0];
                out.push({ title: one.e.label, t0: one.e.t0, t1: one.e.t1, kind: one.e.kind,
                    tone: "open", orig: one.e, interactive: true });
                return;
            }
            out.push({ title: `${g.title} · ${g.members.length} locations`,
                t0: g.members[0].e.t0, t1: g.members[0].e.t1, kind: g.members[0].e.kind,
                tone: "open", offerGroup: g.members, offerGroupTitle: g.title });
        });
    }
    for (const w of pick("open", eligible)) {
        if (!w.tier)
            w.tier = "open"; // tag like the map does, so the detail card
        // reads it as an eligible work-intent (the rim
        // never draws eligible, so nothing else tags it)
        put(w, "open");
    }
    // the LIVED record — what actually happened, in the ledger's own quiet ink
    for (const e of pick("lived", lived))
        put(e, "committed", { lived: true });
    // your declared needs, at their rhythm: one translucent band per arc that
    // stands on this day — demand-intents made visible beside the supply that
    // answers them. An "anytime" need has no clock shape, so it draws nothing.
    for (const s of pick("needs", myNeeds()))
        for (const occ of slotArcsOn(s, doy))
            out.push({ title: `${s.emoji || "▪"} ${s.name || s.spec}`, t0: occ.t0, t1: occ.t1,
                kind: "free", tone: "open", need: true, spec: s.spec });
    const avName = avNameOf(doy);
    for (const it of pick("mine", eventRing.items())) {
        const on = it.repeat ? (it.days || AV_DAYS).includes(avName) : (it.doy === doy);
        if (on)
            out.push({ title: it.title || "event", t0: it.t0, t1: it.t1, kind: "free",
                tone: it.committed ? "committed" : "open", personal: true });
    }
    return out;
}
// availability windows (recurring, weekday-keyed) → a quiet background band.
function availForColumn(doy) {
    const avName = avNameOf(doy);
    return pick("avail", availRing.items()).filter(a => (a.days || AV_DAYS).includes(avName));
}
// greedy side-by-side columns for events that overlap in a single day (port of
// calendar.scm's compute-event-columns).
function layoutColumns(items) {
    const sorted = items.slice().sort((a, b) => a.t0 - b.t0);
    const overlap = (a, b) => a.t0 < b.t1 && b.t0 < a.t1;
    /** Each event with the column it was given, before the widths are worked out. */
    const placed = [];
    for (const e of sorted) {
        const used = new Set(placed.filter(p => overlap(e, p.e)).map(p => p.col));
        let col = 0;
        while (used.has(col))
            col++;
        placed.push({ e, col });
    }
    return placed.map(p => {
        const group = placed.filter(q => overlap(p.e, q.e));
        const total = group.reduce((m, q) => Math.max(m, q.col), 0) + 1;
        return { e: p.e, col: p.col, total };
    });
}
function rangeLabel(start, count) {
    const a = dateOf(start), b = dateOf(start + count - 1);
    const am = a.getUTCMonth(), bm = b.getUTCMonth();
    // ONE day: the bar names the weekday too, so the grid needs no day-header
    // row of its own (drawGrid) — that row is for telling several columns apart
    if (count === 1) {
        const wd = WD[a.getUTCDay()];
        return { long: `${wd}, ${FULLMON[am]} ${a.getUTCDate()}, ${a.getUTCFullYear()}`,
            short: `${wd}, ${MON_DOT[am]} ${a.getUTCDate()}, ${a.getUTCFullYear()}`,
            today: start === Math.floor(S.nowAbs / 24) };
    }
    const sameMonth = am === bm && a.getUTCFullYear() === b.getUTCFullYear();
    if (sameMonth)
        return { long: `${MON[am]} ${a.getUTCDate()}–${b.getUTCDate()}, ${a.getUTCFullYear()}`,
            short: `${MON_DOT[am]} ${a.getUTCDate()}–${b.getUTCDate()}, ${a.getUTCFullYear()}` };
    return { long: `${MON[am]} ${a.getUTCDate()} – ${MON[bm]} ${b.getUTCDate()}, ${b.getUTCFullYear()}`,
        short: `${MON_DOT[am]} ${a.getUTCDate()} – ${MON_DOT[bm]} ${b.getUTCDate()}, ${b.getUTCFullYear()}` };
}
const monthLabel = (y, m) => ({ long: `${FULLMON[m]} ${y}`, short: `${MON_DOT[m]} ${y}` });
/**
 * The view widths, in the order the dropdown offers them. Day through week
 * share ONE grid (COUNT day-columns side by side, hours down), so widening
 * that choice cost nothing beyond naming the extra widths. "month" is drawn
 * by a wholly separate function (drawMonthGrid) — weeks as ROWS rather than
 * hour-columns, the shape a month actually has — so it does not have to fit
 * COUNT or #calscroll's horizontal-scroll-free width at all.
 */
const VIEWS = [
    ["day", "Day"], ["2day", "2 days"], ["3day", "3 days"],
    ["4day", "4 days"], ["5day", "5 days"], ["week", "Week"], ["month", "Month"],
];
/** The rail's view rows (app/tabs/calrail.ts) read and write the SAME signal
 *  the header's select does — one choice, two hands. */
export const calView = () => viewMode();
export function setCalView(m) { viewPicked = true; viewMode.set(m); viewOff.set(0); }
window.addEventListener("resize", () => { if (!viewPicked) {
    const v = fitView();
    if (v !== viewMode.peek())
        viewMode.set(v);
} });
export { VIEWS };
/**
 * The bar over the grid: where you are, and the ways to move.
 *
 * A full rebuild every draw — it holds no half-typed state, only the signals
 * it reads — so it is one expression through the shared renderer rather than
 * a dozen appends. The arrows carry HTML entities, hence `raw`: they are the
 * glyph itself, not text that happens to look like one.
 */
function drawHeader(label) {
    const ed = editAvail();
    const vm = viewMode();
    // A day you have declared away, read against the ONE day showing — a
    // multi-day view has no single "today" for the marker to name, so it
    // shows only in day-count-1 modes, the same guard `edit availability`
    // uses for "no single day to paint". Opens the real editor (settings'
    // own "away" section, app/away.ts) rather than a second one here.
    const win = vm === "month" ? null : windowStart();
    const away = win && win.count === 1 ? awayOn(dateOf(win.start).toISOString().slice(0, 10)) : undefined;
    render("#calhdr", html `
    <div class="calnav"><span class="calbtn" onclick=${() => viewOff.set(0)}>today</span><span
      class="calbtn calarrow" onclick=${() => viewOff.update(k => k - 1)}>${raw("&#9664;")}</span><span
      class="calbtn calarrow" onclick=${() => viewOff.update(k => k + 1)}>${raw("&#9654;")}</span></div>
    <span class="calrange${label.today ? " today" : ""}"${label.today ? ' title="today"' : ""}><span class="cal-long">${label.long}</span><span
      class="cal-short">${label.short}</span></span>
    ${away ? html `<span class="calbtn calaway" title="declared ${away.kind}, ${away.from === away.to ? away.from : `${away.from} → ${away.to}`} — tap to edit"
          onclick=${() => openSettings("away")}>away · ${AWAY_KINDS.find(k => k.id === away.kind)?.label ?? away.kind}</span>` : ""}
    <span class="calspacer"></span>
    ${vm === "month" ? "" : html `<span class="calbtn calavbtn${ed ? " on" : ""}"
          title="paint your available-for-work hours — dragged here, pushed to the planner just like the dial's blue arcs"
          onclick=${() => editAvail.set(!ed)}>${ed ? "✓ done" : html `<span class="cal-long">edit availability</span><span
          class="cal-short">edit avail.</span>`}</span>`}
    <select class="calvsel" title="how many days at once"
            onchange=${(e) => {
        viewPicked = true;
        viewMode.set(e.target.value);
        viewOff.set(0);
    }}>${VIEWS.map(([m, lbl]) => vm === m
        ? html `<option value=${m} selected>${lbl}</option>`
        : html `<option value=${m}>${lbl}</option>`)}</select>`);
}
// ── availability editing: paint / move / resize / delete, per weekday ───────
// All ops mutate the shared availRing's live array in place, then availRing.save()
// (persist + the debounced av_sync push to the planner) and markDayChanged()
// (re-render the grid, the dial ring, and the day's panels). Identical to what a
// drag on the dial's blue arc does — this is just the grid's hand on the same clay.
const bandLabel = (it) => `${fmtClock(it.t0)}–${fmtClock(it.t1)} · ${av_daysLabel(it.days || AV_DAYS)}`;
function styleBand(el, it) {
    el.style.top = it.t0 * H + "px";
    el.style.height = Math.max(6, (it.t1 - it.t0) * H) + "px";
    const l = el.querySelector(".calav-lbl");
    if (l)
        l.textContent = bandLabel(it);
}
function commitAvail() { availRing.save(); markDayChanged(); } // persist + planner push + repaint
/** The weekday column whose band shows the pattern panel, or null. A window
 *  recurring across the view is drawn once per column; the panel opens in the
 *  one that was tapped. Closes with the selection. */
const recOpen = signal(null);
/**
 * Select a band — in the ring the dial shares, so the sidebar card opens the
 * same window's editor — with its pattern panel open in `panel`'s column, or
 * closed. selectEvent clears both rings first: ring editing and the event
 * card are exclusive.
 */
function selectBand(item, panel) {
    selectEvent(null);
    availRing.select(item.id);
    recOpen.set(panel);
    markDayChanged();
}
// The grid's × is column-scoped: clicked from THIS day's own rendered band, so
// "this day" is the only reading a single click can mean here (unlike the
// dial's floating editor, whose "delete" is asked with no day already
// implied). dropRecurringDay is the same mutation dial's own "this day"
// button performs — narrow the window's days, or remove it when that was
// the last one — so the grid and the dial never narrate the edit two ways.
const deleteAvail = (item, avName) => {
    dropRecurringDay(availRing.items(), item, avName);
    commitAvail();
};
const setDays = (item, days, fallback) => {
    av_setDays(item, days, fallback);
    commitAvail();
};
/** A recurrence pattern the panel offers in one tap; custom is the day row. */
const AV_PRESETS = [
    ["weekdays", AV_DAYS.slice(0, 5)], ["weekend", AV_DAYS.slice(5)], ["every day", AV_DAYS.slice()],
];
const sameDays = (a, b) => a.length === b.length && a.every(d => b.includes(d));
/**
 * The pattern panel on a SELECTED band: the recurrence of this window, as
 * presets one tap wide (this day only, weekdays, weekend, every day) and the
 * seven-day row for anything else — the same `days` the dial's picker edits,
 * so a window painted on one day becomes a standing default here, on the
 * band, where the eye already is. Presses inside stay inside: the band
 * underneath is a drag handle.
 */
function recPanel(item, avName) {
    const days = item.days || AV_DAYS;
    const stop = (e) => e.stopPropagation();
    const chip = (label, want) => html `<span class="calav-preset${sameDays(days, want) ? " on" : ""}"
      onclick=${() => setDays(item, want, avName)}>${label}</span>`;
    return html `<div class="calav-rec" onmousedown=${stop} onclick=${stop}>
    <div class="calav-rec-t">repeats</div>
    <div class="calav-presets">${chip("this day only", [avName])}${AV_PRESETS.map(([l, d]) => chip(l, d))}</div>
    <div class="calav-days">${AV_LBL.map((lbl, i) => {
        const name = AV_DAYS[i], on = days.includes(name);
        return html `<span class="${on ? "on" : ""}" title="${name}" onclick=${() => {
            const s = new Set(days);
            s.has(name) ? s.delete(name) : s.add(name);
            setDays(item, [...s], name);
        }}>${lbl}</span>`;
    })}</div></div>`;
}
/**
 * Build one availability band, and hand it back live.
 *
 * Its STRUCTURE is fixed shape (a label, two grips, the corners, the pattern
 * panel when open, or none of those when read-only) with no half-typed
 * state, so it is one `render()` call rather than five
 * `document.createElement`s — the same reasoning as the header. What does
 * NOT move to the renderer is what happens next: `press` holds onto the
 * returned element and writes `.style.top`/`.height` on it at pointer rate,
 * which is exactly the mutation a re-render would fight rather than serve.
 *
 * A band answers a tap in ANY mode: tapped, it is selected — an outline, its
 * grips, the two corners — and the sidebar card opens the same window's
 * editor. Paint mode (`editing`) is the wider offer: every band a handle,
 * and an empty cell a place to draw a new one.
 */
function buildAvailBand(colEl, item, avName, editing) {
    const selected = availRing.selId() === item.id;
    const active = editing || selected;
    const open = selected && recOpen() === avName;
    const shell = colEl.appendChild(document.createElement("div"));
    const el = render(shell, active
        ? html `<div class="calav-lbl">${bandLabel(item)}</div>
           <div class="calav-grip top"></div>
           <div class="calav-grip bot"></div>
           <div class="calav-corner"
             ><span class="calav-rep${open ? " on" : ""}" title="repeat pattern"
               onclick=${() => selectBand(item, open ? null : avName)}>↻</span
             ><span class="calav-del" title="remove from this day"
               onclick=${() => deleteAvail(item, avName)}>×</span></div>
           ${open ? recPanel(item, avName) : ""}`
        : "");
    el.className = "calav" + (active ? " edit" : "") + (selected ? " sel" : "");
    styleBand(el, item);
    // one press handler: what it does depends on where the press landed — a
    // grip resizes, the corners and the panel keep their own clicks, the body
    // moves (or, read-only, only selects)
    el.addEventListener("mousedown", (e) => {
        if (e.button !== 0)
            return;
        e.stopPropagation();
        const at = e.target;
        if (at.closest(".calav-corner, .calav-rec"))
            return;
        press(at.matches(".calav-grip.top") ? "top" : at.matches(".calav-grip.bot") ? "bot"
            : active ? "move" : "tap", item, el, colEl, e);
    });
    return el;
}
/**
 * A press on a band, held until release. Moving edits the window live —
 * `top`/`bot` resize, `move` slides, `tap` moves nothing — and the release
 * persists what moved, or selects the band when nothing did. The column
 * rect, captured at the start, maps y → hour.
 */
function press(mode, item, el, colEl, e) {
    const rect = colEl.getBoundingClientRect();
    const hourAt = (cy) => snap((cy - rect.top) / H);
    const span = item.t1 - item.t0, grab = mode === "move" ? hourAt(e.clientY) - item.t0 : 0;
    let moved = false;
    const move = (ev) => {
        moved = true;
        if (mode === "tap")
            return;
        const h = hourAt(ev.clientY);
        if (mode === "move") {
            const nt0 = Math.max(0, Math.min(24 - span, snap(h - grab)));
            item.t0 = nt0;
            item.t1 = nt0 + span;
        }
        else if (mode === "top")
            item.t0 = Math.min(h, item.t1 - 0.25);
        else
            item.t1 = Math.max(h, item.t0 + 0.25);
        styleBand(el, item);
    };
    const up = () => {
        document.removeEventListener("mousemove", move);
        document.removeEventListener("mouseup", up);
        if (moved) {
            if (mode !== "tap")
                commitAvail();
        }
        else if (availRing.selId() !== item.id)
            selectBand(item, null);
    };
    document.addEventListener("mousemove", move);
    document.addEventListener("mouseup", up);
}
function startCreate(colEl, avName, e) {
    const rect = colEl.getBoundingClientRect();
    const hourAt = (cy) => snap((cy - rect.top) / H);
    const anchor = hourAt(e.clientY);
    const item = { id: "av" + Date.now() + "_" + Math.floor(Math.random() * 1e4),
        t0: anchor, t1: Math.min(24, anchor + 0.25), days: [avName] };
    availRing.items().push(item);
    const el = buildAvailBand(colEl, item, avName, true);
    const move = (ev) => { const h = hourAt(ev.clientY); item.t0 = Math.min(anchor, h); item.t1 = Math.max(anchor, h); styleBand(el, item); };
    const up = () => {
        document.removeEventListener("mousemove", move);
        document.removeEventListener("mouseup", up);
        if (item.t1 - item.t0 < 0.25) {
            const arr = availRing.items(), i = arr.indexOf(item);
            if (i >= 0)
                arr.splice(i, 1);
        }
        commitAvail();
    };
    document.addEventListener("mousemove", move);
    document.addEventListener("mouseup", up);
}
// ── PROGRESSIVE DISCLOSURE, ON THE BLOCK ─────────────────────────────────────
//
// docs/planning/faces/watch-progressive-disclosure.md: an event is a recipe
// instantiation, and one glance earns one fact. The grid keeps that ladder ON
// THE EVENT ITSELF — a tap unfolds the block in place rather than sending
// the eye to a card in the rail — so answering (willing, commit, decline)
// happens where the looking happened.
//
// The rows read in one order — when and where, then what is worked, used,
// consumed, and last what comes out — and the BLOCK'S OWN HEIGHT pages them:
// as many rows as fit stand on a page (paginateBlock measures, after
// layout), a tap turns the page, and a tap past the last folds the block. A
// block with room shows everything at once and carries no dots at all.
//
// The page rides beside the shared selection rather than inside it: the
// dial's rim selects too, and a selection made there opens at the first page.
const disclosed = signal(null);
const skyOpen = signal(false); // the sky glyph, tapped: its one line
const pageOf = (ev) => {
    const d = disclosed();
    return d && d.ev === ev ? d.page : 0;
};
// how many pages the block last laid out for an event — what a tap consults
// to know whether it turns a page or folds the block
const pagesOf = new WeakMap();
function tapBlock(ev) {
    skyOpen.set(false);
    if (selectedEv.peek() !== ev) {
        disclosed.set({ ev, page: 0 });
        selectEvent(ev);
        return;
    }
    const next = pageOf(ev) + 1;
    if (next >= (pagesOf.get(ev) ?? 1)) {
        disclosed.set(null);
        selectEvent(null);
    }
    else
        disclosed.set({ ev, page: next });
}
/**
 * The action, said as what the act is doing. Any VF action reads through
 * here; one not named yet reads as its own word.
 */
const GERUND = {
    use: "using", consume: "consuming", work: "working", cite: "citing",
    produce: "producing", "deliver-service": "delivering", transfer: "transferring",
    move: "moving", "obtain-entity": "obtaining", "obtain-person": "calling on",
    pay: "paying", tell: "telling",
};
const gerund = (a) => GERUND[a] || a;
/** The actions that are the act's OUTPUT — what it leaves behind. */
const OUTPUT = new Set(["produce", "deliver-service"]);
const VERB_EMOJI = {
    use: "🔧", work: "💪", consume: "📦", cite: "📎", produce: "🌱", "deliver-service": "🤝",
    "obtain-entity": "📜", "obtain-person": "🆔", pay: "💶", tell: "📣",
};
/**
 * The recipe underneath the event, one line per action, inputs before
 * outputs. What the act needs HERE (the solve's own `needs` row) is the truer
 * inputs read where it exists — it is placed and priced; the library recipe's
 * flows stand in where the solve published none, and are the only source
 * for what the act leaves behind.
 */
function verbsOf(d) {
    const lines = new Map();
    const add = (action, f) => {
        if (!lines.has(action))
            lines.set(action, []);
        lines.get(action).push(f);
    };
    const flow = (f) => ({
        label: f.name || f.spec || "", emoji: f.emoji, spec: f.spec,
        q: f.q == null || f.q === "" ? null : +f.q, u: f.u
    });
    const rcp = recipeById(d.recipeId);
    for (const st of rcp?.steps || []) {
        for (const f of st.in || [])
            add(f.action || "consume", flow(f));
        for (const f of st.out || [])
            add(f.action || "produce", flow(f));
        if (st.hours && !lines.has("work"))
            add("work", { label: "labour", q: st.hours, u: "hours" });
    }
    if (d.needs && d.needs.length) {
        // the placed row replaces the recipe's INPUTS; the outputs stay
        for (const k of [...lines.keys()])
            if (!OUTPUT.has(k))
                lines.delete(k);
        const placed = new Map();
        for (const n of d.needs) {
            if (!placed.has(n.kind))
                placed.set(n.kind, []);
            placed.get(n.kind).push({ label: n.label, q: n.qty, u: n.unit, met: n.met, spec: n.name });
        }
        const outs = [...lines.entries()];
        lines.clear();
        for (const [k, v] of placed)
            lines.set(k, v);
        for (const [k, v] of outs)
            lines.set(k, v);
    }
    // the reading order: what is worked, then what is used, what is consumed,
    // the rest of the inputs, and what comes out last
    const rank = (a) => { const i = ORDER.indexOf(a); return i < 0 ? ORDER.length : i; };
    return [...lines.entries()].map(([action, flows]) => ({ action, flows }))
        .sort((a, b) => rank(a.action) - rank(b.action));
}
const ORDER = ["work", "use", "consume", "cite", "obtain-entity", "obtain-person", "pay", "tell",
    "transfer", "move", "produce", "deliver-service"];
const fmtQ = (f) => f.q == null ? "" : `${+(+f.q).toFixed(2)}${f.u ? (f.u === "hours" ? " h" : " " + f.u) : ""}`;
/**
 * A flow's own place, on the map, at the act's own time. showEventOnMap is
 * still the one door for day + face + event selection — this only ever adds
 * to what it does, never re-opens it by hand: when the flow's spec names a
 * live pool listing, that listing wins the camera and opens its own card
 * too; with no spec, or none standing in the pool, the event's own site (the
 * jump showEventOnMap already makes) is exactly where the flow is worked,
 * used or produced anyway.
 */
function showFlowOnMap(d, f) {
    showEventOnMap(d);
    if (f.spec)
        showSpecOnMap(f.spec);
}
/** One action's line: its name, then its flows as chips — each a tap to
 *  where that thing is, or is expected to be, at the act's own time. */
function verbLine(l, d) {
    return html `<div class="calxp-line"><span class="calxp-vh">${gerund(l.action)}</span>${l.flows.map(f => html `<span class="calxp-flow${f.met === "missing" ? " unmet" : ""}"
      title="${(f.met === "missing" ? "you do not hold this — " : f.met === "held" ? "held — " : "")}tap: see on the map"
      onclick=${(ev) => { ev.stopPropagation(); showFlowOnMap(d, f); }}>${f.emoji || VERB_EMOJI[l.action] || "•"} ${f.label}${fmtQ(f) ? html ` <small>${fmtQ(f)}</small>` : ""}${f.met === "missing" ? " ✗" : ""}</span>`)}</div>`;
}
/**
 * WHO ELSE has worked in this recipe, and where and when: every other row
 * the day holds — the schedule's placed commitments, the lived record, the
 * committed day — that shares the process (the same cell of the plan) or
 * the recipe. Soonest first. The rows are the wire's own; nothing is
 * inferred about a person the wire did not name.
 */
function peersOf(d) {
    if (!d.proc && !d.recipeId)
        return [];
    const same = (r) => r !== d && !!r.from && ((!!d.proc && r.proc === d.proc) || (!!d.recipeId && r.recipeId === d.recipeId));
    return [...sched, ...lived, ...evs].filter(same)
        .sort((a, b) => (b.doy ?? 0) - (a.doy ?? 0) || b.t0 - a.t0);
}
/** A peer's chip: who, when, where — a tap goes to that event on the map. */
function peerLine(peers) {
    const when = (r) => {
        const day = r.doy != null ? `${WD[dateOf(r.doy).getUTCDay()]} ${dateOf(r.doy).getUTCDate()} ` : "";
        return `${day}${fmtClock(r.t0)}–${fmtClock(r.t1)}`;
    };
    return html `<div class="calxp-line"><span class="calxp-vh">alongside</span>${peers.map(r => html `<span class="calxp-peer" title="${r.label}${r.tier === "lived" ? " — it happened" : " — planned"}"
      onclick=${(ev) => { ev.stopPropagation(); showEventOnMap(r); }}>👤 ${r.from} <small>${when(r)}${r.place ? html ` · 📍 ${r.place}` : ""}</small></span>`)}</div>`;
}
/** The day-of-year (0-based) the sun formulas take, from an absolute day. */
const dayOfYear = (doy) => {
    const d = dateOf(doy);
    return Math.round((d.getTime() - Date.UTC(d.getUTCFullYear(), 0, 1)) / 864e5);
};
/**
 * The unfolded block's body: EVERY row, in reading order, and the foot. The
 * block's height decides how many of the rows stand at once (paginateBlock,
 * below, run right after this lands in the grid). A short block was just
 * tapped by its title, so the title is what it cedes.
 */
function disclosureBody(d, doy, anchor, titled) {
    const stop = (f) => (ev) => { ev.stopPropagation(); f(); };
    const acts = actionsFor(d);
    const v = verbsOf(d);
    const peers = peersOf(d);
    const sky = skyAt((d.t0 + d.t1) / 2, dayOfYear(doy), doy === anchor, locOf(d));
    // the answers as glyphs alone — a raised hand, a check, a cross, an undo
    // arrow; each label opens with its glyph, and the words wait on hover.
    // A hand already raised reads as its own quiet mark, before the undo.
    const raised = d.tier === "open" && isWilling(d);
    const answers = acts.length
        ? html `<div class="respond">${raised ? html `<span class="calxp-state" title="your hand is raised — the plan matches among everyone offering">✋ offered</span>` : ""}${acts.map(a => html `<span class="${a.c}" title="${a.l} — ${a.t}" onclick=${stop(a.f)}>${Array.from(a.l)[0]}</span>`)}</div>`
        : "";
    // the hour is where the block stands, so it is not written again: the
    // title line carries the sky and the place, and the rows begin at once
    return html `${titled ? html `<div class="calev-t">${d.label}<span class="calxp-sky"
      title="${sky.line}" onclick=${stop(() => skyOpen.set(!skyOpen.peek()))}>${sky.glyph}</span>${d.place ? html `<span class="calev-loc" onclick=${stop(() => showEventOnMap(d))}>📍 ${d.place}</span>` : ""}</div>` : ""}${skyOpen() ? html `<div class="calxp-line quiet">${sky.line}</div>` : ""}${v.length ? v.map(l => verbLine(l, d)) : html `<div class="calxp-line"><span class="calxp-flow none">no recipe stated</span></div>`}${peers.length ? peerLine(peers) : ""}
    <div class="calxp-foot">${answers}<span class="calxp-dots" title="tap: next"></span></div>`;
}
/**
 * Page the rows to the block. Measured, not estimated: each row's own laid-out
 * height against the room left under the title and above the foot. Rows are
 * packed greedily in order; the rows not on PAGE are taken out of the block;
 * the dots are drawn for the count that resulted (none when it is one). The
 * count is remembered for the tap that decides whether to turn or fold.
 */
function paginateBlock(blk, ev, page) {
    const rows = Array.from(blk.querySelectorAll(":scope > .calxp-line"));
    const foot = blk.querySelector(":scope > .calxp-foot"); // disclosureBody wrote it
    const title = blk.querySelector(":scope > .calev-t");
    const cs = getComputedStyle(blk);
    const gap = parseFloat(cs.rowGap) || 0;
    const room = blk.clientHeight - parseFloat(cs.paddingTop) - parseFloat(cs.paddingBottom)
        - foot.offsetHeight - gap - (title ? title.offsetHeight + gap : 0);
    const pages = [[]];
    let used = 0;
    for (const r of rows) {
        const last = pages[pages.length - 1];
        const h = r.offsetHeight + (last.length ? gap : 0);
        if (last.length && used + h > room) {
            pages.push([r]);
            used = r.offsetHeight;
        }
        else {
            last.push(r);
            used += h;
        }
    }
    const p = Math.min(page, pages.length - 1);
    for (const r of rows)
        if (!pages[p].includes(r))
            r.remove();
    pagesOf.set(ev, pages.length);
    const dots = foot.querySelector(".calxp-dots");
    if (pages.length < 2) {
        dots.remove();
        return;
    }
    pages.forEach((_, i) => {
        const dot = document.createElement("i");
        if (i === p)
            dot.className = "on";
        dots.appendChild(dot);
    });
}
// ── the grid: sticky day-headers, the hour gutter, the day columns ──────────
//
// This one stays imperative, and the reason is the drag. An availability band
// is MUTATED at pointer rate — startDrag writes el.style.top and .height on
// every mousemove — so the band's node has to outlive the draw that made it
// and answer to the pointer rather than to a re-render. A keyed renderer is the
// right tool for a list rebuilt from data and the wrong one for a node a hand
// is currently holding.
//
// The header above has no such node, which is why it converted and this did not.
function drawGrid(start, count, anchor) {
    const todayDoy = Math.floor(S.nowAbs / 24);
    const nowT = ((S.nowAbs % 24) + 24) % 24;
    const grid = d3.select("#calgrid");
    // the scroller's place is read BEFORE the grid is emptied: with no content
    // the scroller has no height, its scrollTop clamps to 0, and a tap on a
    // block would land the reader back at midnight
    const sc = document.getElementById("calscroll");
    const keepTop = sc ? sc.scrollTop : 0;
    grid.selectAll("*").remove();
    // day-header row — only where there are columns to tell apart; a single
    // day is named once, in the bar above (rangeLabel), and the grid starts
    // straight at the hours
    if (count > 1) {
        const heads = grid.append("div").attr("class", "calheads");
        heads.append("div").attr("class", "calgutter-sp");
        for (let i = 0; i < count; i++) {
            const doy = start + i, d = dateOf(doy);
            const h = heads.append("div").attr("class", "calhead" + (doy === todayDoy ? " today" : ""));
            h.append("div").attr("class", "cald-name").text(WD[d.getUTCDay()]);
            h.append("div").attr("class", "cald-num").text(d.getUTCDate());
        }
    }
    const body = grid.append("div").attr("class", "calbody");
    // Measured once, here, before any day column exists: .calbody's own width
    // comes from its CSS (fills #calgrid), not from its children, so this is
    // already what each day column will settle to once they're all appended —
    // measuring per-column INSIDE the loop below would catch early columns
    // still stretched to a share of the row they won't keep once their
    // siblings land. 46 is .calgutter's own fixed width (see its CSS).
    const dayColW = count > 0 ? Math.max(0, body.node().getBoundingClientRect().width - 46) / count : 0;
    // the hour gutter
    const gut = body.append("div").attr("class", "calgutter");
    for (let hh = 0; hh < 24; hh++) {
        const row = gut.append("div").attr("class", "calhr");
        if (hh)
            row.append("span").text(fmtClock(hh));
    }
    const editing = editAvail();
    d3.select("#calface").classed("editing", editing);
    // the day columns
    for (let i = 0; i < count; i++) {
        const doy = start + i, avName = avNameOf(doy);
        const col = body.append("div").attr("class", "calcol" + (doy === todayDoy ? " today" : ""));
        for (let hh = 0; hh < 24; hh++)
            col.append("div").attr("class", "calcell");
        // d3 just appended it, so the selection has a node.
        const colEl = col.node();
        // availability background — in edit mode each band grows grips + a delete, and
        // an empty-cell drag paints a new one (mirrors the repl calendar's availability
        // editor). Every edit writes through the SAME availRing.save() the dial uses,
        // so the arc, the localStorage buffer, and the planner push stay in one place.
        for (const a of availForColumn(doy))
            buildAvailBand(colEl, a, avName, editing);
        if (editing)
            colEl.addEventListener("mousedown", (e) => {
                // the band under the pointer owns its own drag
                if (e.button !== 0 || e.target.closest(".calav"))
                    return;
                startCreate(colEl, avName, e);
            });
        // the current-time line, on today only
        if (doy === todayDoy)
            col.append("div").attr("class", "calnow").style("top", nowT * H + "px");
        // events, laid side-by-side where they overlap
        const placed = layoutColumns(eventsForColumn(doy, anchor));
        for (const { e, col: c, total } of placed) {
            const top = e.t0 * H, ht = Math.max(16, (e.t1 - e.t0) * H);
            const cur = e.interactive && selectedEv() === e.orig;
            const dim = e.interactive && selectedEv() && selectedEv() !== e.orig;
            const isOpen = e.tone === "open";
            // the plan's own ink — the schedule calendar's rust, outlined and
            // translucent (the .plan class), so the commune's cells never read
            // as a commitment of yours
            const isPlan = e.tone === "plan";
            // the LIVED record wears the ledger's own quiet ink, whatever kind of
            // act it was: the past reads beside the plan, never as the plan
            const ec = isPlan ? "#b0653a" : e.lived ? "#767b6e" : evColor(e);
            // more height, bigger type — a 15-minute event and a 3-hour one used to
            // read at the same size regardless of which one had room to spare.
            const tier = ht >= 160 ? "t5" : ht >= 110 ? "t4" : ht >= 70 ? "t3" : ht >= 46 ? "t2" : ht >= 30 ? "t1" : "";
            const fpx = TIER_PX[tier];
            const evW = dayColW / total;
            const timeStr = ht > 26 ? `${fmtClock(e.t0)}–${fmtClock(e.t1)}` : "";
            // the sky at the event, before any tap: one glyph beside the hour is
            // the glance; its line waits on hover, and on the unfolded block's tap
            const sky = (timeStr && e.orig) ? skyAt((e.t0 + e.t1) / 2, dayOfYear(doy), doy === anchor, locOf(e.orig)) : null;
            const place = e.orig && e.orig.place; // the event's venue, if it has one
            const locStr = (place && ht > 40) ? `📍 ${place}` : "";
            // WIDE means title + time + place actually FIT on one line at the
            // size this box's height already earns them (the .t1–.t4 tier above)
            // — measured, not guessed. A short title next to a long one at the
            // very same box size needs a different answer, and a flat pixel
            // cutoff can only ever be right for one of them; this is right for
            // both, and for a longer title it falls back to the stacked, bigger,
            // wrapped read rather than truncating three things onto one line.
            const rowParts = [textW(e.title || "", "600", fpx)];
            if (timeStr)
                rowParts.push(textW(timeStr + (sky ? " " + sky.glyph : ""), "400", fpx));
            if (locStr)
                rowParts.push(textW(locStr, "400", fpx));
            const rowNeeds = rowParts.reduce((a, b) => a + b, 0) + ROW_GAP * (rowParts.length - 1) + TIER_PAD[tier];
            const wide = timeStr !== "" && evW >= rowNeeds;
            // an open work-intent or a proposal you've raised your hand for reads
            // as such right on the card — before this, committing turned the card
            // solid and expressing willingness left no mark anywhere on the grid,
            // so the same act read as doing nothing depending on which one it was.
            const willing = isOpen && !!e.orig && isWilling(e.orig);
            const cls = "calev" + (tier ? " " + tier : "") + (wide ? " row" : "")
                + (isOpen ? " open" : "") + (isPlan ? " plan" : "") + (willing ? " willing" : "") + (e.personal ? " personal" : "")
                + (e.need ? " needband" : "") + (e.lived ? " lived" : "")
                + (cur ? " sel" : "") + (dim ? " dim" : "");
            const blk = col.append("div").attr("class", cls)
                .style("--ec", ec)
                .style("top", top + "px").style("height", ht + "px")
                .style("left", `calc(${(c / total) * 100}% + 1px)`)
                .style("width", `calc(${100 / total}% - 2px)`)
                .style("background", (isOpen || isPlan || e.lived) ? null : ec)
                .style("color", (isOpen || isPlan) ? null : "#fff");
            if (cur && e.orig) {
                // THE UNFOLDED BLOCK: the selected event grows to its content, takes
                // the column's whole width and stands over its neighbours — the
                // ladder and the answers read on the block, at the hour it occupies
                blk.classed("xp", true).classed("row", false);
                render(blk.node(), disclosureBody(e.orig, doy, anchor, ht >= 46));
                paginateBlock(blk.node(), e.orig, pageOf(e.orig));
            }
            else {
                blk.append("div").attr("class", "calev-t").text(e.title || "");
                if (timeStr) {
                    const w = blk.append("div").attr("class", "calev-w").text(timeStr);
                    if (sky)
                        w.append("span").attr("class", "calxp-sky").attr("title", sky.line).text(sky.glyph);
                }
                if (locStr)
                    blk.append("div").attr("class", "calev-loc").text(locStr)
                        .on("click", (ev) => { ev.stopPropagation(); showEventOnMap(e.orig); });
            }
            if (e.interactive)
                blk.on("click", (ev) => { ev.stopPropagation(); tapBlock(e.orig); });
            if (e.groupKey) // a flow group toggles open/closed in place
                blk.on("click", (ev) => {
                    ev.stopPropagation();
                    flowPop.set(flowPop.peek() === e.groupKey ? null : e.groupKey);
                });
            if (e.offerGroup) { // an offer group opens the location picker in the detail panel
                const k = `${doy}|${e.t0}|${e.t1}|${e.offerGroupTitle}`;
                blk.on("click", (ev) => {
                    ev.stopPropagation();
                    offerGroupPop.set(offerGroupPop.peek() === k ? null : k);
                });
                // THE CHOICE, ON THE BLOCK: its locations as pills in order of
                // optimality, as many as the block's own height holds, so a person
                // commits from the grid without opening anything; the rest stand
                // behind a "+N" that opens the full picker. A pill click is exactly
                // the click on that location's own card.
                drawOfferPills(blk.node(), byPlanGain(e.offerGroup, doy, e.t0, e.t1), k);
            }
            if (e.need) // a band is its need's shadow: tap through to the card itself
                blk.on("click", (ev) => { ev.stopPropagation(); revealSlot(e.spec || "", "need"); });
        }
    }
    // start scrolled to the working day (~07:00), once, on first paint;
    // `_homed` is the dial's own stamp on the scroller. Every later paint
    // puts the reader back exactly where they were.
    if (!sc)
        return;
    if (!sc._homed) {
        sc._homed = true;
        sc.scrollTop = 6.5 * H;
    }
    else
        sc.scrollTop = keepTop;
}
// ── the month grid: weeks as ROWS, days as cells ─────────────────────────────
//
// A different shape than the hour grid above, not a squint at it: a month has
// no hours to lay events against, only a day each block belongs to, so cells
// hold up to MAXEV titles (soonest first) plus an overflow count rather than a
// timed span. Nothing here is dragged, so — unlike drawGrid — this one IS a
// plain render() of one expression: no node outlives the draw that made it.
const MAXEV = 3;
function drawMonthGrid(y, m, gridStart, gridCount, anchor) {
    const todayDoy = Math.floor(S.nowAbs / 24);
    const ws = weekStart();
    const dayNames = Array.from({ length: 7 }, (_, i) => WD[(ws + i) % 7]);
    const cells = [];
    for (let i = 0; i < gridCount; i++) {
        const doy = gridStart + i, d = dateOf(doy);
        const inMonth = d.getUTCMonth() === m && d.getUTCFullYear() === y;
        const isToday = doy === todayDoy;
        const items = eventsForColumn(doy, anchor).slice().sort((a, b) => a.t0 - b.t0);
        const shown = items.slice(0, MAXEV), extra = items.length - shown.length;
        cells.push(html `
      <div class="calmcell${inMonth ? "" : " out"}${isToday ? " today" : ""}" data-doy="${doy}"
           onclick=${() => monthPop.set(null)}>
        <div class="calmnum${isToday ? " today" : ""}">${d.getUTCDate()}</div>
        ${shown.map(e => {
            const cls = "calmev" + (e.tone === "open" ? " open" : "") + (e.personal ? " personal" : "")
                + (e.need ? " needband" : "") + (e.lived ? " lived" : "");
            return html `<div class="${cls}" style="--ec:${evColor(e)}"
            onclick=${(ev) => {
                ev.stopPropagation();
                if (e.need)
                    revealSlot(e.spec || "", "need");
                else if (e.interactive)
                    selectEvent(selectedEv.peek() === e.orig ? null : e.orig);
            }}>${e.title || ""}</div>`;
        })}
        ${extra > 0 ? html `<div class="calmmore"
            onclick=${(ev) => { ev.stopPropagation(); monthPop.set(monthPop.peek() === doy ? null : doy); }}
            >+${extra} more</div>` : ""}
      </div>`);
    }
    render("#calgrid", html `
    <div class="calmheads">${dayNames.map(n => html `<div class="calmhead">${n}</div>`)}</div>
    <div class="calmbody" style="grid-template-rows: repeat(${gridCount / 7}, minmax(var(--calm-min), 1fr))">${cells}</div>`);
}
/**
 * The "+N more" popover: EVERY event the day's cell couldn't fit, not just the
 * overflow past MAXEV — reading the full day in one place beats reading part
 * of it in the cell and the rest here. Positioned in FIXED coordinates off the
 * named cell's own rect (see .calmpop in app.html for why), so it is measured
 * fresh each call rather than carried between draws.
 */
function drawMonthPopover(anchor) {
    const pop = document.getElementById("calmpop");
    const grid = document.getElementById("calgrid");
    const doy = monthPop();
    const cell = doy != null && grid ? grid.querySelector(`.calmcell[data-doy="${doy}"]`) : null;
    if (!pop)
        return;
    if (doy == null || !cell) {
        pop.classList.remove("on");
        return;
    }
    const d = dateOf(doy);
    const items = eventsForColumn(doy, anchor).slice().sort((a, b) => a.t0 - b.t0);
    render(pop, html `
    <div class="calmpop-hd"><span class="calmpop-wd">${WD[d.getUTCDay()]}</span>
      <span class="calmpop-num">${d.getUTCDate()}</span>
      <span class="calmpop-x" onclick=${() => monthPop.set(null)}>${raw("&times;")}</span></div>
    <div class="calmpop-list">${items.map(e => {
        const cls = "calmpop-ev" + (e.tone === "open" ? " open" : "") + (e.personal ? " personal" : "")
            + (e.need ? " needband" : "") + (e.lived ? " lived" : "");
        return html `<div class="${cls}" style="--ec:${evColor(e)}"
        onclick=${() => {
            if (e.need)
                revealSlot(e.spec || "", "need");
            else if (e.interactive)
                selectEvent(selectedEv.peek() === e.orig ? null : e.orig);
            monthPop.set(null);
        }}>${fmtClock(e.t0)} ${e.title || ""}</div>`;
    })}</div>`);
    pop.classList.add("on");
    const cr = cell.getBoundingClientRect();
    pop.style.left = Math.max(4, Math.min(cr.left, window.innerWidth - 284)) + "px";
    pop.style.top = Math.max(4, Math.min(cr.top, window.innerHeight - 60)) + "px";
}
// ── the sidebar: the selected-event reading card ─────────────────────────────
// The colour key that used to sit here is gone: the rail's calendars list
// (app/tabs/calrail.js) already names every source in its own ink, and does it
// as a control rather than a caption — two legends for one palette is one too many.
// mirrors main.js drawCal's #evdetail: the same acts list, the same handlers, so
// a response on the grid takes the exact path a response on the dial does.
/**
 * The card itself — one template, two mounts: the rail's #caldetail beside a
 * wide grid, and #calsheet as a page of its own on a phone. The SAME five
 * answers the dial's card offers, from the one ladder in app/respond.ts; a
 * label, a proposer and a place are the OTHER PARTY's text, so they land
 * escaped and the actions carry their own handlers.
 */
function detailCard(d) {
    const acts = actionsFor(d);
    return html `
    <b>${d.label}</b>${d.from ? html ` <span style="color:#999">· with ${d.from}</span>` : ""}<br>
    ${fmtClock(d.t0)} – ${fmtClock(d.t1)} · ${fmtDur(d.t0, d.t1)}<br>${d.place ? html `<span class="cal-loc" onclick=${() => showEventOnMap(d)}>📍 ${d.place}</span><br>` : ""}
    <span class="${d.kind === "work" ? "kw" : "kf"}">${d.kind === "work" ? "labour time" : "free time"}</span>${d.serves ? html ` · serves → <b>${d.serves}</b>` : ""}<br>
    <span style="color:#999">${vfLine(d)}</span>${acts.length
        ? html `<div class="respond">${acts.map(a => html `<span class="${a.c}" title="${a.t}" onclick=${a.f}>${a.l}</span>`)}</div>`
        : ""}`;
}
function drawDetail() {
    const det = d3.select("#caldetail");
    const sheet = document.getElementById("calsheet");
    const openGroup = offerGroupPop();
    if (openGroup) {
        const [, , , title] = openGroup.split("|");
        det.style("border-left-color", cWarm);
        // the block's own members are re-found from the CURRENT day's rows
        // rather than captured at open-time, so a re-solve mid-pick never
        // hands the picker a stale event
        const members = currentOfferGroupMembers(openGroup);
        const priced = members.some(m => m.e.pull != null);
        render(det.node(), html `<b>${title}</b> · pick where — ${priced ? "where the plan gains most from you first" : "nearest first"}:<div class="respond offer-pick">${members.map(({ place, e, km }) => html `<span class="r-willing" title="${e.pull != null ? `pull ${e.pull.toPrecision(2)}/h · ` : ""}${isFinite(km) ? `${km.toFixed(1)} km` : ""}"
               onclick=${() => { offerGroupPop.set(null); selectEvent(e); }}
             >📍 ${place}${isFinite(km) ? html ` <small>${km.toFixed(1)} km</small>` : ""}</span>`)}</div>`);
        return;
    }
    // a tapped availability band: the card carries the dial's own window editor
    // — hours, the seven-day row, this-day/every-day delete — one editor, two
    // surfaces that reach it
    if (availRing.editItem()) {
        det.style("border-left-color", "#9fd0ea").html("");
        availRing.renderEditorBody(det);
        sheet?.classList.remove("on");
        return;
    }
    const d = selectedEv();
    if (!d) {
        det.style("border-left-color", "#ddd");
        render(det.node(), "select an event on the grid, or on the time dial — the two share it");
        sheet?.classList.remove("on");
        return;
    }
    const col = d.kind === "work" ? cWarm : cYea;
    det.style("border-left-color", col);
    render(det.node(), detailCard(d));
    // a phone: the same card opens as a page of its own OVER THE MONTH GRID,
    // whose cells have no block to unfold; the hour grid unfolds the block
    // itself, and a sheet over it would take the eye exactly where the block
    // just earned it
    if (sheet && viewMode() === "month" && window.matchMedia("(max-width: 920px)").matches) {
        render(sheet, html `
      <div class="calsheet-hd"><span class="calsheet-x" title="back to the grid"
        onclick=${() => selectEvent(null)}>${raw("&times;")}</span></div>
      <div class="calsheet-card" style="border-left-color:${col}">${detailCard(d)}</div>`);
        sheet.classList.add("on");
    }
    else
        sheet?.classList.remove("on");
}
function drawCalendar() {
    // month mode reshapes the scroller (app.html's #calface.month rules): the
    // grid stretches to the stage instead of ending where its content does
    d3.select("#calface").classed("month", viewMode() === "month");
    if (viewMode() === "month") {
        const { y, m, gridStart, gridCount } = monthWindow();
        const anchor = Math.floor(turnAnchor() / 24);
        drawHeader(monthLabel(y, m));
        drawMonthGrid(y, m, gridStart, gridCount, anchor);
        drawMonthPopover(anchor);
        drawDetail();
        return;
    }
    document.getElementById("calmpop")?.classList.remove("on");
    const { start, count, anchor } = windowStart();
    drawHeader(rangeLabel(start, count));
    drawGrid(start, count, anchor);
    drawDetail();
}
// the seam hook setFace / selectEvent / ingest use to refresh the grid.
window.drawCalendar = drawCalendar;
export function initCalendar() {
    // one effect: any data change (the shared `day` notifier) OR a view change
    // re-renders — but only while the face is open (setFace draws it on entry).
    effect(() => {
        // read every signal the grid depends on UNCONDITIONALLY: reads that only
        // happen inside `drawCalendar` are missed on the runs where the calendar
        // face isn't showing, and an effect only re-runs for what it actually read.
        day();
        viewMode();
        viewOff();
        editAvail();
        weekStart();
        calsRev();
        facetsRev();
        selectedEv();
        disclosed();
        skyOpen();
        monthPop();
        flowPop();
        if (stage.face === "cal")
            drawCalendar();
    });
    // the row/stack choice and every tier's font-size are measured off each
    // event block's actual pixel width — right the moment it's drawn, but
    // stale the moment the window (or the panel, dragged — panel.ts's settle()
    // fires this same event for exactly this reason) changes it without a
    // data or view change to re-trigger the effect above. rAF-coalesced: a
    // drag fires many resizes a second, and only the settled width matters.
    let raf = 0;
    window.addEventListener("resize", () => {
        if (stage.face !== "cal")
            return;
        if (raf)
            cancelAnimationFrame(raf);
        raf = requestAnimationFrame(() => { raf = 0; drawCalendar(); });
    });
}
export { drawCalendar };
