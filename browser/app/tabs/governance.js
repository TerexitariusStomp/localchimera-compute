// app/tabs/governance.ts — the forum: the federation's discrete decisions,
// read as threads.
//
// The DISCRETE governance layer over the continuous plan (see
// docs/governance/governance-surface.md). The treemap surface is where you
// weight desires and watch the plan recompose; this face is where you meet
// the decisions that are *events* — each a THREAD with a question, a SUBJECT
// (the recipe, need, means or commune it is about — forum/subjects.ts), a
// tally, your stance, and the discussion around it. Three sub-faces:
//
//   OPEN     — every open decision, both classes, newest first. A row is a
//              thread; open it to read, discuss and vote.
//   DECIDED  — the closed ballots and what they decided.
//   VOICE    — the voice map (forum/voice.ts): franchise × class, with the
//              delegated share of each cell, and the topics spoken across.
//
// A proposal is BORN FROM something: the composer is a picker over the same
// objects the other faces draw, drafting the question from the thing chosen,
// with a free line for a question in your own words. The subject rides the
// wire as the ballot's "kind:id" field; the ballot's franchise is the commune
// whose producers weigh it for production, the federation for consumption
// (forum/subjects.ts franchiseFor).
//
// Every thread carries its CLASS, which says why you weigh what you weigh
// (forum/model.ts): PRODUCTION — how the work is done, producer voice;
// CONSUMPTION — what the community needs, consumer voice.
//
// The face has ONE door, forum/wire.ts: the gateway through HANDLERS, or the
// on-device docket on the demo day. It draws at once from what it holds and
// refreshes quietly behind — a redraw happens only when the wire moved.
import { hint } from '../core.js';
import { onFace } from '../stage.js';
import { html, render } from '../template.js';
import { TOPICS, CLASS_VOICE, classOf, classOfDomain, domainOf, statusOf, titleOf, verdictOf, ago, shortAid, ucId, franchiseScope } from '../forum/model.js';
import { subjectOf, subjectBands, refOf, franchiseFor, scopeName, nameOfScope, scopesKnown } from '../forum/subjects.js';
import { wire, KEPT_HERE } from '../forum/wire.js';
import { viewTally, viewMiniTally, viewClassChip, viewWeight, viewSubjectTile, viewSubjectCard } from '../forum/views.js';
import { viewVoice } from '../forum/voice.js';
import { on } from '../bus.js';
import { scopeSig } from '../scope.js';
import { idHint, voteConsentGiven, recordVoteConsent, VOTE_CONSENT_SENTENCE } from './social/id.js';
const EMPTY = { proposals: [], delegations: [], voice: null, producerBy: {}, uc: [], counts: {} };
const GOV = { snap: EMPTY, mounted: null, timer: null, tab: "open", thread: null, composing: false, pick: null,
    askDomain: "policy", filter: null, topic: null, msgs: [], counts: {}, stance: {}, err: null, drawn: "", ready: false };
const snapshot = () => JSON.stringify([GOV.snap, GOV.msgs]);
/** Your weight for a class, as the wire says. */
function weightFor(cls) {
    const v = GOV.snap.voice || {};
    const w = cls === "production" ? v.producer : v.consumer;
    return (w != null && w >= 0) ? w : null;
}
const producerIn = (sid) => {
    const w = GOV.snap.producerBy[sid];
    return w != null ? w : (sid === scopeSig() ? weightFor("production") : null);
};
async function loadAll(deep = false) {
    GOV.snap = await wire().load(deep);
    GOV.counts = { ...GOV.counts, ...GOV.snap.counts };
    if (GOV.thread && GOV.topic)
        await loadDiscussion(GOV.topic);
}
async function loadDiscussion(topic) {
    const msgs = await wire().history(topic);
    if (GOV.topic === topic) {
        GOV.msgs = msgs;
        GOV.counts[topic] = msgs.length;
    }
}
// a live message on the open thread's topic — day-boot pushes it here.
let subscribed = false;
function subscribeOnce() {
    if (subscribed)
        return;
    subscribed = true;
    on("chatMessage", (topic, message) => {
        const msg = message;
        if (!msg)
            return;
        GOV.counts[topic] = (GOV.counts[topic] || 0) + 1;
        if (topic !== GOV.topic)
            return;
        if (msg.id && GOV.msgs.some(m => m.id === msg.id))
            return;
        GOV.msgs = [...GOV.msgs, msg];
        redraw();
    });
}
/** An act went through the door; say what came back, then refresh. */
async function settle(outcome, kept) {
    GOV.err = null;
    if (outcome === "kept")
        hint(`${kept} ${KEPT_HERE}`, "notice");
    else if (outcome !== "ok") {
        GOV.err = outcome.slice(4);
        hint(GOV.err, "warn");
    }
    await refreshGovernance(true);
}
const went = (o) => o === "ok" || o === "kept";
// A member who ticked the onboarding ask (or answered this once before) casts
// straight away; anyone else — an identity made before the ask existed, or
// who left the tick unchecked — meets it HERE, before the vote is actually
// recorded, which is the moment Art 9(2)(a) consent has to be specific to
// (see id.ts). Held outside any one thread's render, since the ask can span a
// redraw.
let pendingCast = null;
// ── views: the list ──────────────────────────────────────────────────────────
/** One thread row in the list. */
function viewRow(p) {
    const cls = classOf(p), st = statusOf(p), r = p.result, s = subjectOf(p);
    const topic = wire().topicOf(p.id);
    const n = topic ? GOV.counts[topic] : undefined;
    return html `<a class="fo-row fo-cls-${cls} ${st}" onclick=${() => openThread(p.id)}>
    <span class="fo-rowemoji">${s ? s.emoji : (cls === "production" ? "🛠️" : "🌱")}</span>
    <div class="fo-rowmain">
      <div class="fo-rowtitle">${titleOf(p)}</div>
      <div class="fo-rowmeta">
        ${viewClassChip(cls)}
        ${domainOf(p) && html `<span class="fo-domain">${domainOf(p)}</span>`}
        ${s && html `<span class="fo-rowsubj">${s.name}</span>`}
        ${p.age != null && html `<span class="fo-age">${ago(p.age)}</span>`}
        ${GOV.stance[p.id] && html `<span class="fo-said">you said ${GOV.stance[p.id]}</span>`}
        ${st === "closed" && r && html `<span class="fo-verdict">${verdictOf(r.tally)}</span>`}
        ${n != null && n > 0 && html `<span class="fo-replies" title="messages in the discussion">💬 ${n}</span>`}
      </div>
    </div>
    <div class="fo-rowside">${r && r.state !== "error" && viewMiniTally(r.tally)}</div>
  </a>`;
}
// a cross-gateway UC merge proposal — a scope-formation decision surfaced from
// the reconciler. Informational: ratification is the merge-bottom-up! ceremony.
const viewUcRow = (u) => html `
  <a class="fo-row fo-cls-production fo-uc" onclick=${() => openThread(ucId(u))}>
    <span class="fo-rowemoji">🤝</span>
    <div class="fo-rowmain">
      <div class="fo-rowtitle">merge two communes</div>
      <div class="fo-rowmeta">${viewClassChip("production")}<span class="fo-domain">formation</span>
        <span class="fo-ucbody">${shortAid(u.a)} <span class="fo-ucx">⇄</span> ${shortAid(u.b)}</span></div>
    </div>
    <div class="fo-rowside"><span class="fo-status open">proposed</span></div>
  </a>`;
function viewList(tab) {
    const wanted = tab === "open" ? "open" : "closed";
    const f = GOV.filter;
    const items = GOV.snap.proposals.filter(p => statusOf(p) === wanted && (!f || domainOf(p) === f))
        .slice().sort((a, b) => (a.age ?? 0) - (b.age ?? 0));
    const uc = tab === "open" && (!f || f === "formation") ? GOV.snap.uc : [];
    const chip = f && html `<div class="fo-filter">
    <span class="fo-chip fo-cls-${classOfDomain(f)}">${TOPICS.find(t => t.d === f)?.label || f}</span>
    <a class="fo-filter-x" onclick=${() => { GOV.filter = null; redraw(); }}>every topic ×</a></div>`;
    if (!items.length && !uc.length) {
        return html `${chip}<div class="fo-empty">${f ? `nothing ${wanted === "open" ? "open" : "decided"} on this topic`
            : tab === "open" ? "nothing open right now — every decision that needs your voice appears here"
                : "nothing decided yet"}</div>`;
    }
    return html `${chip}<div class="fo-list">${uc.map(viewUcRow)}${items.map(viewRow)}</div>`;
}
// ── views: a thread ──────────────────────────────────────────────────────────
/** The discussion under a thread: the messages, and a reply box. */
function viewDiscussion() {
    const topic = GOV.topic;
    if (!topic || !wire().can.talk) {
        return html `<div class="fo-disc"><div class="fo-dischead">discussion</div>
      <div class="fo-none">sign in to a commune to read and join the discussion</div></div>`;
    }
    const post = async (ev) => {
        const btn = ev.currentTarget;
        const box = btn.parentElement.querySelector(".fo-reply");
        const text = (box.value || "").trim();
        if (!text)
            return;
        btn.setAttribute("disabled", "true");
        box.value = "";
        const out = await wire().post(topic, text);
        if (out === "kept")
            hint(`your word is ${KEPT_HERE}`, "notice");
        else if (out !== "ok")
            hint(out.slice(4), "warn");
        await loadDiscussion(topic);
        redraw();
    };
    const onKey = (ev) => {
        if (ev.key === "Enter" && (ev.metaKey || ev.ctrlKey)) {
            ev.currentTarget.parentElement.querySelector(".fo-post").click();
        }
    };
    return html `<div class="fo-disc">
    <div class="fo-dischead">discussion <span class="fo-count">${GOV.msgs.length || ""}</span></div>
    ${GOV.msgs.length
        ? html `<ul class="fo-msgs">${GOV.msgs.map(m => html `<li class="fo-msg fo-st-${m.stratum || "public"}">
          <span class="fo-auth" title="spoke as ${m.stratum || "public"}">${shortAid(m.author || "?")}</span>
          <span class="fo-msgbody">${m.body || ""}</span></li>`)}</ul>`
        : html `<div class="fo-none">no one has spoken yet — say what you think</div>`}
    <div class="fo-replyrow">
      <textarea class="fo-reply" rows="2" placeholder="say something… (⌘⏎ to post)" onkeydown=${onKey}></textarea>
      <button class="fo-post" onclick=${post}>post</button>
    </div>
  </div>`;
}
/** A thread: the question, its subject, class and weight, the tally, your stance, the talk. */
function viewThread(id) {
    const back = html `<a class="fo-back" onclick=${() => closeThread()}>‹ ${GOV.tab === "decided" ? "decided" : "open"}</a>`;
    if (id.startsWith("uc:")) {
        const u = GOV.snap.uc.find(x => ucId(x) === id);
        return html `<div class="fo-thread fo-cls-production">
      ${back}
      <h3 class="fo-q">merge two communes</h3>
      <div class="fo-meta">${viewClassChip("production")}<span class="fo-domain">formation</span>
        <span class="fo-status open">proposed</span></div>
      <div class="fo-ucbody fo-big">${u ? html `${shortAid(u.a)} <span class="fo-ucx">⇄</span> ${shortAid(u.b)}` : "no longer proposed"}</div>
      <div class="fo-ucnote">a consensual merge, surfaced by the reconciler — ratification is the merge ceremony itself</div>
    </div>`;
    }
    const p = GOV.snap.proposals.find(x => x.id === id);
    if (!p)
        return html `<div class="fo-thread">${back}<div class="fo-empty">this thread is gone</div></div>`;
    const cls = classOf(p), st = statusOf(p), r = p.result, s = subjectOf(p), w = wire();
    const fsid = franchiseScope(r?.franchise);
    const said = GOV.stance[p.id];
    const doCast = async (stance) => {
        const out = await w.cast(p.id, stance, weightFor(cls) ?? 0.05);
        if (went(out))
            GOV.stance[p.id] = stance;
        await settle(out, "your stance is");
    };
    const cast = (stance) => async (ev) => {
        const me = idHint();
        if (me && !voteConsentGiven(me.aid)) {
            pendingCast = { pid: p.id, stance };
            redraw();
            return;
        }
        const acts = ev.currentTarget.parentElement;
        acts?.querySelectorAll("button").forEach(b => b.setAttribute("disabled", "true"));
        await doCast(stance);
    };
    const agreeAndCast = async () => {
        const pc = pendingCast;
        pendingCast = null;
        const me = idHint();
        if (me)
            recordVoteConsent(me.aid);
        if (pc && pc.pid === p.id)
            await doCast(pc.stance);
        else
            redraw();
    };
    const cancelCast = () => { pendingCast = null; redraw(); };
    const closeIt = async () => {
        const out = await w.close(p.id);
        if (went(out))
            GOV.tab = "decided";
        await settle(out, "closed —");
    };
    return html `<div class="fo-thread fo-cls-${cls}">
    ${back}
    <h3 class="fo-q">${titleOf(p)}</h3>
    <div class="fo-meta">
      ${viewClassChip(cls)}
      ${domainOf(p) && html `<span class="fo-domain">${domainOf(p)}</span>`}
      <span class="fo-status ${st}">${st}</span>
      ${r?.franchise && html `<span class="fo-franchise" title="whose voice counts here">${fsid ? nameOfScope(fsid) : r.franchise}</span>`}
      ${p.age != null && html `<span class="fo-age">${ago(p.age)}</span>`}
      ${st === "open" && w.can.close &&
        html `<button class="fo-close" title="close the ballot and record its tally (governor)" onclick=${closeIt}>close</button>`}
    </div>
    ${GOV.err && html `<div class="fo-err">${GOV.err}</div>`}
    <div class="fo-weightrow">${viewWeight(cls, weightFor(cls))}</div>
    ${s && viewSubjectCard(s, producerIn)}
    <div class="fo-tallybox">
      <div class="fo-dischead">${st === "open" ? "where it stands" : "what it decided"}
        ${said && html `<span class="fo-said">you said ${said}</span>`}</div>
      ${r && r.state && r.state !== "error" ? viewTally(r.tally) : html `<span class="fo-none">no tally yet</span>`}
      ${st === "open" && w.can.cast && pendingCast && pendingCast.pid === p.id
        ? html `<div class="fo-voteconsent"><p class="fo-ucnote">${VOTE_CONSENT_SENTENCE}</p>
            <div class="fo-acts"><button class="fo-vote yes" onclick=${agreeAndCast}>agree and cast my ${pendingCast.stance}</button>
              <button class="fo-close" onclick=${cancelCast}>cancel</button></div></div>`
        : st === "open" && w.can.cast &&
            html `<div class="fo-acts">${["yes", "no", "abstain"].map(stance => html `<button class="fo-vote fo-${stance} ${said === stance ? "on" : ""}" onclick=${cast(stance)}>${stance}</button>`)}</div>`}
    </div>
    ${viewDiscussion()}
  </div>`;
}
// ── views: the composer — a proposal is born from something ──────────────────
async function openBallot(text, domain, subject) {
    const id = "p-" + domain + "-" + Date.now().toString(36);
    GOV.composing = false;
    GOV.pick = null;
    const out = await wire().open(id, domain, text, franchiseFor(domain), subject ? refOf(subject) : "");
    await settle(out, "opened —");
    if (went(out))
        openThread(id);
}
function viewCompose() {
    const pick = GOV.pick;
    const cancel = () => { GOV.composing = false; GOV.pick = null; redraw(); };
    if (pick) {
        const cls = classOfDomain(pick.domain);
        const openIt = async (ev) => {
            const btn = ev.currentTarget;
            const q = btn.closest(".fo-draft").querySelector(".fo-draft-q").value.trim();
            if (!q) {
                hint("the question is empty", "warn");
                return;
            }
            btn.setAttribute("disabled", "true");
            await openBallot(q, pick.domain, pick);
        };
        return html `<div class="fo-compose">
      <a class="fo-back" onclick=${() => { GOV.pick = null; redraw(); }}>‹ choose something else</a>
      <div class="fo-draft fo-card fo-cls-${cls}">
        <div class="fo-dischead">a proposal about</div>
        ${viewSubjectTile(pick)}
        <textarea class="fo-draft-q" rows="2">${pick.draft}</textarea>
        <div class="fo-draftmeta">${viewClassChip(cls)}<span class="fo-domain">${pick.domain}</span>
          <span class="fo-weight fo-cls-${cls}">${CLASS_VOICE[cls]}${cls === "production" ? ` in ${scopeName()}` : ""}</span></div>
        ${viewSubjectCard(pick, producerIn)}
        <div class="fo-composerow">
          <button class="fo-cancel" onclick=${cancel}>cancel</button>
          <button class="fo-go" onclick=${openIt}>open the ballot</button>
        </div>
      </div>
    </div>`;
    }
    const askOwn = async (ev) => {
        const btn = ev.currentTarget;
        const box = btn.closest(".fo-askbox").querySelector(".fo-ask");
        const text = (box.value || "").trim();
        if (!text) {
            hint("ask the question first", "warn");
            return;
        }
        btn.setAttribute("disabled", "true");
        await openBallot(text, GOV.askDomain, null);
    };
    // the domain chips restyle in place: a redraw would drop the words being typed
    const pickDomain = (d) => (ev) => {
        GOV.askDomain = d;
        const box = ev.currentTarget.closest(".fo-askbox");
        box.querySelectorAll(".fo-dchip").forEach(c => c.classList.toggle("on", c.dataset.d === d));
        box.querySelector(".fo-askvoice").textContent = CLASS_VOICE[classOfDomain(d)];
    };
    return html `<div class="fo-compose">
    <a class="fo-back" onclick=${cancel}>‹ ${GOV.tab}</a>
    <div class="fo-composehead"><h3 class="fo-q">what should ${scopeName()} decide?</h3>
      <div class="fo-sub">a proposal is born from something the commune already knows — pick it, and the question drafts itself</div></div>
    <div class="fo-askbox">
      <div class="fo-askrow">
        <textarea class="fo-ask" rows="1" placeholder="…or ask in your own words"></textarea>
        <button class="fo-go fo-askgo" onclick=${askOwn}>open</button>
      </div>
      <div class="fo-askdomains">
        <span class="fo-askon">on</span>
        ${TOPICS.map(t => html `<a class="fo-dchip fo-cls-${classOfDomain(t.d)} ${GOV.askDomain === t.d ? "on" : ""}" data-d="${t.d}"
            onclick=${pickDomain(t.d)}>${t.label}</a>`)}
        <span class="fo-askvoice">${CLASS_VOICE[classOfDomain(GOV.askDomain)]}</span>
      </div>
    </div>
    ${subjectBands().map(b => html `
      <div class="fo-band">
        <div class="fo-bandhead">${b.title}</div>
        <div class="fo-bandrow">${b.items.map(s => viewSubjectTile(s, () => { GOV.pick = s; redraw(); }))}</div>
      </div>`)}
  </div>`;
}
// ── the face ─────────────────────────────────────────────────────────────────
function viewTabs() {
    const nOpen = GOV.snap.proposals.filter(p => statusOf(p) === "open").length + GOV.snap.uc.length;
    const nDone = GOV.snap.proposals.filter(p => statusOf(p) === "closed").length;
    const seg = (t, glyph, label, n) => html `<a class="fo-seg seg-${t} ${GOV.tab === t ? "on" : ""}" data-tab="${t}"
            onclick=${() => { GOV.tab = t; GOV.thread = null; GOV.topic = null; GOV.msgs = []; redraw(); }}>
      <span class="fo-seg-i">${glyph}</span><span class="fo-seg-l">${label}</span>
      ${n != null && n > 0 && html `<span class="fo-seg-n">${n}</span>`}</a>`;
    return html `<div class="fo-rail">
    ${seg("open", "🗳️", "open", nOpen)}
    ${seg("decided", "📜", "decided", nDone)}
    ${seg("voice", "🗣️", "voice", null)}
  </div>`;
}
function drawPanels(el) {
    const node = el.node();
    const w = wire();
    // an in-progress reply or ask survives the redraw
    const draft = node?.querySelector(".fo-reply, .fo-ask")?.value || "";
    const body = GOV.composing ? viewCompose()
        : GOV.thread ? viewThread(GOV.thread)
            : GOV.tab === "voice" ? viewVoice({
                scopes: scopesKnown(), currentScope: scopeSig() || null,
                proposals: GOV.snap.proposals, delegations: GOV.snap.delegations,
                consumer: weightFor("consumption"), producerIn, weightFor, canDelegate: w.can.delegate,
                onTopic: (tab, domain) => { GOV.tab = tab; GOV.filter = domain; GOV.thread = null; redraw(); },
                onDelegate: async (to, frac) => {
                    if (!to) {
                        hint("name the delegate", "warn");
                        redraw();
                        return;
                    }
                    if (!(frac > 0 && frac <= 1)) {
                        hint("a share between 1% and 100%", "warn");
                        redraw();
                        return;
                    }
                    await settle(await w.setDelegation(to, frac), "delegation");
                },
                onRevoke: async (d) => settle(await w.revokeDelegation(d), "revoked —"),
            })
                : viewList(GOV.tab);
    render(node, html `
    <div class="fo">
      <div class="fo-top">
        <div class="fo-title">
          <h3>forum</h3>
          <div class="fo-sub">${w.offline ? "the demo docket — the decisions a commune like this one meets" : "the decisions that are events — read, discuss, and give your voice"}</div>
        </div>
        <div class="fo-topright">
          <span class="fo-scope" title="the commune you are standing in">${scopeName()}</span>
          ${w.can.open && !GOV.composing &&
        html `<button class="fo-new" onclick=${() => { GOV.composing = true; GOV.pick = null; GOV.thread = null; redraw(); }}>＋ propose</button>`}
        </div>
      </div>
      ${!GOV.composing && !GOV.thread && viewTabs()}
      <div class="fo-body">${body}</div>
    </div>`);
    if (draft) {
        const box = node?.querySelector(".fo-reply, .fo-ask");
        if (box)
            box.value = draft;
    }
    GOV.drawn = snapshot();
    GOV.ready = true;
}
const redraw = () => { if (GOV.mounted)
    drawPanels(GOV.mounted); };
async function openThread(id) {
    GOV.thread = id;
    GOV.err = null;
    GOV.composing = false;
    GOV.topic = wire().topicOf(id);
    GOV.msgs = [];
    redraw();
    if (GOV.topic) {
        await loadDiscussion(GOV.topic);
        redraw();
    }
}
function closeThread() {
    GOV.thread = null;
    GOV.topic = null;
    GOV.msgs = [];
    GOV.err = null;
    redraw();
}
/** The poll only runs while the face is up — asked of the record, not the rail. */
const visible = () => onFace("forum");
/**
 * Mount: draw at once from what the face holds (the docket, or the last
 * wire), then refresh behind.
 */
export async function initGovernance(el) {
    GOV.mounted = el;
    subscribeOnce();
    if (wire().offline && !GOV.ready)
        await loadAll();
    if (GOV.ready || wire().offline)
        drawPanels(el);
    else
        render(el.node(), html `<div class="fo"><div class="fo-top"><div class="fo-title"><h3>forum</h3><div class="fo-sub">reading the docket…</div></div></div></div>`);
    if (GOV.timer)
        clearInterval(GOV.timer);
    GOV.timer = setInterval(() => { if (visible())
        refreshGovernance(); }, 8000);
    await refreshGovernance(true);
}
/** Refetch, and redraw only when the wire moved. FORCE draws regardless of visibility. */
export async function refreshGovernance(force = false) {
    if (!GOV.mounted || (!force && !visible()))
        return;
    await loadAll(force);
    if (force || !GOV.ready || snapshot() !== GOV.drawn)
        drawPanels(GOV.mounted);
}
