// tests/browser/conform-test.mjs — the browser's ask-for-a-shape door
// (browser/app/conform.js, from ui/app/conform.ts; twin of (playnet ai conform))
//
// With a scripted ask standing in for the gateway, this holds:
//
//   FIRST TRY    a conforming reply is accepted at once, one call
//   HEALING      a failing reply is re-asked WITH the reason and the previous
//                output quoted back; a model that reads them conforms
//   BUDGET       retries bound the calls; the floor ships when they run out
//   SALVAGE      the floor sees the LAST readable candidate
//   UNREADABLE   prose with no {…} is a reason too, never a throw
//   TRANSPORT    a throwing ask goes to the floor with NO retry
//   READER       ONE {…} object out of prose and fences; an array is not that
//
// Run: node tests/browser/conform-test.mjs

const { conform, readFirstJSONObject, healPrompt } = await import("../../browser/app/conform.js");

import { harness } from './assert.mjs';
const { check, done } = harness();

// the shape under test: {kind: "a"|"b", name: string}
const read = readFirstJSONObject;
const checkRec = r => !["a", "b"].includes(r.kind) ? "kind must be a or b"
                    : typeof r.name !== "string" ? "name must be a string" : null;
const accept = r => ({ ok: r });
const floorDry = () => "floor";
const scripted = (...replies) => {
  const seen = [];
  const ask = (system, user) => { seen.push(user); return replies[Math.min(seen.length - 1, replies.length - 1)]; };
  return { ask, seen };
};
const run = (s, extra = {}) => conform({ ask: s.ask, system: "sys", user: "ask", read, check: checkRec, accept, floor: floorDry, ...extra });

console.log("\n── a conforming reply is accepted at once ──");
{
  const s = scripted('Sure: {"kind":"a","name":"x"}');
  const r = await run(s);
  check("accept sees the candidate", r.ok && r.ok.kind === "a" && r.ok.name === "x");
  check("one call", s.seen.length === 1);
}

console.log("\n── a re-ask carries the reason and the previous output ──");
{
  const s = scripted('{"kind":"zzz","name":"x"}', '{"kind":"b","name":"x"}');
  const r = await run(s);
  check("the second reply conforms", r.ok && r.ok.kind === "b");
  check("two calls", s.seen.length === 2);
  check("the re-ask quotes the reason", s.seen[1].includes("kind must be a or b"));
  check("…and the previous output", s.seen[1].includes('"kind":"zzz"'));
  check("…and the original request", s.seen[1].includes("Original request:\nask"));
  check("healPrompt is that wording", healPrompt("ask", "raw", "why").includes("Validation errors:\nwhy"));
}

console.log("\n── retries bound the calls; the floor sees the last candidate ──");
{
  const s0 = scripted('{"kind":"zzz","name":"x"}');
  check("retries 0 ⇒ floor", await run(s0, { retries: 0 }) === "floor");
  check("…one call", s0.seen.length === 1);
  const s2 = scripted('{"kind":"zzz","name":"x"}');
  check("retries 2 ⇒ floor", await run(s2, { retries: 2 }) === "floor");
  check("…three calls", s2.seen.length === 3);
  const s3 = scripted('{"kind":"zzz","name":"x"}');
  check("the floor receives the last readable candidate (salvage)",
        await run(s3, { retries: 0, floor: last => last.name }) === "x");
}

console.log("\n── prose with nothing readable is a reason, not a throw ──");
{
  const s = scripted("I'm sorry, I can't help with that.");
  const r = await run(s, { floor: last => ["floor", last] });
  check("unreadable ⇒ floor with null", r[0] === "floor" && r[1] === null);
  check("…the re-ask says so", s.seen[1].includes("nothing readable"));
  const s2 = scripted("I'm sorry.", '{"kind":"a","name":"late"}');
  check("an unreadable first reply can still heal", (await run(s2)).ok.name === "late");
  const s3 = scripted(undefined);
  check("an empty reply (door returns nothing) floors", await run(s3) === "floor");
}

console.log("\n── a throwing ask floors at once, no retry ──");
{
  let calls = 0;
  const ask = () => { calls++; throw new Error("gateway down"); };
  const r = await conform({ ask, system: "s", user: "u", read, check: checkRec, accept, floor: floorDry, retries: 3 });
  check("error ⇒ floor", r === "floor");
  check("…one call only", calls === 1);
}

console.log("\n── the reader strips prose and fences ──");
check("first {…} behind prose and a fence", readFirstJSONObject('ok:\n```json\n{"a":{"b":1}}\n```')?.a?.b === 1);
check("outermost braces", readFirstJSONObject('{"a":1} and {"b":2}') === null, "two objects joined do not parse: null");
check("no braces ⇒ null", readFirstJSONObject("{") === null);
check("an array of objects is not ONE object ⇒ null", readFirstJSONObject('[{"a":1},{"a":2}]') === null);
check("a bare array has no object ⇒ null", readFirstJSONObject('[1,2]') === null);

done();
