// SPDX-License-Identifier: AGPL-3.0-or-later
// app/machine-executor.ts — the browser IS the node.
//
// A job envelope arrives as the fetch door returns it
// ({bridgeJobId, image, entrypoint, inputHash, caps, network}); runEnvelope
// runs the entrypoint inside a Worker it cannot escape, meters the wall-clock,
// and returns the receipt wire body — the object session/machine-receipt
// accepts. The digest is computed over the same canonical bytes the Scheme
// verifier recomputes (tests/compute/test-receipt.scm carries the vectors):
// sha256("naoms-compute-receipt/v1" + NUL + canonical JSON), field order IS
// the format, absent optionals drop, missing engine/usage/repro emit null.
//
// Sandbox: the worker's globals are stripped — no fetch/XHR/WebSocket/
// sendBeacon/EventSource/importScripts — unless the envelope's network flag
// is true AND its caps name "fetch". A timeout kills the worker; the lender
// owes a receipt by the claim's deadline or the claim expires.
//
// The lender signs when a signer rides opts (loadNodeSigner in
// lib/machine-sig.js — the keystore's non-extractable node key); absent
// one lenderSig rides null and the door answers 'unverifiable, never a
// silent pass.
const RECEIPT_DOMAIN = "naoms-compute-receipt/v1\0";
const hex = (buf) => [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, "0")).join("");
const sha256hex = async (s) => hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
// Canonical JSON — the Scheme side emits exactly what JSON.stringify emits
// for this literal: insertion-ordered keys, no spaces, undefined dropped.
const receiptCanonical = (b) => JSON.stringify({
    bridgeJobId: b.bridgeJobId,
    lenderDid: b.lenderDid,
    inputHash: b.inputHash,
    outputHash: b.outputHash,
    engine: b.engine ?? null,
    usage: b.usage ?? null,
    repro: b.repro ?? null,
    executedAt: b.executedAt,
});
export const digestReceiptBody = async (b) => sha256hex(RECEIPT_DOMAIN + receiptCanonical(b));
// ── the worker ────────────────────────────────────────────────────────────
// The blob prelude runs ENVELOPE's entrypoint and posts the result back.
// Everything that could reach off the sandbox is renamed away before the
// code runs; the cap grant restores it when the envelope allows.
//
// Two image classes:
//   js:…   entrypoint is a JS expression evaluating to (input) => output.
//   wasm:… entrypoint is a module export. "_start" runs the WASI path —
//          stdin is the input's bytes, stdout is the output — and every
//          host fn is DETERMINISTIC (seeded random_get, pinned clock), so
//          the same bytes replay 'exact for free: same module + same input
//          + same seed = same stdout, no RepOps needed. Any other export
//          name calls the raw function and returns its scalar result.
//
// Image bytes: "wasm:data:<b64>" is inline; "wasm:<uri>" fetches and only
// passes the sandbox's network grant — an unsigned wasm: fetch without the
// grant fails closed, never leaks.
const WORKER_PRELUDE = `
const __grant = (self.__caps || []).includes("fetch") && self.__net === true;
if (!__grant) {
  self.fetch = undefined; self.XMLHttpRequest = undefined;
  self.WebSocket = undefined; self.EventSource = undefined;
  self.sendBeacon = undefined; self.importScripts = undefined;
}
// deterministic WASI preview1: stdin=input bytes, stdout=output bytes;
// random_get is a seeded xorshift64, clock pinned — 'exact replay is the
// module's own determinism, not a promise.
const __wasi = (stdinBytes, seed) => {
  let pos = 0, out = [], err = [], t = BigInt(0);
  let rng = (BigInt(seed || 0) ^ 0x9E3779B97F4A7C15n) & 0xFFFFFFFFFFFFFFFFn;
  const next = () => { rng ^= (rng << 13n) & 0xFFFFFFFFFFFFFFFFn;
                       rng ^= rng >> 7n; rng ^= (rng << 17n) & 0xFFFFFFFFFFFFFFFFn;
                       return rng; };
  const iov = (mem, ptr, len) => { const bufs = [];
    for (let i = 0; i < len; i++) { const base = mem.getUint32(ptr + i*8, true);
      bufs.push(new Uint8Array(mem.buffer, base, mem.getUint32(ptr + i*8 + 4, true))); }
    return bufs; };
  const view = () => { throw new Error("wasi: memory export required"); };
  return { set mem(m) { this._m = new DataView(m.buffer); },
    get mem() { return this._m; },
    out: () => out, err: () => err,
    imports: { wasi_snapshot_preview1: {
      fd_write: (w, fd, iovs, iovsLen, nwritten) => {
        const bufs = iov(w._m, iovs, iovsLen); let n = 0;
        for (const b of bufs) { n += b.length; if (fd === 1) out.push(...b); else err.push(...b); }
        w._m.setUint32(nwritten, n, true); return 0; },
      fd_read: (w, fd, iovs, iovsLen, nread) => {
        if (fd !== 0) return 8; let n = 0;
        const bufs = iov(w._m, iovs, iovsLen);
        for (const b of bufs) { const take = Math.min(b.length, stdinBytes.length - pos);
          b.set(stdinBytes.subarray(pos, pos + take)); pos += take; n += take; if (!take) break; }
        w._m.setUint32(nread, n, true); return 0; },
      fd_seek: () => 0, fd_close: () => 0, fd_sync: () => 0,
      fd_fdstat_get: (w, fd, ptr) => { w._m.setUint32(ptr, 0, true); return 0; },
      fd_prestat_get: () => 8, fd_prestat_dir_name: () => 8,
      proc_exit: (w, code) => { w._exit = code; },
      random_get: (w, ptr, len) => { for (let i = 0; i < len; i += 8) {
        const v = next(); for (let j = 0; j < 8 && i + j < len; j++)
          w._m.setUint8(ptr + i + j, Number((v >> BigInt(j*8)) & 255n)); } return 0; },
      clock_time_get: (w, id, prec, ptr) => { w._m.setBigUint64(ptr, t, true); return 0; },
      environ_sizes_get: (w, a, b) => { w._m.setUint32(a, 0, true); w._m.setUint32(b, 0, true); return 0; },
      environ_get: () => 0,
      args_sizes_get: (w, a, b) => { w._m.setUint32(a, 0, true); w._m.setUint32(b, 0, true); return 0; },
      args_get: () => 0,
      sched_yield: () => 0,
      poll_oneoff: (w, in_, out_, n, nevents) => { w._m.setUint32(nevents, 0, true); return 0; },
    } } };
};
self.onmessage = async (e) => {
  try {
    const d = e.data;
    const model = d.model ? new Uint8Array(d.model) : null;
    if (d.kind === "js") {
      const fn = eval("(" + d.entrypoint + ")");
      if (typeof fn !== "function") throw new Error("entrypoint is not a function");
      // ctx rides second — a js image driving its own engine (wllama-style
      // glue over wasm) reads ctx.model; single-arg entrypoints ignore it.
      const out = await fn(d.input, { model, seed: d.seed || 0 });
      self.postMessage({ ok: true, out: out === undefined ? null : out });
      return;
    }
    // wasm: bytes arrive transferred; input becomes stdin bytes
    const stdin = new TextEncoder().encode(JSON.stringify(d.input === undefined ? null : d.input));
    const wasi = __wasi(stdin, d.seed || 0);
    const imports = { wasi_snapshot_preview1: {} };
    for (const k in wasi.imports.wasi_snapshot_preview1)
      imports.wasi_snapshot_preview1[k] = (...a) => wasi.imports.wasi_snapshot_preview1[k](wasi, ...a);
    // the model reaches wasm through deterministic host fns — engine-
    // agnostic: model_len/model_read/seed_get, no filesystem, no clock.
    const env = { mem: null, model, seed: d.seed || 0 };
    imports.env = {
      model_len: () => env.model ? env.model.length : 0,
      model_read: (ptr, off, len) => {
        if (!env.model || !env.mem) return 8;
        const take = Math.min(len, env.model.length - off);
        if (take <= 0) return 8;
        new Uint8Array(env.mem.buffer).set(env.model.subarray(off, off + take), ptr);
        return take;
      },
      seed_get: () => env.seed,
    };
    const { instance } = await WebAssembly.instantiate(d.bytes, imports);
    if (instance.exports.memory) { wasi.mem = instance.exports.memory; env.mem = instance.exports.memory; }
    const entry = instance.exports[d.entrypoint || "_start"];
    if (typeof entry !== "function") throw new Error("no export " + (d.entrypoint || "_start"));
    const r = entry();
    if ((d.entrypoint || "_start") === "_start") {
      const text = new TextDecoder().decode(new Uint8Array(wasi.out()));
      let out; try { out = JSON.parse(text); } catch { out = text; }
      self.postMessage({ ok: true, out, stderr: new TextDecoder().decode(new Uint8Array(wasi.err())) });
    } else self.postMessage({ ok: true, out: r === undefined ? null : r });
  } catch (err) {
    self.postMessage({ ok: false, err: String(err && err.message || err) });
  }
};
`;
const b64ToBytes = (b64) => {
    const bin = atob(b64);
    const u8 = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++)
        u8[i] = bin.charCodeAt(i);
    return u8;
};
// where the module's bytes come from: inline data:, or fetched under the
// envelope's own network grant (no grant → refuse, fail closed).
const wasmBytes = async (env) => {
    const ref = env.image.slice(5);
    if (ref.startsWith("data:")) {
        const b64 = ref.slice(ref.indexOf(",") + 1);
        return b64ToBytes(b64);
    }
    if (!(env.network === true && (env.caps || []).includes("fetch")))
        throw new Error("machine-executor: wasm image ref needs the fetch cap");
    const res = await fetch(ref);
    if (!res.ok)
        throw new Error(`machine-executor: wasm fetch ${res.status}`);
    return new Uint8Array(await res.arrayBuffer());
};
// ── the model stage ─────────────────────────────────────────────────────
// params.model commits the artifact an inference envelope decodes: fetched
// under the envelope's own network grant, verified against sha256 before
// the engine sees a byte, cached keyed BY that hash — a cache hit is by
// definition the verified artifact, so hits never re-fetch or re-verify.
const modelCache = {
    _db: null,
    async _open() {
        if (this._db || typeof indexedDB === "undefined")
            return this._db;
        this._db = await new Promise((res, rej) => {
            const r = indexedDB.open("playnet-models", 1);
            r.onupgradeneeded = () => r.result.createObjectStore("models");
            r.onsuccess = () => res(r.result);
            r.onerror = () => rej(r.error);
        });
        return this._db;
    },
    async get(hash) {
        const db = await this._open();
        if (!db)
            return null;
        return new Promise((res) => {
            const q = db.transaction("models").objectStore("models").get(hash);
            q.onsuccess = () => res(q.result ?? null);
            q.onerror = () => res(null);
        });
    },
    async put(hash, bytes) {
        const db = await this._open();
        if (!db)
            return;
        return new Promise((res) => {
            const tx = db.transaction("models", "readwrite");
            tx.objectStore("models").put(bytes, hash);
            tx.oncomplete = () => res();
            tx.onerror = () => res();
        });
    },
};
const sha256hexBytes = async (u8) => hex(await crypto.subtle.digest("SHA-256", u8));
const modelBytes = async (env) => {
    const m = env.params?.model;
    if (!m || typeof m.uri !== "string" || typeof m.sha256 !== "string")
        throw new Error("machine-executor: params.model needs uri and sha256");
    const hit = await modelCache.get(m.sha256);
    if (hit)
        return hit instanceof Uint8Array ? hit : new Uint8Array(hit);
    if (!(env.network === true && (env.caps || []).includes("fetch")))
        throw new Error("machine-executor: model fetch needs the fetch cap");
    const res = await fetch(m.uri);
    if (!res.ok)
        throw new Error(`machine-executor: model fetch ${res.status}`);
    const got = new Uint8Array(await res.arrayBuffer());
    const digest = await sha256hexBytes(got);
    if (digest !== m.sha256.toLowerCase())
        throw new Error("machine-executor: model sha256 mismatch — the bytes are not the commit");
    await modelCache.put(m.sha256, got);
    return got;
};
export const runEnvelope = async (env, input, opts = {}) => {
    // non-exec kinds need no image; without one there is nothing to run —
    // the scheme parser only forces image on 'exec, and this is the exec path.
    // a "webgpu" cap is a promise the job means to compute on the adapter —
    // request it here so a GPU-less node refuses rather than discovering
    // the absence inside the sandbox and calling it a run.
    if ((env.caps || []).includes("webgpu")) {
        const gpu = opts.gpu ?? (typeof navigator !== "undefined" ? navigator.gpu : null);
        if (!gpu || !(await gpu.requestAdapter()))
            throw new Error("machine-executor: the webgpu cap has no adapter here");
    }
    const isWasm = (env.image ?? "").startsWith("wasm:");
    // the fetch happens OUTSIDE the sandbox — the worker never sees the ref;
    // the network grant check lives here where the bytes actually move
    const bytes = isWasm ? await wasmBytes(env) : null;
    // params.model stages the same way — fetched and verified out here,
    // transferred in as opaque bytes the sandbox reads only through the
    // deterministic host fns (or ctx.model for a js image)
    const mBytes = env.params?.model ? await modelBytes(env) : null;
    // an already-aborted signal refuses before a worker spawns —
    // the member's machine was theirs before the claim ever ran
    if (opts.signal?.aborted)
        throw new Error("machine-executor: aborted");
    return new Promise((resolve, reject) => {
        const timeoutMs = opts.timeoutMs ?? 5 * 60 * 1000;
        const blob = new Blob([`self.__caps = ${JSON.stringify(env.caps || [])};`,
            `self.__net = ${env.network === true};`,
            WORKER_PRELUDE], { type: "text/javascript" });
        const url = URL.createObjectURL(blob);
        const w = new Worker(url);
        const started = Date.now();
        const done = (fn, v) => {
            clearTimeout(timer);
            opts.signal?.removeEventListener?.("abort", onAbort);
            w.terminate();
            URL.revokeObjectURL(url);
            fn(v);
        };
        // a member-first abort kills the worker like the timeout does —
        // no receipt for a run the node's owner reclaimed
        const onAbort = () => done(reject, new Error("machine-executor: aborted"));
        opts.signal?.addEventListener?.("abort", onAbort, { once: true });
        const timer = setTimeout(() => {
            done(reject, new Error(`machine-executor: timeout after ${timeoutMs}ms`));
        }, timeoutMs);
        w.onerror = (e) => {
            done(reject, new Error(`machine-executor: ${e.message || "worker error"}`));
        };
        w.onmessage = (e) => {
            const seconds = (Date.now() - started) / 1000;
            if (e.data && e.data.ok)
                done(resolve, { result: e.data.out, seconds });
            else
                done(reject, new Error(`machine-executor: ${e.data && e.data.err || "failed"}`));
        };
        const transfers = [];
        if (isWasm)
            transfers.push(bytes.buffer);
        if (mBytes)
            transfers.push(mBytes.buffer);
        if (isWasm) {
            const buf = bytes.buffer;
            w.postMessage({ kind: "wasm", entrypoint: env.entrypoint || "_start",
                bytes: buf, input: input ?? null,
                seed: opts.seed ?? env.params?.model?.seed ?? 0,
                model: mBytes ? mBytes.buffer : null }, transfers);
        }
        else {
            w.postMessage({ kind: "js", entrypoint: env.entrypoint, input: input ?? null,
                seed: opts.seed ?? env.params?.model?.seed ?? 0,
                model: mBytes ? mBytes.buffer : null }, transfers);
        }
    });
};
// ── the receipt ───────────────────────────────────────────────────────────
// The body machine-receipt verifies: digest recomputed here matches what the
// door recomputes there, or the receipt is refused. Unsigned — 'unverifiable
// is an honest verdict, 'bad would not be.
export const emitReceipt = async (args) => {
    const { env, result, seconds } = args;
    // the DID the signature will verify under — a signer in hand means
    // the node signs as its own did:key; the field must name that key
    // or the door's verdict is 'bad on a real signature.
    const lenderDid = args.lenderDid ?? args.signer?.did ?? null;
    const body = {
        // the door keys the receipt by the CLAIM's id — the envelope's own
        // bridgeJobId is the submitter's tag, not the claim it landed under
        bridgeJobId: args.bridgeJobId ?? env.bridgeJobId,
        lenderDid,
        inputHash: env.inputHash,
        outputHash: args.outputHash ?? await sha256hex(JSON.stringify(result ?? null)),
        engine: env.image || null,
        usage: args.usage ?? { unit: "seconds", amount: Math.round(seconds * 1000) / 1000 },
        repro: args.reproMode
            ? {
                mode: args.reproMode,
                ...(args.seed !== undefined ? { seed: args.seed } : {}),
            }
            : null,
        executedAt: Date.now(),
    };
    const digest = await digestReceiptBody(body);
    // the lender signs the digest when a signer is in hand — the door
    // verifies did:key sigs outright and AID sigs through the key
    // resolver; absent a signer the null rides to 'unverifiable, the
    // honest verdict (never a silent pass, never a fabricated sig).
    const lenderSig = args.signer ? await args.signer.sign(digest) : null;
    return { ...body, lenderSig, borrowerSig: null, digest };
};
// ── the loop, one claim at a time ─────────────────────────────────────────
// fetch the envelope → run it → land the receipt. SEAM is the browser's
// session bridge (machineFetchEnvelope, machineReceipt). The claim's
// deadline is the timeout — no countersigned receipt by the deadline means
// no payment; the registry's expiry already knows that.
export const runClaim = async (seam, commune, claimId, lenderDid, input, opts = {}) => {
    const raw = await seam.machineFetchEnvelope(commune, claimId);
    if (typeof raw === "string" && raw.startsWith("err:"))
        throw new Error(`machine-executor: ${raw}`);
    const env = (typeof raw === "string" ? JSON.parse(raw) : raw);
    // a swarm descriptor rides any kind — the leg resolves its input from
    // the bus and publishes its output to it; the kind's own runner still
    // does the work inside.
    if (env.params?.swarm) {
        const { runSwarmClaim } = await import("./machine-swarm.js");
        return runSwarmClaim(seam, commune, claimId, env, lenderDid, input, opts);
    }
    // the store kind doesn't run a worker — it holds bytes and answers
    // challenges; the relay kind moves bytes and answers neither — each
    // imported at need so the exec path never pays for legs it doesn't run.
    if (env.kind === "store") {
        const { runStoreClaim } = await import("./machine-store.js");
        return runStoreClaim(seam, commune, claimId, env, lenderDid, opts);
    }
    if (env.kind === "relay") {
        const { runRelayClaim } = await import("./machine-relay.js");
        return runRelayClaim(seam, commune, claimId, env, lenderDid, opts);
    }
    if (env.kind === "sense") {
        const { runSenseClaim } = await import("./machine-sense.js");
        return runSenseClaim(seam, commune, claimId, env, lenderDid, opts);
    }
    if (env.kind === "bundle") {
        const { runBundleClaim } = await import("./machine-bundle.js");
        return runBundleClaim(seam, commune, claimId, env, lenderDid, opts);
    }
    const { result, seconds } = await runEnvelope(env, input, opts);
    // an inference engine that reports a token count meters in tokens —
    // the kind's own unit; the count rides inside the hashed result so a
    // challenge replays the decode it names, not just its byte output.
    const model = env.params?.model;
    const usage = model && result && typeof result.tokens === "number"
        ? { unit: "tokens", amount: result.tokens }
        : undefined;
    const receipt = await emitReceipt({
        env, lenderDid, input, result, seconds,
        bridgeJobId: claimId,
        reproMode: opts.reproMode, seed: opts.seed ?? model?.seed,
        usage,
        signer: opts.signer,
    });
    return seam.machineReceipt(commune, JSON.stringify(receipt));
};
// ── when this tab should lend at all ────────────────────────────────────
// opts.policy names the holds a node honors instead of claiming capacity
// it cannot deliver — each returns the reason it holds, or null:
//   pauseWhenHidden — a hidden tab is deprioritized; work claimed on it is
//                     a deadline the scheduler didn't promise to keep
//   pauseOnSaveData — a metered connection shouldn't carry jobs unasked
//   minBatteryLevel — unplugged below it, "headroom" is a lie the offer told
// An API the platform can't answer is not a constraint — a desktop with no
// battery API has no battery reason to hold.
export const policyHold = async (policy) => {
    if (!policy)
        return null;
    try {
        if (policy.pauseWhenHidden && typeof document !== "undefined"
            && document.visibilityState === "hidden")
            return "hidden";
        if (policy.pauseOnSaveData
            && typeof navigator !== "undefined" && navigator.connection?.saveData)
            return "save-data";
        if (policy.minBatteryLevel && typeof navigator !== "undefined"
            && navigator.getBattery) {
            const b = await navigator.getBattery();
            if (!b.charging && b.level < policy.minBatteryLevel)
                return "battery";
        }
    }
    catch { /* a refused probe is no reading — no hold from it */ }
    return null;
};
export const lendLoop = (seam, commune, lenderDid, input, opts = {}) => {
    const attempted = new Set();
    let stopped = false;
    let lastHold = null;
    let running = 0;
    const tick = async () => {
        if (stopped || !seam.machineClaims)
            return;
        const hold = await policyHold(opts.policy);
        if (hold !== lastHold) {
            lastHold = hold;
            opts.onPolicy?.(hold);
        }
        if (hold)
            return;
        let rows = [];
        try {
            const raw = await seam.machineClaims(commune);
            const v = typeof raw === "string" ? JSON.parse(raw) : raw;
            rows = (Array.isArray(v) ? v
                : (v && Array.isArray(v.ok)
                    ? v.ok : []));
        }
        catch {
            return;
        }
        for (const r of rows) {
            const claimId = String(r.claimId ?? r.id ?? "");
            const state = String(r.state ?? "");
            if (!claimId || attempted.has(claimId))
                continue;
            if (String(r.lender ?? r.lenderDid ?? "") !== lenderDid)
                continue;
            if (state !== "claimed" && state !== "accepted")
                continue;
            // maxClaims — the member's own machine stays first: lending
            // never crowds out more capacity than the node offered
            if (opts.maxClaims !== undefined && running >= opts.maxClaims)
                break;
            attempted.add(claimId);
            running++;
            opts.onRow?.(claimId, "running");
            // every run is governed: a landing hold or a claim that left
            // the live states aborts the worker and lands as preempt —
            // honest eviction, unpaid, the job requeues outward
            import("./machine-governor.js")
                .then((g) => g.runClaimGoverned(seam, commune, claimId,
                                                lenderDid, input, opts))
                .then(() => opts.onRow?.(claimId, "done"))
                .catch((e) => opts.onRow?.(claimId, `err:${e instanceof Error ? e.message : e}`))
                .finally(() => { running--; });
        }
    };
    const t = setInterval(tick, opts.intervalMs ?? 30_000);
    void tick();
    return () => { stopped = true; clearInterval(t); };
};
