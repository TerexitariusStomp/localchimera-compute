// SPDX-License-Identifier: AGPL-3.0-or-later
// browser/lib/seal.js — sealing a secret under an AES-GCM key.
//
// One core: a fresh 12-byte IV, AES-GCM, and the envelope `iv ‖ ciphertext‖tag`
// as bytes (sealBytes / openBytes). Two forms ride on it:
//
//   text   "<iv>.<ciphertext>", each base64url — what localStorage holds
//          (sealWith / openWith): the device's mesh seed under the device's
//          seal key (device-key.js), the Reticulum key under the origin's
//          (rns-identity.js).
//   bytes  the envelope itself — what the gateway keeps as a backup
//          (vault.js, under a bran-derived key).
//
// Every function throws on failure; a wrong key or a tampered envelope fails
// the GCM tag check in open. A caller that wants a softer answer wraps it.

import { toBase64Url, fromBase64Url } from "../app/bytes.js";

const IV_BYTES = 12;

export async function sealBytes(aes, bytes) {
  const iv = crypto.getRandomValues(new Uint8Array(IV_BYTES));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, aes, bytes));
  const out = new Uint8Array(IV_BYTES + ct.length);
  out.set(iv, 0);
  out.set(ct, IV_BYTES);
  return out;
}

export async function openBytes(aes, envelope) {
  if (!envelope || envelope.length <= IV_BYTES) throw new Error("no sealed envelope");
  const iv = envelope.slice(0, IV_BYTES), ct = envelope.slice(IV_BYTES);
  return new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv }, aes, ct));
}

export async function sealWith(aes, bytes) {
  const env = await sealBytes(aes, bytes);
  return toBase64Url(env.slice(0, IV_BYTES)) + "." + toBase64Url(env.slice(IV_BYTES));
}

export async function openWith(aes, text) {
  const [iv, ct] = String(text).split(".").map(fromBase64Url);
  const env = new Uint8Array(iv.length + ct.length);
  env.set(iv, 0);
  env.set(ct, iv.length);
  return openBytes(aes, env);
}
