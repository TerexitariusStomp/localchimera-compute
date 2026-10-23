// app/machine-bundle.js — the bundle kind's node leg: sub-envelopes run
// in order on the one claim, and the receipt binds the legs' report.
//
// A 'bundle envelope carries params.legs — a list of wire envelopes, each
// with its own kind — run SEQUENTIALLY on this node. A leg that fails
// fails the bundle and names its index; there is no partial carry,
// because the receipt's honesty is only as good as its least proven leg.
//
// The receipt's usage is 'seconds — the only meter that can honestly sum
// across kinds — while each leg's own meter rides in the legs report the
// outputHash binds. The report is the digest's preimage: evidence a
// verifier demands the same way it demands an exec run's output.
//
// Legs run one level deep — a bundle inside a bundle is refused: one
// nesting is a job description, two is an obfuscation.

import { emitReceipt, runEnvelope } from "./machine-executor.js";
import { readOnce } from "./machine-sense.js";

const hex = (buf) => [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, "0")).join("");
const sha256hex = async (s) => hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// ── the leg runners ───────────────────────────────────────────────────────
// Each answers {usage:{unit,amount}, outputHash?, note} — the leg's own
// meter, never the bundle's. Lazy imports keep the exec path free of legs
// it will never run.
const legRunners = {
    exec: async (leg, seam, commune, claimId, opts) => {
        const { result, seconds } = await runEnvelope(leg, opts.input, opts);
        return { usage: { unit: "seconds", amount: Math.round(seconds * 1000) / 1000 },
                 note: result };
    },
    sense: async (leg) => {
        const params = leg.params ?? {};
        const intervalMs = Math.max(250, params.intervalMs ?? 5000);
        const count = params.count ??
            (params.durationMs ? Math.max(1, Math.round(params.durationMs / intervalMs)) : 1);
        const readings = [], unavailable = {};
        for (let i = 0; i < count; i++) {
            const r = await readOnce(leg);
            readings.push(...r.readings);
            for (const u of r.unavailable) (unavailable[u.source] ??= []).push(u.why);
            if (i + 1 < count) await sleep(intervalMs);
        }
        return { usage: { unit: "readings", amount: readings.length },
                 note: { ticks: count, unavailable },
                 outputHash: await sha256hex(JSON.stringify(readings)) };
    },
    relay: async (leg, seam, commune, claimId, opts) => {
        const R = await import("./machine-relay.js");
        const params = leg.params ?? {};
        if (params.probe) {
            const r = await R.probe(leg);
            return { usage: { unit: "bytes", amount: r.bytes }, note: r };
        }
        if (params.channel) {
            const l = await R.channelLeg(seam, commune, claimId, leg, opts);
            return { usage: { unit: "bytes", amount: l.sent + l.received },
                     note: { direction: params.direction ?? "recv",
                             sent: l.sent, received: l.received },
                     outputHash: l.received
                         ? await sha256hex(JSON.stringify([...l.bytes])) : null };
        }
        const l = await R.httpLeg(leg);
        return { usage: { unit: "bytes", amount: l.moved },
                 note: { inUrl: params.inUrl, outUrl: params.outUrl ?? null,
                         bytes: l.bytes.byteLength },
                 outputHash: await sha256hex(JSON.stringify([...l.bytes])) };
    },
    store: async (leg) => {
        // a store leg inside a bundle holds for params.durationMs (or one
        // tick of nothing), meters the byte-seconds it actually held, and
        // evicts — the long-retention semantics belong to a real claim,
        // not a job step.
        const S = await import("./machine-store.js");
        const bytes = await S.fetchContent(leg, {});
        const holdMs = Math.max(0, leg.params?.durationMs ?? 0);
        const before = await S.byteSeconds();
        await S.putContent(leg.inputHash, bytes, { claimId: "bundle-leg" });
        if (holdMs) await sleep(holdMs);
        const accrued = await S.byteSeconds() - before;
        await S.evictContent(leg.inputHash);
        return { usage: { unit: "byte-seconds", amount: Math.max(0, accrued) },
                 note: { held: bytes.byteLength, holdMs } };
    },
};

// ── the legs ──────────────────────────────────────────────────────────────
// Each leg answers {index, kind, usage, note, outputHash?} — the leg's own
// meter. Exported so a verifier (or a test) runs the same legs the claim
// did; the claim is this plus a receipt.
export const runLegs = async (env, seam, commune, claimId, opts = {}) => {
    const legs = env.params?.legs;
    if (!Array.isArray(legs) || !legs.length)
        throw new Error("machine-bundle: params.legs is the job");
    if (legs.some(l => l?.kind === "bundle"))
        throw new Error("machine-bundle: a bundle does not bundle bundles");
    const reports = [];
    for (let i = 0; i < legs.length; i++) {
        const leg = legs[i];
        const kind = leg?.kind ?? "exec";
        const run = legRunners[kind];
        if (!run) throw new Error(`machine-bundle: leg ${i}: unknown kind ${kind}`);
        try {
            reports.push({ index: i, kind, ...(await run(leg, seam, commune, claimId, opts)) });
        } catch (e) {
            throw new Error(`machine-bundle: leg ${i} (${kind}): ${e.message}`);
        }
    }
    return reports;
};

// ── the claim ─────────────────────────────────────────────────────────────
export const runBundleClaim = async (seam, commune, claimId, env, lenderDid, opts = {}) => {
    const started = Date.now();
    const reports = await runLegs(env, seam, commune, claimId, opts);
    const seconds = (Date.now() - started) / 1000;
    const receipt = await emitReceipt({
        env, lenderDid, bridgeJobId: claimId,
        result: { legs: reports },
        seconds,
        usage: { unit: "seconds", amount: Math.round(seconds * 1000) / 1000 },
        outputHash: await sha256hex(JSON.stringify(reports)),
    });
    return seam.machineReceipt(commune, JSON.stringify(receipt));
};
