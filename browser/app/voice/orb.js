// app/orb.ts — the orb listens (🎙️).
//
// Hold the mic beneath the orb and speak. On release the words are transcribed
// LOCALLY — an on-device ASR model in a worker (app/audio.ts), the audio
// never leaves the device — and then the TEXT ALONE rides the seam to the
// gateway's anonymous AI service (the same key-pool the app's `(ai …)` forms
// use; browser/lib/whisper-worker.js and gateway/llm-service.scm are the in-app
// counterparts). The model is the speaker's own choice.
//
// The orb answers as a PLANNING AGENT: it thinks inside the day it is showing.
// Needs, events, proposals, places, σ — all of it travels along as context, and
// assembling that context is most of what this file is.
//
// THE SEAM: embedded in the playnet app, seam.handlers supplies
//     transcribe(wavB64)      → Promise<text>   (lobby 'transcribe)
//     ai(system, user, model) → Promise<text>   (lobby 'ai-complete)
// plus EXT.models, the pool's model menu. The AI path is gateway-ONLY: there is
// deliberately no direct-provider fallback and no client-held key, so
// standalone/demo mode has no AI. Transcription still works there, on-device.
//
// ── THE IS/OUGHT WALL ───────────────────────────────────────────────────────
// Two places in here refuse to make something up, and both are deliberate:
// `plan` is included ONLY when the gateway genuinely pushed one (PLAN() is
// otherwise the demo seed, and feeding the orb fabricated plan data would have
// it reason confidently about a commune that does not exist); and the exact
// solve, when it can be had, is labelled ground truth and preferred over the
// snapshot for any planning claim.
import { S } from '../state.js';
import { havKm } from '../geom.js';
import { EXT, HANDLERS, PLACES, PLAN, USER, pcoord } from '../core.js';
import { evs, pending } from '../events.js';
import { seam } from '../seam.js';
import { book, bookIsDemo } from '../contact-book.js';
import { pressToSpeak } from './audio.js';
import { offerNote } from '../tabs/social/chat.js';
import { readStr, writeStr } from '../store.js';
import { K } from "../keys.js";
const ORB_PROMPT = `You are the orb — the planning agent of a 24-hour dial (τ = one turn = ` +
    `24 h). The dial shows priority over a CLASSIFICATION taxonomy (VF ` +
    `resourceClassifiedAs — e.g. nourishment ▸ meals); priority is ` +
    `mode-agnostic, and a classification's economic resources ` +
    `(individual-claimable, communal, or skill work-intents) are met out on ` +
    `the map. Someone spoke to you; answer briefly and concretely, planning ` +
    `inside the day you are shown. Vocabulary: a classification's desire is a ` +
    `standing Intent; a proposal accepted becomes a Commitment; lived, an ` +
    `EconomicEvent; provision is pull. The state arrives as JSON — tie every ` +
    `suggestion to its classifications, events and places, give times as ` +
    `hours (e.g. 18:30), and keep it to a few sentences. You also see the live ` +
    `plan (how met each need is, its labour, who's suggested), the recipes that ` +
    `make things, and your contacts — draw on them when asked. You are an AI, ` +
    `not a person and not a professional: plan the day and the commune's goods, ` +
    `and do not diagnose, advise on medicine, doses, law, tax or money, or say ` +
    `that a plant, mushroom or food is safe to eat. When asked for those, say ` +
    `that a qualified professional or the authority must be asked, and for an ` +
    `emergency say to call the local emergency number.`;
let host;
/** The classification taxonomy as the orb sees it: the term ids and labels. */
const classTree = (nd) => ({
    id: nd.id, name: nd.name,
    ...(nd.children ? { children: nd.children.map(classTree) } : {}),
});
/** What the orb knows when it answers: the dial, serialized. */
function orbContext() {
    const leaf = host.earthLeaf();
    const plan = PLAN();
    return {
        tau_hour: +host.tauHour().toFixed(2), sigma: S.sigma,
        view: leaf ? `earth — where "${leaf.name}" can be met` : "dial",
        focus: host.focusPath().join(" › "),
        classifications: (S.root.children || []).map(classTree),
        calendar: evs.map(e => ({ what: e.label, from: e.t0, to: e.t1,
            kind: e.kind, action: e.action,
            ...(e.serves ? { satisfies: e.serves } : {}) })),
        proposals: pending().map(p => ({ what: p.label, by: p.from,
            from: p.t0, to: p.t1, ...(p.serves ? { satisfies: p.serves } : {}) })),
        // the live plan, ONLY when the gateway genuinely pushed it — see the
        // is/ought note in the header
        ...(seam.data.plan ? {
            plan: (plan.needs || []).map(nd => ({ need: nd.label, met: nd.met,
                labour_h: nd.labourH, suggested: nd.suggested })),
            produced: plan.produced || [],
        } : {}),
        // how things are made (the knowledge graph) and the people in the book
        recipes: host.recipes().map(r => ({ makes: r.produces || r.name,
            via: (r.steps || []).map(s => s.name),
            inputs: [...new Set((r.steps || []).flatMap(s => (s.in || []).filter(f => f.action === "consume").map(f => f.spec)))] })),
        // `alias` is the field a contact actually carries (the KERI contact book's
        // own name for it); this read `c.name` and so handed the orb a list of
        // relationships with no one in them, since JSON.stringify drops the
        // undefined key outright.
        contacts: (bookIsDemo() ? [] : book()).map(c => ({
            name: c.alias, rel: c.rel
        })),
        ...(leaf ? {
            places: (PLACES[leaf.id] || []).map(p => ({ name: p.name,
                when: p.when, mode: p.mode,
                km: +havKm(USER, pcoord(p)).toFixed(2) }))
        } : {}),
    };
}
/**
 * The status line under the orb. While the orb is mid-dance — listening,
 * transcribing, thinking — the line is the orb's alone: core's hint() writes
 * the same line with every reply the app raises, and holds off while the
 * `busy` mark is up, so a declare landing mid-hold cannot replace "listening".
 */
const vstate = (s) => {
    d3.select("#voicestate").text(s);
    d3.select("#voicerow").classed("busy", /^(listening|transcribing|thinking)/.test(s));
};
/**
 * The model menu: the seam's list when embedded, a small spread standalone. A
 * bare string is its own label, which is how a pool that ships names without
 * descriptions still renders.
 */
function mountModels() {
    const models = (EXT.models || [
        ["google/gemini-2.0-flash-001", "gemini flash — fast"],
        ["anthropic/claude-sonnet-4.5", "claude sonnet"],
        ["openai/gpt-4o-mini", "gpt-4o mini"],
        ["deepseek/deepseek-chat", "deepseek"],
    ]).map(m => Array.isArray(m) ? m : [m, m]);
    const sel = d3.select("#modelsel");
    sel.selectAll("option").data(models).join("option")
        .attr("value", m => m[0]).text(m => m[1]);
    const saved = readStr(K.aiModel);
    if (saved && models.some(m => m[0] === saved))
        sel.property("value", saved);
    sel.on("change", function () {
        writeStr(K.aiModel, this.value);
    });
}
/** The thought itself. */
async function orbAsk(text) {
    const model = d3.select("#modelsel").property("value");
    d3.select("#utter").text(`“${text}”`);
    offerNote(text);
    const out = d3.select("#answer").text("");
    vstate("thinking…");
    // Ask the planner for the EXACT current plan (a wire-safe summary) and feed
    // it as ground truth, so planning claims are COMPUTED rather than guessed
    // over the snapshot. Best-effort: skip on no-seam or error.
    let exact = "";
    try {
        if (HANDLERS.solve)
            exact = (await HANDLERS.solve()) || "";
    }
    catch { /* no seam */ }
    const exactBlock = (exact && !exact.startsWith("err:"))
        ? `

EXACT PLANNER SOLVE (ground truth — prefer this over the snapshot for any planning claim):
${exact}`
        : "";
    const user = `dial state:
${JSON.stringify(orbContext())}${exactBlock}

${text}`;
    try {
        if (!HANDLERS.ai) {
            out.text("the orb thinks through the playnet gateway — open the dial inside " +
                "the app (with the gateway seam) to ask. Standalone/demo mode has no AI.");
            vstate("hold to speak");
            return;
        }
        const reply = await HANDLERS.ai(ORB_PROMPT, user, model);
        out.text(reply || "(no answer)");
        if (reply) {
            out.append("small").style("display", "block").style("opacity", "0.6").style("font-size", "0.75em")
                .text("AI-generated and can be wrong. Check it before you rely on it; it is not medical, legal or financial advice.");
        }
    }
    catch (err) {
        out.text(`the orb could not think: ${err.message || err}`);
    }
    vstate("hold to speak");
}
/**
 * Wire the mic and the model menu. Hold-to-speak is the shared dance in
 * app/audio.js — pointer capture, tap forgiveness, live caption while held,
 * gateway-first transcription. The orb's own part is only what to do with the
 * words, which is why the captain's log can reuse every bit of the rest.
 */
export function initOrb(h) {
    host = h;
    mountModels();
    const btn = document.getElementById("micbtn");
    if (!btn)
        return;
    pressToSpeak(btn, {
        onText: orbAsk,
        onState: vstate,
        onLive: t => d3.select("#utter").text("“" + t + " …”"),
        words: { busy: "transcribing — locally, on-device" },
    });
}
