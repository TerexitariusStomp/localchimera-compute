// tests/browser/store-view-test.mjs — the store as it is arranged for the face
// (browser/app/store-view.js, from ui/app/store-view.ts).
//
// What is pinned: stock lands under the places it is at, outermost place first,
// each level in name order; a place with nothing in it, or in what it holds,
// does not show; a container carries its contents a step in; stock that names
// no place gathers at the end; a filter keeps the stock that passes with the
// headings and containers above it; each row is badged, the ledger is said in a
// line, and the counts due are listed overdue first.
//
// Run: node tests/browser/store-view-test.mjs

const V = await import("../../browser/app/store-view.js");

import { harness } from './assert.mjs';
const { check, done } = harness();

const places = [
  { id: "site", name: "Mill House", containedIn: null },
  { id: "pantry", name: "Pantry", containedIn: "site" },
  { id: "shelf1", name: "Shelf 1", containedIn: "pantry" },
  { id: "cellar", name: "Cellar", containedIn: "site" },
  { id: "garage", name: "Garage", containedIn: "site" },          // holds nothing
  { id: "yard", name: "Yard", containedIn: null },
];
const stocks = [
  { id: "bin", name: "jar bin", location: "shelf1", rail: "common" },
  { id: "jam", name: "plum jam", location: "shelf1", containedIn: "bin", rail: "common", perishable: true },
  { id: "lids", name: "lids", location: "shelf1", containedIn: "bin", rail: "common" },
  { id: "rice", name: "rice", location: "pantry", rail: "own" },
  { id: "wine", name: "wine", location: "cellar", rail: "own" },
  { id: "tent", name: "tent", location: "nowhere-known", rail: "common" },
  { id: "pen", name: "pen", rail: "own" },
];
const schedule = new Map([
  ["rice", { id: "rice", name: "rice", lines: 1, hours: 0.15, interval: 86400 * 21, cls: "A", lastCount: "", due: "2026-09-20T00:00:00Z", overdue: true }],
  ["wine", { id: "wine", name: "wine", lines: 1, hours: 0.15, interval: 86400 * 90, cls: "B", lastCount: "2026-09-01T00:00:00Z", due: "2026-12-01T00:00:00Z", overdue: false }],
]);
const contested = new Map([["jam", { id: "contest:evt-1", eventId: "evt-1", kind: "count", resource: "jam", worker: "me", by: "bo", reason: "", role: "attach" }]]);

console.log("\n── the tree ──");
{
  const t = V.storeTree(stocks, places);
  const line = t.map(n => `${"  ".repeat(n.depth)}${n.kind === "place" ? "[" + n.name + "]" : n.name}`);
  check("a place shows its path and what is held in it, outermost first", t[0].kind === "place" && t[0].name === "Mill House", line.join(" | "));
  const names = t.filter(n => n.kind === "place").map(n => n.name);
  check("nested places follow, each level in name order",
        names.join(" › ").startsWith("Mill House › Mill House › Cellar › Mill House › Pantry"), names.join(" ; "));
  check("a place with nothing in it, or in what it holds, is left out", !names.some(n => /Garage|Yard/.test(n)), names.join(" ; "));
  const bin = t.findIndex(n => n.id === "bin");
  check("a container is followed by its contents", t[bin + 1]?.id === "jam" && t[bin + 2]?.id === "lids");
  check("…each a step deeper than the container", t[bin + 1].depth === t[bin].depth + 1);
  check("a container says how many it holds", t[bin].holds === 2);
  check("a stock sits a step inside its place", t[bin].depth === t.find(n => n.kind === "place" && n.name.endsWith("Shelf 1")).depth + 1);
  const last = t.filter(n => n.kind === "place").pop();
  check("what names no place, or one the table lacks, gathers at the end", last.name === V.UNSTATED && last.holds === 2, JSON.stringify(last));
  check("…both under it", t.slice(t.indexOf(last) + 1).map(n => n.id).join() === "tent,pen");
  check("every stock appears once", t.filter(n => n.kind === "stock").length === stocks.length);
  check("a place counts what is held in it and in the places it holds", t.find(n => n.id === "site").holds === 3);
  check("no stock is no tree", V.storeTree([], places).length === 0);
  check("no places is one heading of stock", V.storeTree(stocks, []).length === 1 + stocks.length);
}

console.log("\n── filters ──");
{
  const t = V.storeTree(stocks, places);
  const f = (flt) => V.filterTree(t, flt, schedule, contested);
  check("no filter keeps every line", f({}).length === t.length);
  const due = f({ due: true });
  check("due keeps the stock whose count is overdue", due.filter(n => n.kind === "stock").map(n => n.id).join() === "rice");
  check("…with the headings above it, and none that hold nothing kept",
        due.filter(n => n.kind === "place").map(n => n.name).join(" | ") === "Mill House | Mill House › Pantry", due.map(n => n.name).join(" | "));
  const doubted = f({ contested: true });
  check("contested keeps the contested count's stock, in its container", doubted.filter(n => n.kind === "stock").map(n => n.id).join() === "bin,jam", doubted.map(n => n.id).join());
  check("a rail keeps its own stock", f({ rail: "own" }).filter(n => n.kind === "stock").map(n => n.id).sort().join() === "pen,rice,wine");
  check("perishable keeps what perishes", f({ perishable: true }).filter(n => n.kind === "stock").map(n => n.id).sort().join() === "bin,jam");
  check("two filters keep what passes both", f({ rail: "own", due: true }).filter(n => n.kind === "stock").map(n => n.id).join() === "rice");
  check("a filter nothing passes keeps nothing", f({ rail: "claim" }).length === 0);
  check("whether a filter keeps everything", V.unfiltered({}) && !V.unfiltered({ due: true }));
}

console.log("\n── badges, the ledger, the schedule ──");
{
  check("a row is badged by what is true of it, contest first",
        V.badges(stocks[1], schedule, contested).join() === "your count is contested,perishes");
  check("an overdue count is badged", V.badges(stocks[3], schedule, contested).join() === "count due");
  check("a row nothing is true of has no badge", V.badges(stocks[4], schedule, contested).length === 0);
  check("the ledger says what is held, due and contested", V.ledgerLine(stocks, schedule, contested) === "7 kinds held · 1 count due · 1 contested", V.ledgerLine(stocks, schedule, contested));
  check("…and leaves out what is zero", V.ledgerLine(stocks, new Map(), new Map()) === "7 kinds held");
  check("one kind is not plural", V.ledgerLine([stocks[0]], new Map(), new Map()) === "1 kind held");
  const rows = [...schedule.values(), { id: "x", name: "a bin", lines: 3, hours: 0.3, interval: 86400 * 7, cls: "A", lastCount: "", due: "2026-09-10T00:00:00Z", overdue: true }];
  check("the schedule is worked overdue first, then by date", V.dueOrder(rows).map(r => r.id).join() === "x,rice,wine");
  const now = Date.parse("2026-10-03T00:00:00Z");
  const line = V.dueLine(rows[0], now);
  check("a schedule row says how often and how long it has been due", /counted every 3 weeks/.test(line) && /overdue 13 days/.test(line) && /9 min/.test(line), line);
  check("a row not yet due says in how many days it falls", /due in 59 days/.test(V.dueLine(rows[1], now)), V.dueLine(rows[1], now));
  check("due words: today, tomorrow, one day, and none",
        V.dueWords("2026-10-03T06:00:00Z", false, now) === "due today" && V.dueWords("2026-10-04T00:00:00Z", false, now) === "due tomorrow"
        && V.dueWords("2026-10-02T00:00:00Z", true, now) === "overdue 1 day" && V.dueWords("", false, now) === "" && V.dueWords("", true, now) === "overdue");
}

console.log("\n── one rule each ──");
{
  check("a use-by lot perishes", V.perishable("", "use-by") && V.perishable("durable", "use-by"));
  check("a stock that keeps fresh or for the day perishes", V.perishable("fresh · ~4 days") && V.perishable("same day") && V.perishable("Fresh"));
  check("a stock that keeps does not", !V.perishable("keeps · months") && !V.perishable("durable") && !V.perishable("", "best-before") && !V.perishable(undefined));
  check("what is due is counted over the stock held, not the whole schedule",
        V.dueCount(stocks, schedule) === 1 && V.dueCount([stocks[0]], schedule) === 0);
  check("a schedule row for a target not held is not counted",
        V.dueCount(stocks, new Map([...schedule, ["ghost", { ...schedule.get("rice"), id: "ghost" }]])) === 1);
  const rc = V.railCounts(stocks, ["own", "common", "claim"]);
  check("the rails present, in order, with their counts", rc.map(c => `${c.rail}:${c.n}`).join() === "own:3,common:4", JSON.stringify(rc));
  check("a row with no rail is on the first, own", V.railCounts([{ name: "x" }], ["own", "common"]).map(c => c.rail).join() === "own");
}

console.log("\n── glyphs, the name query and the cards ──");
{
  const g = V.glyphs(stocks[1], schedule, contested);
  check("a row's badges are glyphs, the words behind them", g.map(x => x.word).join() === "your count is contested,perishes" && g[0].glyph === "⚠" && g[0].warn === true && g[1].glyph === "🍂" && g[1].warn === false, JSON.stringify(g));
  check("a count due is a clock", V.glyphs(stocks[3], schedule, contested)[0].glyph === "⏱");
  check("a row with nothing to say has no glyph", V.glyphs(stocks[4], schedule, contested).length === 0);
  check("a name holds every word of a query, in any order and case", V.named("Plum Jam", "jam plum") && !V.named("Plum Jam", "jam rice") && V.named("anything", "  "));
  const t = V.storeTree(stocks, places);
  const q = V.filterTree(t, { q: "jam" }, schedule, contested);
  check("a query keeps the stock it names, in its container and its place", q.filter(n => n.kind === "stock").map(n => n.row.name).join() === "jar bin,plum jam" || q.filter(n => n.kind === "stock").map(n => n.row.name).join() === "plum jam", q.map(n => n.name).join(" | "));
  check("a query is a filter", !V.unfiltered({ q: "jam" }) && V.unfiltered({ q: "  " }));
  const cs = V.cards(t);
  check("the tree is cut at its outermost places, a place holding nothing left out", cs.map(c => c.name).join() === "Mill House,somewhere unstated", cs.map(c => c.name).join());
  check("a card holds the places inside it and the stock at each", cs[0].nodes.some(n => n.kind === "place" && n.name === "Mill House › Pantry") && cs[0].nodes.some(n => n.row?.name === "plum jam"));
  check("a card says what it holds, counting what is in what it holds", cs[0].holds === t[0].holds);
}

done();
