// app/forum/wire.ts — the forum's one door.
//
// Two things answer to the same interface: the GATEWAY, through HANDLERS
// (cast, open, close, delegations, the room-chat rail for discussion), and
// the on-device DOCKET — the demo threads of demo/forum.ts with your own acts
// folded in, which is what the face reads on the demo day. The face asks
// `wire()` and never forks on which one it got.
//
// The demo day is "no commune has answered with its roster" (scopesSig
// empty) — the same test the plan uses to know the gateway's ingest owns its
// data. Handler presence is no signal: day-boot.js wires every wrapper
// whether or not a spine is behind it.
import { HANDLERS, askJSON } from '../core.js';
import { scopesSig } from '../scope.js';
import { DEMO_FORUM } from '../demo/forum.js';
import { classOfDomain, ageOf } from './model.js';
import { scopeSig } from '../scope.js';
export const KEPT_HERE = "kept on this device — it reaches the commune once one is configured";
const asOutcome = (r, failed) => {
    if (typeof r === "string" && r.startsWith("err:"))
        return `err:${r.slice(4) || failed}`;
    return "ok";
};
const guarded = async (fn, failed) => {
    try {
        return asOutcome(await fn(), failed);
    }
    catch (e) {
        return `err:${String(e?.message || e || failed)}`;
    }
};
// ── the gateway ──────────────────────────────────────────────────────────────
const producerBy = {}; // remembered across scope switches
const LIVE = {
    offline: false,
    async load(deep = false) {
        const [list, dels, voice, uc] = await Promise.all([
            askJSON(() => HANDLERS.listProposals?.(), []),
            askJSON(() => HANDLERS.listDelegations?.(), []),
            askJSON(() => HANDLERS.myVoice?.(), null),
            askJSON(() => HANDLERS.listUcProposals?.(), []),
        ]);
        const proposals = Array.isArray(list) ? list : [];
        await Promise.all(proposals.map(async (p) => {
            p.result = await askJSON(() => HANDLERS.getResult?.(p.id), null);
            const a = ageOf(p);
            if (a != null)
                p.age = a;
        }));
        const sid = scopeSig();
        if (voice && sid && voice.producer != null)
            producerBy[sid] = voice.producer;
        // every commune's column of the voice map, in one read each
        if (deep && HANDLERS.voiceIn)
            await Promise.all((scopesSig() || []).map(async (s) => {
                const v = await askJSON(() => HANDLERS.voiceIn(s.id), null);
                if (v && typeof v.producer === "number")
                    producerBy[s.id] = v.producer;
            }));
        return { proposals, delegations: Array.isArray(dels) ? dels : [], voice, producerBy: { ...producerBy },
            uc: Array.isArray(uc) ? uc : [], counts: {} };
    },
    topicOf: id => (id.startsWith("uc:") || !scopeSig()) ? null : `forum/${scopeSig()}/${id}`,
    async history(topic) {
        if (!HANDLERS.chat)
            return [];
        const r = await HANDLERS.chat("history", topic, "");
        if (typeof r === "string" && r.startsWith("[")) {
            try {
                return JSON.parse(r);
            }
            catch (_) { /* a bad page */ }
        }
        return [];
    },
    post: (topic, text) => guarded(() => HANDLERS.chat("post", topic, text), "post failed"),
    cast: (id, stance) => guarded(() => HANDLERS.cast(id, stance), "cast failed"),
    close: id => guarded(() => HANDLERS.close(id), "close failed"),
    open: (id, domain, text, franchise, subject) => guarded(() => HANDLERS.openProposal("ballot", domain, id, text, franchise, subject), "open failed"),
    setDelegation: (to, fraction) => guarded(() => HANDLERS.setDelegation(to, fraction), "delegation refused"),
    revokeDelegation: d => guarded(() => HANDLERS.revokeDelegation(String(d.to)), "revoke refused"),
    get can() {
        return { cast: !!HANDLERS.cast, close: !!HANDLERS.close, open: !!HANDLERS.openProposal,
            delegate: !!HANDLERS.setDelegation, talk: !!HANDLERS.chat };
    },
};
// ── the docket ───────────────────────────────────────────────────────────────
/** The demo docket, with your own acts folded in and kept here. */
const DOCKET = {
    proposals: DEMO_FORUM.proposals.map(p => ({ ...p, tally: { ...p.tally } })),
    discussion: Object.fromEntries(Object.entries(DEMO_FORUM.discussion).map(([k, v]) => [k, v.slice()])),
    delegations: DEMO_FORUM.delegations.map(d => ({ ...d })),
};
const DEMO_WIRE = {
    offline: true,
    async load() {
        const sid = scopeSig();
        const counts = {};
        for (const [id, ms] of Object.entries(DOCKET.discussion))
            counts["demo/" + id] = ms.length;
        return {
            proposals: DOCKET.proposals.map(p => ({ id: p.id, status: p.status, age: p.age,
                result: { state: p.status === "closed" ? "closed" : "open", kind: p.kind, domain: p.domain, text: p.text,
                    subject: p.subject, franchise: p.franchise === "scope" && sid ? `scope:${sid}` : p.franchise, tally: p.tally } })),
            delegations: DOCKET.delegations,
            voice: { producer: sid ? (DEMO_FORUM.voice.producer[sid] ?? 0) : undefined, consumer: DEMO_FORUM.voice.consumer },
            producerBy: DEMO_FORUM.voice.producer,
            uc: [],
            counts,
        };
    },
    topicOf: id => id.startsWith("uc:") ? null : "demo/" + id,
    async history(topic) { return DOCKET.discussion[topic.slice(5)] || []; },
    async post(topic, text) {
        (DOCKET.discussion[topic.slice(5)] ||= []).push({ id: "you-" + Date.now().toString(36), author: "you", stratum: "public", body: text });
        return "kept";
    },
    async cast(id, stance, weight) {
        const p = DOCKET.proposals.find(x => x.id === id);
        if (!p)
            return "err:no such thread";
        p.tally[stance] = (p.tally[stance] || 0) + Math.max(weight, 0.02);
        return "kept";
    },
    async close(id) {
        const p = DOCKET.proposals.find(x => x.id === id);
        if (!p)
            return "err:no such thread";
        p.status = "closed";
        return "kept";
    },
    async open(id, domain, text, franchise, subject) {
        DOCKET.proposals.unshift({ id, status: "open", kind: "ballot", domain, text, subject, tally: {}, age: 0,
            franchise: franchise.startsWith("scope:") ? "scope" : classOfDomain(domain) === "production" ? "scope" : "federation" });
        return "kept";
    },
    async setDelegation(to, fraction) { DOCKET.delegations.push({ to, fraction }); return "kept"; },
    async revokeDelegation(d) { DOCKET.delegations = DOCKET.delegations.filter(x => x !== d); return "kept"; },
    can: { cast: true, close: true, open: true, delegate: true, talk: true },
};
/** The door the face talks through right now. */
export const wire = () => (scopesSig() || []).length ? LIVE : DEMO_WIRE;
