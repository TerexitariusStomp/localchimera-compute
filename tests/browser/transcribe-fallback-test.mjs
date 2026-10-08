// tests/browser/transcribe-fallback-test.mjs — app/voice/audio.ts's
// transcribePcm() (browser/app/voice/audio.js, from ui/app/voice/audio.ts)
//
// The real bug this guards: deploy/UPSTREAM-ISSUES.md #14 — a Hoot/CapTP
// transport bug where a gateway RPC carrying a payload larger than any
// prior one on the same connection never gets a reply, no error, no
// rejection, an unbounded hang. transcribePcm() tried the gateway's
// `transcribe` door FIRST, unbounded — so a hung gateway call meant the
// local worker fallback below it was never even reached. Reproduced live
// against a real running gateway + real synthesized speech (a Playwright
// probe, not this file): a hold-to-speak session hung indefinitely even
// with the local worker itself working perfectly in isolation.
//
// Run: node tests/browser/transcribe-fallback-test.mjs

import { harness } from './assert.mjs';
const { check, done } = harness();

// enough of a Worker to let whisperWorker() construct one and answer a
// canned "local fallback" text without touching a real CDN/ONNX pipeline
class FakeWorker {
  constructor() { this.onmessage = null; }
  postMessage(msg) {
    const { id } = msg;
    setTimeout(() => this.onmessage && this.onmessage({ data: { id, ok: true, text: "local fallback text" } }), 5);
  }
}
globalThis.Worker = FakeWorker;
globalThis.Blob = class { };
globalThis.URL.createObjectURL = () => "blob:fake";

globalThis.window = globalThis;
window.__seam = { handlers: {} };

const { transcribePcm } = await import("../../browser/app/voice/audio.js");

// a gateway transcribe that never resolves — the exact shape of the real bug
window.__seam.handlers.transcribe = () => new Promise(() => {});

const t0 = Date.now();
const text = await transcribePcm(new Float32Array(1600));
const elapsed = Date.now() - t0;

check("a gateway transcribe call that never resolves does not hang transcribePcm forever",
      elapsed < 6000, `${elapsed}ms`);
check("...and it falls through to the local worker instead of returning empty",
      text === "local fallback text", text);

// a gateway transcribe that resolves normally is still used directly —
// the timeout must not fire on the happy path
window.__seam.handlers.transcribe = () => Promise.resolve("gateway text");
const text2 = await transcribePcm(new Float32Array(1600));
check("a gateway transcribe call that resolves normally is used as-is",
      text2 === "gateway text", text2);

done();
