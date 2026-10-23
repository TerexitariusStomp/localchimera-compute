// SPDX-License-Identifier: AGPL-3.0-or-later
// tests/browser/keystore-test.mjs — the IndexedDB keystore + legacy migration
// (browser/lib/keystore.js). Runs in node with REAL WebCrypto (Ed25519) and small
// in-memory mocks for localStorage + IndexedDB, so it exercises the real code
// path rather than a reimplementation.
//
// What this pins — with the migration being the most dangerous operation in
// the module (it moves real private keys and deletes the originals):
//   • put/getAll round-trip through IndexedDB;
//   • a valid legacy key migrates AND its localStorage copy is removed;
//   • a FAILED migration KEEPS the legacy key — a transient import error must
//     never destroy the only copy of a signing key (the load-bearing property);
//   • a mixed batch migrates the good ones and leaves the bad ones intact.
//
// Run: node tests/browser/keystore-test.mjs

import { memStorage, fakeIndexedDB } from './fakes.mjs';

import { harness } from './assert.mjs';
const { check, done } = harness();

// tests/browser/fakes.mjs stands in for both stores. Its localStorage keeps
// keys as own enumerable properties, which migrateLegacy's Object.keys relies on.
const freshLocalStorage = () => { globalThis.localStorage = memStorage(); };
const freshIndexedDB = () => { globalThis.indexedDB = fakeIndexedDB(); };

freshLocalStorage();
freshIndexedDB();

// keystore.js reads globalThis.{indexedDB,localStorage} at call time, so a
// single import suffices and resetting the globals per test gives a clean slate.
const { put, getAll, migrateLegacy } = await import("../../browser/lib/keystore.js");

const hex = (buf) => [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, "0")).join("");

// A valid legacy "<pubHex>:<privHex>" entry, built from a real Ed25519 keypair.
async function legacyEntry() {
  const kp = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  const pub = hex(await crypto.subtle.exportKey("raw", kp.publicKey));
  const priv = hex(await crypto.subtle.exportKey("pkcs8", kp.privateKey));
  return `${pub}:${priv}`;
}

const quiet = async (fn) => {
  const w = console.warn; console.warn = () => {};
  try { return await fn(); } finally { console.warn = w; }
};

console.log("\n── 1. put / getAll round-trip ──");
{
  const kp = await crypto.subtle.generateKey({ name: "Ed25519" }, false, ["sign", "verify"]);
  await put("alice", kp);
  const all = await getAll();
  check("stored keypair is retrievable by name", !!(all.alice && all.alice.privateKey));
}

console.log("\n── 2. migrateLegacy: valid key moves, legacy copy removed ──");
{
  freshLocalStorage(); freshIndexedDB();
  localStorage.setItem("playnet-kp-bob", await legacyEntry());
  const moved = await migrateLegacy();
  check("reported 1 migrated", moved === 1);
  check("legacy localStorage entry removed after a durable put",
        localStorage.getItem("playnet-kp-bob") === null);
  const all = await getAll();
  check("keypair now lives in IndexedDB", !!(all.bob && all.bob.privateKey));
}

console.log("\n── 3. migrateLegacy: a FAILED migration KEEPS the key (the fix) ──");
{
  freshLocalStorage(); freshIndexedDB();
  localStorage.setItem("playnet-kp-broken", "zz:zz"); // bad hex → importKey throws
  const moved = await quiet(() => migrateLegacy());
  check("nothing reported migrated", moved === 0);
  check("legacy key NOT destroyed on failure — kept for retry",
        localStorage.getItem("playnet-kp-broken") === "zz:zz");
}

console.log("\n── 4. mixed batch: valid migrates, invalid survives ──");
{
  freshLocalStorage(); freshIndexedDB();
  localStorage.setItem("playnet-kp-good", await legacyEntry());
  localStorage.setItem("playnet-kp-bad", "nothex");
  const moved = await quiet(() => migrateLegacy());
  check("exactly the valid one migrated", moved === 1);
  check("valid one's legacy copy removed", localStorage.getItem("playnet-kp-good") === null);
  check("invalid one's legacy copy kept", localStorage.getItem("playnet-kp-bad") === "nothex");
  const all = await getAll();
  check("only the valid one is in IndexedDB", !!(all.good && !all.bad));
}

done();
