// tests/browser/machine-store-test.mjs — the store kind's node, tested.
//
// machine-store.js is the "browser tab holds bytes and proves it" claim:
// put/get over IndexedDB, a durable byte-seconds meter, the challenge
// answer sha256(nonce ∥ content), and runStoreClaim's hold→answer→receipt
// lifecycle — fail-closed at every boundary (no IDB, no content source,
// no helia, a commitment the bytes don't hash to).
//
// Run: node tests/browser/machine-store-test.mjs

import { fakeIndexedDB } from "./fakes.mjs";

let pass = 0, fail = 0;
const check = (label, ok, extra = "") => {
  ok ? pass++ : fail++;
  console.log(`  ${ok ? "✓" : "✗"} ${label}${extra ? " — " + extra : ""}`);
};

// ── the device ──────────────────────────────────────────────────────────
globalThis.indexedDB = fakeIndexedDB();
Object.defineProperty(globalThis, "navigator", {
  value: { storage: { estimate: async () => ({ quota: 1e9, usage: 4e6 }) } },
  configurable: true,
});

const S = await import("../../browser/app/machine-store.js");

const b64 = (s) => Buffer.from(s, "utf8").toString("base64");
const sha256hex = async (u8) =>
  [...new Uint8Array(await crypto.subtle.digest("SHA-256", u8))]
    .map(b => b.toString(16).padStart(2, "0")).join("");

// goldens — sha256("abhello") and sha256("hello"), computed by openssl:
const HELLO = new TextEncoder().encode("hello");
const HELLO_HASH = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
const ANSWER_GOLDEN = "04f5e058959c474968d38f7474cdc329c586dd2f5701fc6e8a598741e01f0dca";

// ── the shelf ───────────────────────────────────────────────────────────
await S.putContent(HELLO_HASH, HELLO, { claimId: "claim-1" });
check("put then get round-trips the bytes",
      (await S.getContent(HELLO_HASH))?.byteLength === 5);
check("held bytes counts what is kept", (await S.heldBytes()) === 5);
check("a claim finds its blob",
      (await S.blobForClaim("claim-1"))?.hash === HELLO_HASH);

// ── the meter — byte-seconds accrue held × elapsed ──────────────────────
const realNow = Date.now;
let t = realNow();
Date.now = () => t;
await S.byteSeconds();                     // pin the meter's `since`
const before = await S.byteSeconds();
t += 2000;                                 // 5 B held for 2 s
const accrued = await S.byteSeconds();
Date.now = realNow;
check("byte-seconds accrue held × elapsed",
      Math.abs((accrued - before) - 10) < 0.001,
      `${accrued - before} for 5B × 2s`);

// a clock rewind must not un-meter retention already delivered — the meter
// is monotonic
{
  const rn = Date.now;
  let tt = rn();
  Date.now = () => tt;
  const hi = await S.byteSeconds();
  tt -= 5000;
  const after = await S.byteSeconds();
  Date.now = rn;
  check("a rewound clock does not un-meter", after >= hi, `${after} < ${hi}`);
}

// ── the proof — sha256(nonce ∥ content) ─────────────────────────────────
check("the challenge answer is sha256(nonce ∥ content)",
      (await S.answerFor("ab", HELLO_HASH)) === ANSWER_GOLDEN);
check("a hash we do not hold answers null — no guessing",
      (await S.answerFor("ab", "00".repeat(32))) === null);

// ── health ──────────────────────────────────────────────────────────────
const h = await S.storeHealth();
check("health reports quota, held, metered, blobs",
      h.quota === 1e9 && h.held === 5 && h.blobs === 1 && h.byteSeconds >= 10);

// ── fetchContent — where the bytes come from ────────────────────────────
check("contentB64 decodes inline",
      (await S.fetchContent({ params: { contentB64: b64("hi") } }))
        .byteLength === 2);
{
  let msg = "";
  try { await S.fetchContent({ params: {} }); }
  catch (e) { msg = e.message; }
  check("no content source refuses", msg.includes("no content source"));
}
{
  let msg = "";
  try { await S.fetchContent({ params: { cid: "bafy-x" } }); }
  catch (e) { msg = e.message; }
  check("a cid with no helia leg answers 'unavailable",
        msg.includes("unavailable"), msg);
}
{
  const fake = { fetchBytes: async (cid) => cid === "bafy-ok" ? HELLO : null };
  check("an injected helia leg fetches the cid",
        (await S.fetchContent({ params: { cid: "bafy-ok" } }, { helia: fake }))
          .byteLength === 5);
}

// ── runStoreClaim — hold, answer, receipt ────────────────────────────────
{
  const answers = [], receipts = [];
  const seam = {
    machineChallenges: async () =>
      JSON.stringify([{ id: "chal-1", state: "open", nonce: "ab" }]),
    machineChallengeAnswer: async (c, id, a) => { answers.push(a); return "ok"; },
    machineReceipt: async (c, wire) => { receipts.push(JSON.parse(wire)); return "ok"; },
  };
  const env = { kind: "store", inputHash: HELLO_HASH,
                params: { contentB64: b64("hello"), ttlSeconds: 1 } };
  indexedDB.wipe();                        // fresh device for the claim
  await S.putContent("__warm__", new Uint8Array(1)); // schema init
  await S.evictContent("__warm__");
  const r = await S.runStoreClaim(seam, "commune-1", "claim-9", env,
                                  "did:key:zLender", { challengeMs: 100 });
  check("the claim's lifecycle resolves to a receipt post", r === "ok");
  check("the open challenge got answered from the held bytes",
        answers.includes(ANSWER_GOLDEN), `${answers.length} answers`);
  const receipt = receipts[0];
  check("the receipt meters byte-seconds",
        receipt?.usage?.unit === "byte-seconds" && receipt?.usage?.amount > 0,
        JSON.stringify(receipt?.usage));
  check("the receipt's outputHash re-hashes the retained bytes",
        receipt?.outputHash === HELLO_HASH);
  check("the blob is evicted at retention end",
        (await S.getContent(HELLO_HASH)) === null);
}

// the borrower's half — machineChallengeVerify carries the expected hash
// computed over the content the borrower keeps, bound to the job's
// committed inputHash (node.html's verify button runs this same formula)
{
  const calls = [];
  const seam = {
    machineChallengeVerify: async (commune, id, expected, contentHash) => {
      calls.push({ commune, id, expected, contentHash }); return "ok";
    },
  };
  const nonce = new TextEncoder().encode("ab");
  const both = new Uint8Array(nonce.length + HELLO.length);
  both.set(nonce); both.set(HELLO, nonce.length);
  const expected = await sha256hex(both);
  const r = await seam.machineChallengeVerify("commune-1", "chal-1",
                                              expected, HELLO_HASH);
  check("the borrower's verify carries expected + the committed hash",
        r === "ok" && calls[0].expected === ANSWER_GOLDEN &&
        calls[0].contentHash === HELLO_HASH);
}

// a commitment the bytes don't hash to — refuse before holding anything
{
  let msg = "";
  try {
    await S.runStoreClaim({}, "c", "claim-x",
      { kind: "store", inputHash: "00".repeat(32),
        params: { contentB64: b64("hello"), ttlSeconds: 1 } },
      "did:key:zLender");
  } catch (e) { msg = e.message; }
  check("bytes that miss the commitment refuse to store",
        msg.includes("inputHash"), msg);
}

// a device with no IndexedDB fails closed — the put rejects, nothing held
{
  indexedDB.down = true;
  let msg = "";
  try {
    await S.runStoreClaim({}, "c", "claim-y",
      { kind: "store", inputHash: HELLO_HASH,
        params: { contentB64: b64("hello"), ttlSeconds: 1 } },
      "did:key:zLender");
  } catch (e) { msg = e.message; }
  indexedDB.down = false;
  check("no IndexedDB fails the claim, honestly",
        msg.length > 0, msg || "(resolved)");
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
