// SPDX-License-Identifier: AGPL-3.0-or-later
// tests/browser/machine-swarm-test.mjs — the shard-side runner, tested.
//
// machine-swarm.js is what a swarm leg adds to a claim: params.swarm
// resolves WHERE input comes from and WHERE output goes — deterministic
// map slices, pipeline stage chaining over the bus, quorum merge — while
// the claim's receipt, deadline and metering stay the claim's own.
//
// Pinned here, in node, through runClaim so the dispatch itself is the
// code under test:
//
//   • map — shard-index names a deterministic slice of the swarm input
//   • stage — a pipeline shard waits on the previous shard's bus post
//   • merge — sibling outputs assemble in shard order at quorum, and a
//     shard that never spoke is named honestly, not fabricated
//   • the bus — posts land on the seam's swarm doors; a non-swarm
//     envelope still routes to the plain executor
//
// Run: node tests/browser/machine-swarm-test.mjs

import { Worker as NodeWorker } from "node:worker_threads";
import { Blob as NodeBlob } from "node:buffer";
import { fakeIndexedDB } from "./fakes.mjs";

const L = await import("../../browser/app/machine-executor.js");
const S = await import("../../browser/app/machine-swarm.js");

let pass = 0, fail = 0;
const check = (label, ok, extra = "") => {
  ok ? pass++ : fail++;
  console.log(`  ${ok ? "✓" : "✗"} ${label}${extra ? " — " + extra : ""}`);
};

// the same DOM shim the executor test runs — the prelude under test is
// the real WORKER_PRELUDE, carried by a worker_thread
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

// ── the device seams the legs need: IDB for the store kind, a          ──
// navigator for the fleet's sensors, a FakePeer pair for the hop's RTC
globalThis.indexedDB = fakeIndexedDB();
Object.defineProperty(globalThis, "navigator", {
  value: {
    connection: { downlink: 42, rtt: 30, effectiveType: "4g", saveData: false },
    hardwareConcurrency: 8,
  },
  configurable: true,
});
globalThis.document = { visibilityState: "visible", hasFocus: () => true };

class FakeChannel {
  constructor() { this.peer = null; this.sent = []; }
  static pair(a, b) { a.peer = b; b.peer = a; }
  open() { queueMicrotask(() => { this.onopen?.(); this.peer?.onopen?.(); }); }
  send(d) { this.sent.push(d); queueMicrotask(() => this.peer?.onmessage?.({ data: d })); }
  close() { this.onclose?.(); this.peer?.onclose?.(); }
}
class FakePeer {
  static peers = [];
  static reset() { FakePeer.peers = []; }
  constructor() { FakePeer.peers.push(this); }
  createDataChannel() { this.out = new FakeChannel(); return this.out; }
  async createOffer() { return { type: "offer", sdp: `offer:${FakePeer.peers.indexOf(this)}` }; }
  async createAnswer() { return { type: "answer", sdp: "answer" }; }
  async setLocalDescription(d) {
    if (d.type === "offer") this.offered = d.sdp;
  }
  async setRemoteDescription(d) {
    if (d.type === "offer") {
      this.peerPc = FakePeer.peers.find(p => p !== this && p.offered === d.sdp);
      const ch = new FakeChannel();
      if (this.peerPc?.out) FakeChannel.pair(this.peerPc.out, ch);
      this.incoming = ch;
      queueMicrotask(() => this.ondatachannel?.({ channel: ch }));
    } else {
      this.out?.open();
      this.peerPc?.incoming?.open?.();
    }
  }
  async addIceCandidate() {}
  close() { this.closed = true; }
}

const sha256hexB = async (u8) =>
  [...new Uint8Array(await crypto.subtle.digest("SHA-256", u8))]
    .map(b => b.toString(16).padStart(2, "0")).join("");
const b64 = (s) => Buffer.from(s, "utf8").toString("base64");

// ── the seam double — the bus is the seq'd shelf the doors front ──────
const mkSeam = (env, log, receipts, did = "did:key:zNode") => ({
  machineFetchEnvelope: async () => env,
  machineSwarmSignal: async (_c, _g, body) => {
    log.push({ seq: log.length + 1, from: did, at: 1, body });
    return log.length;
  },
  machineSwarmSignals: async (_c, _g, after = 0) =>
    log.filter((r) => r.seq > after),
  machineReceipt: async (_c, wire) => { receipts.push(JSON.parse(wire)); return "ok:landed"; },
});

const sumEnv = (swarm) => ({
  bridgeJobId: "bj-sw", kind: "exec", image: "js:work",
  entrypoint: "(input) => Array.isArray(input) ? input.reduce((a,b)=>a+b,0) : input",
  inputHash: "in:sw", caps: [], network: false,
  params: swarm ? { swarm } : {},
});

const OPTS = { busPollMs: 5, busDeadlineMs: 800 };

console.log("\n── map — the shard-index IS the slice assignment ──");

{
  const log = [], receipts = [];
  const env = sumEnv({ group: "sw-1", shards: 3, "shard-index": 1, role: "map" });
  await L.runClaim(mkSeam(env, log, receipts), "home", "claim-m1",
                   "did:key:zNode", [1, 2, 3, 4, 5, 6], OPTS);
  const post = log.find((r) => r.body?.type === "shard-output");
  check("the shard posted its result on the bus", !!post);
  // 6 elements / 3 shards → shard 1 owns elements [3,4] → 3+4 = 7
  check("the slice is the deterministic middle third", post?.body?.output === 7,
        `got ${post?.body?.output}`);
  check("the post names its shard", post?.body?.shard === 1 && post?.body?.of === 3);
  check("the claim's own receipt landed", receipts.length === 1
        && receipts[0].bridgeJobId === "claim-m1");

  // determinism: the same envelope + input must slice identically
  const log2 = [], r2 = [];
  await L.runClaim(mkSeam(env, log2, r2), "home", "claim-m1b",
                   "did:key:zNode", [1, 2, 3, 4, 5, 6], OPTS);
  const post2 = log2.find((r) => r.body?.type === "shard-output");
  check("same envelope + same input → the same slice, every time",
        post2?.body?.outputHash === post?.body?.outputHash);
}

console.log("\n── stage — a pipeline shard's input is the previous post ──");

{
  const log = [], receipts = [];
  const env0 = sumEnv({ group: "sw-pipe", shards: 2, "shard-index": 0, role: "stage" });
  const env1 = { ...sumEnv({ group: "sw-pipe", shards: 2, "shard-index": 1, role: "stage" }),
                 entrypoint: "(input) => input * 10" };
  // shard 0 runs on the raw swarm input; shard 1 consumes its bus post
  await L.runClaim(mkSeam(env0, log, receipts), "home", "claim-s0",
                   "did:key:zNode", 5, OPTS);
  const p0 = log.find((r) => r.body?.type === "shard-output");
  check("shard 0's output hit the bus", p0?.body?.output === 5, `got ${p0?.body?.output}`);

  await L.runClaim(mkSeam(env1, log, receipts), "home", "claim-s1",
                   "did:key:zNode2", 99 /* ignored — the pipe feeds it */, OPTS);
  const p1 = log.filter((r) => r.body?.type === "shard-output").pop();
  check("shard 1 ran on shard 0's output, not its own input",
        p1?.body?.output === 50, `got ${p1?.body?.output}`);
}

{
  // a stage that never sees its predecessor posts refuses honestly —
  // the deadline falls, the claim mints no fabricated receipt
  const log = [], receipts = [];
  const env = sumEnv({ group: "sw-pipe2", shards: 2, "shard-index": 1, role: "stage" });
  const err = await L.runClaim(mkSeam(env, log, receipts), "home", "claim-sx",
                               "did:key:zNode2", 99, { busPollMs: 5, busDeadlineMs: 120 })
    .then(() => null).catch((e) => e.message);
  check("a silent predecessor fails the claim, honestly",
        /never posted/.test(err) && receipts.length === 0, err || "no error");
}

console.log("\n── merge — the siblings assemble in shard order ──");

{
  const log = [], receipts = [];
  // two sibling map shards already posted; the merge leg is shard 2
  const seam = mkSeam(
    { ...sumEnv({ group: "sw-m", shards: 3, "shard-index": 2, role: "merge" }),
      entrypoint: "(input) => input.reduce((a,b)=>a+b,0)" }, log, receipts);
  await seam.machineSwarmSignal("home", "sw-m",
    { type: "shard-output", shard: 0, of: 3, role: "map", outputHash: "h0", output: 10 });
  await seam.machineSwarmSignal("home", "sw-m",
    { type: "shard-output", shard: 1, of: 3, role: "map", outputHash: "h1", output: 20 });
  await L.runClaim(seam, "home", "claim-mg", "did:key:zMerge", null, OPTS);
  const post = log.filter((r) => r.body?.type === "shard-output").pop();
  check("the merge assembled the siblings' sum", post?.body?.output === 30,
        `got ${post?.body?.output}`);
  check("a full house names no partial", !post?.body?.partial);
  check("the merge's receipt binds the aggregate",
        receipts.length === 1 && receipts[0].bridgeJobId === "claim-mg");
}

{
  // quorum short of the fan-out: one silent shard is named in partial —
  // the merge still answers, honestly incomplete
  const log = [], receipts = [];
  const seam = mkSeam(
    { ...sumEnv({ group: "sw-q", shards: 3, "shard-index": 2, role: "merge",
                  quorum: 1 }),
      entrypoint: "(input) => input.reduce((a,b)=>a+b,0)" }, log, receipts);
  await seam.machineSwarmSignal("home", "sw-q",
    { type: "shard-output", shard: 0, of: 3, role: "map", outputHash: "h0", output: 7 });
  await L.runClaim(seam, "home", "claim-mq", "did:key:zMerge", null, OPTS);
  const post = log.filter((r) => r.body?.type === "shard-output").pop();
  check("quorum:1 proceeds on the one sibling that spoke",
        post?.body?.output === 7, `got ${post?.body?.output}`);
  check("the silent shard is named, not hidden",
        JSON.stringify(post?.body?.partial) === "[1]", JSON.stringify(post?.body?.partial));
}

{
  // nobody spoke at all → the deadline falls; the merge reports every
  // missing shard rather than inventing an aggregate
  const log = [], receipts = [];
  const seam = mkSeam(
    { ...sumEnv({ group: "sw-e", shards: 3, "shard-index": 2, role: "merge" }),
      entrypoint: "(input) => input.length" }, log, receipts);
  await L.runClaim(seam, "home", "claim-me", "did:key:zMerge", null,
                   { busPollMs: 5, busDeadlineMs: 120 });
  const post = log.filter((r) => r.body?.type === "shard-output").pop();
  check("an empty bus merges to the empty aggregate",
        post?.body?.output === 0, `got ${post?.body?.output}`);
  check("every silent shard is named",
        JSON.stringify(post?.body?.partial) === "[0,1]", JSON.stringify(post?.body?.partial));
}

console.log("\n── stripe — a store shard announces 'held' on the bus ──");

{
  const log = [], receipts = [];
  const stripe = new TextEncoder().encode("stripe-0-of-2");
  const env = { bridgeJobId: "bj-st", kind: "store",
                inputHash: await sha256hexB(stripe),
                caps: [], network: false,
                params: { contentB64: b64("stripe-0-of-2"), ttlSeconds: 0.05,
                          swarm: { group: "sw-st", shards: 2, "shard-index": 0,
                                   role: "stripe" } } };
  await L.runClaim(mkSeam(env, log, receipts), "home", "claim-st0",
                   "did:key:zStore", null, OPTS);
  const post = log.find((r) => r.body?.type === "shard-output");
  check("the stripe announced itself held", post?.body?.role === "stripe"
        && post?.body?.contentHash === env.inputHash);
  check("the stripe's own receipt still landed, byte-seconds metered",
        receipts.length === 1 && receipts[0].usage?.unit === "byte-seconds",
        JSON.stringify(receipts[0]?.usage));
}

console.log("\n── hop — the link's signaling rides the bus, not a claim log ──");

{
  FakePeer.reset();
  const log = [], receipts = [];
  const PAYLOAD = "hop-payload";
  const base = { kind: "relay", inputHash: "in:hop", caps: [], network: false };
  // the borrower names the shared link — shard 0 offers, shard 1 answers
  const offerEnv = { ...base, bridgeJobId: "bj-h0",
                     params: { channel: true, role: "offer", direction: "send",
                               contentB64: b64(PAYLOAD),
                               swarm: { group: "sw-h", shards: 2,
                                        "shard-index": 0, role: "hop",
                                        link: "hop:0" } } };
  const answerEnv = { ...base, bridgeJobId: "bj-h1",
                      params: { channel: true, role: "answer", direction: "recv",
                                swarm: { group: "sw-h", shards: 2,
                                         "shard-index": 1, role: "hop",
                                         link: "hop:0" } } };
  const s0 = mkSeam(offerEnv, log, receipts, "did:key:zH0");
  const s1 = mkSeam(answerEnv, log, receipts, "did:key:zH1");
  const RTC_OPTS = { ...OPTS, RTCPeerConnection: FakePeer, pollMs: 5,
                     silenceMs: 200, timeoutMs: 3000 };
  await Promise.all([
    L.runClaim(s0, "home", "claim-h0", "did:key:zH0", null,
               { ...RTC_OPTS, who: "did:key:zH0" }),
    L.runClaim(s1, "home", "claim-h1", "did:key:zH1", null,
               { ...RTC_OPTS, who: "did:key:zH1" }),
  ]);
  const sigs = log.filter((r) => r.body?.hopLink === "hop:0");
  check("the offer rode the swarm bus under the link's tag",
        sigs.some((r) => r.body?.type === "offer"));
  check("the answer rode the same tagged link",
        sigs.some((r) => r.body?.type === "answer"));
  check("the carried bytes crossed the channel",
        receipts.some((r) => r.usage?.unit === "bytes" && r.usage?.amount > 0),
        JSON.stringify(receipts.map((r) => r.usage)));
  const deliver = receipts.find((r) => r.outputHash);
  check("the receiving hop's outputHash binds the delivered bytes",
        deliver?.outputHash === await sha256hexB(new TextEncoder().encode(PAYLOAD)));
}

console.log("\n── fleet — a sense shard's readings post for the merge ──");

{
  const log = [], receipts = [];
  const env = { bridgeJobId: "bj-fl", kind: "sense",
                inputHash: "in:fl", caps: [], network: false,
                params: { sources: ["network"], intervalMs: 250, count: 1,
                          swarm: { group: "sw-fl", shards: 3, "shard-index": 0,
                                   role: "fleet" } } };
  await L.runClaim(mkSeam(env, log, receipts), "home", "claim-f0",
                   "did:key:zSense", null, OPTS);
  const post = log.find((r) => r.body?.type === "shard-output");
  check("the fleet shard posted its readings hash",
        post?.body?.role === "fleet" && typeof post?.body?.outputHash === "string",
        JSON.stringify(post?.body));
  check("the sense claim's own receipt still landed",
        receipts.length === 1 && receipts[0].usage?.unit === "readings",
        JSON.stringify(receipts[0]?.usage));
}

console.log("\n── dispatch — only a params.swarm envelope routes here ──");

{
  const receipts = [];
  const seam = {
    machineFetchEnvelope: async () => sumEnv(null),
    machineReceipt: async (_c, wire) => { receipts.push(JSON.parse(wire)); return "ok"; },
  };
  await L.runClaim(seam, "home", "claim-plain", "did:key:zN", [2, 3], OPTS);
  check("a plain exec envelope still runs on the executor",
        receipts.length === 1 && receipts[0].bridgeJobId === "claim-plain");
  check("runSwarmClaim on a non-swarm envelope defers",
        (await S.runSwarmClaim(seam, "home", "c", sumEnv(null), "d", null)) === null);
}

console.log(`\n── results: ${pass} passed, ${fail} failed ──`);
process.exit(fail ? 1 : 0);
