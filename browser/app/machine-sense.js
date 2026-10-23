// app/machine-sense.js — the sense kind's node leg: read what the
// platform honestly reports, on an interval, and meter 'readings.
//
// A 'sense envelope asks this tab to be an instrument, not a worker:
// params.sources names which sensors to sample — each reading is
// {source, at, value} where value is whatever the platform API answered
// THIS tick. A source the platform cannot answer reports itself in
// result.unavailable rather than fabricating a value — a reading is a
// measurement, and a guessed measurement is worse than an honest gap.
//
//   sources — "battery" | "network" | "storage" | "machine" | "presence"
//   intervalMs — the tick (default 5000, floor 250 — a sensor that polls
//                faster than the platform settles is noise, not signal)
//   count | durationMs — how long to sample: N ticks, or a wall-clock
//                budget; count wins when both are named. Neither named
//                is one tick — a snapshot, not a stream.
//
// The receipt meters 'readings — the count of real samples taken — and
// outputHash binds the whole readings array, so the report is the proof.

import { emitReceipt } from "./machine-executor.js";

const hex = (buf) => [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, "0")).join("");
const sha256hex = async (s) => hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// ── the sources ───────────────────────────────────────────────────────────
// Each is () => value | throws; a throw lands the source in unavailable —
// the instrument reports the hole rather than guessing.
const SOURCES = {
    battery: async () => {
        if (typeof navigator === "undefined" || !navigator.getBattery)
            throw new Error("no battery API");
        const b = await navigator.getBattery();
        return { charging: b.charging, level: b.level };
    },
    network: async () => {
        const c = typeof navigator !== "undefined" ? navigator.connection : null;
        if (!c) throw new Error("no connection API");
        return { downlink: c.downlink ?? null, rtt: c.rtt ?? null,
                 effectiveType: c.effectiveType ?? null, saveData: c.saveData ?? null };
    },
    storage: async () => {
        const est = typeof navigator !== "undefined" ? navigator.storage?.estimate : null;
        if (!est) throw new Error("no storage estimate API");
        const e = await est.call(navigator.storage);
        return { quota: e.quota ?? null, usage: e.usage ?? null };
    },
    machine: async () => {
        if (typeof navigator === "undefined") throw new Error("no navigator");
        return { cores: navigator.hardwareConcurrency ?? null,
                 memGB: navigator.deviceMemory ?? null,
                 gpu: !!navigator.gpu };
    },
    presence: async () => {
        const vis = typeof document !== "undefined" ? document.visibilityState : null;
        if (vis === null) throw new Error("no document");
        return { visibility: vis,
                 userActive: navigator?.userActivation?.isActive ?? null,
                 focused: typeof document.hasFocus === "function" ? document.hasFocus() : null };
    },
};

export const SENSE_SOURCES = Object.keys(SOURCES);

// one tick: read every source once; failures collect, they don't abort —
// a battery-less desktop still answers the network sample it was asked.
export const readOnce = async (env) => {
    const names = env.params?.sources;
    if (!Array.isArray(names) || !names.length)
        throw new Error("machine-sense: params.sources names the sensors");
    for (const n of names)
        if (!SOURCES[n]) throw new Error(`machine-sense: unknown source ${n}`);
    const readings = [], unavailable = [];
    const at = Date.now();
    for (const n of names) {
        try { readings.push({ source: n, at, value: await SOURCES[n]()}); }
        catch (e) { unavailable.push({ source: n, why: e.message }); }
    }
    return { readings, unavailable };
};

// ── the claim ─────────────────────────────────────────────────────────────
// count ticks or a duration, whichever the envelope names; the meter is
// the readings taken, and every unavailable source is reported once per
// tick in result.unavailable — visible, not silent.
export const runSenseClaim = async (seam, commune, claimId, env, lenderDid, opts = {}) => {
    const params = env.params ?? {};
    const intervalMs = Math.max(250, params.intervalMs ?? 5000);
    const count = params.count ??
        (params.durationMs ? Math.max(1, Math.round(params.durationMs / intervalMs)) : 1);
    const readings = [], unavailable = {};
    let ticks = 0;
    for (let i = 0; i < count; i++) {
        const r = await readOnce(env);
        readings.push(...r.readings);
        for (const u of r.unavailable)
            (unavailable[u.source] ??= []).push(u.why);
        ticks++;
        if (i + 1 < count) await sleep(intervalMs);
    }
    const result = { ticks, sources: params.sources,
                     readings, unavailable,
                     seconds: Math.round((Date.now() - (readings[0]?.at ?? Date.now())) / 10) / 100 };
    const receipt = await emitReceipt({
        env, lenderDid, bridgeJobId: claimId,
        result,
        seconds: 0,
        usage: { unit: "readings", amount: readings.length },
        outputHash: await sha256hex(JSON.stringify(readings)),
        signer: opts.signer,
    });
    return seam.machineReceipt(commune, JSON.stringify(receipt));
};
