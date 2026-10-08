// app/slots/model.ts — the slot, on ValueFlows fields only.
//
// Ported from free-association's slots (BaseSlot / AvailabilityWindow):
// there, capacity and need are ONE type distinguished only by which list
// a slot lives in; here the same unification lands on VF — a NEED slot is
// an <intent> (receiver = you), a CAPACITY slot an <economic-resource>
// (primary-accountable = you) — and the recurring time pattern rides the
// availability-window BOTH records already carry. The wire is the arcs
// convention the agent's calendar availability always used:
//   [{start:"HH:MM", end:"HH:MM", days:["monday",…]}, …]
// (service.scm arcs-json->window / window->arcs — one parser, three rails.)
//
// A slot object here mirrors the my-slots wire verbatim:
//   { id, spec, name, emoji, note, qty, unit, where, from, until,
//     arcs: [{start, end, days[]}] }
import { isoDate } from '../timefmt.js';
export const MONTHS_SHORT = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
export const WEEK_ORDINALS = ["1st", "2nd", "3rd", "4th", "5th"];
export const TENSIONS = ["floor", "held", "des"];
export const TENSION_LABEL = { floor: "a right", held: "a need", des: "a want" };
export const TENSION_HINT = {
    floor: "a hard wall — below it the scope has no plan; never shaved to serve anything else",
    held: "can run short when the commons is short, and is never zeroed",
    des: "can be set aside for a finite price; the quietest rows go first",
};
/**
 * The voice slider's detents: three steps to each factor of ten, spanning
 * 1..1000 — round(10^(i/3)), the range of engine.scm's level ladder
 * (β = 1000^(1/9), so β^level = 10^(level/3)). Position 0 is no attachment.
 * UI quantization only: the wire and the fold take any positive voice.
 */
export const VOICE_LADDER = [0, ...Array.from({ length: 10 }, (_, i) => Math.round(10 ** (i / 3)))];
export const ladderIndex = (v) => {
    let best = 0;
    for (let i = 1; i < VOICE_LADDER.length; i++)
        if (Math.abs(VOICE_LADDER[i] - v) < Math.abs(VOICE_LADDER[best] - v))
            best = i;
    return best;
};
export const DAYS = ["monday", "tuesday", "wednesday", "thursday", "friday",
    "saturday", "sunday"];
export const DAY_LETTERS = ["M", "T", "W", "T", "F", "S", "S"];
export const WEEKDAYS = DAYS.slice(0, 5);
export const WEEKEND = DAYS.slice(5);
// named presets over raw values (free-association options.ts) — each is a
// whole arc; "Custom…" in the editor reveals the raw time inputs
export const TIME_PRESETS = [
    { key: "mornings", label: "mornings", start: "08:00", end: "12:00" },
    { key: "midday", label: "midday", start: "12:00", end: "15:00" },
    { key: "evenings", label: "evenings", start: "17:00", end: "21:00" },
    { key: "workday", label: "workday", start: "09:00", end: "17:00" },
];
export const DAY_PRESETS = [
    { key: "weekdays", label: "weekdays", days: WEEKDAYS },
    { key: "weekend", label: "weekend", days: WEEKEND },
    { key: "all", label: "every day", days: DAYS },
];
// sensible seed — nothing starts blank (their DayScheduleEditor:59)
export const seedArc = () => ({ start: "09:00", end: "17:00", days: [...WEEKDAYS] });
export const TIME_MODES = [
    { value: "business", label: "business hours (9am–5pm)", start: "09:00", end: "17:00" },
    { value: "allday", label: "all day (24 hours)", start: "00:00", end: "23:59" },
    { value: "mornings", label: "mornings (8am–12pm)", start: "08:00", end: "12:00" },
    { value: "afternoons", label: "afternoons (1pm–5pm)", start: "13:00", end: "17:00" },
    { value: "evenings", label: "evenings (6pm–10pm)", start: "18:00", end: "22:00" },
    { value: "custom", label: "custom time…", start: "", end: "" },
];
export const DAY_MODES = [
    { value: "all", label: "every day", days: DAYS },
    { value: "weekdays", label: "weekdays (Mon–Fri)", days: WEEKDAYS },
    { value: "weekends", label: "weekends (Sat–Sun)", days: WEEKEND },
    { value: "custom", label: "custom days…", days: [] },
];
export const MONTH_MODES = [
    { value: "all", label: "all year", months: undefined },
    { value: "summer", label: "summer (Jun–Aug)", months: [6, 7, 8] },
    { value: "winter", label: "winter (Dec–Feb)", months: [12, 1, 2] },
    { value: "q1", label: "Q1 (Jan–Mar)", months: [1, 2, 3] },
    { value: "q2", label: "Q2 (Apr–Jun)", months: [4, 5, 6] },
    { value: "q3", label: "Q3 (Jul–Sep)", months: [7, 8, 9] },
    { value: "q4", label: "Q4 (Oct–Dec)", months: [10, 11, 12] },
    { value: "custom", label: "specific months…", months: [] },
];
export const WEEK_MODES = [
    { value: "all", label: "every week", weeks: undefined },
    { value: "1st_3rd", label: "1st & 3rd weeks", weeks: [1, 3] },
    { value: "2nd_4th", label: "2nd & 4th weeks", weeks: [2, 4] },
    { value: "custom", label: "specific weeks…", weeks: [] },
];
const sameSet = (a, b) => a.length === b.length && a.every(x => b.includes(x));
/**
 * Which named mode an arc's field currently reads as — the first concrete
 * entry that matches, else the table's last entry, which is always "custom".
 */
const modeOf = (modes, hit) => (modes.find(m => m.value !== "custom" && hit(m)) || modes[modes.length - 1]).value;
// a tier (months, weeks) left unset is "all"; a set one matches by its numbers
const tierModeOf = (modes, set, of) => !set || !set.length ? "all" : modeOf(modes, m => !!of(m) && sameSet(of(m), set));
export const timeModeOf = (a) => modeOf(TIME_MODES, m => m.start === a.start && m.end === a.end);
export const dayModeOf = (a) => modeOf(DAY_MODES, m => sameSet(m.days, a.days));
export const monthModeOf = (a) => tierModeOf(MONTH_MODES, a.months, m => m.months);
export const weekModeOf = (a) => tierModeOf(WEEK_MODES, a.weeks, m => m.weeks);
// ── the SPAN of a lend: the socialization grant's window ──────────────────
// Declaring a capacity says you own it and how much; socializing it says for
// how long the commons may use it. That window is the grant's `valid-until`
// (custody-attestation ACDC) — the one field the half-life watcher reads to
// hand custody back, so "open-ended" is the setting that removes the automatic
// return and is named as such wherever it is offered.
export const SPANS = [
    { id: "week", label: "a week", days: 7 },
    { id: "month", label: "a month", days: 30 },
    { id: "season", label: "a season", days: 91 },
    { id: "year", label: "a year", days: 365 },
    { id: "date", label: "a date…" },
    { id: "open", label: "open-ended" },
];
// span → the `until` the wire carries: "" is open-ended (the grant never
// closes), and a date span carries whatever day was picked (empty until it is).
export function spanUntilISO(span, datePick) {
    if (!span)
        return "";
    if (span.id === "open")
        return "";
    if (span.id === "date")
        return datePick || "";
    const d = new Date();
    d.setDate(d.getDate() + (span.days || 0));
    return isoDate(d);
}
// an ISO day as a human reads it; "" when it isn't one
export function humanDate(iso) {
    if (!iso)
        return "";
    const d = new Date(iso + "T00:00:00");
    return isNaN(d.getTime()) ? "" : d.toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" });
}
export const blankDraft = () => ({ arcs: [], where: "", cats: [], spec: null });
export const UNITS = [
    { id: "each", label: "each", emoji: "📦", group: "count" },
    { id: "person-nights", label: "person-nights", emoji: "🛏️", group: "count" },
    { id: "kg", label: "kilograms", emoji: "⚖️", group: "mass" },
    { id: "kg/day", label: "kg a day", emoji: "🥖", group: "mass" },
    { id: "kg/week", label: "kg a week", emoji: "🧺", group: "mass" },
    { id: "L", label: "liters", emoji: "💧", group: "volume" },
    { id: "hours", label: "hours", emoji: "⏱️", group: "time" },
    { id: "hours/day", label: "hours a day", emoji: "🌅", group: "time" },
    { id: "hours/week", label: "hours a week", emoji: "📆", group: "time" },
    { id: "days", label: "days", emoji: "📅", group: "time" },
    { id: "kWh", label: "kWh", emoji: "⚡", group: "energy" },
    { id: "EUR", label: "euros", emoji: "💶", group: "money" },
    { id: "XMR", label: "monero", emoji: "🪙", group: "money" },
];
// No distance unit: transport measures TIME (solve/routing.scm's own trip is
// hours), and road distance is a routing-engine internal a citizen never
// declares — every id above is one a real recipe or spec reads.
/**
 * Money units — the ISO/ticker codes the planner's medium-of-exchange specs
 * carry (spec-eur "EUR", spec-xmr "XMR"). An offer in one of these is a PURSE:
 * lending it is a consume-grant (the commune may spend up to the amount), not
 * a use-grant, and a need in one is a money need the plan answers by
 * acquisition.
 */
export const MONEY_UNITS = ["EUR", "XMR", "USD"];
export const isMoneyUnit = (unit) => MONEY_UNITS.includes(String(unit || "").trim().toUpperCase());
/** How the planner will read this unit on this rail — the echo under the pill. */
export function unitReading(unit, kind) {
    const u = unit.trim();
    const m = u.match(/^(.+)\/(day|week)$/);
    if (m)
        return `rate: ${m[1]} per ${m[2]} — the planner converts by its bands`;
    if ((u === "hours" || u === "minutes" || u === "days") && kind !== "need")
        return "budget: a pool of time, spent across the horizon";
    if (isMoneyUnit(u))
        return kind === "need" ? "money: the plan meets it by acquisition, weighted with everyone else's"
            : "purse: lending it lets the plan spend up to that much — what is unspent comes back";
    return "";
}
export const blankSlot = (kind) => ({
    id: null, spec: "", name: "", emoji: kind === "need" ? "🌱" : "🤲",
    note: "", qty: 1, unit: kind === "need" ? "each" : "hours",
    where: "", from: null, until: null, arcs: [],
});
// name → spec id: the folksonomy slug ("fresh bread" → "spec-fresh-bread").
// Known specs win (datalist suggests them); an unknown name still declares —
// the commune's cut absorbs new terms, recipes catch up.
export const specOf = (name) => "spec-" + String(name || "").trim().toLowerCase()
    .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
// ── summaries: the collapsed accordion reads its own state ────────────────
// the day set as a word when DAY_MODES names it, else the days' own letters
const DAY_WORD = { all: "every day", weekdays: "weekdays", weekends: "weekend" };
const dayLabel = (ds) => DAY_WORD[dayModeOf({ days: ds || [] })] || (ds || []).map(d => d.slice(0, 3)).join(" ");
// a run of ints reads as a span ("Oct–Dec"), a scatter as a list ("Jan, Mar")
const runLabel = (ns, name) => {
    const s = [...ns].sort((a, b) => a - b);
    const contiguous = s.every((n, i) => !i || n === s[i - 1] + 1);
    return s.length > 2 && contiguous ? `${name(s[0])}–${name(s[s.length - 1])}` : s.map(name).join(", ");
};
export function fmtArc(a) {
    const tiers = [];
    if (a.months && a.months.length && a.months.length < 12)
        tiers.push(runLabel(a.months, m => MONTHS_SHORT[m - 1]));
    if (a.weeks && a.weeks.length && a.weeks.length < 5)
        tiers.push(runLabel(a.weeks, w => WEEK_ORDINALS[w - 1]) + " wk");
    return `${tiers.length ? tiers.join(" · ") + " · " : ""}${dayLabel(a.days)} ${a.start}–${a.end}`;
}
export function fmtArcs(arcs) {
    if (!arcs || !arcs.length)
        return "anytime";
    return arcs.map(fmtArc).join(" · ");
}
export function fmtWhere(where, locs) {
    if (!where)
        return "anywhere";
    const l = (locs || []).find(x => x.id === where);
    return l ? l.name : where;
}
// the scope's places (live snapshot) — the same source the shop's order
// card reads; empty offline (the editor then offers free entry)
export function locationOptions(EXT) {
    const locs = (EXT.snapshot && EXT.snapshot.locations) || [];
    return locs.filter(l => l && l.name).map(l => {
        const lat = parseFloat(String(l.lat)), lng = parseFloat(String(l.lng ?? l.long));
        return { id: String(l.id || l.name), name: String(l.name),
            ...(l.address ? { address: String(l.address) } : {}),
            ...(isFinite(lat) && isFinite(lng) ? { lat, lng } : {}) };
    });
}
/**
 * Every known spec, from the two sources the dial carries — inventory specs
 * and plan needs — WITH its folksonomy classification: an inventory spec's
 * own `categories`, or, for a plan need, its id, which in this taxonomy IS a
 * term-id (`nourishment/meals` names both the need and the branch it hangs
 * from). The one walk over those sources: knownSpecs and knownEmoji are
 * projections of these rows, so every reader agrees on the same catalogue.
 */
export function knownSpecRows(EXT, PLAN) {
    const out = [], seen = new Set();
    const put = (r) => { if (!seen.has(r.id)) {
        seen.add(r.id);
        out.push(r);
    } };
    ((EXT.inventory && EXT.inventory.specs) || []).forEach(s => put({ id: s.id, name: s.name || s.id, emoji: String(s.emoji || ""),
        cats: (s.categories || []).filter((c) => typeof c === "string") }));
    const plan = PLAN && PLAN();
    ((plan && plan.needs) || []).forEach(n => put({ id: n.id, name: n.label || n.id, emoji: n.emoji || "", cats: [n.id] }));
    return out;
}
/** spec id → human label */
export function knownSpecs(EXT, PLAN) {
    return new Map(knownSpecRows(EXT, PLAN).map(r => [r.id, r.name]));
}
/** the glyph by id AND by lowercased name — a spine term or a typed name finds it without a catalogue of ours */
export function knownEmoji(EXT, PLAN) {
    const out = new Map();
    for (const r of knownSpecRows(EXT, PLAN))
        if (r.emoji) {
            out.set(r.id, r.emoji);
            out.set(r.name.toLowerCase(), r.emoji);
        }
    return out;
}
