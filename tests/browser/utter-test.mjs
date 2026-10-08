// tests/browser/utter-test.mjs — one sentence → [locus-delta] [act], ranked
// (browser/app/utter.js, from ui/app/utter.ts)
//
// The floor is deterministic and pure: faces, places, specs, units and the
// clock all arrive in the context, so node reads the same sentences the page
// does. What this holds:
//
//   LOCUS ALONE    "garden friday 2pm" → go, nothing to write
//   ACT HERE       "need flour" → a need, the locus left to the reader's here
//   BOTH           "offer bike at the park saturday" → an offer AND a locus
//   HOLES          an unsaid coordinate is absent, never defaulted by the parser
//   RESIDUAL       the words no recogniser claims become the act's name
//   BANGS          "!map" opens a face; "!ddg …" is the ONLY way to the web
//   RANK           the explicit reading first; the lit rail's act as the fallback
//
// Run: node tests/browser/utter-test.mjs

const { parse, FACE_WORDS } = await import("../../browser/app/utter.js");

import { harness } from './assert.mjs';
const { check, done } = harness();
const ctx = {
  faces: FACE_WORDS,
  places: [{ id: "p-garden", name: "community garden", lat: 1, lng: 2 },
           { id: "p-park", name: "park pavilion" }, { id: "p-city", name: "city garden" },
           { id: "p-mill", name: "the old mill" }],
  specs: new Map([["spec-flour", "flour"], ["spec-bike", "bike repair"]]),
  units: [{ id: "each", label: "each" }, { id: "kg", label: "kilograms" }, { id: "hours", label: "hours" },
          { id: "hours/week", label: "hours a week" }, { id: "L", label: "liters" }],
  rail: "need",
  now: new Date(2026, 7, 20, 10, 0),      // Thursday 2026-08-20, 10:00 local
  scopes: [{ id: "s-berlin", name: "Berlin" }, { id: "s-cascadia", name: "Cascadia" }],
};
const top = (t, c = ctx) => parse(t, c)[0];
const verbs = (t, c = ctx) => parse(t, c).map(r => r.verb);

console.log("\n── a locus alone is a move, nothing written ──");
{
  const r = top("community garden friday 2pm");
  check("verb go", r.verb === "go", r.verb);
  check("place read (longest name wins)", r.locus.place?.id === "p-garden", r.locus.place?.id);
  check("friday → the next Friday", r.locus.instant?.iso === "2026-08-21T14:00", r.locus.instant?.iso);
  check("no act", !r.act);
  check("no residual", r.residual === "", JSON.stringify(r.residual));
  const g = top("garden");
  check("'garden' is ambiguous between two places: the longest match that fits, none → residual", g.verb === "need" && g.residual === "garden", g.label);
}

console.log("\n── an act here: the holes stay holes ──");
{
  const r = top("need flour");
  check("verb need", r.verb === "need", r.verb);
  check("the residual is the name", r.act?.name === "flour", r.act?.name);
  check("a known spec is recognised", r.act?.spec === "spec-flour", r.act?.spec);
  check("no locus coordinate invented", !r.locus.face && !r.locus.place && !r.locus.instant);
  const q = top("3 kg flour");
  check("quantity + unit read, unit by label→id", q.act?.qty === 3 && q.act?.unit === "kg", JSON.stringify(q.act));
  const b = top("3 loaves bread");
  check("a bare count keeps the number, the word stays in the name", b.act?.qty === 3 && b.act?.name === "loaves bread", JSON.stringify(b.act));
}

console.log("\n── both: an act with a locus folded in ──");
{
  const r = top("offer bike repair at the park pavilion saturday");
  check("verb offer", r.verb === "offer", r.verb);
  check("name is the residual, spec known", r.act?.name === "bike repair" && r.act?.spec === "spec-bike", JSON.stringify(r.act));
  check("place", r.locus.place?.id === "p-park", r.locus.place?.id);
  check("saturday, no time", r.locus.instant?.iso === "2026-08-22" && !r.locus.instant.hasTime, r.locus.instant?.iso);
  check("…and the bare locus is offered as a lesser reading", verbs("offer bike repair at the park pavilion saturday").includes("go"));
}

console.log("\n── faces and bangs ──");
{
  check("'!map' opens the map", top("!map").verb === "face" && top("!map").locus.face === "map", top("!map").label);
  check("'show me the calendar' opens cal", top("show me the calendar").locus.face === "cal", top("show me the calendar").label);
  check("'constraints' is the frag face by its nav word", top("constraints").locus.face === "frag");
  check("'wheel' is an alias", top("wheel").locus.face === "frag");
  const w = top("!ddg guix channels");
  check("!ddg is web, and ONLY web", w.verb === "web" && w.query === "guix channels" && parse("!ddg guix channels", ctx).length === 1, w.label);
  check("no bang → no web reading ever", !verbs("guix channels").includes("web"));
}

console.log("\n── times ──");
{
  check("'tomorrow' is a date", top("tomorrow").locus.instant?.iso === "2026-08-21");
  check("'tonight' carries 20:00", top("tonight").locus.instant?.iso === "2026-08-20T20:00");
  check("'at 9' is a time", top("at 9").locus.instant?.iso === "2026-08-20T09:00", top("at 9").locus.instant?.iso);
  check("'9' alone is a quantity, not a time", top("9 flour").act?.qty === 9 && !top("9 flour").locus.instant);
  check("14:30 reads", top("14:30").locus.instant?.iso === "2026-08-20T14:30");
  const both = top("offer 3 hours bike repair at the community garden saturday 2pm");
  check("a quantity before a time: both read, neither eats the other",
        both.act?.qty === 3 && both.act?.unit === "hours" && both.locus.instant?.iso === "2026-08-22T14:00" && both.act?.name === "bike repair",
        JSON.stringify({ act: both.act, at: both.locus.instant?.iso }));
  check("thursday today stays today", top("thursday").locus.instant?.iso === "2026-08-20");
}

console.log("\n── rank ──");
{
  const rs = parse("flour", { ...ctx, rail: "capacity" });
  check("a bare word follows the LIT rail", rs[0].verb === "offer", rs[0].verb);
  check("…the other rail and the log come after", rs.map(r => r.verb).join(",") === "offer,need,log", rs.map(r => r.verb).join(","));
  const e = parse("need flour", ctx);
  check("an explicit cue outranks the rail fallback", e[0].verb === "need" && e[0].score > (e[1]?.score ?? 0));
  check("empty text → no readings", parse("   ", ctx).length === 0);
  check("labels are one line each", parse("offer bike repair at the park pavilion saturday", ctx).every(r => !/\n/.test(r.label)));
}

console.log("\n── scope: the fourth locus coordinate ──");
{
  const r = top("what's happening in Cascadia");
  check("a scope name reads as a locus coordinate", r.locus.scope?.id === "s-cascadia", JSON.stringify(r.locus));
  // "needs" the NOUN and "need" the VERB share a spelling — once the cue
  // fires, the whole phrase is the act's name, exactly like a real face word
  // ("log", "shop") would be; this is intentional, not a bug
  const amb = top("our needs in Cascadia");
  check("…so an explicit cue word (even a noun/verb homograph) keeps the rest as ONE name, not fragmented", amb.act?.name === "our cascadia", amb.label);
  const g = top("the Berlin commune");
  check("a bare scope name (nothing else) reads as OPEN, not go", g.verb === "face" && g.locus.scope?.id === "s-berlin", g.label);
  const both = top("Cascadia friday");
  check("scope + time both read", both.locus.scope?.id === "s-cascadia" && !!both.locus.instant, JSON.stringify(both.locus));
}

console.log("\n── a face word inside a real act's name doesn't fragment it ──");
{
  const log = top("need a log for the fire");
  check("'log' (a face id AND a firewood item) stays in the act's name once 'need' cues",
        log.act?.name === "log fire" && !log.locus.face, JSON.stringify({ name: log.act?.name, face: log.locus.face }));
  const shop = top("offer to shop for groceries");
  check("'shop' stays part of the offer, not swallowed as the shop face",
        shop.act?.kind === "capacity" && !shop.locus.face, JSON.stringify(shop.locus));
  // a BARE "log" (nothing else) is itself ambiguous between the verb (log
  // WHAT?) and the face name — the "log" CUE wins here, same as any other verb
  // word would; "the log" or "captain's log" is how a citizen reaches the face
  // unambiguously, same as any other multi-word alias
  const named = top("the captain's log");
  check("'the captain's log' — the face's own multi-word alias — opens it, never fragmented",
        named.verb === "face" && named.locus.face === "log", named.label);
}

console.log("\n── fuzzy matching (app/fuzzy.ts) closes typos and mishearings ──");
{
  const typo = top("3 kg flor");
  check("a typo'd spec still resolves — 'flor' names the known spec 'flour'",
        typo.act?.spec === "spec-flour" && typo.act?.qty === 3, JSON.stringify(typo.act));
  const trunc = top("need bricks at the old mil friday");
  check("a truncated place name resolves, and the CANONICAL name is what's shown",
        trunc.locus.place?.id === "p-park" ? false : /the old mill/i.test(trunc.label), trunc.label);
  const noHelp = top("submarine periscope");
  check("an unrelated phrase resolves to nothing extra — no phantom place or spec",
        !noHelp.act?.spec && !noHelp.locus.place, JSON.stringify({ spec: noHelp.act?.spec, place: noHelp.locus.place }));
}

console.log("\n── fuzzy matching does not falsely attach a face to an unrelated sentence ──");
{
  const r = top("our needs in Cascadia");
  check("a short word inside the residual ('in') never coincidentally fuzzy-matches a face alias",
        !r.locus.face, JSON.stringify(r.locus));
}

console.log("\n── search: the corpus's own verb (docs/planning/faces/corpus-guile-native.md §4) ──");
{
  const r1 = top("what fixes nitrogen in soil");
  check("a bare question word reads as search", r1.verb === "search", r1.verb);
  check("the query keeps every OTHER real word — only the cue word itself ('what') is consumed, same as 'search for' would be",
        r1.query === "fixes nitrogen in soil", r1.query);
  const r2 = top("search for composting techniques");
  check("the explicit 'search' cue works too", r2.verb === "search" && r2.query === "composting techniques", r2.query);
  const r3 = top("how deep should a swale be dug");
  check("'how' triggers search the same as 'what'", r3.verb === "search", r3.label);
  // the priority rule: an economy cue always wins over a question word
  // sharing the same sentence — "how much flour do I need" is a NEED
  const r4 = top("how much flour do I need");
  check("an economy cue (need) outranks the question word 'how' in the same sentence",
        r4.verb === "need", r4.label);
  // a face/scope word inside a search question is NOT pulled into a locus —
  // every word stays in the query, unlike an act or a go reading
  const r0 = top("the corpus");
  check("'the corpus' opens the corpus face (its own face word, not the search verb)",
        r0.verb === "face" && r0.locus.face === "corpus", r0.label);
  const r5 = top("what does the shop face carry");
  check("a face-shaped word inside a genuine question stays IN the query, not stripped into a locus",
        r5.verb === "search" && /shop/.test(r5.query) && /face/.test(r5.query) && !r5.locus.face, JSON.stringify(r5));
}

console.log("\n── parse() never returns empty for a non-empty sentence (its own documented contract) ──");
{
  // a real bug lived here: "need"/"offer"/"go"/"search" typed BARE (the
  // cue word alone, nothing following) each consumed themselves via
  // readCue and left an empty residual — parse() returned [], the
  // preview showed nothing, yet share.ts's enter() still fell through to
  // submit(), silently declaring a slot literally NAMED "search" (or
  // "need", "go", …). Every one of these must produce at least one
  // reading, so what's shown matches what pressing ↵ actually does.
  for (const bare of ["need", "offer", "go", "search"]) {
    const rs = parse(bare, ctx);
    check(`a bare "${bare}" (the cue alone) is not empty`, rs.length > 0, JSON.stringify(rs));
    check(`…and falls back to the SAME multi-ranked-reading shape an ordinary unrecognised word gets`,
          rs[0].act?.name === bare, rs[0]?.label);
  }
  const w = parse("what", ctx);
  check(`a bare question word ("what") is not empty either`, w.length > 0, JSON.stringify(w));
  // a cue that ALSO resolves as a real face word ("log") is legitimately
  // exempt — opening the log face for a bare "log" is more useful than
  // declaring a slot named "log", and it's still non-empty either way
  check(`"log" alone reads as opening the log face — a real face word, not a bug`,
        top("log").verb === "face" && top("log").locus.face === "log");
  // a cue word that ALSO successfully finds a locus (a real place, scope,
  // face, or time) is UNCHANGED — the fallback only fires when NOTHING
  // else was found either
  const withLocus = parse("go to the garden", { ...ctx, places: [{ id: "p-garden", name: "garden" }] });
  check(`a cue with a locus it actually resolves keeps behaving as before (unaffected by the fallback)`,
        withLocus[0].verb === "go" && withLocus[0].locus.place?.id === "p-garden", withLocus[0]?.label);
}

done();
