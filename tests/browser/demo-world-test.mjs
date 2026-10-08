// tests/browser/demo-world-test.mjs — the demo world holds together
// (browser/app/demo/world.js, from ui/app/demo/world.ts).
//
// Offline every face reads one world. What is pinned here is that the world's
// tables refer only to each other: every id a table names exists, a place sits in
// a place that exists and has a position, a venue is at a place, the store's
// stocks are at the world's places and conform to its goods, and the stocks of a
// good sum to the figure the good shows. A face that names a place, a good or a
// person the world does not hold fails here, in node, with no DOM.
//
// Run: node tests/browser/demo-world-test.mjs

const W = await import("../../browser/app/demo/world.js");
const { demoStore } = await import("../../browser/app/demo/store.js");

let pass = 0, fail = 0;
const check = (label, ok, extra = "") => {
  ok ? pass++ : fail++;
  console.log(`  ${ok ? "✓" : "✗"} ${label}${extra ? " — " + extra : ""}`);
};
const dup = xs => xs.filter((x, i) => xs.indexOf(x) !== i);

console.log("\n── people ──");
{
  const ids = W.PEOPLE.map(p => p.id);
  check("each person has one id, lowercase", dup(ids).length === 0 && ids.every(id => id === id.toLowerCase()), dup(ids).join());
  check("the world is seen through you", ids.includes(W.YOU) && W.personName(W.YOU) === "you");
  check("a person is shown by their name", W.personName("ana") === "Ana" && W.personName("nobody") === "nobody");
}

console.log("\n── places ──");
{
  const ids = W.WORLD_PLACES.map(p => p.id), names = W.WORLD_PLACES.map(p => p.name);
  const set = new Set(ids);
  check("each place has one id and one name", dup(ids).length === 0 && dup(names).length === 0, [...dup(ids), ...dup(names)].join());
  check("every id is a place id", ids.every(id => /^place:[a-z0-9-]+$/.test(id)), ids.filter(id => !/^place:[a-z0-9-]+$/.test(id)).join());
  check("a place sits in one that exists, or in none", W.WORLD_PLACES.every(p => p.containedIn === null || set.has(p.containedIn)));
  check("no place sits in itself, however far up", W.WORLD_PLACES.every(p => {
    const seen = new Set(); let at = p;
    while (at && at.containedIn) { if (seen.has(at.id)) return false; seen.add(at.id); at = W.placeOf(at.containedIn); }
    return true;
  }));
  check("every place has a position", W.WORLD_PLACES.every(p => Number.isFinite(p.dLat) && Number.isFinite(p.dLng)));
  check("the place a name looks up is that place", W.placeOf("place:pantry")?.name === "pantry" && W.placeOf("place:nowhere") === undefined);
}

console.log("\n── venues ──");
{
  check("every venue is at a place the world holds", W.VENUES.every(v => !!W.placeOf(v.place)), W.VENUES.filter(v => !W.placeOf(v.place)).map(v => v.place).join());
  check("a venue is on one of the four rails", W.VENUES.every(v => ["own", "claim", "common", "work"].includes(v.mode)));
  const by = W.venuesByLeaf();
  check("a need opens onto its venues, in order", by["nourishment/meals"].map(v => v.name).join() === "Bakery Vitosha,commons canteen,Sourdough Co-op,bakery shift", by["nourishment/meals"].map(v => v.name).join());
  check("a venue stands where its place stands", by["nourishment/meals"][1].dLat === W.placeOf("place:canteen").dLat && by["nourishment/meals"][1].place === "place:canteen");
  check("a shift is a venue of the place it happens at, under its own name", by["nourishment/meals"][3].mode === "work" && by["nourishment/meals"][3].place === "place:canteen" && by["nourishment/meals"][3].emoji !== W.placeOf("place:canteen").emoji);
  check("every venue row has a name, an emoji and its hours", Object.values(by).flat().every(v => v.name && v.emoji && v.when));
  check("every venue is listed under its need once", Object.values(by).flat().length === W.VENUES.length);
}

console.log("\n── goods ──");
{
  const ids = W.DEMO_SPECS.map(s => s.id);
  check("each good has one id", dup(ids).length === 0);
  check("every resource is of a good the world holds", W.DEMO_RESOURCES.every(r => ids.includes(r.spec)));
  check("what the ledger holds of a good is what is shared out and what is kept", W.DEMO_RESOURCES.every(r => r.onhand + (W.DEMO_KEPT_BY_SPEC[r.spec] ?? 0) === W.demoHeld(r.spec)) && W.demoHeld("spec-bread") > 0 && W.demoHeld("spec-none") === 0);
  check("what is kept is kept of a good the world holds", Object.keys(W.DEMO_KEPT_BY_SPEC).every(k => ids.includes(k)));
}

console.log("\n── the store reads the world ──");
{
  const d = demoStore(Date.UTC(2026, 9, 1, 12, 0, 0));
  const places = new Set(W.WORLD_PLACES.map(p => p.id)), goods = new Set(W.GOODS.map(s => s.id));
  const rows = d.inventory.resources;
  check("the store's places are the world's", d.places.length === W.WORLD_PLACES.length && d.places.every(p => places.has(p.id) && W.placeOf(p.id).name === p.name));
  check("every stock is at a place of the world", rows.every(r => places.has(r.location)), rows.filter(r => !places.has(r.location)).map(r => r.id).join());
  const stocked = W.DEMO_SPECS.filter(s => !s.external);
  check("every good held on a shelf has a stock", stocked.every(s => rows.some(r => r["conforms-to"] === s.id)));
  check("the stocks of a good sum to its figure, in its unit", stocked.every(s => {
    const of = rows.filter(r => r["conforms-to"] === s.id && r["custodian-name"] === "the commons");
    return of.reduce((a, r) => a + r.onhand, 0) === W.demoHeld(s.id) && of.every(r => r.unit === s.unit);
  }));
  check("a stock that conforms to a spec-* conforms to a good the world holds", rows.filter(r => String(r["conforms-to"]).startsWith("spec-")).every(r => goods.has(r["conforms-to"])));
  const people = new Set(W.PEOPLE.map(p => p.id));
  const named = [...["demo:greens", "demo:beans", "demo:loaves", "demo:bikes"].flatMap(id => d.counts(id).map(c => c.counter)), ...d.contests.flatMap(c => [c.worker, c.by])];
  check("who counted and who contests are people of the world", named.every(n => people.has(n)), [...new Set(named.filter(n => !people.has(n)))].join());
}

console.log("\n── what people ask for and offer ──");
{
  const ids = W.SLOTS.map(s => s.id), people = new Set(W.PEOPLE.map(p => p.id));
  check("each slot has one id", dup(ids).length === 0, dup(ids).join());
  check("every slot is a person's", W.SLOTS.every(s => people.has(s.person)), W.SLOTS.filter(s => !people.has(s.person)).map(s => s.id).join());
  check("a slot that stands at a place stands at one the world holds", W.SLOTS.every(s => !s.place || !!W.placeOf(s.place)));
  check("a need is matched to a means the world holds", W.SLOTS.every(s => !s.matched || W.slotOf(s.matched)?.kind === "means"));
  check("only a means is lent into the commons, and it stands at a place", W.SLOTS.every(s => !s.socialized || (s.kind === "means" && !!s.place)));
  const pool = W.scopePool();
  check("the scope's pool is every need and every means", pool.needs.length + pool.means.length === W.SLOTS.length);
  check("a need says who asks and a means who offers", pool.needs.every(r => r.who && !r.owner) && pool.means.every(r => r.owner && !r.who));
  check("yours are in the pool, as the share bar's own", pool.needs.filter(r => r.who === W.YOU).length === 3 && pool.means.filter(r => r.owner === W.YOU).length === 2 && pool.needs.filter(r => r.who === W.YOU).every(r => r.id.startsWith(`need:${W.YOU}:`)));
  const map = W.mapPool(d => `+${d}`);
  check("the map shows every need that stands at a place", map.needs.map(r => r.id).join() === W.SLOTS.filter(s => s.kind === "need" && s.place).map(s => s.id).join());
  check("…and only the means lent into the commons", map.means.every(r => W.slotOf(r.id).socialized) && map.means.length === W.SLOTS.filter(s => s.socialized).length);
  check("a slot on the map stands where its place stands", map.means.every(r => r.dLat === W.placeOf(W.slotOf(r.id).place).dLat));
  const bed = id => [pool.means.find(r => r.id === id), map.means.find(r => r.id === id)];
  check("Ana's guest room is one offer with one quantity, in the pool and on the map", bed("means:ana:spec-bed")[0].qty === bed("means:ana:spec-bed")[1].qty && bed("means:ana:spec-bed")[1].owner === "Ana" && bed("means:ana:spec-bed")[0].owner === "ana");
  check("your housing need is matched to it, by name on the map", map.needs.find(r => r.id === "need:you:spec-shelter").matched === "Ana's guest room" && map.needs.find(r => r.id === "need:you:spec-shelter").name === "your housing need");
  check("a count of days becomes the date it falls on", map.means.find(r => r.id === "means:ana:spec-bed").until === "+60");
}

console.log("\n── the day happens at the world's places ──");
{
  const D = await import("../../browser/app/demo.js");
  const byName = new Map(W.WORLD_PLACES.map(p => [p.name, p]));
  const events = [...D.DEMO_DAY.evs, ...D.DEMO_DAY.proposals, ...D.DEMO_DAY.eligible, ...D.DEMO_LIVED];
  check("every event of the demo day and its lived record is at a place of the world", events.every(e => byName.has(e.place)), [...new Set(events.filter(e => !byName.has(e.place)).map(e => e.place))].join());
  check("…standing where that place stands", events.every(e => { const p = byName.get(e.place); return p && e.at.dLat === p.dLat && e.at.dLng === p.dLng; }));
  check("the bed the plan proposes is at Ana's place, where her guest room is offered",
        D.DEMO_DAY.proposals.find(e => /Ana's guest room/.test(e.label)).place === W.placeOf(W.slotOf("means:ana:spec-bed").place).name);
  check("the bakery shift is at the bakery the store holds loaves at", D.DEMO_DAY.proposals.find(e => /bakery shift/.test(e.label)).place === W.placeOf("place:bakery").name);
}

console.log("\n── the same people everywhere ──");
{
  const names = new Set(W.PEOPLE.map(p => p.name)), ids = new Set(W.PEOPLE.map(p => p.id));
  const D = await import("../../browser/app/demo.js");
  const { DEMO_CONTACTS } = await import("../../browser/app/demo/contacts.js");
  const { DEMO_FORUM } = await import("../../browser/app/demo/forum.js");
  const { POPULATION } = await import("../../browser/app/nutrition.js");
  const people = DEMO_CONTACTS.filter(c => c.rel !== "commons");
  check("every person in the contact book is a person of the world", people.every(c => names.has(c.alias)), people.filter(c => !names.has(c.alias)).map(c => c.alias).join());
  const groups = DEMO_CONTACTS.filter(c => c.rel === "commons").map(c => c.alias);
  check("a group in the contact book that meets at a place is that place of the world", W.WORLD_PLACES.some(p => p.name === "neighbourhood assembly") && groups.includes("neighbourhood assembly"));
  const worked = [...new Set(D.DEMO_LIVED.map(e => e.from))];
  check("whoever worked the lived record is a person of the world", worked.every(n => names.has(n)), worked.filter(n => !names.has(n)).join());
  const asks = [...new Set([...D.DEMO_DAY.proposals, ...D.DEMO_DAY.eligible].map(e => e.from))].filter(n => !["the commons", "the plan", "open slot"].includes(n));
  check("whoever proposes a part of the day is a person of the world", asks.every(n => names.has(n)), asks.filter(n => !names.has(n)).join());
  const authors = [...new Set(JSON.stringify(DEMO_FORUM).match(/"author":"[^"]+"/g).map(a => a.slice(10, -1)))];
  check("whoever speaks in the forum is a person of the world", authors.every(n => names.has(n)), authors.filter(n => !names.has(n)).join());
  check("the cohort whose intake is weighed are people of the world, by id", POPULATION.every(p => ids.has(p.id) && W.personName(p.id) === p.name), POPULATION.filter(p => !ids.has(p.id) || W.personName(p.id) !== p.name).map(p => p.id).join());
  const subjects = JSON.stringify(DEMO_FORUM).match(/"subject":"slot:[^"]+"/g).map(s => s.slice(16, -1));
  check("a slot the forum weighs is a slot of the world", subjects.every(id => !!W.slotOf(id)), subjects.filter(id => !W.slotOf(id)).join());
}

console.log("\n── where you stand, and where what waits for you waits ──");
{
  const { DEMO_WHERE } = await import("../../browser/app/demo/profile.js");
  const names = new Set(W.WORLD_PLACES.map(p => p.name));
  const stands = [DEMO_WHERE.place, ...DEMO_WHERE.ahead.map(a => a.place)];
  check("where you stand and will stand are places of the world", stands.every(n => names.has(n)), stands.filter(n => !names.has(n)).join());
  const { readFileSync } = await import("node:fs");
  const shop = readFileSync(new URL("../../ui/app/tabs/shop.ts", import.meta.url), "utf8");
  const waits = [...shop.matchAll(/id: "claim\|[^"]+",[^\n]*place: "([^"]+)"/g)].map(m => m[1]);
  check("what waits for you on the Resources face waits at a place of the world", waits.length > 0 && waits.every(n => names.has(n)), waits.filter(n => !names.has(n)).join());
}

console.log("\n── the stocks held at a place ──");
{
  const H = await import("../../browser/app/held.js");
  const { stocksOf, placesOf } = await import("../../browser/app/stock.js");
  const d = demoStore(Date.UTC(2026, 9, 1, 12, 0, 0));
  const stocks = stocksOf(d.inventory.resources), places = placesOf(d.places);
  const at = id => H.heldAt(id, stocks, places).map(h => h.id);
  check("a place lists what is held at it", at("place:canteen").includes("demo:greens") && !at("place:canteen").includes("demo:loaves"));
  check("…and what is in a container there", at("place:pantry").includes("demo:shelf") && at("place:pantry").includes("demo:beans"));
  check("a place lists what is held at the places inside it", ["demo:greens", "demo:beans", "demo:bikes", "demo:fabric"].every(id => at("place:commons").includes(id)));
  check("a place that holds nothing lists nothing", at("place:yoga-hall").length === 0);
  check("every place the commons holds stock at is a place a venue stands at, or inside the commons",
        [...new Set(d.inventory.resources.filter(r => r["custodian-name"] === "the commons").map(r => r.location))].every(id => W.VENUES.some(v => v.place === id) || W.placeOf(id)?.containedIn === "place:commons"),
        [...new Set(d.inventory.resources.filter(r => r["custodian-name"] === "the commons").map(r => r.location))].filter(id => !(W.VENUES.some(v => v.place === id) || W.placeOf(id)?.containedIn === "place:commons")).join());
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
