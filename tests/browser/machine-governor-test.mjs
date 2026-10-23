// SPDX-License-Identifier: AGPL-3.0-or-later
// tests/browser/machine-governor-test.mjs — member-first, tested.
//
// The governor is the node's loyalty to its owner: policyHold gates a
// claim before it starts, watchRun keeps the same eyes on a running one,
// and an abort lands as machine-preempt — recorded 'preempted, unpaid,
// not a miss, the job requeued. What's pinned here, in node:
//
//   • watchRun — a landing hold fires abort; a claim gone or left live
//     states fires abort; a quiet run leaves it alone
//   • runClaimGoverned — a clean run lands its receipt and never
//     preempts; an aborted run calls machinePreempt and mints nothing
//   • runEnvelope — an aborted signal kills the worker like the timeout
//   • lendLoop — maxClaims caps the capacity lending can occupy
//
// Run: node tests/browser/machine-governor-test.mjs

import { Worker as NodeWorker } from "node:worker_threads";
import { Blob as NodeBlob } from "node:buffer";

const L = await import("../../browser/app/machine-executor.js");
const G = await import("../../browser/app/machine-governor.js");

let pass = 0, fail = 0;
const check = (label, ok, extra = "") => {
  ok ? pass++ : fail++;
  console.log(`  ${ok ? "✓" : "✗"} ${label}${extra ? " — " + extra : ""}`);
};

// the worker shim — the real prelude under test
const blobSources = new Map();
let blobN = 0;
globalThis.Blob = NodeBlob;
URL.createObjectURL = (b) => {
  const u = `blob:node-${blobN++}`;
  blobSources.set(u, b.text());
  return u;
};
URL.revokeObjectURL = () => {};
globalThis.Worker = class {
  constructor(url) {
    const codeP = blobSources.get(url);
    if (!codeP) throw new Error("worker: unknown blob url");
    this._ready = codeP.then((prelude) => {
      this._w = new NodeWorker(`
        const { parentPort } = require('node:worker_threads');
        const self = {};
        self.postMessage = (m) => parentPort.postMessage(m);
        parentPort.on('message', (m) => self.onmessage && self.onmessage({ data: m }));
        ${prelude}`, { eval: true });
      this._w.on("message", (m) => this.onmessage && this.onmessage({ data: m }));
      this._w.on("error", (e) => this.onerror && this.onerror(e));
    });
    this._queue = [];
    this.onmessage = null; this.onerror = null;
  }
  postMessage(m) {
    this._queue.push(m);
    this._ready.then(() => {
      const q = this._queue.splice(0);
      for (const msg of q) this._w.postMessage(msg);
    });
  }
  terminate() { return this._ready.then(() => this._w && this._w.terminate()); }
};

// a mutable claims table — the test moves the rows mid-run
const mkSeam = (env, rows, receipts, preemptions) => ({
  machineFetchEnvelope: async () => env,
  machineClaims: async () => rows,
  machineReceipt: async (_c, wire) => { receipts.push(JSON.parse(wire)); return "ok"; },
  machinePreempt: async (_c, claimId) => { preemptions.push(claimId); return "ok"; },
});

const spinEnv = { bridgeJobId: "bj-g", kind: "exec", image: "js:work",
                  entrypoint: "(i) => { while (true) {} }", inputHash: "in:g",
                  caps: [], network: false, params: {} };
const sumEnv = { ...spinEnv, entrypoint: "(i) => i + 1" };

console.log("\n── watchRun — the eyes stay on during the run ──");

{
  // a claim that leaves the live states mid-run fires the abort
  const rows = [{ claimId: "c-1", lender: "did:key:zN", state: "claimed" }];
  const seam = mkSeam(sumEnv, rows, [], []);
  const fired = [];
  const stop = G.watchRun(seam, "home", "c-1", (w) => fired.push(w),
                          { watchMs: 5 });
  rows[0].state = "preempted";
  await new Promise((r) => setTimeout(r, 40));
  stop();
  check("a preempted claim aborts the run", fired[0] === "claim:preempted",
        fired[0] || "silent");
}
{
  // a claim that vanishes mid-run is the same story
  const rows = [{ claimId: "c-2", lender: "did:key:zN", state: "claimed" }];
  const fired = [];
  const stop = G.watchRun(mkSeam(sumEnv, rows, [], []), "home", "c-2",
                          (w) => fired.push(w), { watchMs: 5 });
  rows.length = 0;
  await new Promise((r) => setTimeout(r, 40));
  stop();
  check("a vanished claim aborts the run", fired[0] === "claim:gone",
        fired[0] || "silent");
}
{
  // a landing policy hold fires too — the tab went hidden mid-run
  const rows = [{ claimId: "c-3", lender: "did:key:zN", state: "claimed" }];
  const fired = [];
  const doc = globalThis.document;
  globalThis.document = { visibilityState: "visible", hasFocus: () => true };
  const stop = G.watchRun(mkSeam(sumEnv, rows, [], []), "home", "c-3",
                          (w) => fired.push(w),
                          { watchMs: 5, policy: { pauseWhenHidden: true } });
  globalThis.document.visibilityState = "hidden";
  await new Promise((r) => setTimeout(r, 40));
  stop();
  globalThis.document = doc;
  check("a landing hold aborts the run", fired[0] === "hold:hidden",
        fired[0] || "silent");
}
{
  // a live claim and no hold — the watch stays quiet
  const rows = [{ claimId: "c-4", lender: "did:key:zN", state: "accepted" }];
  const fired = [];
  const stop = G.watchRun(mkSeam(sumEnv, rows, [], []), "home", "c-4",
                          (w) => fired.push(w), { watchMs: 5 });
  await new Promise((r) => setTimeout(r, 40));
  stop();
  check("a live run is left alone", fired.length === 0);
}

console.log("\n── runClaimGoverned — abort is honest eviction ──");

{
  // the clean path: run lands its receipt, preempt never fires
  const rows = [{ claimId: "c-5", lender: "did:key:zN", state: "claimed" }];
  const receipts = [], preemptions = [];
  await G.runClaimGoverned(mkSeam(sumEnv, rows, receipts, preemptions),
                           "home", "c-5", "did:key:zN", 41, { watchMs: 5 });
  check("a finished run lands its receipt", receipts.length === 1
        && receipts[0].bridgeJobId === "c-5");
  check("no preempt for a run that finished", preemptions.length === 0);
}
{
  // the claim preempts elsewhere mid-spin → abort → machinePreempt lands,
  // no receipt pretends the run completed
  const rows = [{ claimId: "c-6", lender: "did:key:zN", state: "claimed" }];
  const receipts = [], preemptions = [];
  const seam = mkSeam(spinEnv, rows, receipts, preemptions);
  const p = G.runClaimGoverned(seam, "home", "c-6", "did:key:zN", 0,
                               { watchMs: 5 });
  setTimeout(() => { rows[0].state = "expired"; }, 60);
  const err = await p.then(() => null).catch((e) => e.message);
  check("the abort surfaces the honest reason",
        /machine-governor: claim:expired/.test(err), err || "no error");
  check("the eviction recorded as machine-preempt",
        preemptions[0] === "c-6", JSON.stringify(preemptions));
  check("no receipt for a run the node never finished",
        receipts.length === 0);
}

console.log("\n── runEnvelope — the signal kills the worker itself ──");

{
  const ctl = new AbortController();
  const p = L.runEnvelope(spinEnv, 0, { signal: ctl.signal });
  setTimeout(() => ctl.abort(), 50);
  const err = await p.then(() => null).catch((e) => e.message);
  check("an abort mid-run ends the worker", /aborted/.test(err),
        err || "no error");

  const ctl2 = new AbortController();
  ctl2.abort();
  const err2 = await L.runEnvelope(sumEnv, 0, { signal: ctl2.signal })
    .then(() => null).catch((e) => e.message);
  check("an already-aborted signal refuses to start",
        /aborted/.test(err2), err2 || "no error");
}

console.log("\n── lendLoop — maxClaims bounds the capacity lending holds ──");

{
  // two live claims, one slot — the loop never runs them together;
  // the first finishing frees the slot for the second
  const rows = [
    { claimId: "c-7a", lender: "did:key:zN", state: "claimed" },
    { claimId: "c-7b", lender: "did:key:zN", state: "claimed" },
  ];
  const receipts = [], preemptions = [];
  const events = [];
  const seam = {
    machineFetchEnvelope: async (_c, claimId) => sumEnv,
    machineClaims: async () => rows,
    machineReceipt: async (_c, wire) => { receipts.push(JSON.parse(wire)); return "ok"; },
    machinePreempt: async (_c, id) => { preemptions.push(id); return "ok"; },
  };
  let maxConcurrent = 0, now = 0;
  const stop = L.lendLoop(seam, "home", "did:key:zN", 1, {
    intervalMs: 10, watchMs: 5, maxClaims: 1,
    onRow: (id, st) => {
      if (st === "running") { now++; maxConcurrent = Math.max(maxConcurrent, now); }
      if (st === "done" || st.startsWith("err")) now--;
      events.push(`${id}:${st}`);
    },
  });
  await new Promise((r) => setTimeout(r, 400));
  stop();
  check("maxClaims:1 never ran two at once", maxConcurrent === 1,
        `peak ${maxConcurrent}`);
  check("the slot freed for the second claim",
        receipts.length === 2, `${receipts.length} receipts`);
}

console.log(`\n── results: ${pass} passed, ${fail} failed ──`);
process.exit(fail ? 1 : 0);
