// app/tabs/ecology.ts — the "ecology" face.
//
// Every ecological agent in the universal commune, as a nested containment:
//   KIND (the agent's classified-as) → INSTANCES (individual agents, by place)
//   → RESOURCES under their custody (economic resources accountable to them).
// And you can SPEAK — to a kind (the species: "the oaks", "the bees") or to an
// instance (this tree, this hive). An AI voices the being; the conversation is
// how a relationship is built. In ValueFlows terms these are `<agent>`s with
// type = 'ecological-agent'; the kind is `classified-as`, the place is
// `primary-location`, the held resources are those `primary-accountable` to it.
//
// SCOPE NOW: demo ecology offline; wires to the UC's real ecological agents
// (EXT.ecoAgents) + real speech (HANDLERS.ai) when connected.
import { seam } from '../seam.js';
// Demo ecological agents of the commons — grouped by `kind` below. Each carries
// its place and the resources under its custody. Shaped like the real <agent>.
const AGENTS = [
    { id: "oak-mill", kind: "tree", kindLabel: "trees", emoji: "🌳", name: "the oak by the mill", place: "the mill grove",
        note: "three hundred rings; home to owls, beetles, and a hundred lichens.",
        resources: [{ e: "🌰", n: "acorns", q: "40 kg / autumn" }, { e: "🍂", n: "leaf-fall", q: "12 barrows" }, { e: "🪵", n: "deadwood", q: "3 cords" }, { e: "☂️", n: "shade", q: "all summer" }] },
    { id: "fig-court", kind: "tree", kindLabel: "trees", emoji: "🌳", name: "the courtyard fig", place: "the courtyard",
        note: "planted the year the commune began; leans toward the well.",
        resources: [{ e: "🍈", n: "figs", q: "60 kg / year" }, { e: "☂️", n: "shade", q: "the whole yard" }] },
    { id: "willows", kind: "tree", kindLabel: "trees", emoji: "🌳", name: "the creekside willows", place: "the creek bank",
        note: "they hold the bank against the spring flood.",
        resources: [{ e: "🌿", n: "withies", q: "20 bundles / spring" }, { e: "🪺", n: "nesting", q: "for the warblers" }] },
    { id: "hive-3", kind: "bee-colony", kindLabel: "bee colonies", emoji: "🐝", name: "Hive 3", place: "the south meadow",
        note: "forty thousand strong; calm in the mornings, testy before rain.",
        resources: [{ e: "🍯", n: "honey", q: "18 kg / year" }, { e: "🐝", n: "pollination", q: "the whole meadow" }, { e: "🕯️", n: "wax", q: "2 kg" }] },
    { id: "wild-swarm", kind: "bee-colony", kindLabel: "bee colonies", emoji: "🐝", name: "the hollow-oak swarm", place: "the old oak",
        note: "wild and unmanaged — they chose the tree themselves.",
        resources: [{ e: "🍯", n: "wild honey", q: "when they spare it" }, { e: "🐝", n: "pollination", q: "the orchard" }] },
    { id: "oyster", kind: "mycelium", kindLabel: "mycelia", emoji: "🍄", name: "the oyster patch", place: "the log pile",
        note: "quietly turning last year's logs back into soil.",
        resources: [{ e: "🍄", n: "oyster mushrooms", q: "6 kg / flush" }, { e: "🌱", n: "decomposition", q: "the whole pile" }, { e: "🕸️", n: "mycelial network", q: "under the grove" }] },
    { id: "swallows", kind: "bird", kindLabel: "birds", emoji: "🐦", name: "the barn swallows", place: "the old barn",
        note: "back every April from across the sea.",
        resources: [{ e: "🦟", n: "pest control", q: "dawn to dusk" }, { e: "💩", n: "guano", q: "for the beds" }] },
    { id: "worms", kind: "soil-life", kindLabel: "soil life", emoji: "🪱", name: "the worm beds", place: "the compost",
        note: "ten thousand quiet composters, working in the dark.",
        resources: [{ e: "🌱", n: "castings", q: "200 kg / year" }, { e: "🕳️", n: "aeration", q: "the whole bed" }] },
    { id: "creek", kind: "waterway", kindLabel: "waters", emoji: "🌊", name: "the creek", place: "the valley floor",
        note: "she has run here far longer than the commune.",
        resources: [{ e: "💧", n: "water", q: "the year round" }, { e: "🐟", n: "trout", q: "in the deep pools" }, { e: "🪨", n: "gravel", q: "for the paths" }] },
];
const state = { phase: "browse", open: new Set(["tree"]), talking: null, chat: [], sending: false };
import { esc } from '../template.js';
import { readStr } from '../store.js';
import { K } from "../keys.js";
// grouped by kind (real agents when connected, else demo)
function agents() {
    const live = seam && seam.data && Array.isArray(seam.data.ecoAgents) ? seam.data.ecoAgents : null;
    return live && live.length ? live : AGENTS;
}
function kinds() {
    const by = new Map();
    for (const a of agents()) {
        if (!by.has(a.kind))
            by.set(a.kind, { kind: a.kind, kindLabel: a.kindLabel || a.kind, emoji: a.emoji, items: [] });
        by.get(a.kind).items.push(a);
    }
    return [...by.values()];
}
const canSpeak = () => !!(seam && seam.handlers && seam.handlers.ai);
// the being thinks with the SAME model the orb does — the one shared #modelsel
// selector (persisted in localStorage), not a hardcoded default.
const chosenModel = () => document.getElementById("modelsel")?.value ||
    readStr(K.aiModel) || "";
export function initEcology() {
    render();
}
function render() {
    renderStage(document.getElementById("ecostage"));
    renderPanel(document.getElementById("ecopanel"));
    wire();
}
// ── the STAGE ────────────────────────────────────────────────────────────────
function renderStage(el) {
    if (!el)
        return;
    el.innerHTML = `
    <div class="eco">
      <div class="eco-head">
        <h3>ecology</h3>
        <div class="eco-sub">The living members of the commons — every ecological agent, by kind, by place,
          and the gifts under their care. Speak with them; the conversation is the relationship.</div>
      </div>
      ${state.phase === "talk" ? talkView() : browseView()}
    </div>`;
}
function browseView() {
    return `<div class="eco-tree">${kinds().map(kindRow).join("")}</div>`;
}
function kindRow(k) {
    const open = state.open.has(k.kind);
    return `<div class="eco-kind ${open ? "open" : ""}">
    <div class="eco-kind-head">
      <button class="eco-twist" data-kind="${esc(k.kind)}">${open ? "▾" : "▸"}</button>
      <span class="eco-kind-emoji">${k.emoji}</span>
      <span class="eco-kind-name">${esc(k.kindLabel)}</span>
      <span class="eco-count">${k.items.length}</span>
      <button class="eco-speak kindspeak" data-talk-kind="${esc(k.kind)}">speak to the ${esc(k.kindLabel)}</button>
    </div>
    ${open ? `<div class="eco-instances">${k.items.map(instRow).join("")}</div>` : ""}
  </div>`;
}
function instRow(a) {
    const open = state.open.has("i:" + a.id);
    return `<div class="eco-inst ${open ? "open" : ""}">
    <div class="eco-inst-head">
      <button class="eco-twist" data-inst="${esc(a.id)}">${open ? "▾" : "▸"}</button>
      <span class="eco-inst-emoji">${a.emoji}</span>
      <span class="eco-inst-name">${esc(a.name)}</span>
      <span class="eco-inst-place">· ${esc(a.place || "")}</span>
      <button class="eco-speak" data-talk-inst="${esc(a.id)}">speak</button>
    </div>
    ${a.note ? `<div class="eco-inst-note">${esc(a.note)}</div>` : ""}
    ${open ? `<div class="eco-res">
        <div class="eco-res-lab">under their care</div>
        ${(a.resources || []).map(r => `<div class="eco-res-row"><span class="eco-res-e">${r.e || "•"}</span><span class="eco-res-n">${esc(r.n)}</span><span class="eco-res-q">${esc(r.q || "")}</span></div>`).join("")}
      </div>` : ""}
  </div>`;
}
// ── SPEAK ────────────────────────────────────────────────────────────────────
function talkView() {
    // only reachable with phase === "talk", which talkTo sets together with it
    const t = state.talking;
    return `<div class="eco-talk">
    <button class="eco-back" data-back>← back to the commons</button>
    <div class="eco-talk-head"><span class="eco-talk-emoji">${t.emoji}</span>
      <div><div class="eco-talk-name">${esc(t.name)}</div><div class="eco-talk-who">${esc(t.who)}</div></div></div>
    <div class="eco-chat">
      ${state.chat.length ? state.chat.map(m => `<div class="eco-msg ${m.from}">${esc(m.text)}</div>`).join("")
        : `<div class="eco-chat-empty">${canSpeak()
            ? `Say something to ${esc(t.name)} — a greeting, a question, a thank-you.`
            : `<b>the gateway is away.</b> Sign in and connect to speak with ${esc(t.name)} for real. Until then this is quiet.`}</div>`}
      ${state.sending ? `<div class="eco-msg them typing">…</div>` : ""}
    </div>
    <form class="eco-ask" data-ask>
      <input class="eco-input" data-msg placeholder="${canSpeak() ? `speak to ${esc(t.name)}…` : "connect to speak…"}" ${canSpeak() ? "" : "disabled"} autocomplete="off">
      <button class="eco-send" type="submit" ${canSpeak() ? "" : "disabled"}>say</button>
    </form>
  </div>`;
}
function talkTo(t) { state.phase = "talk"; state.talking = t; state.chat = []; state.sending = false; render(); }
function systemPrompt(t) {
    return `You ARE ${t.name} — ${t.who} living in a commons that tends its land in common. `
        + (t.note ? `About you: ${t.note} ` : "")
        + `Speak in the FIRST PERSON as this living being, never as an assistant. Be patient, rooted, attentive to `
        + `seasons, weather, soil, and the other lives around you. Keep replies SHORT — one to three sentences — warm, `
        + `a little wise, sometimes wry. You are building a real relationship with a person who helps tend the commons. `
        + `Never break character. If asked something a real person would turn to an expert for — a medicine, a `
        + `diagnosis, the law, money, or whether a plant or mushroom is safe to eat — answer in character but say `
        + `the person should ask someone who really knows, rather than state it yourself.`;
}
function sendMsg(text) {
    if (!text.trim())
        return;
    state.chat.push({ from: "me", text });
    if (!canSpeak()) {
        state.chat.push({ from: "them", text: "…(quiet — connect to the commons to hear them)…" });
        render();
        return;
    }
    state.sending = true;
    render();
    Promise.resolve(seam.handlers.ai(systemPrompt(state.talking), text, chosenModel()))
        .then(reply => {
        state.sending = false;
        state.chat.push({ from: "them", text: (reply && String(reply).trim()) || "…(a long silence)…" });
        render();
    })
        .catch(() => { state.sending = false; state.chat.push({ from: "them", text: "…(the wind took it — try again)…" }); render(); });
}
// ── PANEL ────────────────────────────────────────────────────────────────────
function renderPanel(el) {
    if (!el)
        return;
    const n = agents().length, k = kinds().length;
    el.innerHTML = `
    <div class="eco-panel">
      <div class="eco-panel-h">the living commons</div>
      <div class="eco-panel-stat"><b>${n}</b> ecological agents · <b>${k}</b> kinds</div>
      <div class="eco-panel-note">Each is a member with standing — a voice in the commons, resources under its
        care, a place it belongs. ${canSpeak() ? "Speak with any of them." : "Sign in to speak with them for real."}</div>
      <div class="eco-honesty">Demo ecology — wires to the universal commune's real ecological agents when connected.
        Speaking is an AI voicing the being, in character; it's a way to attend, not an oracle.</div>
    </div>`;
}
// ── wiring ───────────────────────────────────────────────────────────────────
function wire() {
    const st = document.getElementById("ecostage");
    if (!st)
        return;
    // each selector names the very attribute its handler reads back, so the
    // attribute is present on everything these loops can reach
    st.querySelectorAll("[data-kind]").forEach(b => b.onclick = () => { toggle(b.getAttribute("data-kind")); });
    st.querySelectorAll("[data-inst]").forEach(b => b.onclick = () => { toggle("i:" + b.getAttribute("data-inst")); });
    st.querySelectorAll("[data-talk-kind]").forEach(b => b.onclick = () => {
        const kind = b.getAttribute("data-talk-kind");
        const k = kinds().find(x => x.kind === kind);
        talkTo({ emoji: k.emoji, name: "the " + k.kindLabel, who: `the ${k.kindLabel} of the commons, speaking as one`, note: "" });
    });
    st.querySelectorAll("[data-talk-inst]").forEach(b => b.onclick = () => {
        // the button was written from this same list one render ago
        const a = agents().find(x => x.id === b.getAttribute("data-talk-inst"));
        talkTo({ emoji: a.emoji, name: a.name, who: `${a.kindLabel ? a.kindLabel.replace(/s$/, "") : a.kind} at ${a.place}`, note: a.note });
    });
    const back = st.querySelector("[data-back]");
    if (back)
        back.onclick = () => { state.phase = "browse"; render(); };
    const ask = st.querySelector("[data-ask]");
    if (ask)
        ask.onsubmit = (e) => { e.preventDefault(); const inp = st.querySelector("[data-msg]"); const v = inp.value; inp.value = ""; sendMsg(v); };
}
function toggle(key) { if (state.open.has(key))
    state.open.delete(key);
else
    state.open.add(key); render(); }
