// app/voice/roomchip.ts — a door to a room, for any face to put anywhere.
//
// A face that wants a room about the thing it shows writes one chip into its own
// template and is done:
//
//     ${roomChip(roomAbout("plan"), "talk this plan over")}
//
// Any element carrying `data-room="<topic>"` is a door: one delegated handler
// opens that room (voice/room.ts `openRoom`), so a face rebuilding its markup
// never has to bind anything. The chip says whether you are on air in it and how
// many others are there now, kept current by one effect over every chip on the
// page, so a chip drawn a minute ago still tells the truth.

import { effect } from '../reactive.js';
import { esc } from '../template.js';
import { scopeSig } from '../scope.js';
import { liveRoom, openRoom } from './room.js';
import { meetingTopic, roomSlug } from './room-model.js';
import { peopleIn } from './wake.js';

/**
 * The room about SUBJECT in the commune you stand in — `roomAbout("plan")`,
 * `roomAbout("recipe", id)` — or "" before you stand in one. Read it inside the
 * render, so a scope switch gives the next commune's room.
 */
export function roomAbout(...subject: string[]): string {
  const scope = scopeSig(), slug = roomSlug(...subject);
  return scope && slug ? meetingTopic(scope, slug) : "";
}

/** The chip as markup, or "" when there is no room to open yet. */
export function roomChip(topic: string, label = "meet here"): string {
  if (!topic) return "";
  return `<span class="roomchip" data-room="${esc(topic)}" role="button" tabindex="0"`
       + ` title="a live room about this — talk, or join with video">📻 ${esc(label)}`
       + `<span class="roomhere"></span></span>`;
}

const doorOf = (t: EventTarget | null): HTMLElement | null =>
  t instanceof Element ? t.closest<HTMLElement>("[data-room]") : null;

/** Start the doors: the delegated tap, and the one effect that keeps chips true. */
export function initRoomChips(): void {
  document.addEventListener("click", (e) => {
    const topic = doorOf(e.target)?.dataset.room;
    if (topic) openRoom(topic);
  });
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Enter" && e.key !== " ") return;
    const door = doorOf(e.target);
    if (!door || !door.classList.contains("roomchip")) return;
    e.preventDefault();
    if (door.dataset.room) openRoom(door.dataset.room);
  });
  effect(() => {
    const live = liveRoom();
    document.querySelectorAll<HTMLElement>(".roomchip").forEach((chip) => {
      const topic = chip.dataset.room ?? "";
      const mine = !!topic && topic === live;
      const others = Math.max(0, peopleIn(topic) - (mine ? 1 : 0));
      chip.classList.toggle("live", mine);
      chip.classList.toggle("busy", others > 0);
      const n = chip.querySelector<HTMLElement>(".roomhere");
      if (n) n.textContent = others > 0 ? ` · ${others} here` : "";
    });
  });
}
