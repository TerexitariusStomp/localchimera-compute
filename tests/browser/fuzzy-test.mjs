// tests/browser/fuzzy-test.mjs — one string-similarity primitive
// (browser/app/fuzzy.js, from ui/app/fuzzy.ts), reused by app/utter.ts for
// places, specs and scopes alike.
//
// Sørensen–Dice over bigrams, boosted when one string contains the other —
// tolerant of typos, transpositions and truncation ("mil" for "mill"), not
// phonetic ("flour"/"flower" is out of scope; that's the AI normalizer's job).
//
// Run: node tests/browser/fuzzy-test.mjs

const { similarity, bestMatch, bestMatchInText } = await import("../../browser/app/fuzzy.js");

import { harness } from './assert.mjs';
const { check, done } = harness();

console.log("\n── similarity ──");
{
  check("identical strings score 1", similarity("flour", "flour") === 1);
  check("case-insensitive", similarity("Flour", "flour") === 1);
  check("empty query scores 0", similarity("", "flour") === 0);
  check("a real typo scores high enough to pass the default threshold", similarity("flor", "flour") > 0.5, String(similarity("flor", "flour")));
  check("a truncation of a single word scores high (the containment boost)", similarity("mil", "mill") > 0.7, String(similarity("mil", "mill")));
  check("…but never as high as true identity", similarity("mil", "mill") < similarity("mill", "mill"));
  check("unrelated words score low", similarity("bicycle", "flour") < 0.3, String(similarity("bicycle", "flour")));
  check("a boosted score never exceeds 1", similarity("mill", "the old mill") <= 1);
  check("a 1-2 char fragment does not fuzzy-match a long candidate by coincidental containment",
        similarity("in", "captain's log") < 0.3, String(similarity("in", "captain's log")));
  check("…the same guard for a two-letter word", similarity("at", "the fat cat") < 0.3, String(similarity("at", "the fat cat")));
  check("…a real 3-char truncation still gets the boost (the guard's floor is 2 bigrams, not 3)",
        similarity("mil", "mill") > 0.7);
}

console.log("\n── bestMatch ──");
{
  const specs = [{ name: "flour", value: "spec-flour" }, { name: "bike repair", value: "spec-bike" },
                 { name: "firewood", value: "spec-wood" }];
  check("a typo resolves to the right spec", bestMatch("flor", specs)?.value === "spec-flour");
  check("an unrelated word resolves to nothing", bestMatch("submarine", specs) === undefined);
  check("below threshold is undefined even for the closest candidate",
        bestMatch("xyz", specs, 0.6) === undefined);
  check("the highest-scoring candidate wins, not the first",
        bestMatch("bike", [{ name: "bike repair", value: "a" }, { name: "bike", value: "b" }])?.value === "b");
}

console.log("\n── bestMatchInText — the sentence, not just the name ──");
{
  const places = [{ name: "the old mill", value: "p-mill" }, { name: "community garden", value: "p-garden" }];
  const hit = bestMatchInText("need bricks at the old mil friday", places);
  check("finds the place inside the sentence", hit?.value === "p-mill", JSON.stringify(hit));
  check("the span covers exactly the matched words, nothing more",
        hit && "the old mil".split(" ").length === (hit.span[1] - hit.span[0]),
        JSON.stringify(hit?.span));
  const words = "need bricks at the old mil friday".split(" ");
  const rest = [...words.slice(0, hit.span[0]), ...words.slice(hit.span[1])].join(" ");
  check("removing the span leaves the rest of the sentence intact",
        rest === "need bricks at friday", rest);
  const none = bestMatchInText("need bricks for the harvest", places);
  check("no place named in the sentence → no hit", none === undefined);
  const garden = bestMatchInText("meet at community gardens tomorrow", places);
  check("a pluralised/lengthened phrase still lines up (±1 word width)",
        garden?.value === "p-garden", JSON.stringify(garden));
}

done();
