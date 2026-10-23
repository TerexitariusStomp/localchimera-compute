// SPDX-License-Identifier: AGPL-3.0-or-later
// browser/lib/rns-identity.js — the Reticulum mesh key, at rest.
//
// A browser's anonymous mesh identity is a 64-byte private key that has to
// outlive a reload, and rns-wasm needs it as raw bytes, so it cannot be a
// non-extractable CryptoKey the way the signing keys are. It is kept SEALED:
// the bytes are encrypted under an AES-GCM key that is itself non-extractable
// and lives in the keystore ("local-seal"), and localStorage holds only the
// ciphertext. A copy of localStorage — a backup, a synced profile, a dump —
// carries nothing that opens without this origin's IndexedDB beside it.
//
// The seal key belongs to the origin, with or without an enrolled device key,
// so every visitor's mesh key is sealed.
//
// Both pages come through here: the dial (spine-imports.js, on the page or in
// the spine worker, where `ls` is the worker's mirror of localStorage) and the
// REPL page (repl.js).

import * as keystore from "./keystore.js";
import { sealWith, openWith } from "./seal.js";
import { K } from "../app/keys.js";

const KEY = K.meshIdentity;
const SEAL_NAME = "local-seal";
const SEALED = "sealed:v1:";

// The origin's seal key, made on first use.
const sealKey = async () =>
  (await keystore.sealKey(SEAL_NAME)) || (await keystore.makeSealKey(SEAL_NAME));

/**
 * Keep BYTES as this device's mesh key. Answers whether it was stored; a
 * device that cannot seal (no IndexedDB) keeps the key for the session only.
 */
export async function keepMeshKey(ls, bytes) {
  try {
    ls.setItem(KEY, SEALED + await sealWith(await sealKey(), bytes));
    return true;
  } catch (_) { return false; }
}

/**
 * The mesh key this device holds, or null when it holds none it can open.
 * A value stored before sealing (a JSON byte array) is read and sealed in
 * place; it stays as it is when this device cannot seal.
 */
export async function loadMeshKey(ls) {
  let stored = null;
  try { stored = ls.getItem(KEY); } catch (_) { return null; }
  if (!stored) return null;
  if (stored.startsWith(SEALED)) {
    try { return await openWith(await sealKey(), stored.slice(SEALED.length)); }
    catch (_) { return null; }             // the seal key is gone: the caller mints anew
  }
  try {
    const bytes = new Uint8Array(JSON.parse(stored));
    await keepMeshKey(ls, bytes);
    return bytes;
  } catch (_) { return null; }
}

/**
 * This device's mesh identity: the one it holds, or a fresh one, kept.
 * RNS is the rns-wasm module.
 */
export async function meshIdentity(rns, ls) {
  const bytes = await loadMeshKey(ls);
  if (bytes) {
    try { return rns.Identity.fromPrivateKey(bytes); } catch (_) { /* unreadable: mint anew */ }
  }
  const id = new rns.Identity();
  await keepMeshKey(ls, id.privateKey());
  return id;
}
