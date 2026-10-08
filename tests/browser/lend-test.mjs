// tests/browser/lend-test.mjs — the lend, as far as it is words and a door
// (browser/app/lend-core.js, from ui/app/lend-core.ts).
//
// What is pinned: an audience writes the rule the gate reads and reads it back;
// who in a contact book it admits; a lend reaches the socialize door with the
// resource named (so the title gate engages), the span's end as the grant's
// valid-until and the steward rule as its `eligible`; kept-back names become
// attestations the owner holds; a refusal is said in the gateway's words; and a
// lend with no door or no commune goes nowhere.
//
// Run: node tests/browser/lend-test.mjs

const L = await import("../../browser/app/lend-core.js");

let pass = 0, fail = 0;
const check = (label, ok, extra = "") => {
  ok ? pass++ : fail++;
  console.log(`  ${ok ? "✓" : "✗"} ${label}${extra ? " — " + extra : ""}`);
};
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

console.log("\n── an audience and its rule ──");
{
  const anyone = L.audienceOf(undefined);
  check("no rule is anyone", L.openTo(anyone) && L.ruleOf(anyone) === undefined);
  check("true is anyone too", L.openTo(L.audienceOf(true)));
  const a = L.audienceOf(["in-group", "friend", "family"]);
  check("a kinds rule reads as its kinds", a.kinds.has("friend") && a.kinds.has("family") && !a.vouched);
  check("…and writes back the same rule", same(L.ruleOf(a), ["in-group", "friend", "family"]));
  check("one pick is one clause", same(L.ruleOf(L.audienceOf(["vouched"])), ["vouched"]));
  const mixed = ["or", ["vouched"], ["in-group", "friend"], ["aid", "EANA"]];
  check("several picks are any-of", same(L.ruleOf(L.audienceOf(mixed)), mixed));
  check("nobody is no audience", L.audienceOf(false) === null);
  check("a rule the picker does not write is no audience", L.audienceOf(["not-aid", "EANA"]) === null
        && L.audienceOf(["or", ["vouched"], ["within-km", 5]]) === null);
}

console.log("\n── who it admits ──");
{
  const book = [
    { alias: "Ana", aid: "EANA", rel: "friend", online: true, mine: "friend" },
    { alias: "Ben", aid: "EBEN", rel: "friend", online: true },
    { alias: "Cy",  aid: "ECY",  rel: "",       online: true, mine: "colleague" },
    { alias: "Dee", aid: "EDEE", rel: "family", online: true },
  ];
  const names = rule => L.admitted(L.audienceOf(rule), book).map(c => c.alias).join();
  check("the vouched are those you signed for", names(["vouched"]) === "Ana,Cy", names(["vouched"]));
  check("a kind is the tag you gave", names(["in-group", "friend"]) === "Ana,Ben");
  check("…or the kind your vouch states", names(["in-group", "colleague"]) === "Cy");
  check("an untagged contact is a contact", names(["in-group", "contact"]) === "Cy");
  check("a person by name", names(["aid", "EDEE"]) === "Dee");
  check("any of the picks admits", names(["or", ["in-group", "family"], ["aid", "EBEN"]]) === "Ben,Dee");
}

const calls = [];
const door = reply => (...args) => { calls.push(args); return Promise.resolve(reply); };
const terms = over => ({ kind: "use", qty: 1, until: "2099-01-31", movable: false, returnTo: "", conditionFloor: "", retain: "", eligible: "", ...over });
const lamp = { spec: "lamp", name: "desk lamp", unit: "each", qty: 2, resource: "means:EAID:lamp" };

console.log("\n── a lend ──");
{
  const rule = JSON.stringify({ "filter-rule": ["vouched"] });
  const r = await L.lendThrough({ socialize: door("ok"), commune: "ECOMMUNE", communeName: "Riverside" }, lamp, terms({ eligible: rule }));
  check("it goes through", r.ok === true);
  const [commune, spec, qty, until, movable, returnTo, condition, resource, kind, ref, eligible] = calls[0];
  check("to the commune", commune === "ECOMMUNE");
  check("naming the resource, so the title gate engages", resource === "means:EAID:lamp");
  check("the spec and the quantity", spec === "lamp" && qty === 1);
  check("the grant ends when the span does", until === "2099-01-31");
  check("it is not movable and carries no condition", movable === false && returnTo === "" && condition === "");
  check("the verb and the steward rule ride", kind === "use" && ref === undefined && eligible === rule);
  check("it says whose it is to draw on, and that the person still owns it",
        /Riverside's to draw on until/.test(r.says) && /you still own it/.test(r.says), r.says);
}
{
  calls.length = 0;
  const r = await L.lendThrough({ socialize: door("ok"), commune: "ECOMMUNE", communeName: "the whole commons" }, lamp, terms({ until: "" }));
  check("an open-ended lend states no end", calls[0][3] === "" && /until you recall it/.test(r.says), r.says);
  check("a name ending in s takes a bare apostrophe", /the whole commons' to draw on/.test(r.says));
}

console.log("\n── what is kept back ──");
{
  calls.length = 0;
  const r = await L.lendThrough({ socialize: door("ok"), commune: "ECOMMUNE", communeName: "Riverside", me: "EME" },
                                { spec: "flat", name: "the flat", qty: 1 }, terms({ retain: "radio, locked study" }));
  check("the grant, then one attestation a kept-back name", r.ok && calls.length === 3);
  check("each held by the owner", calls[1][0] === "EME" && calls[2][0] === "EME");
  check("…over the thing it names", calls[1][1] !== calls[2][1] && calls[1][2] === 1);
  calls.length = 0;
  const anon = await L.lendThrough({ socialize: door("ok"), commune: "ECOMMUNE", communeName: "Riverside" },
                                   { spec: "flat", name: "the flat", qty: 1 }, terms({ retain: "radio" }));
  check("with no identity the grant stands and the kept-back wait", anon.ok && calls.length === 1 && /wait for a signed-in identity/.test(anon.says));
}

console.log("\n── what does not go through ──");
{
  const refused = await L.lendThrough({ socialize: door("err:only the owner may lend it"), commune: "ECOMMUNE", communeName: "Riverside" }, lamp, terms());
  check("a refusal is said in the gateway's words", refused.ok === false && refused.says === "only the owner may lend it");
  const silent = await L.lendThrough({ socialize: () => Promise.reject(new Error("down")), commune: "ECOMMUNE", communeName: "Riverside" }, lamp, terms());
  check("a gateway that does not answer is said so", silent.ok === false && /did not answer/.test(silent.says));
  calls.length = 0;
  const noDoor = await L.lendThrough({ commune: "ECOMMUNE", communeName: "Riverside" }, lamp, terms());
  const noCommune = await L.lendThrough({ socialize: door("ok"), commune: null, communeName: "the whole commons" }, lamp, terms());
  check("no door, or no commune, goes nowhere", !noDoor.ok && !noCommune.ok && calls.length === 0);
}

console.log("\n── a recall ──");
{
  const g = { id: "ESAID", spec: "lamp" };
  const seen = [];
  const ok = await L.recallThrough(said => { seen.push(said); return Promise.resolve("ok"); }, g);
  check("it names the grant's SAID", ok.ok && seen[0] === "ESAID");
  check("with no door it says to sign in", (await L.recallThrough(undefined, g)).ok === false);
  check("a refusal is said", (await L.recallThrough(() => Promise.resolve("err:not yours"), g)).says === "not yours");
}

console.log("\n── how a grant reads ──");
{
  check("a thing counted in itself reads by its name", L.grantAmount({ id: "x", qty: 1 }, { name: "bicycle", unit: "each" }) === "1 bicycle");
  check("a measured thing reads in its unit", L.grantAmount({ id: "x", qty: 4 }, { name: "bike repair", unit: "hours" }) === "4 hours");
  check("no quantity is all of it", L.grantAmount({ id: "x", qty: "" }, { name: "oven" }) === "all of it");
}

console.log(`\n=== ${pass} passed, ${fail} failed ===`);
process.exit(fail ? 1 : 0);
