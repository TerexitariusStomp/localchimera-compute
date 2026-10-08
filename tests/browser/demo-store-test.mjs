// tests/browser/demo-store-test.mjs — the offline store keeps its own books
// (browser/app/demo/store.js, from ui/app/demo/store.ts).
//
// What is pinned: every id the schedule, the contests and the counts name is a
// stock the inventory holds; every place a stock is at, and every thing it sits
// in, exists; a code is of the label alphabet and length and no two stocks share
// one; a use-by lot is dated the day it is built for, and a count overdue is
// dated before it; the rows have the shapes the faces read the gateway's answers
// into; the week opens on a Monday after the day.
//
// Run: node tests/browser/demo-store-test.mjs

const { demoStore } = await import("../../browser/app/demo/store.js");
const { LABEL_ALPHABET, LABEL_LENGTH } = await import("../../browser/app/count-catalogue.js");
const { stocksOf, placesOf } = await import("../../browser/app/stock.js");
const { contestedBy } = await import("../../browser/app/contest.js");

let pass = 0, fail = 0;
const check = (label, ok, extra = "") => {
  ok ? pass++ : fail++;
  console.log(`  ${ok ? "✓" : "✗"} ${label}${extra ? " — " + extra : ""}`);
};

const NOW = Date.UTC(2026, 9, 1, 12, 0, 0);          // Thursday 2026-10-01
const d = demoStore(NOW);
const stocks = stocksOf(d.inventory.resources);
const ids = new Set(stocks.map(s => s.id));
const places = placesOf(d.places);
const placeIds = new Set(places.map(p => p.id));

check("the books hold stock, each named by an id", stocks.length > 0 && ids.size === stocks.length);
// the Resources face's goods and the store's stocks are one ledger
{
  const P = await import("../../browser/app/desire-projection.js");
  // the commons' stocks of a good; a person's own offer of it is on the books under their name
  const commons = new Set(d.inventory.resources.filter(r => r["custodian-name"] === "the commons").map(r => r.id));
  const held = spec => stocks.filter(r => r.spec === spec && commons.has(r.id));
  const stocked = P.DEMO_SPECS.filter(sp => !sp.external);
  check("every good the Resources face holds has a stock in the store", stocked.every(sp => held(sp.id).length > 0), stocked.filter(sp => !held(sp.id).length).map(sp => sp.name).join());
  check("…whose stocks sum to the figure the good shows", stocked.every(sp => held(sp.id).reduce((a, r) => a + r.onhand, 0) === P.demoHeld(sp.id)),
        stocked.map(sp => `${sp.name} ${held(sp.id).reduce((a, r) => a + r.onhand, 0)}/${P.demoHeld(sp.id)}`).join(" · "));
  check("…in the good's own unit", stocked.every(sp => held(sp.id).every(r => r.unit === sp.unit)));
  check("…each at a place the books name", stocked.every(sp => held(sp.id).every(r => d.places.some(pl => pl.id === r.location))));
  check("a good of the outside (euros, monero) is held as a stock too", P.DEMO_SPECS.filter(sp => sp.external).every(sp => held(sp.id).length > 0));
}
check("every stock is at a place the table names", stocks.every(s => placeIds.has(s.location)), stocks.filter(s => !placeIds.has(s.location)).map(s => s.id).join());
check("every place sits in one that exists, or in nothing", places.every(p => !p.containedIn || placeIds.has(p.containedIn)));
check("every thing that sits in another sits in one the books hold", stocks.every(s => !s.containedIn || ids.has(s.containedIn)));
check("a container holds what is in it", stocks.filter(s => s.containedIn === "demo:shelf").length === 2 && stocks.filter(s => s.containedIn === "demo:crate").length === 1);

const codes = stocks.filter(s => s.code).map(s => s.code);
check("a code is of the alphabet and the length", codes.length >= 2 && codes.every(c => c.length === LABEL_LENGTH && [...c].every(ch => LABEL_ALPHABET.includes(ch))), codes.join());
check("no two stocks share a code", new Set(codes).size === codes.length);

const lot = stocks.find(s => s.id === "demo:meals");
check("a use-by lot is dated the day it is built for", lot.expires === "2026-10-01" && lot.expiresKind === "use-by", JSON.stringify(lot));

check("the schedule carries the fields the faces read of a count row",
      d.schedule.every(r => r.id && r.name && r.lines >= 1 && r.interval > 0 && typeof r.overdue === "boolean" && typeof r.due === "string"));
check("every target scheduled is a stock held", d.schedule.every(r => ids.has(r.id)));
check("a count overdue is dated before the day, and one not due after it",
      d.schedule.filter(r => r.overdue).every(r => Date.parse(r.due) <= NOW) && d.schedule.filter(r => !r.overdue).every(r => Date.parse(r.due) > NOW));
check("a stock never counted is scheduled and says so", d.schedule.some(r => r.lastCount === "" && r.overdue));

check("every contest names a stock held", d.contests.every(c => ids.has(c.resource)));
check("a contest names an adjustment the counts of that stock hold",
      d.contests.every(c => d.counts(c.resource).some(x => c.id === "contest:" + x.id)));
check("the contests split into one to answer and one to vote in", d.contests.map(c => c.role).sort().join() === "attach,vote");
check("the counter's contested stock is found by the stock", [...contestedBy(d.contests).keys()].join() === "demo:greens");
check("every count of a stock is of a stock held", ["demo:greens", "demo:beans", "demo:loaves"].every(id => ids.has(id) && d.counts(id).length > 0));
check("a stock with no counts has none", d.counts("demo:library").length === 0);

check("readings are of a spec the books hold", d.readings("spec-beans")?.drift.n > 0 && d.readings("nothing/at-all") === null);
check("the history of a spec is in time order", (h => h.every((r, i) => i === 0 || r.at >= h[i - 1].at))(d.history("spec-beans")));

check("the week opens on a Monday after the day", (t => new Date(t).getUTCDay() === 1 && t > NOW)(Date.parse(d.allot.opens)), d.allot.opens);
check("the reads left are within the week's allotment", d.allot.remaining <= d.allot.perWeek && d.allot.sees === true);

check("the same day builds it once", demoStore(NOW + 3600000) === d);
const next = demoStore(NOW + 86400000);
check("another day builds another day's data", next !== d && next.inventory.resources.find(r => r.id === "demo:meals").expires === "2026-10-02");

// the doors the seat answers from the recording say what the recording's books say
{
  const s = demoStore(Date.UTC(2026, 9, 2, 9, 0, 0));
  const { readHistory, readContests } = await import("../../browser/app/contest.js");
  const { readSchedule } = await import("../../browser/app/count.js");
  check("the history door answers a stock's counts, and none for a stock the books do not hold",
        readHistory(s.reply("countHistory", "demo:greens")).length === s.counts("demo:greens").length && s.counts("demo:greens").length > 0
        && readHistory(s.reply("countHistory", "demo:none")).length === 0);
  check("the schedule door answers the schedule", readSchedule(s.reply("countSchedule")).length === s.schedule.length && s.schedule.length > 0);
  check("the contests door answers the open contests", readContests(s.reply("contests")).length === s.contests.length && s.contests.length > 0);
  check("a spec nothing has read answers an empty reading", JSON.parse(s.reply("scopeReadings", "spec-none")).drift.n === 0);
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
