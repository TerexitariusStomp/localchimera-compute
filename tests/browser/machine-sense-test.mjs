// tests/browser/machine-sense-test.mjs — the sense and bundle kinds,
// the gpu gate, and the lend policy — tested.
//
// machine-sense.js: the tab as instrument — params.sources names the
// sensors, each tick reads what the platform answers, and a source that
// can't answer lands in unavailable, never fabricated. Meter: 'readings.
//
// machine-bundle.js: params.legs run in order; the receipt meters
// 'seconds (the only honest cross-kind sum) and binds the per-leg
// meters in the result it hashes.
//
// machine-executor.js's policyHold: a hidden tab, a metered connection,
// or a low unplugged battery holds the lend loop — claimed-on-deadline
// capacity this node can't deliver is a lie the offer told.
//
// Run: node tests/browser/machine-sense-test.mjs

import { Worker as NodeWorker } from "node:worker_threads";
import { Blob as NodeBlob } from "node:buffer";
import { fakeIndexedDB } from "./fakes.mjs";

let pass = 0, fail = 0;
const check = (label, ok, extra = "") => {
  ok ? pass++ : fail++;
  console.log(`  ${ok ? "✓" : "✗"} ${label}${extra ? " — " + extra : ""}`);
};
const throws = async (label, fn, match) => {
  try { await fn(); check(label, false, "no throw"); }
  catch (e) { check(label, match.test(e.message), e.message); }
};

// ── the device: a navigator/document/IDB with dials the test turns ──────
const dials = {
  battery: { charging: false, level: 0.5 },
  connection: { downlink: 42, rtt: 30, effectiveType: "4g", saveData: false },
  estimate: { quota: 1e9, usage: 2e6 },
  cores: 8, memGB: 8, gpu: { requestAdapter: async () => ({}) },
  visibility: "visible", focused: true, userActive: true,
  getBattery: true,
};
const resetNav = () => {
  Object.defineProperty(globalThis, "navigator", {
    value: {
      ...(dials.getBattery ? { getBattery: async () => dials.battery } : {}),
      connection: dials.connection,
      storage: { estimate: async () => dials.estimate },
      hardwareConcurrency: dials.cores,
      deviceMemory: dials.memGB,
      gpu: dials.gpu,
      userActivation: { isActive: dials.userActive },
    },
    configurable: true,
  });
  globalThis.document = {
    visibilityState: dials.visibility,
    hasFocus: () => dials.focused,
  };
};
resetNav();
globalThis.indexedDB = fakeIndexedDB();

// worker shim — the exec leg runs the real prelude (see executor test)
const blobSources = new Map();
let blobN = 0;
globalThis.Blob = NodeBlob;
URL.createObjectURL = (b) => { const u = `blob:n-${blobN++}`; blobSources.set(u, b.text()); return u; };
URL.revokeObjectURL = () => {};
globalThis.Worker = class {
  constructor(url) {
    const codeP = blobSources.get(url);
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
    this._queue = []; this.onmessage = null; this.onerror = null;
  }
  postMessage(m) { this._queue.push(m);
    this._ready.then(() => { const q = this._queue.splice(0); for (const x of q) this._w.postMessage(x); }); }
  terminate() { return this._ready.then(() => this._w && this._w.terminate()); }
};

const S = await import("../../browser/app/machine-sense.js");
const B = await import("../../browser/app/machine-bundle.js");
const X = await import("../../browser/app/machine-executor.js");
const receipts = [];
const seam = { machineReceipt: async (_c, j) => { receipts.push(JSON.parse(j)); return { ok: 1 }; } };

// ── the sources — what the platform answers, and the holes ──────────────
{
  const r = await S.readOnce({ params: { sources: ["battery", "network", "machine", "presence"] } });
  check("four sources read", r.readings.length === 4, `${r.readings.length}`);
  const bat = r.readings.find(x => x.source === "battery");
  check("the battery reading is the platform's answer",
        bat.value.charging === false && bat.value.level === 0.5);
  const pres = r.readings.find(x => x.source === "presence");
  check("presence reports visibility + activity",
        pres.value.visibility === "visible" && pres.value.userActive === true);
  check("no holes to report", r.unavailable.length === 0);
}
{
  dials.getBattery = false; resetNav();
  const r = await S.readOnce({ params: { sources: ["battery", "machine"] } });
  check("a source the platform lacks lands in unavailable",
        r.unavailable.length === 1 && r.unavailable[0].source === "battery");
  check("…and the readable source still reads",
        r.readings.length === 1 && r.readings[0].source === "machine");
  dials.getBattery = true; resetNav();
}
await throws("an unnamed source is an error, not a null reading",
  () => S.readOnce({ params: { sources: ["smell"] } }), /unknown source/);
await throws("no sources is no instrument",
  () => S.readOnce({ params: {} }), /sources/);

// ── the claim — N ticks meter N×sources readings ────────────────────────
{
  receipts.length = 0;
  await S.runSenseClaim(seam, "home", "claim-sense",
    { kind: "sense", inputHash: "in:s",
      params: { sources: ["machine", "network"], count: 3, intervalMs: 250 } },
    "did:lender");
  check("three ticks × two sources meter six readings",
        receipts[0].usage.unit === "readings" && receipts[0].usage.amount === 6,
        `${receipts[0].usage.amount}`);
  check("the report's hash binds the readings",
        /^[0-9a-f]{64}$/.test(receipts[0].outputHash));
}

// ── the gpu gate — a cap the platform can't honor refuses ───────────────
{
  dials.gpu = null; resetNav();
  await throws("webgpu cap, no adapter → fail closed",
    () => X.runEnvelope({ image: "js:x", entrypoint: "(i)=>i", inputHash: "i",
                          caps: ["webgpu"], network: false }, null),
    /adapter|gpu/i);
  dials.gpu = { requestAdapter: async () => null }; resetNav();
  await throws("a null adapter is no adapter",
    () => X.runEnvelope({ image: "js:x", entrypoint: "(i)=>i", inputHash: "i",
                          caps: ["webgpu"], network: false }, null),
    /adapter/i);
  dials.gpu = { requestAdapter: async () => ({}) }; resetNav();
  const { result } = await X.runEnvelope(
    { image: "js:x", entrypoint: "(i)=>i*3", inputHash: "i",
      caps: ["webgpu"], network: false }, 7);
  check("an adapter present → the run proceeds", result === 21);
}

// ── the bundle — legs in order, meters bound in the report ──────────────
await throws("a bundle without legs is not a job",
  () => B.runBundleClaim(seam, "home", "c", { kind: "bundle", params: {} }, "d"),
  /legs/);
await throws("a bundle does not bundle bundles",
  () => B.runBundleClaim(seam, "home", "c",
    { kind: "bundle", params: { legs: [{ kind: "bundle" }] } }, "d"),
  /does not bundle/);
await throws("an unknown leg kind names its index",
  () => B.runBundleClaim(seam, "home", "c",
    { kind: "bundle", params: { legs: [{ kind: "exec", image: "js:", entrypoint: "(i)=>i" },
                                       { kind: "levitate" }] } }, "d"),
  /leg 1.*unknown kind/);

{
  receipts.length = 0;
  globalThis.fetch = async () =>
    ({ ok: true, status: 200, arrayBuffer: async () => new TextEncoder().encode("abcd").buffer });
  await B.runBundleClaim(seam, "home", "claim-bundle",
    { kind: "bundle", inputHash: "in:b",
      params: { legs: [
        { kind: "exec", image: "js:", entrypoint: "(i) => (i ?? 0) + 5" },
        { kind: "sense", params: { sources: ["machine"], count: 2, intervalMs: 250 } },
        { kind: "relay", network: true, caps: ["fetch"], params: { inUrl: "https://in" } },
      ] } },
    "did:lender", { input: 35 });
  const r = receipts[0];
  check("the bundle meters seconds — the honest cross-kind sum",
        r.usage.unit === "seconds" && r.usage.amount >= 0);
  check("the legs' report is the bound output",
        /^[0-9a-f]{64}$/.test(r.outputHash));
  // the wire carries the hash; the legs report is its preimage — runLegs
  // is what a verifier re-runs to see the per-leg meters
  const legs = await B.runLegs(
    { kind: "bundle", inputHash: "in:b",
      params: { legs: [
        { kind: "exec", image: "js:", entrypoint: "(i) => (i ?? 0) + 5" },
        { kind: "sense", params: { sources: ["machine"], count: 2, intervalMs: 250 } },
        { kind: "relay", network: true, caps: ["fetch"], params: { inUrl: "https://in" } },
      ] } },
    seam, "home", "claim-bundle", { input: 35 });
  check("three legs reported, in order",
        legs.length === 3 && legs[0].kind === "exec"
        && legs[1].kind === "sense" && legs[2].kind === "relay");
  check("the exec leg metered seconds",
        legs[0].usage.unit === "seconds");
  check("the sense leg metered its readings",
        legs[1].usage.unit === "readings" && legs[1].usage.amount === 2);
  check("the relay leg metered its bytes",
        legs[2].usage.unit === "bytes" && legs[2].usage.amount === 4);
  check("the exec leg's note carries its result", legs[0].note === 40);

  // a store leg: holds for its duration, meters the byte-seconds delta
  const storeLegs = await B.runLegs(
    { kind: "bundle", inputHash: "in:sb",
      params: { legs: [
        { kind: "store", inputHash: "deadbeef",
          params: { contentB64: btoa("held bytes"), durationMs: 30 } },
      ] } },
    seam, "home", "claim-sb", {});
  check("the store leg meters byte-seconds, not the meter's lifetime",
        storeLegs[0].usage.unit === "byte-seconds"
        && storeLegs[0].usage.amount > 0 && storeLegs[0].usage.amount < 60,
        `${storeLegs[0].usage.amount}`);
  const after = await (await import("../../browser/app/machine-store.js")).getContent("deadbeef");
  check("the leg evicts what it held — no residue", after === null);
}
{
  const claims = async () => [{ claimId: "c1", lenderDid: "did:lender", state: "claimed" }];
  const mkSeam = () => ({
    machineClaims: claims,
    machineFetchEnvelope: async () => JSON.stringify({ image: "js:", entrypoint: "(i)=>i", inputHash: "i" }),
    machineReceipt: async () => ({ ok: 1 }),
  });
  const holdFor = async (policy) => {
    const events = [];
    const stop = X.lendLoop(mkSeam(), "home", "did:lender", {}, {
      policy, intervalMs: 15, onPolicy: (w) => events.push(w) });
    await new Promise(r => setTimeout(r, 60));
    stop();
    return events;
  };

  dials.visibility = "hidden"; resetNav();
  const hidden = await holdFor({ pauseWhenHidden: true });
  check("a hidden tab holds the loop", hidden.includes("hidden"));

  dials.visibility = "visible"; dials.connection.saveData = true; resetNav();
  const sd = await holdFor({ pauseOnSaveData: true });
  check("a metered connection holds the loop", sd.includes("save-data"));
  dials.connection.saveData = false;

  dials.battery = { charging: false, level: 0.1 }; resetNav();
  const bat = await holdFor({ minBatteryLevel: 0.2 });
  check("an unplugged low battery holds the loop", bat.includes("battery"));

  dials.battery = { charging: true, level: 0.1 }; resetNav();
  const chg = await holdFor({ minBatteryLevel: 0.2 });
  check("charging at the same level is no hold",
        chg.length === 0 || chg[0] === null, JSON.stringify(chg));

  dials.battery = { charging: false, level: 0.9 }; resetNav();
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
