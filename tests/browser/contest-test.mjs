// tests/browser/contest-test.mjs — the counts of a stock and the contests of
// them (browser/app/contest.js, from ui/app/contest.ts).
//
// What is pinned: the two replies the contest screen is made of read into
// entries (a refusal or an unreadable answer is none); a count's contest is the
// ballot named from its adjustment id; and each count reads as a sentence that
// says which way it found the ledger off and how it was come by.
//
// Run: node tests/browser/contest-test.mjs

const C = await import("../../browser/app/contest.js");

import { harness } from './assert.mjs';
const { check, done } = harness();

console.log("\n── the counts of a stock ──");
{
  const raw = JSON.stringify({ rows: [
    { id: "evt-2", at: "2026-10-01T10:00:00Z", delta: -2.5, unit: "kg", counter: "EADA123456789", technique: "count:photo", evidence: "sha256:" + "a".repeat(64), mine: false },
    { id: "evt-1", at: "2026-09-30T08:00:00Z", delta: 1, unit: "kg", counter: "EBOB", technique: "count~announced", evidence: "", mine: true },
    { at: "no id" },
  ] });
  const h = C.readHistory(raw);
  check("a count with an id is an entry", h.length === 2 && h[0].id === "evt-2");
  check("its figures and who counted", h[0].delta === -2.5 && h[0].unit === "kg" && h[0].counter === "EADA123456789");
  check("the picture it names and whether the reader counted it", h[0].evidence.startsWith("sha256:") && h[0].mine === false && h[1].mine === true);
  check("a refusal is no counts", C.readHistory("err:sign in first").length === 0);
  check("an unreadable answer is no counts", C.readHistory("{oops").length === 0 && C.readHistory(undefined).length === 0);
}

console.log("\n── the contests open ──");
{
  const raw = JSON.stringify({ rows: [
    { id: "contest:evt-2", eventId: "evt-2", kind: "count", worker: "EADA", by: "EBOB", reason: "never opened the crate", role: "vote" },
    { id: "contest:evt-9", eventId: "evt-9", kind: "work", worker: "EBOB", by: "EADA", reason: "", role: "attach" },
    { id: "contest:evt-8", role: "mystery" },
  ] });
  const o = C.readContests(raw);
  check("each contest is an entry", o.length === 3 && o[0].kind === "count");
  check("what the reader may do", o[0].role === "vote" && o[1].role === "attach");
  check("a role the gateway did not name is none", o[2].role === "none");
  const h = C.readHistory(JSON.stringify({ rows: [{ id: "evt-2", delta: -1 }, { id: "evt-3", delta: 1 }] }));
  check("a count's contest is its adjustment's ballot", C.ballotOf(h[0]) === "contest:evt-2");
  check("the open contest of a count is found by it", C.contestOf(h[0], o)?.by === "EBOB");
  check("a count with none open has none", C.contestOf(h[1], o) === undefined);
}

console.log("\n── a count in a sentence ──");
{
  const less = C.countLine({ delta: -2.5, unit: "kg", technique: "count:stated" });
  check("a count that found the ledger high", /found 2\.5 kg fewer than the ledger read/.test(less), less);
  check("…and how it was come by", /by their word/.test(less), less);
  check("a count that found it low", /found 3 kg more/.test(C.countLine({ delta: 3, unit: "kg", technique: "count:label" })));
  check("a photograph, a label and a planned run are each said",
        /photograph/.test(C.countLine({ delta: 1, unit: "", technique: "count:photo" })) &&
        /label/.test(C.countLine({ delta: 1, unit: "", technique: "count:label" })) &&
        /planned/.test(C.countLine({ delta: 1, unit: "", technique: "count~random" })));
  check("a count that states its figure says it first",
        C.countLine({ counted: 8, delta: -2, unit: "kg", technique: "count:stated" }) === "counted 8 kg, found 2 kg fewer than the ledger read, by their word");
  check("a count that agreed says so, with its figure",
        C.countLine({ counted: 6, delta: 0, unit: "", technique: "count:label" }) === "counted 6, found the ledger right, off a label");
  check("a row that names its ballot is contested under it",
        C.ballotOf({ id: "evt-9-record", ballot: "contest:evt-9" }) === "contest:evt-9");
  const agreed = C.readHistory(JSON.stringify({ rows: [{ id: "evt-9-record", ballot: "contest:evt-9", counted: 6, at: "2026-10-01T10:00:00Z", delta: 0, unit: "", counter: "EADA", technique: "count:stated", evidence: "", mine: false }] }));
  check("a row is read with its figure and its ballot", agreed.length === 1 && agreed[0].counted === 6 && agreed[0].ballot === "contest:evt-9");
  check("a technique it does not know is left unsaid", C.countLine({ delta: 1, unit: "", technique: "mystery" }) === "found 1 more than the ledger read");
  check("the day of a count, as a person reads one", /2026/.test(C.countDay("2026-10-01T10:00:00Z")) && C.countDay("2026-10-01T10:00:00Z") !== "2026-10-01" && C.countDay("") === "");
  check("a counter's AID is shortened", C.shortAid("EADA123456789") === "EADA12…" && C.shortAid("EBOB") === "EBOB");
  check("a held picture is an image URL", C.pictureUrl("AAAA") === "data:image/jpeg;base64,AAAA" && C.pictureUrl("") === "");
}

console.log("\n── the counts a person may attach to ──");
{
  const o = C.readContests(JSON.stringify({ rows: [
    { id: "contest:a", kind: "count", resource: "jam", role: "attach" },
    { id: "contest:b", kind: "count", resource: "rice", role: "vote" },
    { id: "contest:c", kind: "work", resource: "", role: "attach" },
    { id: "contest:d", kind: "count", resource: "oil", role: "attach" },
  ] }));
  const m = C.contestedBy(o);
  check("the stock of each of their own contested counts", [...m.keys()].sort().join() === "jam,oil");
  check("a contest they only vote on is not theirs", !m.has("rice"));
  check("work names no stock, so none", m.size === 2);
  check("no contests are none", C.contestedBy([]).size === 0);
}

console.log("\n── a row of the history ──");
{
  const h = C.countHead({ at: "2026-10-01T10:00:00Z", unit: "kg", counted: 45 }, "you");
  check("a row leads with the figure found, who and the day", h.figure === "45 kg" && /^you · /.test(h.rest) && /2026/.test(h.rest) && !/2026-10-01/.test(h.rest), JSON.stringify(h));
  check("a count that states no figure leads with who and the day", C.countHead({ at: "2026-10-01T10:00:00Z", unit: "kg" }, "mara").figure === "");
  check("what it found follows, without the figure again", C.foundLine({ delta: -3, unit: "kg", technique: "count:stated" }) === "3 kg fewer than the ledger read, by their word");
  check("…and a count that agreed says the ledger was right", /^the ledger was right/.test(C.foundLine({ delta: 0, unit: "kg", technique: "count:photo" })));
  check("an instant with no day reads as nothing", C.countDay("") === "");
}

done();
