// app/rest.ts — the time floor of the right to rest, as the browser reads it:
// SNIRT, socially necessary individual reproduction time — the sleep, meals
// and washing a body takes each day — and the disposable time it leaves.
// housing.ts states the CONDITIONS of rest; this states its TIME. Pure, so
// node runs it (tests/browser/rest-test.mjs).
//
// The numbers are the catalogue's, generated into rest-catalogue.ts
// (tools/rest-emit.scm); the person layer here is a PORT of knowledge/rest-
// catalogue.scm's — code in both places, a table in neither — pinned to its
// figures by tests/browser/rest-test.mjs and tests/planner/
// test-rest-catalogue.scm. The plan RESERVES this time and does not allocate it:
// the hours a person offers sit inside D = period − SNIRT
// (docs/planning/food/reproduction-of-labour-power.md §2b).
//
import { SLEEP_BANDS, PERSONAL_HOURS, REST_LABOUR_INCREMENT } from './rest-catalogue.js';
/** The hours of a clock span "HH:MM"→"HH:MM", wrapping midnight: what a person who states a sleep span states of their need. */
export function spanHours(from, to) {
    const min = (s) => { const [h, m] = s.split(":").map(Number); return h * 60 + m; };
    return (((min(to) - min(from)) % 1440) + 1440) % 1440 / 60;
}
export const AWAY_KINDS = [{ id: "sick", label: "ill" }, { id: "rest", label: "resting" }, { id: "leave", label: "away" }];
export const WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"];
const isClock = (s) => typeof s === "string" && /^([01]?\d|2[0-3]):[0-5]\d$/.test(s);
const isDay = (s) => /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/.test(s);
/** Whether A is a span the plan can read: two ISO dates, the first no later than the second, a known kind. */
export const isAway = (a) => isDay(a.from) && isDay(a.to) && a.from <= a.to && AWAY_KINDS.some(k => k.id === a.kind);
/** Whether S is a span the plan can read: two clock times, and — if stated — every day a known weekday. */
export const isSleepSpan = (s) => isClock(s.from) && isClock(s.to) && (!s.days || (s.days.length > 0 && s.days.every(d => WEEKDAYS.includes(d))));
/** The hours of a clock span "HH:MM"→"HH:MM", wrapping midnight — SPAN-HOURS' own use, spelled once. */
const spanLength = (s) => spanHours(s.from, s.to);
/** Every stated span's length, summed — a night-shift split and a biphasic nap both count, the way several sleep: tags stack for the plan. A per-day APPROXIMATION where sleep genuinely varies by day, since SNIRT (below) reads one constant a day. */
export const sleepSpansHours = (spans) => spans.length ? spans.reduce((sum, s) => sum + spanLength(s), 0) : undefined;
/** The tags a person's sleep spans and away days become: "sleep:23:00-07:00", "sleep:14:00-22:00:saturday,sunday", "away:2026-09-28..2026-09-30:sick". */
export function restTags(sleep = [], away = []) {
    const tags = [];
    for (const s of sleep)
        if (isSleepSpan(s))
            tags.push(`sleep:${s.from}-${s.to}${s.days?.length ? `:${s.days.join(",")}` : ""}`);
    for (const a of away)
        if (isAway(a))
            tags.push(`away:${a.from}..${a.to}:${a.kind}`);
    return tags;
}
/** Sleep a day: the age band plus an hour in pregnancy, or the person's own stated need, kept inside 4–14 h. */
export function sleepHours(c) {
    if (c.sleepHours != null)
        return Math.max(4, Math.min(14, c.sleepHours));
    const band = SLEEP_BANDS.find(b => c.age < b[0]) ?? SLEEP_BANDS[SLEEP_BANDS.length - 1];
    return band[1] + (c.pregnant ? 1 : 0);
}
/** SNIRT a day: the base, lifted by the scope's ratified standard (which may only raise), plus the labour increment. */
export function snirtHours(c) {
    const std = Math.max(1, c.restStandard ?? 1);
    return (sleepHours(c) + PERSONAL_HOURS) * std + REST_LABOUR_INCREMENT * (c.effort ?? 1) * (c.labour ?? 0);
}
/** The hours of a period a person can be planned on: everything but SNIRT. */
export const disposableHours = (c, days = 1) => Math.max(0, 24 * days - days * snirtHours(c));
/** The hours a person offers, kept inside their disposable time. */
export const reserveOffer = (offered, c, days = 1) => Math.min(offered, disposableHours(c, days));
