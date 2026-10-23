// SPDX-License-Identifier: AGPL-3.0-or-later
// browser/app/machine-governor.js — member-first: the owner's own
// machine use always wins over the work this tab is lending.
//
// policyHold gates a claim BEFORE it starts; the governor watches DURING
// the run. Two signals end a run honestly:
//
//   • a landing policy hold — the tab hid, the connection went metered,
//     the battery dropped: the node can't promise the deadline it took
//   • the claim leaving the live states — withdrawn, expired, or
//     preempted by the borrower or a governor elsewhere: there is no
//     receipt to write for a claim that no longer exists
//
// The abort kills the worker through runEnvelope's own signal surface —
// the same termination the timeout uses — then the governor converts it
// to machine-preempt: the registry records 'preempted (unpaid, NOT a
// miss) and bumps the job outward a ring to requeue. The borrower's work
// continues on another node; the member's machine is simply theirs again.

import { policyHold } from "./machine-executor.js";

// watchRun — poll the member's own pressure plus the claim's liveness
// while a run is live; fire abort(why) on the first honest reason to
// stop. Returns the stop fn.
export const watchRun = (seam, commune, claimId, abort, opts = {}) => {
    let stopped = false;
    const tick = async () => {
        if (stopped) return;
        const hold = await policyHold(opts.policy);
        if (hold) return void abort(`hold:${hold}`);
        if (!seam.machineClaims) return;
        let rows = [];
        try {
            const raw = await seam.machineClaims(commune);
            const v = typeof raw === "string" ? JSON.parse(raw) : raw;
            rows = Array.isArray(v) ? v : (v?.ok ?? []);
        } catch { return; /* a transient read fails nothing */ }
        const row = rows.find((r) => String(r.claimId ?? r.id ?? "") === claimId);
        if (!row) return void abort("claim:gone");
        const state = String(row.state ?? "");
        if (state !== "claimed" && state !== "accepted")
            return void abort(`claim:${state}`);
    };
    const t = setInterval(tick, opts.watchMs ?? 5_000);
    void tick();
    return () => { stopped = true; clearInterval(t); };
};

// runClaimGoverned — runClaim under the governor's eye. An abort lands
// as machine-preempt on the claim before the error surfaces: the record
// is honest (preempted, not failed), the job requeues, and no receipt
// pretends a run that was stopped mid-way.
export const runClaimGoverned = async (seam, commune, claimId, lenderDid,
                                       input, opts = {}) => {
    const { runClaim } = await import("./machine-executor.js");
    const ctl = new AbortController();
    let why = null;
    const stop = watchRun(seam, commune, claimId,
                          (w) => { why = w; ctl.abort(); }, opts);
    try {
        return await runClaim(seam, commune, claimId, lenderDid, input,
                              { ...opts, signal: ctl.signal });
    } catch (e) {
        if (ctl.signal.aborted) {
            try { await seam.machinePreempt?.(commune, claimId); } catch { }
            throw new Error(`machine-governor: ${why ?? "aborted"}`);
        }
        throw e;
    } finally { stop(); }
};
