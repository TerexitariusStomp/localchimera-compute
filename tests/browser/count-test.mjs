// tests/browser/count-test.mjs — a count of a stock, as the faces speak it
// (browser/app/count.js, from ui/app/count.ts).
//
// The capture sheet, the inventory face and the calendar read a figure, read
// the gateway's reply and say what the count found through this one module.
// What is pinned here is each of those sentences:
//
//   • a figure is the first number in what was typed or said, zero or more,
//     with a decimal comma read as a point;
//   • text with no figure, and a figure below zero, read as no figure, which is
//     a different answer from zero;
//   • a reply is a landed count or the gateway's refusal in its own words;
//   • the verdict names which way the ledger was off and what it reads now.
//
// Run: node tests/browser/count-test.mjs

const { parseFigure, readReply, refused, verdict, quantity, plannedCount, parseReply, finite, figure, readSchedule, readExpected, planRange, flowLine, against, planVerdict, standing, farOff, shortfall } = await import("../../browser/app/count.js");

import { harness } from './assert.mjs';
const { check, done } = harness();

console.log("\n── a figure ──");
{
  check("a plain number", parseFigure("42") === 42);
  check("a decimal point", parseFigure("8.5") === 8.5);
  check("a decimal comma", parseFigure("8,5") === 8.5);
  check("a figure with its unit after it", parseFigure("8,5 kg") === 8.5);
  check("a figure inside a spoken sentence", parseFigure("there are 12 jars left") === 12);
  check("a leading point", parseFigure(".5") === 0.5);
  check("zero is a count", parseFigure("0") === 0);
  check("surrounding space is no matter", parseFigure("  7 ") === 7);
  check("no figure in words alone", parseFigure("a few") === null);
  check("no figure in nothing", parseFigure("") === null);
  check("…and nothing is a different answer from zero", parseFigure("") !== parseFigure("0"));
  check("a figure below zero is no count", parseFigure("-3") === null);
  check("…with the typographic minus too", parseFigure("−3") === null);
  check("a hyphen earlier in the sentence leaves the figure standing",
        parseFigure("the top-shelf jars: 4") === 4);
}

console.log("\n── what the plan expects ──");
{
  const wire = { low: 7, high: 15, flows: [
    { id: "bake", action: "consume", quantity: -3, when: "2026-09-28T08:00:00Z", proc: "bake" },
    { id: "delivery", action: "produce", quantity: 5, when: "2026-09-28T09:00:00Z", proc: "mill" },
  ] };
  const e = readExpected(wire);
  check("a range with flows reads", !!e && e.low === 7 && e.high === 15 && e.flows.length === 2);
  check("a range with no flow behind it is no range", readExpected({ low: 10, high: 10, flows: [] }) === null);
  check("an absent range is none", readExpected(undefined) === null && readExpected(null) === null);
  check("a flow with no figure is dropped", readExpected({ low: 1, high: 2, flows: [{ id: "x" }] }) === null);
  check("the range is written as ends", planRange(e, "kg") === "7–15 kg");
  check("…and as one figure where the ends meet", planRange({ low: 5, high: 5, flows: e.flows }, "kg") === "5 kg");
  check("a draw says it is going", /^3 kg going/.test(flowLine(e.flows[0], "kg")));
  check("an addition says it is arriving", /^5 kg arriving/.test(flowLine(e.flows[1], "kg")));
  check("a flow with no time names none", flowLine({ ...e.flows[0], when: "" }, "kg") === "3 kg going");
  check("a figure inside the range is within it", against(8, e) === "within" && against(7, e) === "within" && against(15, e) === "within");
  check("below it is under, above it over", against(5, e) === "under" && against(16, e) === "over");
  check("the verdict inside", planVerdict(8, e, "kg") === "inside what the plan expected: 7–15 kg");
  check("the verdict under says by how much", planVerdict(5, e, "kg") === "2 kg under what the plan expected: 7–15 kg");
  check("the verdict over says by how much", planVerdict(18, e, "kg") === "3 kg over what the plan expected: 7–15 kg");
  const landed = readReply(JSON.stringify({ event: "", record: "r", delta: 0, onhand: 8, expected: wire }));
  check("a reply carries the range", !refused(landed) && landed.expected?.low === 7);
  const bare = readReply(JSON.stringify({ event: "", record: "r", delta: 0, onhand: 8, expected: { low: 8, high: 8, flows: [] } }));
  check("…and none where no plan bears on the stock", !refused(bare) && bare.expected === null);
}

console.log("\n── a figure, weighed against a stock ──");
{
  const flows = [{ id: "bake", action: "consume", quantity: -3, when: "", proc: "bake" }];
  const planned = { onhand: 18, expected: { low: 12, high: 15, flows } }, bare = { onhand: 6 };
  check("the ledger's own figure agrees, plan or none", standing(18, planned) === "agrees" && standing(6, bare) === "agrees");
  check("inside the plan's range is within; outside it under or over", standing(13, planned) === "within" && standing(4, planned) === "under" && standing(16, planned) === "over");
  check("with no plan the ledger is the reference", standing(5, bare) === "under" && standing(7, bare) === "over");
  check("far off is beyond the range by more than half its end and more than one unit", farOff(4, planned) && farOff(40, planned) && !farOff(11, planned) && !farOff(17, planned) && farOff(2, bare) && !farOff(5, bare));
  check("the shortfall is against the plan's low end, else the ledger", shortfall(4, planned) === 8 && shortfall(4, bare) === 2 && shortfall(20, planned) === 0);
}

console.log("\n── the gateway's reply ──");
{
  const landed = readReply(JSON.stringify({ event: "evt-count-1", record: "", delta: -1.5, onhand: 8.5 }));
  check("a landed count reads as one", !refused(landed));
  check("…with its difference", !refused(landed) && landed.delta === -1.5);
  check("…and what is on hand after", !refused(landed) && landed.onhand === 8.5);
  check("…and the adjustment's event", !refused(landed) && landed.event === "evt-count-1");

  const earlier = readReply(JSON.stringify({ event: "", record: "r", delta: 0, onhand: 8.5, sighting: "earlier" }));
  check("an earlier sighting is read as one", earlier.sighting === "earlier");
  check("…and says the ledger holds the later count", /earlier sighting.*later count.*8\.5 kg/.test(verdict(earlier, "kg")));
  const agreed = readReply(JSON.stringify({ event: "", record: "", delta: 0, onhand: 8.5 }));
  check("a count that agreed names no event", !refused(agreed) && agreed.event === "");

  const no = readReply("err:not yours to count");
  check("a refusal reads as one", refused(no));
  check("…in the gateway's own words", refused(no) && no.err === "not yours to count");
  check("an offline bridge is a refusal", refused(readReply("err:offline")));
  check("an empty answer is a refusal", refused(readReply("")));
  check("an answer that is no JSON is a refusal", refused(readReply("{not json")));
  check("an answer with no figures is a refusal", refused(readReply(JSON.stringify({ event: "e" }))));
  check("an answer that is no string is a refusal", refused(readReply(undefined)));
  check("a figure of false is no figure, where Number(false) reads zero",
        refused(readReply(JSON.stringify({ event: "e", delta: false, onhand: 3 }))));
  check("a figure of null is no figure", refused(readReply(JSON.stringify({ event: "e", delta: 1, onhand: null }))));
  check("a figure that rode as text reads", !refused(readReply(JSON.stringify({ event: "e", delta: "1.5", onhand: "8" }))));
}

console.log("\n── a reply, read once for every door ──");
{
  check("an object reads as itself", parseReply('{"code":"ABC234"}').code === "ABC234");
  check("a refusal keeps the gateway's words", parseReply("err:no such stock").err === "no such stock");
  check("a bare refusal says so", parseReply("err:").err === "refused");
  check("an array is no reply", refused(parseReply("[1,2]")));
  check("text that is no JSON is no reply", refused(parseReply("{oops")));
  check("a missing answer is no reply", refused(parseReply(undefined)));
  check("a number reads from a number or from its text", finite(2) === 2 && finite("2.5") === 2.5);
  check("false, null, blank and nan are no figures",
        finite(false) === null && finite(null) === null && finite("") === null && finite(NaN) === null);
  check("a schedule reads its rows",
        readSchedule(JSON.stringify({ rows: [{ id: "rice", name: "rice", lines: 1, hours: 0.15, interval: 86400, class: "A", overdue: true }] }))[0]?.overdue === true);
  check("a refused schedule reads as none", readSchedule("err:sign in first").length === 0);
  check("a figure is written to two decimals at most", figure(8.456) === "8.46" && figure(40) === "40");
}

console.log("\n── a planned count's process ──");
{
  const p = plannedCount("count~random~bin/1");
  check("a planned count names its regime and its target", p?.regime === "random" && p?.target === "bin/1");
  check("a random count is counted blind", p?.blind === true);
  check("an undisclosed count is counted blind", plannedCount("count~undisclosed~rice")?.blind === true);
  check("an announced count shows the ledger's figure", plannedCount("count~announced~rice")?.blind === false);
  check("a target with tildes and colons in it reads back whole",
        plannedCount("count~announced~means:ada:oven~2")?.target === "means:ada:oven~2");
  check("a recipe's process is no planned count", plannedCount("bake") === null);
  check("an unplanned count's technique is no planned count", plannedCount("count:stated") === null);
  check("a regime the grammar does not know is no planned count", plannedCount("count~loud~rice") === null);
  check("a process naming no target is no planned count", plannedCount("count~announced~") === null);
  check("a technique with its target left off is no planned count", plannedCount("count~announced") === null);
  check("nothing is no planned count", plannedCount(null) === null && plannedCount("") === null);

  const landed = readReply(JSON.stringify({ event: "e", record: "r", hours: 0.15, delta: 0, onhand: 3 }));
  check("a planned count's reply carries the hours it landed", !refused(landed) && landed.hours === 0.15);
  const bare = readReply(JSON.stringify({ event: "", record: "", delta: 0, onhand: 3 }));
  check("an unplanned count's reply carries none", !refused(bare) && bare.hours === 0);
}

console.log("\n── a quantity ──");
{
  check("a whole number stays whole", quantity(40, "kg") === "40 kg");
  check("a fraction keeps up to two decimals", quantity(8.456, "kg") === "8.46 kg");
  check("…and drops the zeros it does not need", quantity(8.5, "kg") === "8.5 kg");
  check("a stock with no unit is a bare figure", quantity(6, "") === "6");
}

console.log("\n── the verdict ──");
{
  const high = verdict({ event: "e", record: "", delta: -1.5, onhand: 8.5 }, "kg");
  check("a ledger that read high is said to have read more", /1\.5 kg more than is there/.test(high), high);
  check("…and the sentence ends on what it reads now", /now reads 8\.5 kg$/.test(high), high);

  const low = verdict({ event: "e", record: "", delta: 2, onhand: 42 }, "kg");
  check("a ledger that read low is said to have read less", /2 kg less than is there/.test(low), low);

  const same = verdict({ event: "", record: "", delta: 0, onhand: 8.5 }, "kg");
  check("a ledger that agreed is said to agree", /agrees/.test(same), same);
  check("…with the figure both hold", /8\.5 kg/.test(same), same);

  check("the difference is stated as a size, never signed",
        !/-/.test(high) && !/\+/.test(low), `${high} | ${low}`);
}

done();
