// tests/browser/machine-relay-test.mjs — the relay kind's node, tested.
//
// machine-relay.js moves bytes and meters them: the HTTP leg (inUrl →
// outUrl, fetch-cap gated), the WebRTC DataChannel leg negotiated through
// the claim's own signal log, and the canary probe. A FakePeer pair wires
// the two ends through the fake seam's signal log exactly as two browser
// tabs would — the test is the rendezvous working, not a stub that says so.
//
// Run: node tests/browser/machine-relay-test.mjs

let pass = 0, fail = 0;
const check = (label, ok, extra = "") => {
  ok ? pass++ : fail++;
  console.log(`  ${ok ? "✓" : "✗"} ${label}${extra ? " — " + extra : ""}`);
};
const throws = async (label, fn, match) => {
  try { await fn(); check(label, false, "no throw"); }
  catch (e) { check(label, match.test(e.message), e.message); }
};

// ── the fake seam: a signal log + a receipt trap ──────────────────────────
// One log both ends post to — the door's role (stamp from/seq) played by
// the seam fake since the Scheme side is already tested apart.
const mkSeam = (did, log, receipts) => ({
  machineSignal: async (_c, _id, body) => {
    const row = { seq: log.length + 1, from: did, at: 1, body };
    log.push(row);
    return { ok: row.seq };
  },
  machineSignals: async (_c, _id, after = 0) => log.filter(r => r.seq > after),
  machineReceipt: async (_c, json) => { receipts.push(JSON.parse(json)); return { ok: true }; },
});

// ── the fake peer ─────────────────────────────────────────────────────────
// An offer sdp carries its maker's index; setRemoteDescription(offer) pairs
// this peer's answering channel with the offerer's outbound one; the answer
// opening both channels is what a connected ICE pair does for real.
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
  async setLocalDescription(d) { if (d.type === "offer") this.offered = d.sdp; }
  async setRemoteDescription(d) {
    if (d.type === "offer") {
      this.peerPc = FakePeer.peers.find(p => p !== this && p.offered === d.sdp);
      const ch = new FakeChannel();
      if (this.peerPc?.out) FakeChannel.pair(this.peerPc.out, ch);
      this.incoming = ch;
      queueMicrotask(() => this.ondatachannel?.({ channel: ch }));
    } else {
      this.out?.open();            // offerer: the answer connects both ends
      this.peerPc?.incoming?.open?.();
    }
  }
  async addIceCandidate() {}
  close() { this.closed = true; }
}

const sha256hex = async (u8) =>
  [...new Uint8Array(await crypto.subtle.digest("SHA-256", u8))]
    .map(b => b.toString(16).padStart(2, "0")).join("");
const b64 = (s) => Buffer.from(s, "utf8").toString("base64");

const R = await import("../../browser/app/machine-relay.js");
const X = await import("../../browser/app/machine-executor.js");

// ── the fetch cap — no grant, no wire ─────────────────────────────────────
await throws("an ungranted envelope cannot fetch",
  () => R.probe({ params: { inUrl: "https://x" }, probe: true }),
  /fetch cap/);
await throws("network:true without the cap is not a grant",
  () => R.probe({ network: true, caps: ["wasm"], params: { inUrl: "https://x" } }),
  /fetch cap/);
await throws("the HTTP leg wants the same grant",
  () => R.httpLeg({ params: { inUrl: "https://x" } }),
  /fetch cap/);
await throws("the HTTP leg needs an inUrl",
  () => R.httpLeg({ network: true, caps: ["fetch"], params: {} }),
  /inUrl/);
await throws("a probe needs an inUrl",
  () => R.probe({ network: true, caps: ["fetch"], probe: true, params: {} }),
  /inUrl/);

// ── the HTTP leg — bytes in, bytes out, both metered ──────────────────────
{
  const PAYLOAD = new TextEncoder().encode("throughput");
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url, method: init.method ?? "GET" });
    return { ok: true, status: 200, arrayBuffer: async () => PAYLOAD.buffer.slice(0) };
  };
  const env = { network: true, caps: ["fetch"], inputHash: "in:r",
                params: { inUrl: "https://in", outUrl: "https://out" } };
  const leg = await R.httpLeg(env);
  check("the leg fetched then posted",
        calls.length === 2 && calls[0].method === "GET" && calls[1].method === "POST");
  check("both crossings meter",
        leg.moved === PAYLOAD.byteLength * 2, `${leg.moved} vs ${PAYLOAD.byteLength * 2}`);
  check("the carried bytes hash for the proof",
        await sha256hex(leg.bytes) === await sha256hex(PAYLOAD));

  const receipts = [];
  const seam = { machineReceipt: async (_c, j) => { receipts.push(JSON.parse(j)); return { ok: 1 }; } };
  await R.runRelayClaim(seam, "home", "claim-http", env, "did:lender");
  check("the receipt meters bytes",
        receipts[0].usage.unit === "bytes" && receipts[0].usage.amount === PAYLOAD.byteLength * 2);
  check("the receipt's outputHash is the carried digest",
        receipts[0].outputHash === await sha256hex(PAYLOAD));
  check("a relay receipt carries no engine",
        receipts[0].engine === null);

  // a sink-only leg — bytes in, nothing onward
  const sink = await R.httpLeg({ network: true, caps: ["fetch"], params: { inUrl: "https://in" } });
  check("a sink leg meters what it drank", sink.moved === PAYLOAD.byteLength);

  // upstream 5xx fails the leg
  globalThis.fetch = async () => ({ ok: false, status: 503 });
  await throws("a failed upstream fails the leg",
    () => R.httpLeg(env), /503/);
}

// ── the canary — a timed fetch whose result IS the report ─────────────────
{
  globalThis.fetch = async () =>
    ({ ok: true, status: 200, arrayBuffer: async () => new TextEncoder().encode("abcd").buffer });
  const receipts = [];
  const seam = { machineReceipt: async (_c, j) => { receipts.push(JSON.parse(j)); return { ok: 1 }; } };
  await R.runRelayClaim(seam, "home", "claim-probe",
    { network: true, caps: ["fetch"], params: { probe: true, inUrl: "https://x" } },
    "did:lender");
  check("the canary meters what it measured",
        receipts[0].usage.unit === "bytes" && receipts[0].usage.amount === 4);
}

// ── the channel leg — two ends through the claim's own log ────────────────
{
  await throws("no RTCPeerConnection fails closed, not silent",
    () => R.runRelayClaim(mkSeam("did:a", [], []), "home", "c",
      { params: { channel: true } }, "did:a", { RTCPeerConnection: undefined }),
    /unavailable|timed out/);

  FakePeer.reset();
  const log = [], rSend = [], rRecv = [];
  const offerer = R.runRelayClaim(
    mkSeam("did:a", log, rSend), "home", "claim-ch",
    { params: { channel: true, role: "offer", direction: "send",
                contentB64: b64("hello relay") } },
    "did:a", { RTCPeerConnection: FakePeer, who: "did:a", pollMs: 2, silenceMs: 20 });
  const answerer = R.runRelayClaim(
    mkSeam("did:b", log, rRecv), "home", "claim-ch",
    { params: { channel: true, role: "answer", direction: "recv" } },
    "did:b", { RTCPeerConnection: FakePeer, who: "did:b", pollMs: 2, silenceMs: 20 });
  await Promise.all([offerer, answerer]);

  check("the offer and answer crossed the claim's log",
        log.some(r => r.body.type === "offer") && log.some(r => r.body.type === "answer"));
  check("each row carries its stamped sender",
        log.every(r => typeof r.seq === "number" && typeof r.from === "string"));
  const expectHash = await sha256hex(new TextEncoder().encode("hello relay"));
  check("the sender meters what it sent",
        rSend[0].usage.amount === 11 && rSend[0].usage.unit === "bytes", `${rSend[0].usage.amount}`);
  check("the receiver meters what arrived",
        rRecv[0].usage.amount === 11, `${rRecv[0].usage.amount}`);
  check("the delivery proof is the received digest",
        rRecv[0].outputHash === expectHash);
  // a send end carried nothing back — its outputHash binds the result
  // report instead of a content digest it can't honestly claim
  check("the send end's hash binds its report, not phantom content",
        /^[0-9a-f]{64}$/.test(rSend[0].outputHash)
        && rSend[0].outputHash !== expectHash);

  // a stranded offerer: posts into the log, nobody answers — honest timeout
  FakePeer.reset();
  const deadLog = [];
  await throws("an unanswered offer times out",
    () => R.runRelayClaim(mkSeam("did:a", deadLog, []), "home", "claim-lonely",
      { params: { channel: true, role: "offer", direction: "send", contentB64: b64("x") } },
      "did:a", { RTCPeerConnection: FakePeer, who: "did:a", pollMs: 2, timeoutMs: 30 }),
    /timed out/);
}

// ── the dispatch — runClaim routes 'relay to the leg, not the worker ──────
{
  const PAYLOAD = new TextEncoder().encode("z");
  globalThis.fetch = async () =>
    ({ ok: true, status: 200, arrayBuffer: async () => PAYLOAD.buffer.slice(0) });
  const receipts = [];
  const seam = {
    machineFetchEnvelope: async () => JSON.stringify({
      kind: "relay", network: true, caps: ["fetch"], inputHash: "in:d",
      params: { inUrl: "https://in" } }),
    machineReceipt: async (_c, j) => { receipts.push(JSON.parse(j)); return { ok: 1 }; },
  };
  await X.runClaim(seam, "home", "claim-dispatch", "did:lender", {});
  check("runClaim dispatched the relay leg",
        receipts.length === 1 && receipts[0].usage.unit === "bytes");
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
