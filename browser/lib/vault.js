// browser/lib/vault.js — authenticated encryption for at-rest blobs.
//
// Used to encrypt the credential backup before it is handed to the gateway,
// so the gateway stores something it cannot read.
//
// This is NOT transport security. The session runs over the websocket
// netlayer and the gateway is the intended RECIPIENT — link encryption
// (Reticulum's included) would hand it the plaintext by design, because
// that is what delivering a message means. The point is what sits on its
// disk afterwards, and what a backup, a subpoena or a compromise exposes.
//
// AES-256-GCM. The key is supplied by the caller — derived from the KERI
// bran via HKDF under its own info-string — so no key management lives
// here. That is what makes the blob recoverable from bran + AID and from
// nothing else: no second, weaker recovery path, and no dependence on
// browser state or on rns-wasm having loaded.
//
// Envelope: iv(12) || ciphertext||tag — lib/seal.js's byte form.
//
// Promise-based on purpose: repl.js adapts these to the callback shape
// Hoot's FFI needs (it cannot await), which keeps the crypto testable
// on its own — see tests/browser/vault-test.mjs.

import { sealBytes, openBytes } from "./seal.js";

async function importKey(keyBytes, usage) {
  return crypto.subtle.importKey("raw", keyBytes, { name: "AES-GCM" }, false, [usage]);
}

// Encrypt PLAINTEXT (Uint8Array) under KEYBYTES (32 raw bytes).
// Resolves to the envelope as a Uint8Array, or a zero-length array on
// failure — callers treat empty as "do not proceed", never as success.
export async function seal(keyBytes, plaintext) {
  try {
    return await sealBytes(await importKey(keyBytes, "encrypt"), plaintext);
  } catch (e) {
    console.warn("[vault] seal failed:", e.message);
    return new Uint8Array(0);
  }
}

// Inverse of seal. A wrong key or a tampered blob fails the GCM tag check
// and lands in the catch — authentication failure, not a crash — so this
// resolves to a zero-length array rather than throwing.
export async function open(keyBytes, blob) {
  try {
    return await openBytes(await importKey(keyBytes, "decrypt"), blob);
  } catch (e) {
    console.warn("[vault] open failed:", e.message);
    return new Uint8Array(0);
  }
}
