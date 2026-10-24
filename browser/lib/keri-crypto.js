// SPDX-License-Identifier: AGPL-3.0-or-later
// browser/lib/keri-crypto.js — synchronous KERI crypto primitives for Hoot
//
// Exposes Blake3-256, HMAC-SHA256, Ed25519 keygen-from-seed, and
// Ed25519 sign as sync functions over Uint8Array. Hoot's FFI cannot
// await Promises, so every primitive here MUST be synchronous —
// noble-ed25519 v2 + noble-hashes are pure-JS and meet that bar
// (we wire `etc.sha512Sync` from noble-hashes/sha512 so that
// noble-ed25519 doesn't need WebCrypto's async digest path).
//
// The surface mirrors (localchimera keri crypto-primitives) on the Scheme
// side; (localchimera keri crypto-primitives-browser) does the FFI binding.

import * as ed25519 from '../vendor/noble/ed25519.js';
import { blake3 }   from '../vendor/noble/blake3.js';
import { hmac }     from '../vendor/noble/hmac.js';
import { sha256 }   from '../vendor/noble/sha256.js';
import { sha512 }   from '../vendor/noble/sha512.js';

// Wire sha512Sync so noble-ed25519's sign/getPublicKey are pure-sync.
// Noble passes one or more Uint8Arrays; concat then digest.
ed25519.etc.sha512Sync = (...msgs) => {
  if (msgs.length === 1) return sha512(msgs[0]);
  let total = 0;
  for (const m of msgs) total += m.length;
  const concat = new Uint8Array(total);
  let off = 0;
  for (const m of msgs) { concat.set(m, off); off += m.length; }
  return sha512(concat);
};

// All inputs/outputs are Uint8Array. Hoot marshalling on the Scheme
// side converts these to/from bytevectors via the same route Scheme
// already uses for `crypto.digest` etc.
export const keri = {
  /** Blake3-256: bv → Uint8Array(32). */
  blake3_256(bv) { return blake3(bv); },

  /** SHA-256: bv → Uint8Array(32). Reticulum identity/destination
   *  hashes are truncated SHA-256 (AID↔mesh binding verification). */
  sha256(bv) { return sha256(bv); },

  /** HMAC-SHA256: (key, data) → Uint8Array(32). */
  hmac_sha256(key, data) { return hmac(sha256, key, data); },

  /** Ed25519 keygen from 32-byte seed.
   *  Returns { pub:Uint8Array(32), seed:Uint8Array(32) }. The 'seed'
   *  field doubles as backend-data for the sign primitive — noble's
   *  signing path takes the 32-byte private key (== seed) directly. */
  ed25519_from_seed(seed) {
    const pub = ed25519.getPublicKey(seed);
    return { pub, seed };
  },

  /** Ed25519 sign: (seed, message) → Uint8Array(64). */
  ed25519_sign(seed, message) {
    return ed25519.sign(message, seed);
  },

  /** Ed25519 verify: (pubkey, message, sig) → 1 if valid, 0 if not.
   *  noble-ed25519 throws on malformed inputs; we swallow to match
   *  the goblins-crypto verify shape (returns #f, no raise). */
  ed25519_verify(pub, msg, sig) {
    try {
      return ed25519.verify(sig, msg, pub) ? 1 : 0;
    } catch (_) {
      return 0;
    }
  },

  /** WebCrypto getRandomValues passthrough. Returns Uint8Array(n). */
  random_bytes(n) {
    const out = new Uint8Array(n);
    globalThis.crypto.getRandomValues(out);
    return out;
  },

  /** Length / index helpers — Hoot's FFI returns Uint8Array as opaque
   *  externs; Scheme can't index into them directly without these. */
  u8_length(arr) { return arr.length; },
  u8_ref(arr, i) { return arr[i]; },

  /** Object field accessors for the keypair record returned by
   *  ed25519_from_seed. Avoids exposing JS object property syntax to
   *  the FFI layer; all access goes through these named helpers. */
  kp_pub(kp)  { return kp.pub; },
  kp_seed(kp) { return kp.seed; },
};

