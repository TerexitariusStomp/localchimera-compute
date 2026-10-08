// app/voice/room.ts — a live room, reachable from any surface.
//
// docs/planning/faces/meeting-station.md, Layer 0. A room is a topic string
// (`meeting/<scope>/<slug>`, or any chat topic: an event's, a commune's) and the
// live layer rides that one id — the gateway's roster, the audio/video mesh, the
// chat and the transcript all key off it. This module is the app's whole
// vocabulary for being live in one:
//
//   state      liveRoom() — read from anywhere; the state itself is room-model.ts
//   actions    joinRoom, leaveRoom, toggleTalk, toggleCam, toggleScreen
//   controls   mountRoomControls(host, topic) — the join / talk / camera / screen
//              row, dropped into any element a surface offers
//   the door   mountRoomDoor(el, topic) — a button that opens a room and shows
//              whether you are live in it
//   the way in openRoom(topic) — one call from any face; whichever surface hosts
//              room sheets answers it on the bus
//
// The media itself (the mesh, the floating call stage) lives in the spine and
// day-boot.js and is face-independent already; day-boot reports its state back
// through the seam's one `walkie` string, which is narrowed and folded into the
// state here and nowhere else.
import { signal, effect } from '../reactive.js';
import { on, emit } from '../bus.js';
import { HANDLERS, hint } from '../core.js';
import { scopeSig } from '../scope.js';
import { startRoomTranscript, stopRoomTranscript } from './walkie-transcript.js';
import { OUT, step, parseSpine, noticeFor, liveRoomOf, meetingTopic } from './room-model.js';
// ── state ───────────────────────────────────────────────────────────────────
const state = signal(OUT);
const send = (e) => state.update(s => step(s, e));
/** The topic of the room we are live in, "" when out. Reactive. */
export const liveRoom = () => liveRoomOf(state());
/** The scope-wide channel of the commune you stand in, "" before you have one. Reactive. */
export function networkTopic() {
    const s = scopeSig();
    return s ? meetingTopic(s, "network") : "";
}
// The spine can be asked nothing until day-boot has installed its handler, and
// it installs it after the page is up: availability is a signal, looked at again
// whenever the gateway reports a status and whenever a row of controls mounts,
// so a sheet opened early draws its controls the moment the spine is there.
const spineReady = signal(!!HANDLERS.walkie);
const lookAtSpine = () => spineReady.set(!!HANDLERS.walkie);
on("status", lookAtSpine);
const spine = (op, arg) => { if (HANDLERS.walkie)
    HANDLERS.walkie(op, arg); };
// day-boot reports the live layer's state through this one string.
on("walkie", (raw) => {
    const s = parseSpine(raw);
    if (!s) {
        console.warn(`[room] unknown walkie state "${raw}"`);
        return;
    }
    send({ t: "spine", s });
    const n = noticeFor(s);
    if (n)
        hint(n.msg, n.kind);
});
// the browser's own "stop sharing" chrome ends the share behind our back
on("screenEnded", () => {
    send({ t: "spine", s: "screen-off" });
    spine("screen", "off");
});
// What follows from being live is a function of being live, not a step in any
// transition: the room transcribes itself — our OWN mic, on THIS device, posted
// to the room's chat as kind:"transcript" (walkie-transcript.ts) — for exactly
// as long as liveRoom() names a room, so the tap cannot outlive the call. Each
// edge also tells the wake its room map changed, so our own join or leave shows
// now rather than on the next poll.
let was = "";
effect(() => {
    const room = liveRoom();
    if (room === was)
        return;
    was = room;
    if (room)
        startRoomTranscript(room, () => emit("roomPosted", room));
    else
        stopRoomTranscript();
    emit("roomChanged");
});
// ── actions ─────────────────────────────────────────────────────────────────
// v1 holds ONE room at a time: joining a second hands the mic over.
/** Go live in TOPIC, with the camera on when WITHVIDEO. That is only where you
 *  begin: the camera goes off and on at any time (toggleCam), so a call that
 *  started with video carries on as audio, and one that started as audio can
 *  add a camera. */
export function joinRoom(topic, withVideo = false) {
    send({ t: "join", room: topic });
    spine(withVideo ? "joinvideo" : "join", topic);
}
export function leaveRoom() { spine("leave"); }
export function toggleTalk() {
    const s = state.peek();
    if (s.phase !== "live")
        return;
    send({ t: "talk", on: !s.talking });
    spine("talk", s.talking ? "off" : "on");
}
// The camera and the screen are asked for, never assumed: capture is
// asynchronous and can be refused, so the state changes when the spine reports
// it ("cam-on", "cam-off", "cam-denied", and likewise for the screen).
export function toggleCam() {
    const s = state.peek();
    if (s.phase === "live")
        spine("cam", s.cam ? "off" : "on");
}
export function toggleScreen() {
    const s = state.peek();
    if (s.phase === "live")
        spine("screen", s.screen ? "off" : "on");
}
const flags = (s) => (s.phase === "live" ? s : { talking: false, cam: false, screen: false });
const ACTS = {
    join: { cls: "wkbtn", run: t => joinRoom(t), say: () => ["📡 join live audio", false] },
    joinvideo: { cls: "wkbtn", run: t => joinRoom(t, true), say: () => ["🎥 join with video", false] },
    talk: { cls: "wkbtn", run: toggleTalk,
        say: s => {
            const on = flags(s).talking;
            return [on ? "🔴 on air — tap to stop" : "🎤 tap to talk (live)", on];
        } },
    cam: { cls: "wkbtn", run: toggleCam,
        say: s => {
            const on = flags(s).cam;
            return [on ? "📹 stop camera" : "📷 start camera", on];
        } },
    screen: { cls: "wkbtn", run: toggleScreen,
        say: s => {
            const on = flags(s).screen;
            return [on ? "🖥 sharing — stop" : "🖥 share screen", on];
        } },
    leave: { cls: "wkbtn hang", run: leaveRoom, say: () => ["☎ leave", false] },
};
function controlsHtml(topic) {
    if (!spineReady())
        return "";
    const s = state();
    // live HERE only when the room we are live in is this one: another room's
    // controls show the join doors while we are on air elsewhere, and joining
    // hands the mic over.
    const acts = s.phase !== "live" || s.room !== topic ? ["join", "joinvideo"]
        : ["talk", "cam", "screen", "leave"];
    return acts.map(a => {
        const c = ACTS[a], [text, lit] = c.say(s);
        return `<span class="${c.cls}${lit ? " on" : ""}" data-act="${a}">${text}</span>`;
    }).join("");
}
/**
 * Put the live controls for TOPIC into HOST. Any surface can carry them: the
 * row redraws itself from the room's state, so the caller never re-renders it.
 * Returns the unmount.
 */
export function mountRoomControls(host, topic) {
    lookAtSpine();
    host.classList.add("wkrow");
    host.onclick = (e) => {
        const act = e.target.closest("[data-act]")?.dataset.act;
        if (act && act in ACTS)
            ACTS[act].run(topic);
    };
    const stop = effect(() => { host.innerHTML = controlsHtml(topic); });
    return () => { stop(); host.onclick = null; host.textContent = ""; };
}
// ── the way in ──────────────────────────────────────────────────────────────
/** Open TOPIC's room — its conversation and its live controls — from any face. */
export function openRoom(topic) { emit("openRoom", topic); }
/**
 * Make EL a door to a room. TOPIC is read reactively, so a door onto "the
 * commune I stand in" follows the scope; "" means there is no room yet and the
 * tap says what is missing. EL carries class `live` (and aria-pressed) while
 * you are on air in it.
 */
export function mountRoomDoor(el, topic) {
    const tap = () => {
        const t = topic();
        if (!t) {
            hint("connect & sign in to open a room", "warn");
            return;
        }
        openRoom(t);
    };
    el.addEventListener("click", tap);
    const stop = effect(() => {
        const t = topic();
        const live = !!t && liveRoom() === t;
        el.classList.toggle("live", live);
        el.setAttribute("aria-pressed", String(live));
    });
    return () => { stop(); el.removeEventListener("click", tap); };
}
