// app/wake.ts — every live room, legible at once.
//
// docs/planning/faces/meeting-station.md, Layer 2. The thing NOT to build is every
// room's media piped into every other; the thing to build is a low-rate index
// any peer can hold ALL of — who is in each room, and the last thing said in
// it. Text and counts: a hundred rooms of this costs less than one video
// thumbnail, which is what makes "accessible at all times" affordable.
//
// This is SHELL furniture, not a tab: it renders at the head of the panel's own
// room section (#roomsec, outside every face's rail group), so it is read from
// every face. It therefore lives beside the other
// dial modules rather than inside tabs/chat.js — the wake is not a thing the
// chat tab owns, it is a thing that sometimes opens the chat tab.

import { signal, effect } from '../reactive.js';
import { on } from '../bus.js';
import { HANDLERS } from '../core.js';
import { spokenMark } from './walkie-transcript.js';
import { openRoom } from './room.js';
import { roomLabel } from './room-model.js';

import { esc } from '../template.js';

/** A live room in the federation's index. */
export interface WakeRoom {
  /** The room topic, `meeting/<scope>/<slug>`. */
  room: string;
  /** How many are in it now. */
  here?: number;
  /** The room's current utterance, if anyone has spoken. */
  said?: string;
  /** note | transcript — which spoken layer `said` came from. */
  kind?: string;
  [key: string]: unknown;
}

const wakeRooms = signal<WakeRoom[]>([]);
let wakeTimer: number | null = null, lastRaw: string | null = null, quietRounds = 0;

// Poll cadence: brisk while anything is live, backing off while the whole
// federation is quiet. Polling every 7 s forever costs a gateway round trip
// AND a server vat turn per client per tab, indefinitely, to keep re-learning
// that nothing is happening.
//
// The backoff only ever applies to an EMPTY federation, and two things end it
// immediately: any non-empty answer (so the moment one room is live, everyone
// polling is back to 7 s), and `bumpWake()` (so the person who just joined
// never waits on a timer to see their own room). Without those a quiet
// federation would take the better part of a minute to notice its first
// meeting — which is exactly the moment the index matters most.
const FAST = 7000, SLOW = 30000;
const nextDelay = (): number => Math.min(SLOW, FAST * Math.pow(2, Math.min(quietRounds, 3)));

async function refreshWake(): Promise<void> {
  if (HANDLERS.wake && !document.hidden) {
    const r = await HANDLERS.wake();
    if (typeof r === "string" && r.startsWith("[")) {
      // Bail before parsing when the answer is byte-identical: signals compare
      // by identity, so a freshly parsed array would fire the effect and
      // rebuild the whole rail on every tick even though nothing moved.
      if (r !== lastRaw) {
        lastRaw = r;
        try { wakeRooms.set(JSON.parse(r)); } catch (_) {}
      }
      quietRounds = r === "[]" ? quietRounds + 1 : 0;
    }
  }
  wakeTimer = setTimeout(refreshWake, nextDelay());
}

/// How many are in TOPIC's room right now, by the wake's last reading (a room
/// nobody is in is not live, so 0). Reactive: read it inside an effect.
export function peopleIn(topic: string): number {
  const r = wakeRooms().find(x => x.room === topic);
  return r && typeof r.here === "number" ? r.here : 0;
}

/// Start the index. A row opens its room (voice/room.ts) — the wake knows
/// which room, and whoever hosts room sheets knows what opening one means.
export function startWake(): void {
  if (wakeTimer) return;
  refreshWake();
}

/// Something just changed the room map from THIS client — a join, a leave.
/// Read it now rather than on the next tick, and drop back to the fast
/// cadence: whatever we just did is very likely the thing worth showing.
function bumpWake() {
  quietRounds = 0;
  if (wakeTimer) { clearTimeout(wakeTimer); wakeTimer = null; }
  refreshWake();
}

// our own join or leave changed the room map — show it now
on("roomChanged", bumpWake);

// Polled, not pushed: the wake is a handful of strings, and a poll cannot get
// out of step with a room whose gateway push was missed. Pushing it is a
// refinement, not a correctness fix.
effect(() => {
  const rooms = wakeRooms();
  const hub = document.getElementById("roomsec");
  if (!hub) return;
  let box = document.getElementById("wakebox");
  if (!rooms.length) { if (box) box.remove(); return; }
  if (!box) {
    box = document.createElement("div");
    box.id = "wakebox";
    hub.prepend(box);
  }
  box.innerHTML = rooms.map(r => `
    <div class="wakerow" data-room="${esc(r.room)}" title="hop into ${esc(r.room)}">
      <span class="wakename">${esc(roomLabel(r.room))}</span>
      <span class="wakehere">${r.here}</span>
      <div class="wakesaid">${r.said
        ? spokenMark(r.kind ?? "") + esc(String(r.said).slice(0, 90))
        : "<i>quiet</i>"}</div>
    </div>`).join("");
  box.querySelectorAll<HTMLElement>(".wakerow").forEach(el => {
    // the attribute is written one line up, from this same list
    el.onclick = () => openRoom(el.dataset.room!);
  });
});
