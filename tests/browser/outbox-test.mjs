// tests/browser/outbox-test.mjs — acts made with no gateway in reach (browser/app/outbox.js, from ui/app/outbox.ts).
//
// What is pinned: a queued act is stated at its instant; a gateway in reach
// answers and nothing waits; with none in reach the device's copy answers a read
// and lands an act that may wait, which is kept in order; an act that may not
// wait is told so; a flush sends what waits oldest first, drops what a gateway
// answers, keeps a refusal with its words, and stops at the first act no gateway
// answers.
//
// Run: node tests/browser/outbox-test.mjs

import { harness } from "./assert.mjs";
const O = await import("../../browser/app/outbox.js");
const { check, section, done } = harness();

function memBox() {
  const rows = new Map(); let n = 0;
  return {
    rows,
    add: async act => { rows.set(++n, act); },
    all: async () => [...rows.entries()],
    drop: async key => { rows.delete(key); },
    keep: async (key, act) => { rows.set(key, act); },
  };
}
const NOW = new Date(Date.UTC(2026, 9, 4, 9, 30, 15));
const READS = new Set(["countHistory"]);
const ends = (gateway, box = memBox(), seen = []) => ({
  box, seen, now: () => NOW,
  gateway: async (door, args) => gateway(door, args),
  device: async (door, args) => { seen.push([door, args]); return door === "countStock" && args[2] === "kg" ? "err:count in the stock's unit: box" : `{"device":"${door}"}`; },
});

section("an act is of its instant");
{
  check("a count is stamped with when it was made", O.stamp("countStock", ["tea", 7, "box"], NOW)[5] === "2026-10-04T09:30:15Z");
  check("an instant the person stated is kept", O.stamp("countStock", ["tea", 7, "box", "", "", "2026-10-01T08:00:00Z"], NOW)[5] === "2026-10-01T08:00:00Z");
  check("every argument goes as a string, an absent one empty", O.stamp("countStock", ["tea", 7, null], NOW).slice(0, 3).join("|") === "tea|7|");
  check("a need is named by who and what, and takes no instant", O.stamp("declareNeed", ["spec-tea", 2], NOW).length === 2);
}

section("a gateway in reach");
{
  const e = ends(() => '{"onhand":7}');
  const r = await O.ask(e, "countStock", ["tea", 7, "box"], READS);
  check("its answer is the answer", r === '{"onhand":7}');
  check("nothing waits and the device is not asked", (await e.box.all()).length === 0 && e.seen.length === 0);
  const refused = await O.ask(ends(() => "err:not yours to count"), "countStock", ["tea", 7, "box"], READS);
  check("its refusal is the answer too", refused === "err:not yours to count");
}

section("no gateway in reach");
{
  const e = ends(() => "err:offline");
  const r = await O.ask(e, "countStock", ["tea", 7, "box"], READS);
  const waiting = await e.box.all();
  check("the device's copy lands the count", r === '{"device":"countStock"}' && e.seen.length === 1);
  check("…and it waits, as it was sent, with its instant", waiting.length === 1 && waiting[0][1].door === "countStock" && waiting[0][1].args[5] === "2026-10-04T09:30:15Z");
  check("the copy was given the same arguments the gateway will be", JSON.stringify(e.seen[0][1]) === JSON.stringify(waiting[0][1].args));
  const asked = [];
  await O.ask({ ...ends(() => "{}"), gateway: async (door, args) => { asked.push(args); return "{}"; } }, "countStock", ["tea", 7, "box"], READS);
  check("a gateway in reach is asked exactly as the face asked", asked[0].length === 3 && asked[0][1] === 7);
  const demo = ends(() => "err:offline"); delete demo.box;
  check("a copy of no gateway's scope lands the act and keeps nothing", await O.ask(demo, "countStock", ["tea", 7, "box"], READS) === '{"device":"countStock"}');
  const bad = await O.ask(e, "countStock", ["tea", 7, "kg"], READS);
  check("an act the copy refuses does not wait", bad.startsWith("err:count in") && (await e.box.all()).length === 1);
  check("a read is answered by the copy", await O.ask(e, "countHistory", ["tea"], READS) === '{"device":"countHistory"}');
  check("an act that depends on others waits for a connection", await O.ask(e, "claim", ["r1"], READS) === "err:this waits for a connection");
  check("each way of being out of reach is read as one", ["err:offline", "err:spine down", "err:planner unreachable", "err:unavailable: no worker", "err:sign in first", "err:no scope yet"].every(O.unreached) && !O.unreached("err:not yours"));
}

section("a keyed act carries its token from the first send");
{
  const flow = ["s", "consume", "water", "3", "3", "A", "2026-10-02", "P", "", "mc|row"];
  const k = O.keyed("recordFlow", flow);
  check("a token is minted at the last place, in the server's alphabet", k.length === 11 && /^[A-Za-z0-9_-]{1,64}$/.test(k[10]));
  check("a token the caller has is kept", O.keyed("recordFlow", [...flow, "mine"])[10] === "mine");
  check("two acts have two tokens", O.keyed("recordFlow", flow)[10] !== k[10]);
  check("a door that is not keyed gets none", O.keyed("countStock", ["tea"]).length === 1);
  const seen = [];
  const e = ends((door, args) => { seen.push(args); return "{}"; });
  await O.ask(e, "recordFlow", flow, READS);
  check("the gateway is asked with the token on the first send", seen[0].length === 11 && seen[0][10] !== "");
  const plain = [];
  await O.ask(ends((door, args) => { plain.push(args); return "{}"; }), "countStock", ["tea", 7, "box"], READS);
  check("a door that is not keyed is still asked exactly as the face asked", plain[0].length === 3 && plain[0][1] === 7);
  const box = memBox();
  const lost = ends(() => "err:offline", box);
  const first = await O.ask(lost, "recordFlow", flow, READS);
  check("a keyed act no gateway answers lands on the device and waits", first === '{"device":"recordFlow"}' && box.rows.size === 1);
  const waiting = [...box.rows.values()][0];
  check("it waits with the token it was first asked with", waiting.args.length === 11 && waiting.args[10] === lost.seen[0][1][10] && waiting.args[10] !== "");
  const sent = [];
  await O.flush(box, async (door, args) => { sent.push(args); return "ok:ev"; });
  check("a flush sends that same token, so the gateway answers it with what landed", sent[0][10] === waiting.args[10] && box.rows.size === 0);
  check("an act the device cannot take is not kept", await O.ask({ ...lost, box: memBox(), device: async () => "err:this needs the books" }, "recordEffort", ["s", "c", "1", "hours"], READS) === "err:this needs the books");
}

section("a flush");
{
  const box = memBox();
  await box.add({ door: "countStock", args: ["a"], at: "t" });
  const told = await O.flush(box, async () => "err:not yours to count");
  check("what a gateway refuses is told once, in its own words", told.told.join() === "not yours to count" && told.refused === 1);
  const again = await O.flush(box, async () => "{}");
  check("a refusal already told is not told again", again.told.length === 0 && again.refused === 1);
}
{
  const box = memBox();
  for (const d of ["a", "b", "c", "d"]) await box.add({ door: "countStock", args: [d], at: "t" });
  const sent = [];
  const first = await O.flush(box, async (door, args) => { sent.push(args[0]); return args[0] === "b" ? "err:no such stock" : args[0] === "c" ? "err:offline" : "{}"; });
  check("goes oldest first and stops at the first act no gateway answers", sent.join() === "a,b,c");
  check("what landed is gone, what was refused is kept with its words, the rest wait",
        first.landed === 1 && first.refused === 1 && first.waiting === 2
        && [...box.rows.values()].map(a => a.args[0] + (a.refused ? "!" + a.refused : "")).join() === "b!no such stock,c,d");
  const again = [];
  const second = await O.flush(box, async (door, args) => { again.push(args[0]); return "{}"; });
  check("the next flush sends what waited, and leaves the refused act for the person", again.join() === "c,d" && second.landed === 2 && second.refused === 1 && box.rows.size === 1);
}

section("the box on the device");
{
  const { fakeIndexedDB } = await import("./fakes.mjs");
  globalThis.indexedDB = fakeIndexedDB();
  const { idbBox } = await import("../../browser/app/outbox-idb.js");
  const box = idbBox();
  for (const d of ["a", "b", "c"]) await box.add({ door: "countStock", args: [d], at: "t" });
  const kept = await box.all();
  check("keeps the acts in the order they were made", kept.map(([, a]) => a.args[0]).join() === "a,b,c");
  await box.drop(kept[0][0]);
  await box.keep(kept[1][0], { ...kept[1][1], refused: "no such stock" });
  const after = await idbBox().all();           // another page's box reads the same store
  check("a dropped act is gone and a refusal is kept with the act, across pages",
        after.map(([, a]) => a.args[0] + (a.refused ? "!" : "")).join() === "b!,c");
  const flushed = await O.flush(idbBox(), async () => "{}");
  check("a flush over it lands what waits", flushed.landed === 1 && flushed.refused === 1 && (await idbBox().all()).length === 1);
}

done();
