// browser/lib/device-key.js — the device's own signing key
//
// docs/planning/device-keys.md. The passcode is the root of an identity and
// stays cold; this device signs everyday acts with a key of its own that the
// root authorized once. Two ways of holding that key, chosen by what the
// browser offers:
//
//   hardware — a WebAuthn passkey with the `prf` extension. The seed is
//              HMAC(prf-output, "playnet:device:v1"), derived after a touch
//              on every load and held in memory only. On disk: the credential
//              id and the salt — neither is a key.
//   software — a non-extractable WebCrypto Ed25519 key in IndexedDB
//              (keystore.js, name "device"). Script can use it, never read it.
//
// The record of which tier this device uses lives in
// localStorage (K.deviceKey); the root's authorization (the
// credential the gateway verifies) is the spine's, under K.deviceWire.

import { keri as keriCrypto } from "./keri-crypto.js";
import * as keystore from "./keystore.js";
import { sealWith, openWith } from "./seal.js";
import { toBase64Url, fromBase64Url } from "../app/bytes.js";
import { readJSON, writeJSON, forget as forgetKey } from "../app/store.js";
import { K } from "../app/keys.js";

const RECORD = K.deviceKey;
const KEY_NAME = "device";
const PRF_INFO = new TextEncoder().encode("playnet:device:v1");
// a second key off the same root, for sealing small secrets the persona
// needs on this device (the mesh identity seed): hardware — derived from
// the PRF output next to the signing seed; software — a non-extractable
// AES-GCM key in the keystore beside the signing key
const SEAL_INFO = new TextEncoder().encode("playnet:device:seal:v1");
const SEAL_NAME = "device-seal";

const record = () => readJSON(RECORD, null);
const setRecord = (r) => { writeJSON(RECORD, r); };

export function hasRecord() { return !!record(); }
export function recordedTier() { const r = record(); return r ? r.tier : null; }

/** What this browser can hold: hardware needs WebAuthn (PRF is probed at
 *  enrolment — the API cannot say beforehand); software needs WebCrypto
 *  Ed25519, probed here by trying to make a throwaway key. */
export async function tiers() {
  // WebAuthn binds a passkey to a registrable domain: an IP literal (a dev
  // stack on 127.0.0.1) cannot be an RP ID, so the passkey tier is not on
  // offer there — the software tier still is
  const ipHost = /^(\d{1,3}\.){3}\d{1,3}$|^\[?[0-9a-f:]+\]?$/i.test(location.hostname);
  const hardware = !!(window.PublicKeyCredential && navigator.credentials
                      && navigator.credentials.create && window.isSecureContext && !ipHost);
  let software = false;
  try {
    await crypto.subtle.generateKey({ name: "Ed25519" }, false, ["sign", "verify"]);
    software = true;
  } catch { software = false; }
  return { hardware, software };
}

// ── hardware tier ────────────────────────────────────────────────────────
const keri = () => keriCrypto;

async function prfOutput(credId, salt) {
  const assertion = await navigator.credentials.get({
    publicKey: {
      challenge: crypto.getRandomValues(new Uint8Array(32)),
      rpId: location.hostname,
      allowCredentials: [{ type: "public-key", id: credId }],
      userVerification: "preferred",
      extensions: { prf: { eval: { first: salt } } },
    },
  });
  const ext = assertion.getClientExtensionResults();
  const out = ext.prf && ext.prf.results && ext.prf.results.first;
  if (!out) throw new Error("this authenticator does not derive keys (no PRF)");
  return new Uint8Array(out);
}

async function aesFromBytes(raw) {
  return crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}
async function fromPrf(prf) {
  const seed = keri().hmac_sha256(prf, PRF_INFO);
  const aes = await aesFromBytes(keri().hmac_sha256(prf, SEAL_INFO));
  const kp = keri().ed25519_from_seed(seed);
  return {
    pub: kp.pub,
    sign: async (bytes) => keri().ed25519_sign(seed, bytes),
    seal: (bytes) => sealWith(aes, bytes),
    open: (blob) => openWith(aes, blob),
  };
}

async function createHardware() {
  const salt = crypto.getRandomValues(new Uint8Array(32));
  const cred = await navigator.credentials.create({
    publicKey: {
      challenge: crypto.getRandomValues(new Uint8Array(32)),
      rp: { name: "playnet", id: location.hostname },
      user: {
        id: crypto.getRandomValues(new Uint8Array(16)),
        name: "playnet device key",
        displayName: "playnet device key",
      },
      pubKeyCredParams: [
        { type: "public-key", alg: -8 }, { type: "public-key", alg: -7 },
        { type: "public-key", alg: -257 },
      ],
      authenticatorSelection: { residentKey: "preferred", userVerification: "preferred" },
      extensions: { prf: {} },
    },
  });
  const ext = cred.getClientExtensionResults();
  if (!(ext.prf && ext.prf.enabled))
    throw new Error("this authenticator does not derive keys (no PRF)");
  const credId = new Uint8Array(cred.rawId);
  const prf = await prfOutput(credId, salt);
  setRecord({ tier: "hardware", credId: toBase64Url(credId), salt: toBase64Url(salt) });
  return { tier: "hardware", ...(await fromPrf(prf)) };
}

async function loadHardware(r) {
  const prf = await prfOutput(fromBase64Url(r.credId), fromBase64Url(r.salt));
  return { tier: "hardware", ...(await fromPrf(prf)) };
}

// ── software tier ────────────────────────────────────────────────────────
async function softwareFromPair(kp, aes) {
  const pub = new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey));
  return {
    tier: "software",
    pub,
    sign: async (bytes) =>
      new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, kp.privateKey, bytes)),
    seal: (bytes) => sealWith(aes, bytes),
    open: (blob) => openWith(aes, blob),
  };
}

async function createSoftware() {
  const kp = await crypto.subtle.generateKey({ name: "Ed25519" }, false, ["sign", "verify"]);
  await keystore.put(KEY_NAME, kp);
  const aes = await keystore.makeSealKey(SEAL_NAME);
  setRecord({ tier: "software" });
  return softwareFromPair(kp, aes);
}

async function loadSoftware() {
  const all = await keystore.getAll();
  const kp = all[KEY_NAME];
  if (!kp) throw new Error("device key missing from this browser's store");
  const aes = all[SEAL_NAME] && all[SEAL_NAME].privateKey;
  if (!aes) throw new Error("device seal key missing from this browser's store");
  return softwareFromPair(kp, aes);
}

// ── the door ─────────────────────────────────────────────────────────────
/** Make this device's key at TIER ("hardware" | "software"). Replaces any
 *  earlier record — the old key's authorization is the caller's to revoke. */
export async function create(tier) {
  if (tier === "hardware") return createHardware();
  if (tier === "software") return createSoftware();
  throw new Error("unknown device tier: " + tier);
}

/** The key this device holds, ready to sign. Throws when there is none, or
 *  when the hardware tier needs a gesture the caller does not have. */
export async function load() {
  const r = record();
  if (!r) throw new Error("no device key on this browser");
  return r.tier === "hardware" ? loadHardware(r) : loadSoftware();
}

/** Forget the key and its record. The gateway-side authorization is revoked
 *  separately (the spine's revokeDevice) — this only clears the browser. */
export async function forget() {
  forgetKey(RECORD);
  try { await keystore.del(KEY_NAME); } catch {}
  try { await keystore.del(SEAL_NAME); } catch {}
}
