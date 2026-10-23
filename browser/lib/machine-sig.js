// SPDX-License-Identifier: AGPL-3.0-or-later
// browser/lib/machine-sig.js — the lender's signature on a receipt.
//
// A machine node's accountable chain (spec §1): the tab holds an Ed25519
// key, its did:key is the lenderDid on every offer and receipt, and a
// keri:<aid> AccountLink (machine-bind) is what makes the did:key answer
// to a Playnet AID. The receipt's lenderSig is the CESR qb64 "0B" form of
// the Ed25519 signature over the receipt digest's UTF-8 bytes — exactly
// what binding-verifiers.scm's verify-did-key-sig recomputes door-side.
//
// Two signers, one shape { did, sign(digestStr) → qb64 }:
//   makeSeedSigner(seed)  — noble-ed25519 over raw seed bytes (tests,
//                           the wasm-side FFI, anywhere bytes are in hand)
//   loadNodeSigner()      — the keystore's non-extractable WebCrypto pair
//                           under "machine-node"; the page's real signer
// Absent WebCrypto Ed25519 or a refused keystore the answer is null —
// emitReceipt falls back to lenderSig:null and the door says
// 'unverifiable, never a fabricated signature.

import * as ed25519 from '../vendor/noble/ed25519.js';
import { sha512 } from '../vendor/noble/sha512.js';

ed25519.etc.sha512Sync ??= (...msgs) => {
    const total = msgs.reduce((n, m) => n + m.length, 0);
    const cat = new Uint8Array(total);
    let off = 0;
    for (const m of msgs) { cat.set(m, off); off += m.length; }
    return sha512(cat);
};

const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

export const base58Encode = (bytes) => {
    // digits-into-base58, no bigint needed at this size
    let digits = [0];
    for (const byte of bytes) {
        let carry = byte;
        for (let i = 0; i < digits.length; i++) {
            carry += digits[i] << 8;
            digits[i] = carry % 58;
            carry = (carry / 58) | 0;
        }
        while (carry) { digits.push(carry % 58); carry = (carry / 58) | 0; }
    }
    let str = "";
    for (const byte of bytes) {
        if (byte === 0) str += "1"; else break;
    }
    for (let i = digits.length - 1; i >= 0; i--) str += B58[digits[i]];
    return str;
};

export const base58Decode = (str) => {
    let bytes = [0];
    for (const ch of str) {
        let carry = B58.indexOf(ch);
        if (carry < 0) throw new Error(`base58: bad char ${ch}`);
        for (let i = 0; i < bytes.length; i++) {
            carry += bytes[i] * 58;
            bytes[i] = carry & 0xff;
            carry >>= 8;
        }
        while (carry) { bytes.push(carry & 0xff); carry >>= 8; }
    }
    let zeros = 0;
    for (const ch of str) { if (ch === "1") zeros++; else break; }
    const out = new Uint8Array(zeros + bytes.length);
    for (let i = 0; i < bytes.length; i++)
        out[zeros + i] = bytes[bytes.length - 1 - i];
    return out;
};

// did:key:z… ↔ the 32-byte Ed25519 pubkey — multicodec 0xed01 then
// base58btc, the same shape binding-verifiers.scm decodes.
export const pubkeyToDidKey = (pub) => {
    if (!(pub instanceof Uint8Array) || pub.length !== 32)
        throw new Error("pubkeyToDidKey: need a 32-byte key");
    const tagged = new Uint8Array(34);
    tagged[0] = 0xed; tagged[1] = 0x01;
    tagged.set(pub, 2);
    return "did:key:z" + base58Encode(tagged);
};

export const didKeyToPubkey = (did) => {
    if (typeof did !== "string" || !did.startsWith("did:key:z")) return null;
    let bv;
    try { bv = base58Decode(did.slice(9)); } catch { return null; }
    return bv.length === 34 && bv[0] === 0xed && bv[1] === 0x01
        ? bv.slice(2) : null;
};

const B64U = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const b64url = (bytes) => {
    let s = "";
    for (let i = 0; i < bytes.length; i += 3) {
        const bits = (bytes[i] << 16) | ((bytes[i + 1] ?? 0) << 8) | (bytes[i + 2] ?? 0);
        s += B64U[(bits >> 18) & 63] + B64U[(bits >> 12) & 63];
        if (i + 1 < bytes.length) s += B64U[(bits >> 6) & 63];
        if (i + 2 < bytes.length) s += B64U[bits & 63];
    }
    return s;
};

// CESR qb64 under code "0B" (SigDex.Ed25519_Sig): pre-pad to a multiple
// of 3, b64url, then the code replaces the leading 'A' chars — the same
// substitution cesr.scm's cesr-bytes->qb64 makes, so both sides emit the
// same string over the same 64 bytes.
export const cesrQb64Sig = (sig) => {
    if (!(sig instanceof Uint8Array) || sig.length !== 64)
        throw new Error("cesrQb64Sig: need a 64-byte signature");
    const padded = new Uint8Array(66);
    padded.set(sig, 2);
    return "0B" + b64url(padded).slice(2);
};

// A signer over raw seed bytes — noble path, synchronous.
export const makeSeedSigner = (seed) => {
    if (!(seed instanceof Uint8Array) || seed.length !== 32)
        throw new Error("makeSeedSigner: need a 32-byte seed");
    const did = pubkeyToDidKey(ed25519.getPublicKey(seed));
    return {
        did,
        sign: (digestStr) =>
            cesrQb64Sig(ed25519.sign(new TextEncoder().encode(digestStr), seed)),
    };
};

// Verify a qb64 signature against a did:key — the test-side twin of
// binding-verifiers.scm's verify-did-key-sig.
export const verifyDidKeySig = (did, digestStr, sigQb64) => {
    const pub = didKeyToPubkey(did);
    if (!pub || typeof sigQb64 !== "string" || !sigQb64.startsWith("0B"))
        return false;
    const b64 = "AA" + sigQb64.slice(2);
    let bits = 0, nbits = 0; const raw = [];
    for (const ch of b64) {
        bits = (bits << 6) | B64U.indexOf(ch); nbits += 6;
        if (nbits >= 8) { nbits -= 8; raw.push((bits >> nbits) & 0xff); }
    }
    if (raw.length !== 66 || raw[0] !== 0 || raw[1] !== 0) return false;
    try {
        return ed25519.verify(new Uint8Array(raw.slice(2)),
                              new TextEncoder().encode(digestStr), pub);
    } catch { return false; }
};

// The node's own signer: the keystore's "machine-node" Ed25519 pair,
// generated non-extractable on first use — signable, never exportable.
// null when WebCrypto can't do Ed25519 or the store refuses: the caller
// degrades to an unsigned receipt, the door to 'unverifiable.
export const loadNodeSigner = async () => {
    try {
        const ks = await import("./keystore.js");
        let pair = (await ks.getAll())["machine-node"];
        if (!pair) {
            pair = await crypto.subtle.generateKey({ name: "Ed25519" }, false,
                                                   ["sign", "verify"]);
            await ks.put("machine-node", pair);
        }
        const pub = new Uint8Array(
            await crypto.subtle.exportKey("raw", pair.publicKey));
        return {
            did: pubkeyToDidKey(pub),
            sign: async (digestStr) => cesrQb64Sig(new Uint8Array(
                await crypto.subtle.sign("Ed25519", pair.privateKey,
                                         new TextEncoder().encode(digestStr)))),
        };
    } catch {
        return null;
    }
};
