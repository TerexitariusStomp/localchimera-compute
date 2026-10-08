// tests/browser/vault-test.mjs — the at-rest blob cipher (browser/lib/vault.js)
//
// The credential backup the gateway stores is sealed with this. It runs in
// the browser, but the crypto is plain WebCrypto with no DOM, so node can
// exercise the real code path rather than a reimplementation of it.
//
// What this pins:
//   • round-trip fidelity, including payloads past one AES block and past
//     the 8160-byte ceiling that ruled out the HKDF-keystream approach;
//   • a wrong key does not decrypt — the whole point of the exercise;
//   • a tampered blob fails the GCM tag rather than returning plaintext;
//   • failures resolve empty instead of throwing, since both callers treat
//     empty as "do not proceed".
//
// Run: node tests/browser/vault-test.mjs

import { seal, open } from "../../browser/lib/vault.js";

import { harness } from './assert.mjs';
const { check, done } = harness();

const enc = new TextEncoder(), dec = new TextDecoder();
const key = () => crypto.getRandomValues(new Uint8Array(32));
const bytes = n => crypto.getRandomValues(new Uint8Array(n));

// vault.js logs a warning on every expected failure below; silence it so a
// passing run is quiet and a real problem stands out.
const warn = console.warn;
const quiet = async fn => { console.warn = () => {}; try { return await fn(); }
                            finally { console.warn = warn; } };

console.log("\n── 1. Round-trip ──");
{
  const k = key();
  const msg = enc.encode('((said . "EABC") (schema . playnet-personhood/v1))');
  const blob = await seal(k, msg);
  check("sealed output is non-empty", blob.length > 0);
  check("envelope is longer than the plaintext (iv + tag)",
        blob.length === msg.length + 12 + 16);
  check("opens back to the same bytes",
        dec.decode(await open(k, blob)) === dec.decode(msg));
}

console.log("\n── 2. Sizes ──");
{
  const k = key();
  for (const n of [0, 1, 15, 16, 17, 8160, 8161, 65536]) {
    const msg = bytes(n);
    const out = await open(k, await seal(k, msg));
    // n=0 is indistinguishable from failure by length alone; both callers
    // treat empty as "do not proceed", so that collision is harmless.
    check(`round-trips ${n} bytes`,
          n === 0 ? out.length === 0
                  : out.length === n && out.every((b, i) => b === msg[i]));
  }
}

console.log("\n── 3. A wrong key does not decrypt ──");
{
  const msg = enc.encode("the personhood credential");
  const blob = await seal(key(), msg);
  const out = await quiet(() => open(key(), blob));
  check("decrypting under a different key yields nothing", out.length === 0);
}

console.log("\n── 4. Tampering is detected, not silently accepted ──");
{
  const k = key();
  const blob = await seal(k, enc.encode("hours: 40"));

  const flipped = Uint8Array.from(blob); flipped[20] ^= 0x01;
  check("a flipped ciphertext byte fails the tag",
        (await quiet(() => open(k, flipped))).length === 0);

  const ivFlipped = Uint8Array.from(blob); ivFlipped[0] ^= 0x01;
  check("a flipped IV byte fails the tag",
        (await quiet(() => open(k, ivFlipped))).length === 0);

  const truncated = blob.slice(0, blob.length - 1);
  check("a truncated blob fails the tag",
        (await quiet(() => open(k, truncated))).length === 0);
}

console.log("\n── 5. Malformed input resolves empty rather than throwing ──");
{
  const k = key();
  check("null blob", (await quiet(() => open(k, null))).length === 0);
  check("blob shorter than the IV",
        (await quiet(() => open(k, bytes(8)))).length === 0);
  check("blob of exactly the IV length, no ciphertext",
        (await quiet(() => open(k, bytes(12)))).length === 0);
  check("a bad key length seals empty rather than throwing",
        (await quiet(() => seal(bytes(7), enc.encode("x")))).length === 0);
}

console.log("\n── 6. Nonce reuse: same input twice, different envelopes ──");
{
  const k = key(), msg = enc.encode("same plaintext");
  const a = await seal(k, msg), b = await seal(k, msg);
  check("two seals of identical input differ (fresh IV each time)",
        !a.every((x, i) => x === b[i]));
  check("both still open correctly",
        dec.decode(await open(k, a)) === dec.decode(await open(k, b)));
}

done();
