// browser/lib/keystore.js — IndexedDB-backed store for org signing keypairs.
//
// Replaces the previous localStorage scheme, which held Ed25519 private
// keys as plaintext hex (exported via crypto.subtle.exportKey("pkcs8")).
// Any XSS on the served page could read them straight out and walk away
// with the identity permanently.
//
// IndexedDB structured-clones CryptoKey objects natively, including
// NON-extractable ones. So the private key never becomes bytes at all:
// it is generated non-extractable, stored as an opaque handle, and can
// only ever be *used* (sign) by code running in this origin — never
// exfiltrated. An XSS becomes a session compromise instead of a
// permanent key theft.
//
// Public keys stay extractable; WebCrypto always marks the public half
// of a generated pair extractable regardless of the generateKey flag,
// and the FFI's exportKey path legitimately needs raw public bytes.
//
// Usage (both day-boot.js and repl.js):
//
//   const ks = await import("./lib/keystore.js");
//   await ks.migrateLegacy();            // one-time move off localStorage
//   const pairs = await ks.getAll();     // { name: CryptoKeyPair }
//   ks.put(name, keyPair);               // fire-and-forget
//   ks.del(name);
//
// See docs/planning/gdpr-analysis.md §5 Phase 0.

import { table } from "../app/idb.js";
import { fromHex } from "../app/bytes.js";
import { readStr, forget } from "../app/store.js";

const STORE = "keypairs";
const LEGACY_PREFIX = "playnet-kp-";

// One store of key handles under out-of-line names. A later shape is a new
// branch in `upgrade` and a bumped version.
const SCHEMA = {
  name: "playnet-keys",
  version: 1,
  upgrade(db) {
    if (!db.objectStoreNames.contains(STORE)) db.createObjectStore(STORE);
  },
};
const keys = table(SCHEMA, STORE);

// Store a CryptoKeyPair under NAME. The privateKey should already be
// non-extractable; this never exports it either way. Resolves once the write
// is durable and rejects when the device refuses it (quota, private mode) —
// a caller holding a freshly made key must hear that.
export async function put(name, keyPair) {
  if (!keyPair || !keyPair.publicKey || !keyPair.privateKey) return;
  await keys.put({ publicKey: keyPair.publicKey, privateKey: keyPair.privateKey }, name);
}

// Every stored pair, as { name: {publicKey, privateKey} }.
export async function getAll() {
  return Object.fromEntries(await keys.entries());
}

export async function del(name) {
  await keys.del(name);
}

// ── seal keys ────────────────────────────────────────────────────────────
// A seal key is one non-extractable AES-GCM key, for lib/seal.js. The store
// keeps {publicKey, privateKey} pairs, so the one key rides as both halves
// and the store stays a single shape.

// The seal key kept under NAME, or null when there is none.
export async function sealKey(name) {
  const pair = (await getAll())[name];
  return pair ? pair.privateKey : null;
}

// Make a fresh seal key and keep it under NAME, replacing any before it.
export async function makeSealKey(name) {
  const aes = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false,
                                              ["encrypt", "decrypt"]);
  await put(name, { publicKey: aes, privateKey: aes });
  return aes;
}

// One-time migration off the old localStorage["playnet-kp-<name>"] =
// "<pubHex>:<privHex>" entries. The private half is re-imported as
// NON-extractable and the legacy entry is removed once the IndexedDB write
// is durable, so from then on the raw bytes exist nowhere.
//
// Best-effort per key: an entry that cannot be migrated (malformed hex, an
// unsupported curve, a refused write) STAYS and is retried next boot — it is
// the only copy of a signing key. A device whose localStorage is blocked has
// no legacy entries to move. Returns the number of keys migrated.
export async function migrateLegacy() {
  let names = [];
  try {
    names = Object.keys(localStorage)
      .filter(k => k.startsWith(LEGACY_PREFIX))
      .map(k => k.slice(LEGACY_PREFIX.length));
  } catch (_) { return 0; }
  let moved = 0;
  for (const name of names) {
    const stored = readStr(LEGACY_PREFIX + name);
    try {
      const [pubHex, privHex] = stored.split(":");
      const publicKey = await crypto.subtle.importKey(
        "raw", fromHex(pubHex), { name: "Ed25519" }, true, ["verify"]);
      const privateKey = await crypto.subtle.importKey(
        "pkcs8", fromHex(privHex), { name: "Ed25519" }, false, ["sign"]);
      await put(name, { publicKey, privateKey });
      // Drop the legacy copy ONLY after a durable IndexedDB put succeeds.
      // A transient import failure (unsupported curve in some browser, a
      // quota error, malformed hex) must never destroy the only copy of a
      // signing key — an Ed25519 private key is a persona, not something you
      // "regenerate". On failure we keep the legacy entry and retry next boot.
      forget(LEGACY_PREFIX + name);
      moved++;
    } catch (e) {
      console.warn("[keystore] keeping unmigratable legacy key for retry", name, e.message);
    }
  }
  if (moved) console.log(`[keystore] migrated ${moved} keypair(s) to IndexedDB`);
  return moved;
}
