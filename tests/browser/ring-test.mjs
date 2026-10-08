// tests/browser/ring-test.mjs — the hours a ring is drawn in, and the interval
// algebra net availability rests on (browser/app/ring.js)
//
// What the planner is told is NET availability: your windows MINUS the time
// taken by committed recurring events. Your band practice carves a hole in
// Tuesday evening, and the hole has to be exact — an offer of hours you are not
// free is a commitment the solver will place work into.
//
// av_merge and av_subtract are that arithmetic, and they are pure, so node runs
// the real ones. The end-to-end suite (test-availability-ux) proves the wire
// SHAPE; what it cannot show is the case that produces a shape it never sees —
// a busy span strictly inside an available one, which does not shrink a window
// but SPLITS it into two. Get that wrong and the hole silently swallows the
// whole afternoon, or vanishes.
//
// Run: node tests/browser/ring-test.mjs

import { installDomStub, harness } from "./dom-stub.mjs";
installDomStub();

const R = await import("../../browser/app/ring.js");

const { check, done } = harness();
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// ── merging windows ────────────────────────────────────────────────────────
{
  check("disjoint windows stay apart",
        eq(R.av_merge([[9, 11], [14, 16]]), [[9, 11], [14, 16]]));
  check("overlapping windows become one",
        eq(R.av_merge([[9, 12], [11, 14]]), [[9, 14]]));
  // Touching is merging: 09–11 and 11–13 is one stretch of being free, not two
  // with an instant between them that nothing could be scheduled in.
  check("windows that merely touch are one window",
        eq(R.av_merge([[9, 11], [11, 13]]), [[9, 13]]));
  check("a window swallowed whole by another disappears into it",
        eq(R.av_merge([[9, 17], [12, 13]]), [[9, 17]]));
  check("order in does not matter — it sorts first",
        eq(R.av_merge([[14, 16], [9, 11]]), [[9, 11], [14, 16]]));
  check("three overlapping windows collapse to one",
        eq(R.av_merge([[9, 11], [10, 13], [12, 15]]), [[9, 15]]));
  check("nothing merges to nothing", eq(R.av_merge([]), []));
  // it must not mutate what it was handed — both rings' items are live objects
  const src = [[9, 12], [11, 14]];
  R.av_merge(src);
  check("the input is left alone", eq(src, [[9, 12], [11, 14]]));
}

// ── carving out busy time ──────────────────────────────────────────────────
{
  check("busy before the window takes nothing",
        eq(R.av_subtract([[9, 17]], [[7, 8]]), [[9, 17]]));
  check("busy after the window takes nothing",
        eq(R.av_subtract([[9, 17]], [[18, 19]]), [[9, 17]]));
  check("busy meeting the edge exactly takes nothing",
        eq(R.av_subtract([[9, 17]], [[17, 19]]), [[9, 17]]));

  check("busy over the front trims the start",
        eq(R.av_subtract([[9, 17]], [[8, 11]]), [[11, 17]]));
  check("busy over the back trims the end",
        eq(R.av_subtract([[9, 17]], [[15, 19]]), [[9, 15]]));

  // THE CASE THE SHAPE TESTS CANNOT SEE: band practice at 13–14 inside a 09–17
  // window does not shorten the day, it makes two days.
  check("busy strictly inside SPLITS the window in two",
        eq(R.av_subtract([[9, 17]], [[13, 14]]), [[9, 13], [14, 17]]));
  check("two busy spans inside make three windows",
        eq(R.av_subtract([[9, 17]], [[11, 12], [14, 15]]), [[9, 11], [12, 14], [15, 17]]));

  check("busy covering the whole window leaves nothing",
        eq(R.av_subtract([[9, 17]], [[8, 18]]), []));
  check("busy covering it exactly leaves nothing",
        eq(R.av_subtract([[9, 17]], [[9, 17]]), []));

  check("each window is carved independently",
        eq(R.av_subtract([[9, 12], [14, 17]], [[10, 11], [15, 16]]),
           [[9, 10], [11, 12], [14, 15], [16, 17]]));

  // A sliver below a millisecond is float residue from the snapping, not an
  // offer of time. Offering it would put a commitment in a gap of no duration.
  check("a sub-millisecond sliver is dropped, not offered",
        eq(R.av_subtract([[9, 17]], [[9, 16.9999999]]), []));
  check("…but a real quarter-hour survives",
        eq(R.av_subtract([[9, 17]], [[9, 16.75]]), [[16.75, 17]]));

  const avail = [[9, 17]];
  R.av_subtract(avail, [[13, 14]]);
  check("the available list is left alone", eq(avail, [[9, 17]]));
}

// ── the hours themselves ───────────────────────────────────────────────────
{
  check("an hour reads as a clock face", R.av_hhmm(13.5) === "13:30");
  check("…zero-padded on both halves", R.av_hhmm(9.25) === "09:15");
  check("midnight is 00:00", R.av_hhmm(0) === "00:00");
  // 24:00 would be tomorrow's 00:00, and the wire says the hour of the turn
  check("the end of the turn wraps to 00:00, not 24:00", R.av_hhmm(24) === "00:00");

  check("snapping lands on the quarter hour", R.av_snap(13.6) === 13.5);
  check("…rounding to the nearest, not down", R.av_snap(13.7) === 13.75);
  check("snapping never leaves the turn", R.av_snap(-3) === 0 && R.av_snap(99) === 24);

  // the angular reading: noon is the bottom of the dial, midnight the top
  check("the top of the dial is hour 0", Math.abs(R.av_hourAt(0, -1) - 0) < 1e-9);
  check("a quarter turn clockwise is 06:00", Math.abs(R.av_hourAt(1, 0) - 6) < 1e-9);
  check("the bottom is noon", Math.abs(R.av_hourAt(0, 1) - 12) < 1e-9);
  check("three quarters round is 18:00", Math.abs(R.av_hourAt(-1, 0) - 18) < 1e-9);
}

// ── unifying windows, per weekday ──────────────────────────────────────────
// The grid and the dial both write through the ring's save, and save settles
// the items first: two windows saying "free" over the same hour of the same
// day are ONE window. Recurrence makes this per-day arithmetic — a window that
// also runs on days the other does not keeps those days as its own.
{
  const w = (id, t0, t1, days) => ({ id, t0, t1, days });
  const byId = (arr) => arr.slice().sort((a, b) => a.id < b.id ? -1 : 1);

  let arr = [w("a", 3.5, 7.5, ["sunday"]), w("b", 5.5, 9.25, ["sunday"])];
  R.av_unify(arr);
  check("overlapping same-day windows become one",
        eq(arr, [w("a", 3.5, 9.25, ["sunday"])]));

  arr = [w("a", 9, 11, ["monday"]), w("b", 11, 13, ["monday"])];
  R.av_unify(arr);
  check("touching windows are one window", eq(arr, [w("a", 9, 13, ["monday"])]));

  arr = [w("a", 9, 11, ["monday"]), w("b", 10, 13, ["tuesday"])];
  R.av_unify(arr);
  check("overlap in hours on different days is no overlap", arr.length === 2);

  arr = [w("a", 3.5, 7.5, ["sunday", "monday"]), w("b", 5.5, 9.25, ["sunday"])];
  R.av_unify(arr);
  check("the shared day widens; the other day keeps its own window",
        eq(byId(arr), [w("a", 3.5, 9.25, ["sunday"]), w("a_1", 3.5, 7.5, ["monday"])]));

  arr = [w("a", 9, 10, ["monday"]), w("b", 10, 11, ["monday"]), w("c", 11, 12, ["monday"])];
  R.av_unify(arr);
  check("a chain of touching windows collapses to one",
        eq(arr, [w("a", 9, 12, ["monday"])]));

  arr = [w("a", 3.5, 7.5, ["sunday"]), w("b", 5.5, 9.25, ["sunday"])];
  const kept = R.av_unify(arr, "b");
  check("the selected window survives its own merge, under its id",
        kept === "b" && arr.length === 1 && arr[0].id === "b");

  arr = [w("a", 9, 11, undefined), w("b", 10, 12, ["monday"])];
  R.av_unify(arr);
  check("absent days means every day, and the merge splits accordingly",
        arr.length === 2 && arr.some(x => eq(x.days, ["monday"]) && x.t0 === 9 && x.t1 === 12)
        && arr.some(x => x.days.length === 6 && x.t0 === 9 && x.t1 === 11));
}

// ── the days rule and the label, stated once for both pickers ─────────────
{
  const it = { id: 'x', t0: 9, t1: 10, days: ['monday'] };
  R.av_setDays(it, ['friday', 'monday'], 'monday');
  check("days are kept in week order", eq(it.days, ['monday', 'friday']));
  R.av_setDays(it, [], 'tuesday');
  check("no days falls back to the day asked from — a window with no day is not a window",
        eq(it.days, ['tuesday']));
  check("every day reads as such", R.av_daysLabel(['monday','tuesday','wednesday','thursday','friday','saturday','sunday']) === "every day");
  check("the working week reads as Mon–Fri", R.av_daysLabel(['monday','tuesday','wednesday','thursday','friday']) === "Mon–Fri");
  check("anything else names its days", R.av_daysLabel(['sunday', 'wednesday']) === "Wed Sun");
}

done();
