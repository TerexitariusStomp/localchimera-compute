// SPDX-License-Identifier: AGPL-3.0-or-later
// browser/app/machine-swarm.js — the shard-side runner: what a claimed
// swarm leg does beyond running its envelope.
//
// A swarm leg is still ONE claim on ONE envelope — the receipt, the
// deadline, the metering are the claim's own. What params.swarm changes
// is only WHERE the shard's input comes from and WHERE its output goes;
// the kind's runner (runEnvelope, and in P3 the store/relay legs) does
// the actual work, so a shard replays like any other claim.
//
//   map   — deterministic slice i of the swarm input in, a result slice
//           out, posted to the bus for the merge leg
//   stage — pipeline position shardIndex: input is the previous shard's
//           posted output (the swarm input for shard 0), output posted
//           for the next shard; the last shard's output IS the answer
//   merge — reads sibling shard-output posts off the bus until quorum
//           (or the deadline), assembles them in shard-index order, and
//           its own receipt's outputHash binds the aggregate
//
// The bus is machine-swarm-signal(s) — the swarm-scoped signal shelf the
// doors gate to members. Posts carry {type:"shard-output", shard, of,
// outputHash, output}; a shard never trusts a post it cannot read back —
// the seq'd shelf IS the transcript.

const hex = (b) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
const sha256hex = async (s) => hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));

// deterministic contiguous split — the same input, shards and index
// always name the same slice, so a replayed shard sees the same bytes.
// Arrays split by element, strings by char, bytes by byte.
const sliceInput = (input, shards, index) => {
    if (Array.isArray(input)) {
        const n = input.length;
        const lo = Math.floor((n * index) / shards);
        const hi = Math.floor((n * (index + 1)) / shards);
        return input.slice(lo, hi);
    }
    if (typeof input === "string" || input instanceof Uint8Array) {
        const n = input.length;
        const lo = Math.floor((n * index) / shards);
        const hi = Math.floor((n * (index + 1)) / shards);
        return input.slice(lo, hi);
    }
    // a scalar input is the whole swarm's — every shard gets it; the
    // shard index still names which shard ran what for the receipt.
    return input;
};

// the bus over the seam's swarm doors — post(body) seqs a row,
// read(after) answers the rows strictly after it.
const busOf = (seam, commune, group) => ({
    post: async (body) => {
        const r = await seam.machineSwarmSignal(commune, group, body);
        if (typeof r === "string" && r.startsWith("err:"))
            throw new Error(`machine-swarm: ${r}`);
        return r;
    },
    read: async (after = 0) => {
        const r = await seam.machineSwarmSignals(commune, group, after);
        const v = typeof r === "string" ? JSON.parse(r) : r;
        return Array.isArray(v) ? v : (v?.ok ?? []);
    },
});

// wait for the shard-output post naming SHARD — the stage's input is
// the sibling's output, and the shelf's seq order is the transcript.
// Deadline past → an honest refusal, never a fabricated input.
const awaitShard = async (bus, shard, opts) => {
    const deadline = Date.now() + (opts.busDeadlineMs ?? 120_000);
    const poll = opts.busPollMs ?? 500;
    let cursor = 0;
    while (Date.now() < deadline) {
        const rows = await bus.read(cursor);
        for (const r of rows) {
            cursor = Math.max(cursor, r.seq ?? cursor);
            if (r.body?.type === "shard-output" && r.body?.shard === shard)
                return r.body;
        }
        await new Promise((res) => setTimeout(res, poll));
    }
    throw new Error(`machine-swarm: shard ${shard} never posted before the deadline`);
};

// gather every sibling shard-output until QUORUM are in or the deadline
// falls — missing shards are named honestly in the returned set.
const gatherShards = async (bus, shards, selfIndex, quorum, opts) => {
    const deadline = Date.now() + (opts.busDeadlineMs ?? 120_000);
    const poll = opts.busPollMs ?? 500;
    const got = new Map();
    let cursor = 0;
    while (Date.now() < deadline && got.size < quorum) {
        const rows = await bus.read(cursor);
        for (const r of rows) {
            cursor = Math.max(cursor, r.seq ?? cursor);
            const b = r.body;
            if (b?.type === "shard-output" && b.shard !== selfIndex
                && Number.isInteger(b.shard) && b.shard >= 0 && b.shard < shards)
                got.set(b.shard, b);
        }
        if (got.size >= quorum) break;
        await new Promise((res) => setTimeout(res, poll));
    }
    const missing = [];
    for (let i = 0; i < shards; i++)
        if (i !== selfIndex && !got.has(i)) missing.push(i);
    return { got, missing };
};

export const runSwarmClaim = async (seam, commune, claimId, env, lenderDid,
                                    input, opts = {}) => {
    const s = env.params?.swarm;
    if (!s) return null; // not a swarm leg — the caller's own dispatch
    const bus = busOf(seam, commune, s.group);
    const { runEnvelope, emitReceipt } = await import("./machine-executor.js");
    // the wire keeps the Scheme spelling (shard-index); a borrower-written
    // camelCase descriptor reads the same — both name this claim's shard.
    const index = s["shard-index"] ?? s.shardIndex ?? 0;

    // ── input resolution — the role says where this shard's bytes are ──
    let shardInput = input;
    if (s.role === "map")
        shardInput = sliceInput(input, s.shards, index);
    else if (s.role === "stage" && index > 0) {
        const prev = await awaitShard(bus, index - 1, opts);
        shardInput = prev.output;
    }

    // ── the merge leg gathers before it runs ──
    let gathered = null;
    if (s.role === "merge") {
        const quorum = s.quorum ?? s.shards - 1; // every shard but itself
        gathered = await gatherShards(bus, s.shards, index, quorum, opts);
        // the merge's input is the assembled siblings, in shard order —
        // deterministic: the same posts always concatenate the same way.
        shardInput = [...gathered.got.keys()]
            .sort((a, b) => a - b)
            .map((i) => gathered.got.get(i).output);
    }

    const { result, seconds } = await runEnvelope(env, shardInput, opts);
    const outputHash = await sha256hex(JSON.stringify(result ?? null));

    // ── output publication — the bus learns what this shard produced ──
    const post = { type: "shard-output", shard: index, of: s.shards,
                   role: s.role, outputHash, output: result ?? null };
    if (gathered && gathered.missing.length)
        post.partial = gathered.missing; // honest: these shards never spoke
    await bus.post(post);

    // ── the claim's own receipt — kind unit, claim id, honest hash ──
    const receipt = await emitReceipt({
        env, lenderDid, input: shardInput, result, seconds,
        bridgeJobId: claimId,
        outputHash,
        reproMode: opts.reproMode, seed: opts.seed ?? env.params?.model?.seed,
        signer: opts.signer,
    });
    return seam.machineReceipt(commune, JSON.stringify(receipt));
};
