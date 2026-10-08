// tests/browser/declarations-test.mjs — the scope's declarations (browser/app/slots/declarations.js)
//
// The three declaration cards (span on the offer card, hosting on the Our
// Offers rail, regime on the recipe card) share this module, and what it
// claims is pinned here against the real emitted module:
//
//   · a regime reads "statistics" under thin tails AND a stable process, and
//     probability-free under every other pair — the rule recipe-standing.md
//     states, held as a function of the two words alone
//   · a hosting ceiling is a positive finite number of unit-hours a day; the
//     card refuses zero, a negative, a word and infinity before the door does
//   · a door's reply reads "" for "ok" and the refusal's own text otherwise,
//     the "err:" prefix dropped, and a missing reply is still a refusal
//   · the sentences the cards read back name the scope, the spec and the
//     amount, with the unit's plural following the count
//
// Run: node tests/browser/declarations-test.mjs

import { harness } from "./dom-stub.mjs";

const D = await import("../../browser/app/slots/declarations.js");
const { check, done } = harness();

// ── the regime's reading ───────────────────────────────────────────────────
{
  check("thin tails and a stable process license statistics",
        D.regimeReads("thin", "stable") === "statistics");
  const pairs = [];
  for (const t of D.REGIME_TAILS) for (const p of D.REGIME_PROCESS)
    if (!(t === "thin" && p === "stable")) pairs.push([t, p]);
  check("every other pair of the offered words reads probability-free",
        pairs.length === 8 && pairs.every(([t, p]) => D.regimeReads(t, p) === "probability-free"));
  check("a word off the list reads probability-free too",
        D.regimeReads("thin", "stableish") === "probability-free");
}

// ── the ceiling ────────────────────────────────────────────────────────────
{
  check("a typed number parses, with surrounding space", D.ceilingOf(" 12.5 ") === 12.5);
  check("a number passes through", D.ceilingOf(3) === 3);
  check("zero is no ceiling", D.ceilingOf("0") === null);
  check("a negative is no ceiling", D.ceilingOf(-4) === null);
  check("a word is no ceiling", D.ceilingOf("many") === null);
  check("infinity is no ceiling", D.ceilingOf("Infinity") === null);
}

// ── the reply ──────────────────────────────────────────────────────────────
{
  check('"ok" reads as nothing to say', D.declarationReply("ok") === "");
  check("a refusal reads without its wire prefix",
        D.declarationReply("err:a scope's declaration is spoken by a governor")
          === "a scope's declaration is spoken by a governor");
  check("a missing reply is still a refusal", D.declarationReply(undefined) === "refused");
  check("an empty error is still a refusal", D.declarationReply("err:") === "refused");
}

// ── the word read back: one reading for the three cards ────────────────────
{
  const ok = await D.spoken(Promise.resolve("ok"), "the oven pool stands at bakery");
  check("an ok reply reads as the act that now stands", ok.ok && ok.text === "declared — the oven pool stands at bakery");
  const no = await D.spoken(Promise.resolve("err:a scope's declaration is spoken by a governor"), "x");
  check("a refusal reads as the refusal, and only that", !no.ok && no.text === "a scope's declaration is spoken by a governor");
  const thrown = await D.spoken(Promise.reject(new Error("err:gateway away")), "x");
  check("a rejected door reads as a refusal too, its message kept", !thrown.ok && thrown.text === "gateway away");
}

// ── the sentences ──────────────────────────────────────────────────────────
{
  check("hosting names scope, spec and ceiling",
        D.hostingSentence("Kreuzberg", "kitchen-hours", 6) === "Kreuzberg hosts pools of kitchen-hours up to 6 unit-hours a day");
  check("one unit-hour is singular",
        D.hostingSentence("Kreuzberg", "oven", 1).endsWith("up to 1 unit-hour a day"));
  check("a span names the pool and the place",
        D.spanSentence("oven", "bakery") === "the oven pool stands at bakery");
  check("a regime sentence carries its reading",
        D.regimeSentence("bread", "fat", "stable").endsWith("reads probability-free"));
}

done();
