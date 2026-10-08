// tests/browser/audio-timeout-test.mjs — app/voice/audio.ts's withTimeout
// (browser/app/voice/audio.js, from ui/app/voice/audio.ts)
//
// The real bug this guards: the local Moonshine worker's first call
// downloads model weights from a CDN with no bound of its own — a stalled
// fetch (slow network, blocked host) left every awaiting call hanging
// forever, indistinguishable from a silently broken worker. withTimeout
// wraps every such call so a stall surfaces as a real, visible error
// instead of an unbounded wait.
//
// Run: node tests/browser/audio-timeout-test.mjs

const { withTimeout } = await import("../../browser/app/voice/audio.js");

import { harness } from './assert.mjs';
const { check, done } = harness();

const never = new Promise(() => {});   // the exact shape of a stalled CDN fetch

try {
  await withTimeout(never, 50, "stalled fetch");
  check("a promise that never resolves rejects once the timeout elapses", false);
} catch (err) {
  check("a promise that never resolves rejects once the timeout elapses",
        /stalled fetch timed out/.test(err.message), err.message);
}

const fast = new Promise(res => setTimeout(() => res("hi"), 10));
check("a promise that resolves well within the bound still resolves normally",
      await withTimeout(fast, 500, "quick call") === "hi");

const failing = new Promise((_, rej) => setTimeout(() => rej(new Error("boom")), 10));
try {
  await withTimeout(failing, 500, "quick call");
  check("a promise that rejects on its own propagates its OWN error, not a timeout", false);
} catch (err) {
  check("a promise that rejects on its own propagates its OWN error, not a timeout",
        err.message === "boom", err.message);
}

done();
