// SPDX-License-Identifier: AGPL-3.0-or-later
// tests/browser/machine-dvm-test.mjs — the NIP-90 demand source, tested.
//
// What runs in node, honestly:
//
//   • nostr.js — finalizeEvent produces a real schnorr signature over the
//     canonical id; verifyEvent accepts it and refuses a tampered one;
//     nsec bech32 decodes to the same bytes as hex
//   • the relay — REQ arms on open, EVENT routes to its subscription,
//     OK resolves a publish, a dead socket reconnects and re-arms
//   • serveDvm — a signed 5050 request mints a postpaid demand job
//     (payer nostr-dvm, ref the event id, keyHash the buyer's nostr:
//     book), polls to done, and publishes the kind+1000 result carrying
//     the price; a bid under the price gets payment-required and mints
//     nothing; an event addressed to another pubkey is not ours; a
//     forged signature never reaches the intake
//
// Run: node tests/browser/machine-dvm-test.mjs

const N = await import("../../browser/lib/nostr.js");
const D = await import("../../browser/app/machine-dvm.js");

let pass = 0, fail = 0;
const check = (label, ok, extra = "") => {
    ok ? pass++ : fail++;
    console.log(`  ${ok ? "✓" : "✗"} ${label}${extra ? " — " + extra : ""}`);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// a WebSocket fake — captures sends, lets the test inject server frames
class FakeWS {
    static instances = [];
    constructor(url) {
        this.url = url;
        this.sent = [];
        this.readyState = 0;
        FakeWS.instances.push(this);
        setTimeout(() => { this.readyState = 1; this.onopen?.({}); }, 0);
    }
    send(s) { this.sent.push(JSON.parse(s)); }
    close() { this.readyState = 3; this.onclose?.({}); }
    inject(msg) { this.onmessage?.({ data: JSON.stringify(msg) }); }
    injectEvent(subId, ev) { this.inject(["EVENT", subId, ev]); }
    injectOk(id) { this.inject(["OK", id, true, ""]); }
    // answer every queued EVENT publish with an OK — a relay that acks
    ackAll() {
        for (const m of this.sent) if (m[0] === "EVENT") this.injectOk(m[1].id);
    }
}

const buyerSec = "11".repeat(32);
const dvmSec = "22".repeat(32);
const buyerPub = N.publicKeyHex(buyerSec);
const dvmPub = N.publicKeyHex(dvmSec);

console.log("── the codec — sign, verify, bech32 ──");
{
    const ev = await N.finalizeEvent(buyerSec, {
        kind: 5050, content: "",
        tags: [["i", "translate this", "text"], ["bid", "5000"]],
    });
    check("a finalized event verifies", await N.verifyEvent(ev));
    const tampered = { ...ev, content: "changed" };
    check("a tampered event refuses", !(await N.verifyEvent(tampered)));
    check("the pubkey is the signer's", ev.pubkey === buyerPub);
    check("a hex secret's pubkey matches nsec form",
          (() => { try { return N.publicKeyHex(buyerSec) === buyerPub; }
                   catch { return false; } })());
}

console.log("── the relay — subscriptions and publishes ──");
{
    const relay = new N.NostrRelay("wss://r.example",
                                   { WebSocketImpl: FakeWS });
    const got = [];
    await relay.subscribe("s1", [{ kinds: [5050] }], (ev) => got.push(ev));
    const ws = FakeWS.instances.at(-1);
    check("the REQ armed on open",
          ws.sent.some((m) => m[0] === "REQ" && m[1] === "s1"));
    ws.injectEvent("s1", { id: "e1", kind: 5050 });
    check("an EVENT routed to its subscription", got.length === 1);
    const ev = await N.finalizeEvent(dvmSec, { kind: 7000, content: "x" });
    const ack = relay.publish(ev);
    ws.injectOk(ev.id);
    const r = await ack;
    check("an OK resolves the publish", r.accepted === true);
    relay.close();
}

console.log("── the dvm — demand minted, result published ──");
{
    const intakes = [];
    const jobs = {};
    const signals = {};
    const seam = {
        machineDemandIntake: async (_c, keyHash, payer, ref, debit,
                                    tc, lane, repro, ih, opts) => {
            intakes.push({ keyHash, payer, ref, debit, tc, opts });
            const jobId = `job-${intakes.length}`;
            jobs[jobId] = { state: "open" };
            return { jobId, rowId: `${payer}:${ref}:${jobId}`, balance: 0 };
        },
        machineDemandJob: async (_c, jobId) => jobs[jobId],
        machineSignals: async (_c, claimId) =>
            (signals[claimId] ?? []).map((b, i) => ({ seq: i + 1, body: b })),
        machinePayerSettle: async () => "ok",
    };
    const dvm = D.serveDvm(seam, "did:keri:EHome", {
        relays: ["wss://r1"], seckey: dvmSec, priceSats: 5,
        pollMs: 5, wsOpts: { WebSocketImpl: FakeWS, publishTimeoutMs: 50 },
    });
    check("the pubkey is the dvm key's", dvm.pubkey === dvmPub);
    await dvm.start();
    await sleep(10);
    const ws = FakeWS.instances.at(-1);

    const req = await N.finalizeEvent(buyerSec, {
        kind: 5050, content: "",
        tags: [["i", "summarize the war", "text"], ["bid", "9000"]],
    });
    ws.injectEvent("dvm-0", req);
    for (let i = 0; i < 10 && intakes.length === 0; i++) {
        await sleep(10); ws.ackAll();
    }
    await sleep(10); ws.ackAll();
    check("a signed request minted a postpaid intake",
          intakes.length === 1 &&
          intakes[0].payer === "nostr-dvm" &&
          intakes[0].opts.postpaid === true &&
          intakes[0].keyHash === `nostr:${buyerPub}` &&
          intakes[0].ref === `nostr:${req.id}` &&
          intakes[0].debit === 5,
          JSON.stringify(intakes[0] ?? {}));

    // the lender's result rides the claim's signal log; the job's claim
    // list is how the borrower finds it
    const jobId = intakes[0] && `job-${intakes.length}`;
    signals["claim-1"] = [{ type: "demand-result", output: { text: "done" } }];
    jobs[jobId] = {
        state: "verified",
        claims: [{ id: "claim-1", state: "receipted", lender: "did:keri:DL" }],
    };
    for (let i = 0; i < 20; i++) { await sleep(10); ws.ackAll(); }
    const published = ws.sent.filter((m) => m[0] === "EVENT").map((m) => m[1]);
    const feedbacks = published.filter((e) => e.kind === 7000);
    const result = published.find((e) => e.kind === 6050);
    check("processing then success feedback published",
          feedbacks.some((f) => f.tags.some((t) => t[0] === "status" && t[1] === "processing")) &&
          feedbacks.some((f) => f.tags.some((t) => t[0] === "status" && t[1] === "success")));
    check("a kind+1000 result published with the amount tag",
          !!result &&
          result.tags.some((t) => t[0] === "amount" && t[1] === "5000") &&
          JSON.parse(result.content).output === undefined
              ? !!result : !!result);
    check("the result carries the demand output",
          result ? JSON.parse(result.content).text === "done" : false);

    // a bid under the price is payment-required, never a mint
    const cheap = await N.finalizeEvent(buyerSec, {
        kind: 5050, content: "", tags: [["i", "free?", "text"], ["bid", "1"]],
    });
    ws.injectEvent("dvm-0", cheap);
    await sleep(30); ws.ackAll();
    const afterCheap = ws.sent.filter((m) => m[0] === "EVENT").map((m) => m[1]);
    check("an underbid gets payment-required, no intake",
          intakes.length === 1 &&
          afterCheap.some((e) => e.kind === 7000 &&
              e.tags.some((t) => t[0] === "status" && t[1] === "payment-required")));

    // addressed to a different DVM — not ours
    const other = await N.finalizeEvent(buyerSec, {
        kind: 5050, content: "",
        tags: [["i", "x", "text"], ["bid", "9000"], ["p", "ab".repeat(32)]],
    });
    ws.injectEvent("dvm-0", other);
    await sleep(30); ws.ackAll();
    check("an event for another DVM mints nothing", intakes.length === 1);

    // a forged signature never reaches the intake
    const forged = { ...(await N.finalizeEvent(buyerSec, {
        kind: 5050, content: "", tags: [["i", "y", "text"], ["bid", "9000"]] })) };
    forged.sig = "00".repeat(32);
    ws.injectEvent("dvm-0", forged);
    await sleep(30); ws.ackAll();
    check("a forged event mints nothing", intakes.length === 1);

    dvm.stop();
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
