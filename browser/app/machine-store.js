// app/machine-store.js — the store kind's node leg: hold bytes, prove it.
//
// A 'store envelope's inputHash is the content commitment — sha256(content)
// — and its params say where the bytes come from: contentB64 inline, or a
// cid for the content-addressed network leg. runStoreClaim verifies the
// bytes hash to inputHash — storing bytes that don't match the commitment
// is worse than refusing — keeps them in IndexedDB, answers
// machine-challenges against the held bytes (sha256(nonce ∥ content), the
// same formula machine/challenge.scm recomputes), and at retention end
// lands a receipt metering the byte-seconds this blob accrued.
//
// Metering: every put/evict/report first settles held×elapsed into a
// durable counter in IDB, so a blob that sits untouched meters exactly the
// time it sat, and the counter survives the tab closing mid-claim.
//
// The network leg is lazy and fail-closed: a params.cid job needs a
// content-addressed fetch, which imports the caller's helia at need — no
// helia, the claim refuses 'unavailable instead of pretending it fetched.

import { table } from "./idb.js";
import { fromBase64 } from "./bytes.js";
import { emitReceipt } from "./machine-executor.js";

const hex = (buf) => [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, "0")).join("");
const sha256Bytes = async (u8) => hex(await crypto.subtle.digest("SHA-256", u8));
const utf8 = (s) => new TextEncoder().encode(s);

// ── the shelf ─────────────────────────────────────────────────────────────
// blobs: hash → {hash, bytes, size, since, claimId}. meter: the durable
// byte-seconds counter under key "bs".
const SCHEMA = {
    name: "machine-store",
    version: 1,
    upgrade(db) {
        db.createObjectStore("blobs", { keyPath: "hash" });
        db.createObjectStore("meter", { keyPath: "k" });
    },
};
const blobs = table(SCHEMA, "blobs");
const meter = table(SCHEMA, "meter");

export const heldBytes = async () =>
    (await blobs.all()).reduce((n, r) => n + (r.size ?? 0), 0);

// settle held×elapsed into the counter, then answer it — reads are writes
// here because "bytes held right now" is the rate. The elapsed is clamped
// at zero: a clock that rewinds (leap smear, a VM resume, a corrected NTP)
// must not un-meter retention the node already delivered.
export const byteSeconds = async () => {
    const m = (await meter.get("bs")) ?? { k: "bs", accrued: 0, since: Date.now() };
    const now = Date.now();
    m.accrued += (await heldBytes()) * Math.max(0, now - m.since) / 1000;
    m.since = Math.max(now, m.since);   // the marker never rewinds either
    await meter.put(m);
    return Math.round(m.accrued * 1000) / 1000;
};

export const putContent = async (hash, bytes, meta = {}) => {
    await byteSeconds();   // meter the outgoing state before it changes
    await blobs.put({ hash, bytes, size: bytes.byteLength,
                      since: Date.now(), claimId: meta.claimId ?? null });
};
export const getContent = async (hash) => (await blobs.get(hash))?.bytes ?? null;
export const evictContent = async (hash) => { await byteSeconds(); await blobs.del(hash); };
export const blobForClaim = async (claimId) =>
    (await blobs.all()).find(r => r.claimId === claimId) ?? null;

export const storeHealth = async () => {
    let est = {};
    try { est = await navigator.storage?.estimate?.() ?? {}; } catch { }
    return { quota: est.quota ?? null, usage: est.usage ?? null,
             held: await heldBytes(), byteSeconds: await byteSeconds(),
             blobs: (await blobs.all()).length };
};

// ── the proof ─────────────────────────────────────────────────────────────
// sha256(nonce-utf8 ∥ content) — challenge.scm's challenge-answer-hash.
// null when the bytes aren't here: not holding is a fact to say, not a
// hash to guess.
export const answerFor = async (nonceHex, hash) => {
    const bytes = await getContent(hash);
    if (!bytes) return null;
    const n = utf8(nonceHex);
    const both = new Uint8Array(n.length + bytes.byteLength);
    both.set(n);
    both.set(bytes, n.length);
    return sha256Bytes(both);
};

// ── where the bytes come from ─────────────────────────────────────────────
// contentB64 rides in the envelope's params; a cid reaches the lazy
// content-addressed leg. No source is a refusal — the job said what it
// wants stored and neither shape arrived.
export const fetchContent = async (env, opts = {}) => {
    const params = env.params ?? {};
    if (params.contentB64) return fromBase64(params.contentB64);
    if (params.cid) {
        const helia = opts.helia ?? await lazyHelia(opts);
        return helia.fetchBytes(params.cid);
    }
    throw new Error("machine-store: no content source in envelope params");
};

// the content-addressed leg is a capability, not a dependency — import the
// caller's helia wrapper at need, and say 'unavailable rather than fake a
// fetch. opts.heliaModule lets a test or a vendor bundle name the import.
const lazyHelia = async (opts = {}) => {
    try {
        const mod = await import(opts.heliaModule ?? "./helia.js");
        if (typeof mod.fetchBytes !== "function")
            throw new Error("helia module has no fetchBytes");
        return mod;
    } catch (e) {
        throw new Error(`machine-store: content-addressed fetch unavailable (${e.message})`);
    }
};

// ── the claim ─────────────────────────────────────────────────────────────
// The lifecycle: fetch + verify + hold → answer challenges while the claim
// is live → at retention end, land the receipt and evict. The receipt's
// usage is byte-seconds THIS blob accrued — size × seconds held — and its
// outputHash re-hashes the retained bytes, so corruption shows up as a
// digest the verifier can flag rather than a silent shrug.
export const runStoreClaim = async (seam, commune, claimId, env, lenderDid, opts = {}) => {
    const params = env.params ?? {};
    const content = await fetchContent(env, opts);
    // the commitment check: inputHash is sha256(content) — a mismatch means
    // the bytes on offer are not the bytes the job committed, and holding
    // them would only waste the borrower's claim.
    if (await sha256Bytes(content) !== env.inputHash)
        throw new Error("machine-store: content does not hash to the committed inputHash");
    await putContent(env.inputHash, content, { claimId });
    opts.onRow?.(claimId, "held");

    const ttlMs = Math.max(1, (params.ttlSeconds ?? 3600)) * 1000;
    const challengeMs = Math.min(opts.challengeMs ?? 30_000, ttlMs);
    const deadline = Date.now() + ttlMs;

    // answer open challenges on this claim — the node reads the nonce off
    // the row, hashes it against the bytes it holds, posts the digest.
    const poll = async () => {
        if (!seam.machineChallenges || !seam.machineChallengeAnswer) return;
        let list = [];
        try {
            const raw = await seam.machineChallenges(commune, claimId);
            const v = typeof raw === "string" ? JSON.parse(raw) : raw;
            list = Array.isArray(v) ? v : (v && Array.isArray(v.ok) ? v.ok : []);
        } catch { return; }
        for (const ch of list) {
            if (String(ch.state ?? "") !== "open") continue;
            const answer = await answerFor(ch.nonce, env.inputHash);
            if (!answer) continue;   // not holding → let the deadline say it
            try {
                await seam.machineChallengeAnswer(commune, ch.id ?? ch.challengeId, answer);
            } catch { /* next tick */ }
        }
    };

    // one ticker: answer open challenges while live — silence past a
    // deadline reads 'failed — then at retention end re-hash what we still
    // hold, meter it, land the receipt, evict. The claim's own deadline may
    // expire the claim first; that is the registry's business — ours is to
    // stop holding and say so.
    return new Promise((resolve, reject) => {
        const ticker = setInterval(async () => {
            if (Date.now() < deadline) { await poll(); return; }
            clearInterval(ticker);
            try {
                const row = await blobs.get(env.inputHash);
                const held = row?.bytes ?? null;
                const seconds = row ? (Date.now() - row.since) / 1000 : 0;
                const outputHash = held ? await sha256Bytes(held) : null;
                await evictContent(env.inputHash);
                const receipt = await emitReceipt({
                    env, lenderDid, bridgeJobId: claimId,
                    result: { stored: held != null, bytes: held?.byteLength ?? 0 },
                    seconds,
                    usage: { unit: "byte-seconds",
                             amount: Math.round((held?.byteLength ?? 0) * seconds * 1000) / 1000 },
                    outputHash,
                });
                resolve(await seam.machineReceipt(commune, JSON.stringify(receipt)));
            } catch (e) { reject(e); }
        }, challengeMs);
        void poll();
    });
};
