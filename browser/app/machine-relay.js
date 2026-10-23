// app/machine-relay.js — the relay kind's node leg: move bytes, meter them.
//
// A 'relay envelope asks this tab to move bytes; its params name the legs:
//
//   inUrl / outUrl — the HTTP leg: GET the bytes in, POST them onward.
//         Both legs need the envelope's own grant (network:true and the
//         'fetch cap) — the same check machine-executor's wasm fetch makes,
//         and for the same reason: an ungranted fetch would leak.
//   probe        — a canary: fetch inUrl once, time it, and the RESULT is
//         the measurement (bytes, ms, bps, status) — no content moves on.
//   channel      — the WebRTC leg: a DataChannel to the claim's other end,
//         negotiated through the claim's own signal log (machine-signal /
//         machine-signals) because neither browser can listen. params.role
//         is "offer" | "answer", params.direction "send" | "recv", and the
//         payload rides params.contentB64 (send) or arrives on the wire
//         (recv, hashed into outputHash as the delivery proof).
//
// The receipt meters 'bytes — what actually crossed this node — and the
// channel leg is lazy: no RTCPeerConnection here (a node, a test, a browser
// with WebRTC off) answers 'unavailable rather than pretending to carry.

import { emitReceipt } from "./machine-executor.js";
import { fromBase64 } from "./bytes.js";

const hex = (buf) => [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, "0")).join("");
const sha256Bytes = async (u8) => hex(await crypto.subtle.digest("SHA-256", u8));
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// the fetch grant — the same shape machine-executor checks on a wasm ref:
// a relay that moves bytes over HTTP needs it spelled out, or refuses.
const fetchGranted = (env) =>
    env.network === true && (env.caps || []).includes("fetch");

const httpBytes = async (url, init = {}) => {
    const res = await fetch(url, init);
    if (!res.ok) throw new Error(`machine-relay: ${init.method ?? "GET"} ${url} → ${res.status}`);
    return new Uint8Array(await res.arrayBuffer());
};

// ── the canary ────────────────────────────────────────────────────────────
// One timed fetch — the honest answer to "how fast is this node's path".
export const probe = async (env) => {
    const url = env.params?.inUrl;
    if (!url) throw new Error("machine-relay: a probe needs params.inUrl");
    if (!fetchGranted(env))
        throw new Error("machine-relay: a probe needs the fetch cap");
    const t0 = Date.now();
    const bytes = await httpBytes(url);
    const ms = Math.max(1, Date.now() - t0);
    return { status: "ok", bytes: bytes.byteLength, ms,
             bps: Math.round(bytes.byteLength / ms * 1000) };
};

// ── the HTTP leg ──────────────────────────────────────────────────────────
export const httpLeg = async (env) => {
    const params = env.params ?? {};
    if (!fetchGranted(env))
        throw new Error("machine-relay: the HTTP leg needs the fetch cap");
    if (!params.inUrl) throw new Error("machine-relay: no params.inUrl");
    const bytes = await httpBytes(params.inUrl);
    let pushed = 0;
    if (params.outUrl) {
        const res = await fetch(params.outUrl, { method: "POST", body: bytes });
        if (!res.ok) throw new Error(`machine-relay: POST ${params.outUrl} → ${res.status}`);
        pushed = bytes.byteLength;
    }
    return { bytes, moved: params.outUrl ? pushed * 2 : pushed + bytes.byteLength };
};

// ── the WebRTC leg ────────────────────────────────────────────────────────
// The claim's signal log is the rendezvous: offers, answers and candidates
// are signal bodies {type, sdp | candidate}; each end ignores its own posts
// by 'from. The RTC machinery comes from opts.RTCPeerConnection or the
// platform — injectable so a test can hand a fake pair in.
const openChannel = async (seam, commune, claimId, env, opts = {}) => {
    const params = env.params ?? {};
    const role = params.role ?? "offer";
    const RTC = opts.RTCPeerConnection ?? globalThis.RTCPeerConnection;
    if (typeof RTC !== "function")
        throw new Error("machine-relay: WebRTC unavailable on this node");
    const who = opts.who ?? null;    // this node's did — own posts skip
    const pc = new RTC({ iceServers: opts.iceServers ?? [] });
    const timeoutMs = opts.timeoutMs ?? 60_000;
    const deadline = Date.now() + timeoutMs;

    const post = (body) => seam.machineSignal(commune, claimId, body);
    // poll the claim's log for rows not posted by this node; 'after walks
    // the cursor so nothing repeats
    let cursor = 0;
    const pending = async () => {
        const raw = await seam.machineSignals(commune, claimId, cursor);
        const v = typeof raw === "string" ? JSON.parse(raw) : raw;
        const rows = Array.isArray(v) ? v : (v && Array.isArray(v.ok) ? v.ok : []);
        for (const r of rows) cursor = Math.max(cursor, r.seq ?? cursor);
        return rows.filter(r => !who || r.from !== who).map(r => r.body ?? {});
    };
    // ICE candidates this node produces ride the same log
    pc.onicecandidate = (e) => {
        if (e.candidate)
            void post({ type: "candidate", candidate: e.candidate });
    };
    const untilDeadline = async (what, step) => {
        while (Date.now() < deadline) {
            const got = await step();
            if (got) return got;
            await sleep(opts.pollMs ?? 500);
        }
        throw new Error(`machine-relay: timed out waiting for ${what}`);
    };

    let channel;
    const ready = new Promise((ok, no) => {
        if (role === "offer") {
            channel = pc.createDataChannel("relay");
            channel.binaryType = "arraybuffer";
            channel.onopen = () => ok(channel);
            channel.onerror = (e) => no(new Error(`machine-relay: channel error ${e.message ?? ""}`));
        } else {
            pc.ondatachannel = (e) => {
                channel = e.channel;
                channel.binaryType = "arraybuffer";
                channel.onopen = () => ok(channel);
            };
        }
    });

    if (role === "offer") {
        const offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        await post({ type: "offer", sdp: offer.sdp });
        await untilDeadline("the answer", async () => {
            for (const b of await pending()) {
                if (b.type === "answer") {
                    await pc.setRemoteDescription({ type: "answer", sdp: b.sdp });
                    return true;
                }
                if (b.type === "candidate" && b.candidate)
                    await pc.addIceCandidate(b.candidate);
            }
            return null;
        });
    } else {
        await untilDeadline("the offer", async () => {
            for (const b of await pending()) {
                if (b.type === "offer") {
                    await pc.setRemoteDescription({ type: "offer", sdp: b.sdp });
                    const answer = await pc.createAnswer();
                    await pc.setLocalDescription(answer);
                    await post({ type: "answer", sdp: answer.sdp });
                    return true;
                }
                if (b.type === "candidate" && b.candidate)
                    await pc.addIceCandidate(b.candidate);
            }
            return null;
        });
    }
    // stragglers: candidates can arrive after the session description
    const trailing = setInterval(async () => {
        for (const b of await pending())
            if (b.type === "candidate" && b.candidate)
                try { await pc.addIceCandidate(b.candidate); } catch { }
    }, opts.pollMs ?? 500);
    try {
        const ch = await Promise.race([
            ready,
            sleep(timeoutMs).then(() => {
                throw new Error("machine-relay: channel never opened");
            }),
        ]);
        return { pc, channel: ch };
    } finally { clearInterval(trailing); }
};

// the leg's two halves: send params.contentB64, or receive until the
// channel closes (or the byte budget params.recvBytes fills, or a silence
// timeout) — whichever the envelope asked for.
const channelLeg = async (seam, commune, claimId, env, opts = {}) => {
    const params = env.params ?? {};
    const direction = params.direction ?? "recv";
    const { pc, channel } = await openChannel(seam, commune, claimId, env, opts);
    try {
        if (direction === "send") {
            const bytes = params.contentB64 ? fromBase64(params.contentB64) : new Uint8Array(0);
            channel.send(bytes);
            return { sent: bytes.byteLength, received: 0, bytes };
        }
        return await new Promise((resolve, reject) => {
            const chunks = [];
            let total = 0;
            const silence = opts.silenceMs ?? 10_000;
            let timer = setTimeout(fin, silence);
            function fin() {
                const bytes = new Uint8Array(total);
                let off = 0;
                for (const c of chunks) { bytes.set(c, off); off += c.byteLength; }
                resolve({ sent: 0, received: total, bytes });
            }
            channel.onmessage = (e) => {
                const c = new Uint8Array(e.data);
                chunks.push(c); total += c.byteLength;
                clearTimeout(timer);
                if ((params.recvBytes && total >= params.recvBytes)) return fin();
                timer = setTimeout(fin, silence);
            };
            channel.onclose = fin;
            channel.onerror = (e) => reject(new Error(`machine-relay: channel error ${e.message ?? ""}`));
        });
    } finally { try { pc.close(); } catch { } }
};

// ── the claim ─────────────────────────────────────────────────────────────
// probe → canary report; channel → the WebRTC leg; inUrl → the HTTP leg.
// The receipt's usage is the bytes this node actually carried, and for a
// 'recv or an HTTP carry the outputHash is the carried bytes' digest —
// a delivery proof the verifier can recompute.
export const runRelayClaim = async (seam, commune, claimId, env, lenderDid, opts = {}) => {
    const params = env.params ?? {};
    let moved, bytesForHash, result;
    if (params.probe) {
        result = await probe(env);
        moved = result.bytes;
        bytesForHash = null;
    } else if (params.channel) {
        const leg = await channelLeg(seam, commune, claimId, env, opts);
        moved = leg.sent + leg.received;
        bytesForHash = leg.received ? leg.bytes : null;
        result = { direction: params.direction ?? "recv",
                   sent: leg.sent, received: leg.received };
    } else {
        const leg = await httpLeg(env);
        moved = leg.moved;
        bytesForHash = leg.bytes;
        result = { inUrl: params.inUrl, outUrl: params.outUrl ?? null,
                   bytes: leg.bytes.byteLength };
    }
    const receipt = await emitReceipt({
        env, lenderDid, bridgeJobId: claimId,
        result,
        seconds: 0,
        usage: { unit: "bytes", amount: moved },
        outputHash: bytesForHash ? await sha256Bytes(bytesForHash) : null,
    });
    return seam.machineReceipt(commune, JSON.stringify(receipt));
};
