// SPDX-License-Identifier: AGPL-3.0-or-later
// app/machine-dvm.js — the NIP-90 demand source: paid compute a browser
// tab can honestly serve today.
//
// The flow, end to end:
//
//   1. REQ subscriptions on the configured relays for the job-request
//      kinds this tab serves (default 5050 — text processing).
//   2. Each signed request mints a postpaid demand job through the
//      ordinary intake: payer "nostr-dvm", ref "nostr:<event id>",
//      keyHash "nostr:<buyer pubkey>" — the buyer's receivable book
//      appears on first sight, nothing is fabricated.
//   3. The job rides the normal lanes — any lender in the commune can
//      claim it; the DVM tab is the demand edge, not the executor.
//   4. machineDemandJob polls to a terminal state; the paid-for output
//      arrives on the claim's signal log as a demand-result post.
//   5. The kind+1000 result event publishes with an `amount` tag naming
//      the price (millisats) — NIP-90's settlement cue. The ledger row
//      stays 'running until the operator's rail confirms and
//      markPaid() lands machinePayerSettle.
//
// Payment honesty: `bid` is the buyer's ceiling in millisats. A bid
// under the price gets payment-required feedback, not silent free work;
// with no price configured the tab serves openly — the operator's
// choice, not an accident. There is no invoice magic here: the rail
// (zap, LN webhook, mutual credit) lives outside this file, and the
// ledger row records the receivable either way.

import { NostrRelay, finalizeEvent, verifyEvent, publicKeyHex } from "../lib/nostr.js";

// request kinds this runner serves by default — 5050 is NIP-90 text
// generation/extraction, the kind a browser executor honestly runs.
// Add kinds only when the commune's envelopes can mean them.
export const DVM_KINDS = Object.freeze({ 5050: "text-processing" });

const sha256hex = async (u8) =>
    [...new Uint8Array(await crypto.subtle.digest("SHA-256", u8))]
        .map((b) => b.toString(16).padStart(2, "0")).join("");

const tag = (ev, name) => ev.tags.find((t) => t[0] === name);
const tagAll = (ev, name) => ev.tags.filter((t) => t[0] === name);

// the seam's wire reply → a plain object; an "err:…" string or an
// {error} payload is a refusal either way
const unwrap = (raw) => {
    const v = typeof raw === "string" ? JSON.parse(raw) : raw;
    if (v && typeof v === "object" && "ok" in v) return v.ok;
    return v;
};
const refused = (raw) =>
    (typeof raw === "string" && raw.startsWith("err:")) ? raw
        : (() => {
            const v = typeof raw === "string" ? null : raw;
            return v?.error ? String(v.error) : null;
        })();

// event → the demand job's params.input: the NIP-90 payload rides
// verbatim so the lender's executor sees exactly what the buyer asked
const jobInput = (ev) => ({
    dvmKind: ev.kind,
    requester: ev.pubkey,
    inputs: tagAll(ev, "i").map((t) => ({ type: t[2] ?? "text", data: t[1] })),
    params: Object.fromEntries(
        tagAll(ev, "param").map((t) => [t[1], t.slice(2)])),
    output: tag(ev, "output")?.[1],
});

const dvmEnvelope = (ev, ref, ih) => ({
    kind: "exec", bridgeJobId: ref,
    image: "js:demand", entrypoint: "demand",
    inputHash: ih, caps: [], network: false,
    params: { input: jobInput(ev) },
});

export const serveDvm = (seam, commune, cfg) => {
    const kinds = new Set(cfg.kinds ?? Object.keys(DVM_KINDS).map(Number));
    const pub = publicKeyHex(cfg.seckey);
    const priceSats = cfg.priceSats ?? 0;
    const pollMs = cfg.pollMs ?? 5000;
    const maxJobs = cfg.maxJobs ?? 4;
    const seen = new Set();
    const running = new Map(); // eventId → {jobId, rowId, claimIds}
    const relays = (cfg.relays ?? []).map((u) => new NostrRelay(u, cfg.wsOpts ?? {}));
    let stopped = false;

    const publish = async (partial) =>
        Promise.all(relays.map((r) => finalizeEvent(cfg.seckey, partial)
            .then((ev) => r.publish(ev))));

    const feedback = (req, status, extra = []) =>
        publish({
            kind: 7000, content: "",
            tags: [["e", req.id], ["p", req.pubkey], ["status", status, ...extra]],
        });

    const answer = (req, content) =>
        publish({
            kind: req.kind + 1000, content,
            tags: [["e", req.id], ["p", req.pubkey],
                   ["request", JSON.stringify(req)],
                   ["amount", String(priceSats * 1000)]],
        });

    // the paid-for output: demand-result posts on the claim's signal
    // log (the borrower is a party, so the read is its own)
    const outputOf = async (job) => {
        for (const c of job.claims ?? []) {
            try {
                const raw = await seam.machineSignals(commune, c.id, 0);
                const v = typeof raw === "string" ? JSON.parse(raw) : raw;
                const rows = Array.isArray(v) ? v : (v?.ok ?? []);
                for (const r of rows) {
                    const body = typeof r.body === "string" ? JSON.parse(r.body) : r.body;
                    if (body?.type === "demand-result") return body.output;
                }
            } catch { /* a claim with no log yet carries nothing */ }
        }
        return null;
    };

    const poll = async (req, rec) => {
        while (!stopped) {
            await new Promise((r) => setTimeout(r, pollMs));
            if (stopped) return;
            let job;
            try { job = unwrap(await seam.machineDemandJob(commune, rec.jobId)); }
            catch { continue; /* a transient read fails nothing */ }
            const state = String(job?.state ?? "");
            if (state === "open" || state === "claimed" || state === "accepted")
                continue;
            running.delete(req.id);
            if (state === "verified" || state === "receipted" || state === "done") {
                const out = await outputOf(job);
                await answer(req, JSON.stringify(out ?? { receipt: job }));
                await feedback(req, "success");
            } else {
                await feedback(req, "error", [`job:${state}`]);
            }
            return;
        }
    };

    const handle = async (ev) => {
        if (stopped || seen.has(ev.id) || running.size >= maxJobs) return;
        seen.add(ev.id);
        if (!(await verifyEvent(ev))) return;
        const p = tag(ev, "p");
        if (p && p[1] !== pub) return; // addressed to another DVM
        const bidMsats = Number(tag(ev, "bid")?.[1] ?? 0);
        if (bidMsats < priceSats * 1000) {
            await feedback(ev, "payment-required", [String(priceSats * 1000)]);
            return;
        }
        await feedback(ev, "processing");
        const keyHash = `nostr:${ev.pubkey}`;
        const ref = `nostr:${ev.id}`;
        const ih = `b3:${await sha256hex(new TextEncoder().encode(ev.id + JSON.stringify(jobInput(ev))))}`;
        const raw = await seam.machineDemandIntake(
            commune, keyHash, "nostr-dvm", ref, priceSats,
            cfg.taskClass ?? "swarm-infer", cfg.lane ?? "member",
            "deterministic", ih,
            { envelope: dvmEnvelope(ev, ref, ih), postpaid: true });
        const err = refused(raw);
        if (err) { await feedback(ev, "error", [err.slice(0, 200)]); return; }
        const rec = unwrap(raw);
        running.set(ev.id, { jobId: rec.jobId ?? rec["jobId"], rowId: rec.rowId ?? rec["rowId"] });
        void poll(ev, running.get(ev.id));
    };

    const start = async () => {
        const filter = { kinds: [...kinds], since: Math.floor(Date.now() / 1000) };
        await Promise.all(relays.map((r, i) =>
            r.subscribe(`dvm-${i}`, [filter], (ev) => void handle(ev))));
    };

    const stop = () => {
        stopped = true;
        relays.forEach((r) => r.close());
    };

    // the operator's rail confirms sats landed → the row's 'paid mark
    const markPaid = (rowId) => seam.machinePayerSettle?.(commune, rowId);

    return { start, stop, markPaid, pubkey: pub,
             running, feedback, answer };
};
