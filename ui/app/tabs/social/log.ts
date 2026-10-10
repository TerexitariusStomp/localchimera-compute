// app/tabs/log.ts — the "log" face: the captain's log.
//
// Speak an entry (the shared pressToSpeak dance from app/audio.js — the
// same dance the orb holds) or type one; each entry is stamped with a
// stardate and kept LOCAL-FIRST (localStorage), the gateway holding a
// per-AID backup through HANDLERS.log — the same local-first +
// server-backup shape as the contact book.
//
// The log reads itself back, at two rhythms:
//
//   PER ENTRY — one extraction pass suggests (a) the contacts the entry
//   speaks about, matched against the live book and confirmable as tags,
//   and (b) the VF economic events the entry narrates. A tag opens the
//   social flows (invite the person, share the entry to the commune
//   channel); an event's "observe" records it on the scope's observer
//   through HANDLERS.logObserve — lived days become ledger facts.
//
//   PER WEEK — the digest reads several days of entries at once and
//   proposes STANDING NEEDS worth planning for; "plan this" declares one
//   through HANDLERS.declareNeed, the same standing intent the share face
//   mints — the "suggest what to plan" half of the pipeline.
//
// Both passes live in app/extract.js — the extraction pipeline proper,
// grounded in the scope's recipe library (a suggestion whose spec the
// library knows arrives stamped `known`, and the plan can act on it
// directly). This file is the pipeline's CONSUMER: the diary, the cards,
// and the actions each suggestion opens.
//
// Standalone/demo mode keeps the diary + a plain alias scan; AI, the
// observer and the planner arrive only with the gateway seam (the orb's
// rule).
import { HANDLERS, hint } from '../../core.js';
import { book, invite } from '../../contact-book.js';
import { html, list, render } from '../../template.js';
import { signal, effect } from '../../reactive.js';
import { pressToSpeak } from '../../voice/audio.js';
import { runPass, scanContacts, aiAvailable } from '../../day/extract.js';
import type { ExtractedContact, ExtractedEvent, ExtractedProposal } from '../../day/extract.js';
import { readJSON, writeJSON } from '../../store.js';
import { fitNewest, SYNC_MAX_ENTRIES, SYNC_MAX_BYTES, LOCAL_MAX_BYTES } from './log-bound.js';
import { gateHint } from '../../day/respond.js';

import { scopeSig } from '../../scope.js';
import { K } from "../../keys.js";
import { isCountUnit } from '../../units-catalogue.js';
/** An extracted event, plus the observer id once it has been recorded. */
type LoggedEvent = ExtractedEvent & { observed?: string };

/** What the entry pass found in one entry, once it has run. */
interface Suggestion {
  contacts: ExtractedContact[];
  events: LoggedEvent[];
}

/** One day of the captain's log. Local-first; the gateway keeps a copy. */
interface Entry {
  id: string;
  /** When it was logged, in ms. */
  t: number;
  text: string;
  /**
   * Aliases the entry speaks about, accepted into it. Always an array —
   * commit() seeds it, and tagContact only ever rewrites it.
   */
  contacts: string[];
  /** Seeded by the scan floor before any AI pass, so it is always there. */
  sug: Suggestion;
  /** "" before a pass, then how it went. */
  sugState?: "" | "thinking" | "done" | "none";
  /** Bumped on every edit, so the keyed list knows the row changed. */
  rev?: number;
}

/** The stand-in row, so an empty log says what it means rather than going blank. */
interface EmptyEntry {
  empty: true;
}
const isEmptyEntry = (e: Entry | EmptyEntry): e is EmptyEntry => "empty" in e;

/** A week read back: the standing needs it revealed. */
interface Digest {
  t: number;
  state: "done" | "thinking";
  proposals: ExtractedProposal[];
}

// ── the entries: local-first, one signal drives the list ───────────────────
// entry = { id, t (ms), text, contacts: [alias…], sug: {contacts, events},
//           sugState: "" | "thinking" | "done" | "none", rev }
const LS_KEY = K.logEntries;
const DIGEST_KEY = K.logDigest;
const entries = signal<Entry[]>(readJSON<Entry[]>(LS_KEY, []));
// digest = { t, state: "done" | "thinking", proposals: [{spec, name, emoji,
//            qty, unit, why, declared}] } | null — regenerable, so local only
const digest = signal<Digest | null>(readJSON<Digest | null>(DIGEST_KEY, null));
let serverMerged = false;

function persist(): void {
  const es = entries();
  // each store gets the newest entries that fit it (log-bound.ts)
  writeJSON(LS_KEY, fitNewest(es, Infinity, LOCAL_MAX_BYTES));
  // best-effort server backup, per AID
  if (HANDLERS.log) {
    const settled = es.map(e => ({ ...e, sugState: e.sugState === "thinking" ? "" : e.sugState }));
    const doc = JSON.stringify(fitNewest(settled, SYNC_MAX_ENTRIES, SYNC_MAX_BYTES));
    HANDLERS.log("sync", doc).catch(() => {});
  }
}
function persistDigest(): void {
  writeJSON(DIGEST_KEY, digest());
}
// the gateway's copy, merged by id — local entries win (they are newer or equal)
async function mergeServer(): Promise<void> {
  if (serverMerged || !HANDLERS.log) return;
  serverMerged = true;
  try {
    const raw = await HANDLERS.log!("list", "");
    if (!raw || raw.startsWith("err:")) return;
    const remote = JSON.parse(raw);
    if (!Array.isArray(remote)) return;
    const have = new Set(entries().map(e => e.id));
    const fresh = (remote as Entry[]).filter(e => e && e.id && !have.has(e.id));
    if (fresh.length)
      entries.update(es => [...es, ...fresh].sort((a, b) => b.t - a.t));
  } catch (_) {}
}

// ── the stardate: (year−2000)·1000 + the year's fraction, one decimal ──────
function stardate(t: number): string {
  const d = new Date(t);
  const y0 = Date.UTC(d.getUTCFullYear(), 0, 1);
  const y1 = Date.UTC(d.getUTCFullYear() + 1, 0, 1);
  return ((d.getUTCFullYear() - 2000) * 1000 + (t - y0) / (y1 - y0) * 1000).toFixed(1);
}
const civil = (t: number): string => new Date(t).toLocaleString([], {
  weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });

// the live contact book (the demo book standalone) — the entry pass's world

function touch(id: string, fn: (e: Entry) => void): void {
  entries.update(es => es.map(e => {
    if (e.id !== id) return e;
    const n = { ...e, rev: (e.rev || 0) + 1 };
    fn(n);
    return n;
  }));
  persist();
}

// ── per-entry suggestion pass (extract.js "entry") ─────────────────────────
async function suggest(entry: Entry): Promise<void> {
  const scanned = scanContacts(entry.text, book());
  touch(entry.id, e => {
    e.sug = { contacts: scanned, events: [] };
    e.sugState = aiAvailable() ? "thinking" : (scanned.length ? "done" : "none");
  });
  if (!aiAvailable()) return;
  const got = await runPass("entry", { text: entry.text,
                                       tIso: new Date(entry.t).toISOString(),
                                       book: book() });
  touch(entry.id, e => {
    if (got) {
      const cs = [...got.contacts];
      scanned.forEach(s => {                     // the scan floor stays
        if (!cs.some(c => c.alias === s.alias)) cs.push(s); });
      e.sug = { contacts: cs, events: got.events };
      e.sugState = (cs.length || got.events.length) ? "done" : "none";
    } else {
      e.sugState = e.sug.contacts.length ? "done" : "none";
    }
  });
}

// ── the weekly digest (extract.js "digest"): entries → needs to plan ───────
async function runDigest(): Promise<void> {
  if (!aiAvailable()) { hint("the digest thinks through the gateway — sign in first", "warn"); return; }
  const week = entries().filter(e => e.t > Date.now() - 7 * 86400000);
  if (!week.length) { hint("nothing logged this week yet"); return; }
  if (digest()?.state === "thinking") return;
  digest.set({ t: Date.now(), state: "thinking", proposals: [] });
  const lines = week.map(e =>
    `[${new Date(e.t).toISOString().slice(0, 16)}] ${e.text}`).join("\n");
  const got = await runPass("digest", { lines });
  digest.set({ t: Date.now(), state: "done", proposals: got ? got.proposals : [] });
  persistDigest();
}
async function declareProposal(i: number): Promise<void> {
  const d = digest();
  const p = d?.proposals[i];
  if (!p || p.declared) return;
  if (!HANDLERS.declareNeed) { hint("planning needs the gateway — sign in first", "warn"); return; }
  // a digest proposal is a WANT, said so: a bare declare would fold at the
  // unstated baseline (truth-telling.md), and a stated kind is what puts
  // the ⚖️ on its share-bar card, where the voice is the citizen's to set
  const r = await HANDLERS.declareNeed(p.spec, p.qty, p.unit, "", "",
                                       `from the log's digest: ${p.why}`,
                                       p.emoji, "", "", p.name, "", "", "des");
  if (r === "ok") {
    digest.set({ ...d!, proposals: d!.proposals.map((x, j) =>
      j === i ? { ...x, declared: true } : x) });
    persistDigest();
    hint(`declared as a want — the plan provisions ${p.name}; weigh it on its ⚖️ in the share bar`, "success");
  } else hint(String(r || "err:offline").replace(/^err:/, "can't declare — "), "error");
}

// ── acting on a suggestion ──────────────────────────────────────────────────
function tagContact(entry: Entry, alias: string): void {
  touch(entry.id, e => {
    e.contacts = e.contacts.includes(alias)
      ? e.contacts.filter(a => a !== alias)
      : [...e.contacts, alias];
  });
}
// a tagged person, invited to what the entry narrates: the label is the first
// suggested event's line (else the entry's own opening), the window that
// event's narrated hour (else the entry's) plus one.
function inviteTagged(entry: Entry, alias: string): void {
  const c = book().find(x => x.alias === alias);
  if (!c) { hint("can't invite — not connected", "warn"); return; }
  const ev = (entry.sug?.events || [])[0];
  const label = (ev && ev.summary) || entry.text.slice(0, 60);
  const t0 = (ev && ev.when) ? new Date(ev.when) : new Date(entry.t);
  invite(c, label, t0, new Date(t0.getTime() + 3600000));
}
// the entry, shared to the commune's own channel as a note (the same topic
// the network button opens; chat.js renders it under the 📝 spoken layer)
function shareEntry(entry: Entry): void {
  if (!(scopeSig() && HANDLERS.chat)) { hint("sharing rides the gateway — sign in first", "warn"); return; }
  HANDLERS.chat("post", "meeting/" + scopeSig() + "/network",
                `📖 stardate ${stardate(entry.t)} — ${entry.text}`, "note")
    .then(r => hint(String(r).startsWith("ok") ? "shared to the network channel"
                                               : String(r).replace(/^err:/, ""),
                    String(r).startsWith("ok") ? "success" : "error"));
}
async function observeEvent(entry: Entry, i: number): Promise<void> {
  const v = (entry.sug?.events || [])[i];
  if (!v || v.observed) return;
  if (!HANDLERS.logObserve) { hint("observing needs the gateway — sign in first", "warn"); return; }
  const when = v.when || new Date(entry.t).toISOString();
  const r = await HANDLERS.logObserve(v.action, v.spec, v.qty, v.unit,
                                      `captain's log ${stardate(entry.t)}: ${v.summary || entry.text.slice(0, 120)}`,
                                      when);
  const reply = String(r ?? "");
  if (reply.startsWith("ok:"))
    touch(entry.id, e => { e.sug.events = e.sug.events.map((x, j) =>
      j === i ? { ...x, observed: reply.slice(3) } : x); });
  else if (!gateHint(reply)) hint(String(r || "err:offline").replace(/^err:/, "can't observe — "), "error");
}

// ── drawing ─────────────────────────────────────────────────────────────────
function entryCard(e: Entry) {
  const chips = (e.sug?.contacts || []).flatMap(c => {
    const on = e.contacts.includes(c.alias);
    const chip = html`<span class="lg-chip${on ? " on" : ""}" title="${c.why || ""}${on ? " — tagged; tap to untag" : " — tap to tag"}"
                      onclick=${() => tagContact(e, c.alias)}>${on ? "✓ " : ""}${c.alias}</span>`;
    // a tag opens the social flow: the invite rides the entry's own narration
    return on
      ? [chip, html`<span class="lg-inv" title="invite ${c.alias} to what this entry narrates"
                         onclick=${() => inviteTagged(e, c.alias)}>✉ invite</span>`]
      : [chip];
  });
  const evs = (e.sug?.events || []).map((v, i) => html`
    <div class="lg-ev">
      <span class="lg-ev-act lg-${v.action}">${v.action}</span>
      <span class="lg-ev-what${v.known ? " lg-knownspec" : ""}"
            title="${v.known ? "a spec in the scope's recipe library — the plan knows how to provision it" : ""}"
            >${v.qty}${isCountUnit(v.unit) ? "" : v.unit} ${v.spec}</span>
      ${v.summary ? html`<span class="lg-ev-sum">${v.summary}</span>` : ""}
      ${v.observed
        ? html`<span class="lg-ev-done" title="recorded on the observer as ${v.observed}">✓ observed</span>`
        : html`<span class="lg-ev-go" onclick=${() => observeEvent(e, i)}
                     title="record this as an EconomicEvent on the scope's observer">observe</span>`}
    </div>`);
  return html`
    <div class="lg-entry">
      <div class="lg-head">
        <span class="lg-star">stardate ${stardate(e.t)}</span>
        <span class="lg-when">${civil(e.t)}</span>
        <span class="lg-share" title="share this entry to the commune's network channel"
              onclick=${() => shareEntry(e)}>⇢ share</span>
        <span class="lg-del" title="strike this entry from the log"
              onclick=${() => { entries.update(es => es.filter(x => x.id !== e.id)); persist(); }}>×</span>
      </div>
      <div class="lg-text">${e.text}</div>
      ${chips.length ? html`<div class="lg-chips">${chips}</div>` : ""}
      ${evs.length ? html`<div class="lg-evs">${evs}</div>` : ""}
      ${e.sugState === "thinking" ? html`<div class="lg-think">reading the entry…</div>` : ""}
    </div>`;
}

function digestSection() {
  const d = digest();
  const rows = (d?.proposals || []).map((p, i) => html`
    <div class="lg-prop">
      <span class="lg-prop-what${p.known ? " lg-knownspec" : ""}"
            title="${p.known ? "a spec in the scope's recipe library — the plan knows how to provision it" : ""}"
            >${p.emoji} <b>${p.name}</b> · ${p.qty}${isCountUnit(p.unit) ? "" : " " + p.unit}/week</span>
      <span class="lg-prop-why">${p.why}</span>
      ${p.declared
        ? html`<span class="lg-ev-done">✓ planned</span>`
        : html`<span class="lg-ev-go" title="declare this as a standing need — the plan provisions it"
                     onclick=${() => declareProposal(i)}>＋ plan this</span>`}
    </div>`);
  return html`
    <div class="lg-digest">
      <div class="lg-panel-h">the week, digested</div>
      ${d?.state === "thinking" ? html`<div class="lg-think">reading the week…</div>` : ""}
      ${rows}
      ${d?.state === "done" && !rows.length
        ? html`<div class="lg-panel-note">nothing recurring surfaced — a quiet week.</div>` : ""}
      <button class="lg-digest-go" onclick=${() => runDigest()}
              title="read the last seven days of entries and propose standing needs to plan">
        ✦ digest the week</button>
    </div>`;
}

function draw() {
  const es = entries();
  list("#logentries",
       (es.length ? es : [{ empty: true }]) as (Entry | EmptyEntry)[],
       e => isEmptyEntry(e) ? "·empty" : `${e.id}:${e.rev || 0}`,
       e => isEmptyEntry(e)
         ? html`<div class="lg-empty">No entries yet. Hold the mic and speak — or type below.</div>`
         : entryCard(e));
  const tagged = new Set(es.flatMap(e => e.contacts));
  const observed = es.reduce((n, e) =>
    n + (e.sug?.events || []).filter(v => v.observed).length, 0);
  render("#logpanel", html`
    <div class="lg-panel">
      <div class="lg-panel-h">the captain's log</div>
      <div class="lg-panel-stat"><b>${es.length}</b> entr${es.length === 1 ? "y" : "ies"}
        · <b>${tagged.size}</b> people tagged · <b>${observed}</b> event${observed === 1 ? "" : "s"} observed</div>
      <div class="lg-panel-note">Each entry is yours, local-first, with the gateway as
        backup. The log reads itself back: it suggests the contacts you spoke about and
        the ValueFlows events your day narrates — <i>observe</i> puts one on the ledger.</div>
      ${digestSection()}
    </div>`);
}

// ── the composer ────────────────────────────────────────────────────────────
const lgState = (s: string): void => { const el = document.getElementById("logstate"); if (el) el.textContent = s; };

function commit(text: string): void {
  const t = (text || "").trim();
  if (!t) return;
  // sug starts empty rather than absent: suggest() fills it in the same tick,
  // and every reader can then take it as always-there.
  const entry: Entry = { id: "lg-" + Date.now() + "-" + Math.floor(Math.random() * 1e5),
                  t: Date.now(), text: t, contacts: [], sug: { contacts: [], events: [] }, sugState: "", rev: 0 };
  entries.update(es => [entry, ...es]);
  persist();
  suggest(entry);
  const draft = document.getElementById("logdraft") as HTMLTextAreaElement | null;
  if (draft) draft.value = "";
}

// the universal door in: the footer's mic (tabs/share.js) commits here from
// ANY face — the entry lands in the signal and persists whether or not the
// log face has booted; opening it later draws everything logged meanwhile.
export function logEntry(text: string): void { commit(text); }

let booted = false;
export function initLog() {
  if (!booted) {
    booted = true;
    render("#logstage", html`
      <div class="lg">
        <div class="lg-top"><h3>captain’s log</h3>
          <div class="lg-sub">Hold the mic and speak your day — release, and the entry
            is logged under its stardate. The log suggests who you spoke about and the
            economic events it heard; <b>observe</b> records one on the ledger.</div></div>
        <div class="lg-composer">
          <button id="logmic" title="hold to speak an entry">🎙️</button>
          <span id="logstate">hold to log</span>
          <textarea id="logdraft" rows="2" placeholder="…or write the entry, then log it"></textarea>
          <button id="logcommit" title="log the written entry">log it</button>
        </div>
        <div id="logentries"></div>
      </div>`);
    // the same hold-to-speak dance as the orb's — app/audio.js owns it; the
    // log's part is its own words and what to do with the text: commit it.
    // the shell writes these three, so a booted log face has them
    pressToSpeak(document.getElementById("logmic")!, {
      onText: commit,
      onState: lgState,
      onLive: t => lgState("“" + t + " …”"),
      words: { idle: "hold to log",
               listening: "listening — release to log",
               tap: "press and KEEP holding to log",
               nothing: "heard nothing — hold and speak" },
    });
    const draft = document.getElementById("logdraft") as HTMLTextAreaElement;
    document.getElementById("logcommit")!.addEventListener("click",
      () => commit(draft.value));
    draft.addEventListener("keydown", e => {
      if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); commit((e.target as HTMLTextAreaElement).value); }
    });
    // the entries + panel track the signals from here on: every commit,
    // delete, suggestion arrival, tag toggle or digest turn redraws.
    effect(draw);
  }
  mergeServer();
}
