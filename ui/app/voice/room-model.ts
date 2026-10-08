// app/voice/room-model.ts — what a room is, and what being live in one can be.
//
// The pure half of voice/room.ts: no DOM, no seam, no imports, so node reads the
// same sentences the page does (tests/browser/room-model-test.mjs). Two things
// live here because each is a closed vocabulary that more than one module speaks:
//
//   the topic      `meeting/<scope>/<slug>` and its reading back as a label
//   the live state ONE value, a union, and ONE reducer over a closed set of events
//
// The state is a union so that an impossible state has no spelling: talk, camera
// and screen exist only while live, and "live" always names its room.

// ── the topic ───────────────────────────────────────────────────────────────

/** `meeting/<scope>/<slug>` — the topic of a named room inside a commune. */
export const meetingTopic = (scope: string, slug: string): string => `meeting/${scope}/${slug}`;

/**
 * A room's slug from the thing it is about: lower-case words joined by `-`, so
 * `roomSlug("recipe", "Sourdough Loaf!")` is `recipe-sourdough-loaf`. Empty when
 * there is nothing to name it by.
 */
export function roomSlug(...about: string[]): string {
  return about.join(" ").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

/** A room topic reads as `meeting/<scope>/<slug>`; show the slug. */
export function roomLabel(topic: string): string {
  const m = /^meeting\/[^/]+\/(.+)$/.exec(topic);
  return m ? (m[1] === "network" ? "📻 the network" : m[1]) : topic;
}

// ── what the spine says ─────────────────────────────────────────────────────

/**
 * Every state the spine reports about the live layer — exactly the strings
 * `seam-walkie-state!` carries in hoot/day-boot.scm (the model's test holds the
 * two lists together).
 */
export const SPINE_STATES = [
  "joined", "joined-video", "cam-on", "cam-off", "cam-denied",
  "screen-on", "screen-off", "screen-denied", "full", "denied", "left",
] as const;
export type SpineState = typeof SPINE_STATES[number];

/** Narrow the seam's raw string. An unknown state is `null`, never a guess. */
export function parseSpine(raw: string): SpineState | null {
  return (SPINE_STATES as readonly string[]).includes(raw) ? (raw as SpineState) : null;
}

/** What to tell the person when the spine reports a state that needs saying. */
export interface Notice { msg: string; kind: "warn" | "error"; }
export function noticeFor(s: SpineState): Notice | null {
  switch (s) {
    case "denied":        return { msg: "mic permission denied", kind: "error" };
    case "cam-denied":    return { msg: "camera permission denied — staying on audio", kind: "warn" };
    case "screen-denied": return { msg: "screen share declined", kind: "warn" };
    // the room outgrew the mesh — say so rather than let the people past the
    // ceiling read as silence
    case "full":          return { msg: "room is at the mesh limit — later joiners are not connected", kind: "warn" };
    default:              return null;
  }
}

// ── the live state ──────────────────────────────────────────────────────────

/**
 * Where this client stands with the live layer. `joining` is a room asked for
 * and not yet confirmed; `live` is one the spine confirmed. Every live room
 * carries a video sender, so the camera is a switch you can turn on or off at
 * any time and a call that starts with one can carry on as audio: `cam` and
 * `screen` are what the spine has REPORTED true (capture is asynchronous and
 * can be refused), and `talking` is ours alone (the mic is a local flip).
 */
export type Live =
  | { phase: "out" }
  | { phase: "joining"; room: string }
  | { phase: "live"; room: string; talking: boolean; cam: boolean; screen: boolean };

export const OUT: Live = { phase: "out" };

/** What can happen to that state: our own intent, or the spine's report. */
export type RoomEvent =
  | { t: "join"; room: string }
  | { t: "talk"; on: boolean }
  | { t: "spine"; s: SpineState };

/** The topic of the room we are live in, "" otherwise. */
export const liveRoomOf = (s: Live): string => (s.phase === "live" ? s.room : "");

/**
 * The one transition function. Reports that do not fit the state are ignored —
 * the spine cannot put us in a room we did not ask for, and a camera or screen
 * report means nothing outside a live room.
 *
 * `left` while `joining` is the PREVIOUS room ending: the spine leaves the old
 * room (v1 holds one at a time) before it answers the new join, so it arrives
 * between the ask and the answer and must leave the ask standing.
 */
export function step(s: Live, e: RoomEvent): Live {
  switch (e.t) {
    case "join":
      return { phase: "joining", room: e.room };
    case "talk":
      return s.phase === "live" ? { ...s, talking: e.on } : s;
    case "spine":
      switch (e.s) {
        case "joined":
        case "joined-video":
          return s.phase === "joining"
            ? { phase: "live", room: s.room, talking: false,
                cam: e.s === "joined-video", screen: false }
            : s;
        case "cam-on":
          return s.phase === "live" ? { ...s, cam: true } : s;
        case "cam-off":
          return s.phase === "live" ? { ...s, cam: false } : s;
        case "cam-denied":
          return s;
        case "screen-on":
          return s.phase === "live" ? { ...s, screen: true } : s;
        case "screen-off":
        case "screen-denied":
          return s.phase === "live" ? { ...s, screen: false } : s;
        case "denied":
          return OUT;
        case "left":
          return s.phase === "joining" ? s : OUT;
        case "full":
          return s;
      }
  }
}
