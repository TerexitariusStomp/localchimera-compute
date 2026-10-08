// tests/browser/offers-test.mjs — the offer field (browser/app/offers.js)
//
// The rim and the map show ONE set, and this module is why: both ask the same
// two questions of every offer — does it fall under the classification being
// looked at, and does it fall inside the turn currently on the dial. If those
// two answers ever diverge from what drawEvents clips the rim to, the two
// surfaces disagree and nothing says so; you select something on the rim and
// fly to an empty spot on the map.
//
// So what is pinned here is exactly the claims the module's own prose makes:
//
//   · AT-OR-UNDER is tree-based over flat term-ids, with a slash-path fallback
//     for legacy ids — and the unlensed "map" tab short-circuits to everything.
//   · A multi-valued tag shows under EITHER branch: the raw tag matches a
//     legacy slash spine, its flat segments match an aggregated one. One offer
//     set, correct against either spine source — the claim that the two spellings
//     coexist rather than one winning.
//   · THE TURN WINDOW is not "today": a daily routine repeats on each day the
//     window spans, which is what makes a week-scale dial show the 08:00 stand-up
//     rather than one instance of it.
//
// All of it is pure, so node runs the real module rather than a restatement.
//
// Run: node tests/browser/offers-test.mjs

// offers.js reaches core.js (for PLACES) and calendars.js, both of which touch
// the DOM and storage at import time. The stubs below are the minimum that lets
// the real module load; nothing under test reads any of them except S and the
// event arrays, which the cases set directly.
import { installDomStub, harness } from "./dom-stub.mjs";
installDomStub();

const O = await import("../../browser/app/offers.js");
const { S } = await import("../../browser/app/state.js");

const { check, done } = harness();

// ── at-or-under: which lens an offer belongs to ────────────────────────────
{
  check("the unlensed map tab takes everything, whatever the tag",
        O.atOrUnder("anything/at/all", O.MAP_ALL_ID) === true);
  check("…even a tag that is empty", O.atOrUnder("", O.MAP_ALL_ID) === true);

  check("a term is at-or-under itself", O.atOrUnder("nourishment", "nourishment") === true);
  check("a legacy slash-path id is under its prefix",
        O.atOrUnder("nourishment/meals", "nourishment") === true);
  check("…but a prefix is NOT under its own child",
        O.atOrUnder("nourishment", "nourishment/meals") === false);
  check("a sibling is under neither",
        O.atOrUnder("rest/sleep", "nourishment") === false);
  // The near-miss the slash rule exists to exclude: a term whose NAME starts
  // with the lens is not inside it. "nourishmental" is not under "nourishment".
  check("a shared prefix without the slash is not containment",
        O.atOrUnder("nourishmentality", "nourishment") === false);
  check("nothing is under a missing lens", O.atOrUnder("meals", "") === false);

  // the FLAT spine: ids carry no path, so containment lives in S.desc — the
  // descendant index main.js builds beside the tree
  S.desc = new Map([["Food", new Set(["Food", "Grain", "Bread"])]]);
  check("a flat term-id is under its lens through the descendant index",
        O.atOrUnder("Grain", "Food") === true);
  check("…and a term outside that subtree is not",
        O.atOrUnder("Timber", "Food") === false);
  S.desc = null;
  check("with no index at all, the slash rule still answers",
        O.atOrUnder("Food/Grain", "Food") === true);
}

// ── multi-valued tags: one offer, either spine ─────────────────────────────
{
  const cats = O.offerCats({ cats: ["Food/Grain", "local"] });
  check("the RAW tag survives, for a legacy slash spine",
        cats.includes("Food/Grain"));
  check("…and so do its flat segments, for an aggregated spine",
        cats.includes("Food") && cats.includes("Grain"));
  check("a second tag rides alongside the first", cats.includes("local"));

  // the property that matters: a loaf tagged both ways shows under EITHER
  // branch, and it is the same object either time
  const loaf = { cats: ["Food/Grain", "local"] };
  S.desc = new Map([["Food", new Set(["Food", "Grain"])]]);
  check("a multi-tagged offer is under its aggregated branch",
        O.offerCats(loaf).some(c => O.atOrUnder(c, "Food")));
  check("…and under its other tag too, not just the first",
        O.offerCats(loaf).some(c => O.atOrUnder(c, "local")));
  S.desc = null;

  check("with no cats, the single primary `serves` stands in",
        O.offerCats({ serves: "rest/sleep" }).join() === "rest/sleep,rest,sleep");
  check("with neither, an offer belongs to no branch",
        O.offerCats({}).length === 0);
  // `cats` rides the seam as unknown; a string is not a list of tags
  check("a string in the cats slot is not iterated character by character",
        O.offerCats({ cats: "grain", serves: "food" }).includes("food"));
  check("an empty leading segment is dropped, not kept as a term",
        O.offerCats({ serves: "/meals" }).includes("") === false);
}

// ── the turn window: a routine repeats on every day it spans ───────────────
{
  // Put the dial at a known anchor: day 100, at day scale. turnAnchor reads
  // S.viewTurnOffset and S.nowAbs, so setting those fixes the window exactly.
  S.nowAbs = 100 * 24 + 6; S.viewTurnOffset = 0; S.turnH = 24;

  check("an offer inside today's hours is in the window",
        O.inTurnWindow({ t0: 8, t1: 9 }) === true);
  check("an offer at the very top of the turn is in",
        O.inTurnWindow({ t0: 0, t1: 1 }) === true);
  // Zero-length is the boundary the strict `e > s` decides: an instant is not
  // a span, and it does not show.
  check("a zero-length offer is not in the window",
        O.inTurnWindow({ t0: 8, t1: 8 }) === false);

  // THE CLAIM: widen the turn to a week and the 08:00 routine is in the window
  // because it recurs on each of the seven days, not because one instance of it
  // happens to land inside. That is what makes the week-scale map show it.
  S.turnH = 24 * 7;
  check("at week scale a daily routine is in the window",
        O.inTurnWindow({ t0: 8, t1: 9 }) === true);

  // …and an hour-scale turn shows only what actually overlaps that hour
  S.turnH = 1; S.nowAbs = 100 * 24 + 8.5;
  check("at hour scale an offer overlapping the hour is in",
        O.inTurnWindow({ t0: 8, t1: 9 }) === true);
  check("…and one two hours later is out",
        O.inTurnWindow({ t0: 10.5, t1: 11 }) === false);
  S.turnH = 24; S.nowAbs = 100 * 24 + 6;
}

done();
