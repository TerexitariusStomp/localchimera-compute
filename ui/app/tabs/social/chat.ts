// app/tabs/chat.ts — the chat sheet: an event's conversation, or a room's.
//
// Panel subsystem: owns the chat state and the "chat" seam callback that
// day-boot pushes into. The live layer (join, talk, camera, screen) is not
// here: voice/room.ts owns it and this sheet carries its controls like any
// other surface could. A room's sheet stands in the panel's own `#roomsec`, so
// it is there on every face; an event's sheet stays under the event's card.
// Depends on the core only at call time — HANDLERS (the gateway seam), hint
// (toast), the live selectedEv binding, and selectEvent — so the
// main.js <-> chat.js import cycle is benign (nothing is touched at module
// eval, only inside functions and the deferred seam closures).
import { signal, effect, type Dispose } from '../../reactive.js';
import { chatOpen } from '../../unread.js';
import { HANDLERS, hint } from '../../core.js';
import { selectedEv, selectEvent } from '../../ribbons.js';
import { isSpoken, spokenMark } from '../../voice/walkie-transcript.js';
import { startWake } from '../../voice/wake.js';
import { roomLabel } from '../../voice/room-model.js';
import { mountRoomControls } from '../../voice/room.js';
import { holdPanelOpen } from '../../panel.js';

// ── the event's chat: every message stamped with the author's standing
// toward the event AT THE TIME OF SPEAKING (public / willing / committed /
// satisfied — facts the plan resolves server-side); the chips here are
// pure read-side selection. Topic = the planner id when the event has one,
// a label-slug otherwise (topics are generic strings).
const CHAT_STRATA = ["public", "willing", "committed", "satisfied"];
const CHAT_COL: Record<string, string> =
                 { public: "#8a8a8a", willing: "#2c6e8a",
                   committed: "#2c4a6e", satisfied: "#2e7d52" };

/**
 * What the sheet can be ABOUT: a selected event, or the synthetic room the
 * network channel is. Both answer to a label and a topic id, which is all the
 * sheet needs — it is event-shaped, and a room fits that shape on purpose.
 */
export interface ChatSubject {
  label: string;
  /** The topic id: the planner's own when there is one, else derived. */
  vfId?: string;
  /** Set for the scope-wide channel, which draws its own header. */
  /** Set for a room opened by topic: its sheet stands in the panel, on every face. */
  room?: boolean;
  [key: string]: unknown;
}

/**
 * One message, stamped with the author's standing toward the event AT THE TIME
 * OF SPEAKING — a fact the plan resolved server-side, never re-derived here.
 */
export interface ChatMessage {
  id?: string;
  /** public | willing | committed | satisfied. */
  stratum: string;
  /** note | transcript, or absent for typed text. */
  kind?: string;
  author?: string;
  body?: string;
}
// Reactive chat state — signals drive one effect (see initChat), so a filter
// toggle, a live message or a subject switch all
// re-render #evchat with no manual renderChat() calls.
const chatFilter = signal<Set<string>>(new Set(CHAT_STRATA));   // active strata
const chatShowNotes = signal(true);                // include voice-note transcripts
const chatMsgs = signal<ChatMessage[]>([]);                        // the loaded transcript
const chatCtx = signal<ChatSubject | null>(null);                       // the sheet's subject: an event, OR
                                                    // a room ({room:true}, stood in #roomsec)
let chatTopic: string | null = null;                                // derived from chatCtx (plain)

import { esc as escHtml } from '../../template.js';
import { on } from '../../bus.js';
// A ROOM IS A CHAT TOPIC — one id, not two (meeting-station.md, Layer 0).
// The roster the walkie meshes over, the conversation, and the transcript all
// key off this one string, which is what lets the wake index live rooms and
// their last utterance with no mapping table between them.
const chatTopicOf = (d: ChatSubject): string =>
  d.vfId || ("event:" + (d.label || "").toLowerCase().replace(/[^a-z0-9]+/g, "-"));
// live push from the gateway (day-boot → here): a new message on a topic
// we have open. Dedup by id (history + live race on our own post).
on("chatMessage", (topic, message) => {
  const msg = message as ChatMessage;
  if (topic !== chatTopic || !msg) return;
  if (msg.id && chatMsgs.peek().some(m => m.id === msg.id)) return;
  chatMsgs.update(ms => [...ms, msg]);   // effect redraws iff this topic is open
});
async function loadChat(d: ChatSubject): Promise<void> {
  chatTopic = chatTopicOf(d); chatMsgs.set([]); chatCtx.set(d);
  chatOpen(chatTopic);                   // its unread count clears; its pushes stay seen
  if (HANDLERS.chat) {
    const r = await HANDLERS.chat("history", chatTopic, "");
    if (typeof r === "string" && r.startsWith("[") && chatCtx.peek() === d) {
      try { chatMsgs.set(JSON.parse(r)); } catch (_) {}
    }
  }
}
// ONE way into a room, whichever door you came through — the header's door,
// a row in the wake, or any surface calling openRoom(topic) from voice/room.ts.
// A room is a synthetic chat subject, so the sheet (which is event-shaped) can
// host it without a selected event.
//
// Clearing the selection goes through main.js's own setter: `selectedEv`
// arrives here as an ES module IMPORT and imported bindings are read-only, so
// assigning to it throws under module strict mode. selectEvent(null) also
// clears both rings and redraws, which a bare assignment never did.
function openRoomSheet(topic: string): void {
  holdPanelOpen("room", true);   // asked for by hand, so it is held by hand — not on every redraw
  selectEvent(null);
  loadChat({ label: roomLabel(topic), vfId: topic, room: true });
}
function closeChat(): void {
  chatCtx.set(null);                    // effect hides #evchat
  chatOpen(null);
  d3.select("#noteoffer").remove();
}

// The sheet is one element, built once: a header (a room's name and its way
// out), the live controls' host, and the body that every render rewrites. The
// controls live in their own child so a message arriving redraws the
// conversation and leaves the controls alone.
interface Sheet { root: HTMLElement; hdr: HTMLElement; host: HTMLElement; body: HTMLElement; }
function sheet(): Sheet {
  let root = document.getElementById("evchat");
  if (!root) {
    root = document.createElement("div"); root.id = "evchat";
    root.innerHTML = '<div class="chathdr"></div><div class="wkhost"></div><div class="chatbody"></div>';
  }
  // the three children are written one line up, the only place #evchat is made
  const at = (cls: string) => root!.querySelector<HTMLElement>("." + cls)!;
  return { root, hdr: at("chathdr"), host: at("wkhost"), body: at("chatbody") };
}

// Where the sheet stands. A room's sheet belongs to the panel itself (#roomsec,
// outside every face's rail group), so the room is there on every face; an
// event's sheet sits under the event's card, in the clock's rail. The one
// element moves to whichever host its subject names.
function placeSheet(root: HTMLElement, d: ChatSubject): boolean {
  const hub = document.getElementById("roomsec");
  const det = document.getElementById("evdetail");
  if (d.room && hub) { if (root.parentElement !== hub) hub.append(root); return true; }
  if (!det) return false;
  if (root.previousElementSibling !== det) det.after(root);
  return true;
}

// The live controls belong to the sheet's TOPIC: mounted when it changes,
// released when the sheet closes — never per render.
let controlsTopic: string | null = null, unmountControls: Dispose | null = null;
function followControls(topic: string | null, host: HTMLElement | null): void {
  if (topic === controlsTopic) return;
  controlsTopic = topic;
  if (unmountControls) { unmountControls(); unmountControls = null; }
  if (topic && host) unmountControls = mountRoomControls(host, topic);
}

function renderChat(d: ChatSubject | null): void {
  // a room's sheet holds the sidebar open from the moment it is opened (see
  // openRoomSheet) until something else is showing; an event's sheet takes
  // nothing from the rail
  if (!d?.room) holdPanelOpen("room", false);
  if (!d) {
    followControls(null, null);
    const shown = document.getElementById("evchat");
    if (shown) shown.style.display = "none";
    return;
  }
  const sh = sheet();
  if (!placeSheet(sh.root, d)) return;
  sh.root.style.display = "block";
  followControls(chatTopicOf(d), sh.host);
  const filt = chatFilter(), notes = chatShowNotes();   // reactive reads (subscribe the effect)
  // The chip covers everything SPOKEN: a hand-offered voice note ("note") and
  // the room's own live transcript ("transcript"). Both are speech that became
  // a record, so one switch hides or shows the spoken layer and leaves the
  // typed conversation alone.
  const shown = chatMsgs().filter(m =>
    filt.has(m.stratum) && (notes || !isSpoken(m.kind)));
  // a room has no event card to name it, so it draws its own header (and its way out)
  sh.hdr.style.display = d.room ? "" : "none";
  sh.hdr.innerHTML = d.room ? `${escHtml(d.label)} <span id="chatx">×</span>` : "";
  sh.body.innerHTML = `
    <div class="chatchips">${CHAT_STRATA.map(st =>
      `<span class="chatchip${filt.has(st) ? " on" : ""}"
             data-s="${st}" style="--c:${CHAT_COL[st]}">${st}</span>`).join("")
      }<span class="chatchip${notes ? " on" : ""}" data-note="1"
             style="--c:#c79a3a" title="what was spoken: voice notes and the room's live transcript"
             >📝 transcript</span></div>
    <ul class="chatlist">${shown.map(m => `
      <li${m.kind === "transcript" ? ' class="ctrans"' : ""}
         ><span class="cauth" style="color:${CHAT_COL[m.stratum] || "#888"}"
            title="spoke as ${m.stratum}">${escHtml((m.author || "?").slice(0, 10))}</span
          ><span class="cbody">${spokenMark(m.kind)}${escHtml(m.body || "")}</span></li>`)
      .join("") ||
      `<li class="cempty">${HANDLERS.chat
        ? "no messages yet — say the first thing"
        : "chat rides the gateway — connect and sign in"}</li>`}</ul>
    ${HANDLERS.chat ? `<div class="chatrow">
      <input id="chatin" placeholder="say something…">
      <button id="chatsend" title="post">↩</button></div>` : ""}`;
  sh.body.querySelectorAll<HTMLElement>(".chatchip").forEach(el => el.onclick = () => {
    if (el.dataset.note) { chatShowNotes.update(v => !v); return; }   // effect redraws
    // the note chip returned above; every other chip carries data-s.
    const st = el.dataset.s!;
    chatFilter.update(s => { const n = new Set(s); n.has(st) ? n.delete(st) : n.add(st); return n; });
  });
  const send = async () => {
    const inp = document.getElementById("chatin") as HTMLInputElement;
    const body = (inp.value || "").trim(); if (!body) return;
    inp.value = "";
    // the row this runs from is only rendered when HANDLERS.chat is set, and
    // loadChat set chatTopic before anything could be rendered at all.
    const r = await HANDLERS.chat!("post", chatTopic!, body);
    if (typeof r === "string" && r.startsWith("err:")) hint(r.slice(4), "error");
    loadChat(d);
  };
  const x = document.getElementById("chatx");
  if (x) x.onclick = closeChat;
  const btn = document.getElementById("chatsend");
  if (btn) {
    btn.onclick = send;
    (document.getElementById("chatin") as HTMLInputElement).onkeydown =
      (e) => { if (e.key === "Enter") send(); };
  }
}

// spoken words become NOTES on the selected event's chat: the dial's
// hold-to-speak already transcribes locally; this hands the transcript to
// the ledger's conversation as kind:"note", stratum-stamped like any
// message. The voice stays ephemeral — the note is the record.
function offerNote(text: string): void {
  d3.select("#noteoffer").remove();
  const d = chatCtx.peek() || selectedEv.peek();   // the open channel — event OR the network
  if (!text || !d || !HANDLERS.chat) return;
  d3.select("#utter").append("span")
    .attr("id", "noteoffer")
    .style("margin-left", "8px").style("cursor", "pointer")
    .style("font-size", "11px").style("color", "#2e7d52")
    .style("font-family", "var(--sans)")
    .text(`📝 note → ${d.label}`)
    .on("click", async () => {
      // offerNote returns above unless HANDLERS.chat is set.
      const r = await HANDLERS.chat!("post", chatTopicOf(d), text, "note");
      d3.select("#noteoffer")
        .text(typeof r === "string" && r.startsWith("err:")
              ? r : `📝 noted → ${d.label}`)
        .style("cursor", "default").on("click", null);
      loadChat(d);
    });
}

// show (or clear) the chat for a subject — the encapsulated entry main.js calls,
// so the core no longer reaches into chatTopic/renderChat. New subject → load its
// history; same subject → surface it; null → hide.
export function showChat(d: ChatSubject | null): void {
  if (!d) { chatCtx.set(null); return; }
  if (chatTopicOf(d) !== chatTopic) loadChat(d);
  else chatCtx.set(d);
}
// start the effect that keeps #evchat in sync with the chat signals.
export function initChat(): void {
  effect(() => renderChat(chatCtx()));
  on("openRoom", openRoomSheet);   // any surface's openRoom(topic) lands here
  // the room's own transcript lands as chat lines; the sheet showing that room reloads
  on("roomPosted", topic => {
    const d = chatCtx.peek();
    if (d && chatTopicOf(d) === topic) loadChat(d);
  });
  startWake();  // the live-room index, from boot, on every face
}

export { offerNote };
