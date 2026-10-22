// tests/browser/machine-executor-test.mjs — the browser node, tested.
//
// machine-executor.js is the "browser tab IS the compute node" claim:
// runEnvelope sandboxes the entrypoint in a Worker, meters it, and
// emitReceipt produces the digest the Scheme verifier recomputes.
//
// What's pinned here, in node — a worker_threads shim carries the REAL
// WORKER_PRELUDE so the sandbox/cap/timeout code under test is the code
// that ships:
//
//   • digestReceiptBody — sha256("naoms-compute-receipt/v1" + NUL +
//     canonical JSON) is byte-identical to the Scheme receipt-digest
//     goldens in tests/compute/test-receipt.scm.
//   • runEnvelope js: — the entrypoint runs, output + metering return.
//   • cap denial — no fetch cap → the sandbox has no fetch (fail closed).
//   • timeout — a loop that never yields is killed at the deadline,
//     honestly, with no receipt.
//   • wasm: — a hand-encoded WASI module writes "hi" through the
//     deterministic preview1 shim; a second export returns its scalar.
//
// Run: node tests/browser/machine-executor-test.mjs

import { Worker as NodeWorker } from "node:worker_threads";
import { Blob as NodeBlob } from "node:buffer";

const L = await import("../../browser/app/machine-executor.js");

let pass = 0, fail = 0;
const check = (label, ok, extra = "") => {
  ok ? pass++ : fail++;
  console.log(`  ${ok ? "✓" : "✗"} ${label}${extra ? " — " + extra : ""}`);
};

// ── the DOM shim — just enough for runEnvelope's real path ──────────────
// Blob: node's own. URL.createObjectURL: capture the blob's source so the
// Worker shim can hand it to worker_threads as eval'd code.
const blobSources = new Map();
let blobN = 0;
globalThis.Blob = NodeBlob;
const origCreate = URL.createObjectURL?.bind(URL);
URL.createObjectURL = (b) => {
  const u = `blob:node-${blobN++}`;
  blobSources.set(u, b.text());
  return u;
};
URL.revokeObjectURL = () => {};

// Worker: run the prelude code in a real worker thread. The prelude speaks
// browser (self.onmessage/self.postMessage/self.__caps) — the wrapper maps
// it onto parentPort.
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

console.log("\n── the digest — same bytes the Scheme verifier recomputes ──");

{
  // the goldens from tests/compute/test-receipt.scm — byte-exact or the
  // two sides' canonicalization has drifted
  const b1 = { bridgeJobId: "bj-1", lenderDid: "did:key:z6MkAlice",
               inputHash: "aa11", outputHash: "bb22", engine: null,
               usage: null, repro: null, executedAt: 1761000000000 };
  check("bj-1 digest matches the Scheme golden",
        await L.digestReceiptBody(b1)
          === "c33eb2ac2c573c8272b9647a57066e5461b0810534aa434e0824707e8c7acd48");

  const b2 = { bridgeJobId: "bj-3", lenderDid: "did:key:z6MkCarol",
               inputHash: "ee55", outputHash: "ff66", engine: null,
               usage: { unit: "seconds", amount: 3 },
               repro: { mode: "exact" }, executedAt: 1761000000456 };
  check("bj-3 digest matches the Scheme golden",
        await L.digestReceiptBody(b2)
          === "03369b9cd11b98d2ab86cc5d353242d9301da30444e05b26392156928b0887bd");
}

console.log("\n── js: envelopes — the sandboxed run meters and returns ──");

{
  const env = { bridgeJobId: "bj-js", image: "js:work",
                entrypoint: "(input) => input * 2", inputHash: "in:x",
                caps: [], network: false };
  const { result, seconds } = await L.runEnvelope(env, 21);
  check("the entrypoint's answer comes back", result === 42, `got ${result}`);
  check("the run was metered", typeof seconds === "number" && seconds >= 0);
}

{
  // cap denial: without caps:fetch + network, the sandbox strips fetch —
  // an entrypoint reaching for it fails INSIDE the sandbox, honestly.
  const env = { bridgeJobId: "bj-cap", image: "js:x",
                entrypoint: "async (i) => { try { await fetch('http://x'); return 'leaked'; } catch { return 'no fetch'; } }",
                inputHash: "in:x", caps: [], network: false };
  const { result } = await L.runEnvelope(env, null);
  check("no fetch cap → the sandbox has no fetch", result === "no fetch",
        `got ${result}`);
}

{
  // timeout: a job that never yields is killed at the deadline — the
  // lender owes no receipt for a run it can't complete
  const env = { bridgeJobId: "bj-loop", image: "js:x",
                entrypoint: "(i) => { while (true) {} }", inputHash: "in:x",
                caps: [], network: false };
  const err = await L.runEnvelope(env, null, { timeoutMs: 300 })
    .then(() => null).catch(e => e.message);
  check("a non-yielding job is killed at the deadline",
        /timeout/.test(err), err || "no error");
}

console.log("\n── wasm: — the deterministic WASI shim runs a real module ──");

{
  // a hand-encoded module exporting run(): i32.const 42 — exercises
  // instantiate + export dispatch without needing _start
  const runMod = Uint8Array.from([
    0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00,
    0x01,0x05,0x01,0x60,0x00,0x01,0x7f,        // type: () -> i32
    0x03,0x02,0x01,0x00,                       // func: type 0
    0x07,0x07,0x01,0x03,0x72,0x75,0x6e,0x00,0x00, // export "run" func 0
    0x0a,0x06,0x01,0x04,0x00,0x41,0x2a,0x0b,   // code: i32.const 42; end
  ]);
  const env = { bridgeJobId: "bj-wasm", image: "wasm:data:unused",
                entrypoint: "run", inputHash: "in:x", caps: [], network: false };
  // wasmBytes reads image — data: ref: put the b64 in the image string
  env.image = "wasm:data:," + Buffer.from(runMod).toString("base64");
  const { result } = await L.runEnvelope(env, null);
  check("a non-_start export returns its scalar", result === 42, `got ${result}`);
}

{
  // the WASI path: _start writes "hi" to fd 1 through the deterministic
  // preview1 imports (fd_write over iov[0] = {ptr:16, len:2}, "hi" @16)
  const wasi = Uint8Array.from([
    0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00,
    0x01,0x0c,0x02,0x60,0x00,0x00,0x60,0x04,0x7f,0x7f,0x7f,0x7f,0x01,0x7f,
    0x02,0x23,0x01,0x16,0x77,0x61,0x73,0x69,0x5f,0x73,0x6e,0x61,0x70,
    0x73,0x68,0x6f,0x74,0x5f,0x70,0x72,0x65,0x76,0x69,0x65,0x77,0x31,
    0x08,0x66,0x64,0x5f,0x77,0x72,0x69,0x74,0x65,0x00,0x01,
    0x03,0x02,0x01,0x00,
    0x05,0x03,0x01,0x00,0x01,
    0x07,0x13,0x02,0x06,0x6d,0x65,0x6d,0x6f,0x72,0x79,0x02,0x00,
    0x06,0x5f,0x73,0x74,0x61,0x72,0x74,0x00,0x01,
    0x0a,0x0f,0x01,0x0d,0x00,0x41,0x01,0x41,0x00,0x41,0x01,0x41,0x08,
    0x10,0x00,0x1a,0x0b,
    0x0b,0x15,0x02,0x00,0x41,0x00,0x0b,0x08,0x10,0x00,0x00,0x00,0x02,
    0x00,0x00,0x00,0x00,0x41,0x10,0x0b,0x02,0x68,0x69,
  ]);
  const env = { bridgeJobId: "bj-wasi",
                image: "wasm:data:," + Buffer.from(wasi).toString("base64"),
                entrypoint: "_start", inputHash: "in:x",
                caps: [], network: false };
  const a = await L.runEnvelope(env, null);
  const b = await L.runEnvelope(env, null);
  check("the WASI module writes its bytes through the shim",
        a.result === "hi", `got ${JSON.stringify(a.result)}`);
  check("same module + same input + same seed → same stdout, 'exact",
        JSON.stringify(a.result) === JSON.stringify(b.result));
}

console.log(`\n── results: ${pass} passed, ${fail} failed ──`);
process.exit(fail ? 1 : 0);
