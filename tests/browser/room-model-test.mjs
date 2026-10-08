// tests/browser/room-model-test.mjs — what a room is, and what being live in one can be
// (browser/app/voice/room-model.js)
//
// The live state is a union and one reducer, so the claims worth holding are
// PROPERTIES of every path through it, not the paths a person happens to click:
// talk, camera and screen exist only while live, "live" always names its room,
// and no report can put this client in a room it never asked for.
//
// The one path no tidy reducer finds on its own is the room HOP. The spine leaves
// the old room (v1 holds one at a time) BEFORE it answers the new join, so a
// `left` lands between the ask and the answer. A reducer that took it for the
// end of the ask would drop the `joined` behind it and leave the person on air
// in a room the page believes it is out of.
//
// Run: node tests/browser/room-model-test.mjs

import { readFileSync } from "node:fs";
import { harness } from "./dom-stub.mjs";

const M = await import("../../browser/app/voice/room-model.js");
const { check, done } = harness();
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

const run = (events, from = M.OUT) => events.reduce(M.step, from);
const spine = (s) => ({ t: "spine", s });
const join = (room) => ({ t: "join", room });

// ── the spine's vocabulary is the vocabulary the spine speaks ───────────────
{
  const scm = readFileSync(new URL("../../hoot/day-boot.scm", import.meta.url), "utf8");
  // every literal handed to seam-walkie-state!, bare or as either arm of an (if …)
  const spoken = new Set();
  for (const m of scm.matchAll(/\(seam-walkie-state!\s+(\(if [^)]*\)|"[a-z-]+")\)/g))
    for (const lit of m[1].matchAll(/"([a-z-]+)"/g)) spoken.add(lit[1]);
  check("every state the spine emits is in SPINE_STATES",
        [...spoken].every(s => M.SPINE_STATES.includes(s)), [...spoken].join());
  check("every SPINE_STATES entry is one the spine emits",
        M.SPINE_STATES.every(s => spoken.has(s)), M.SPINE_STATES.filter(s => !spoken.has(s)).join());
  check("parseSpine accepts each of them", M.SPINE_STATES.every(s => M.parseSpine(s) === s));
  check("parseSpine refuses what the spine never says",
        M.parseSpine("joind") === null && M.parseSpine("") === null && M.parseSpine("LEFT") === null);
}

// ── the way in and out ──────────────────────────────────────────────────────
{
  const asked = run([join("r1")]);
  check("asking is joining, not live", asked.phase === "joining" && M.liveRoomOf(asked) === "");
  const live = run([join("r1"), spine("joined-video")]);
  check("joined-video is live in that room with the camera on",
        live.phase === "live" && live.room === "r1" && live.cam === true);
  const refused = run([join("r1"), spine("joined")]);
  check("a refused camera drops to audio — the room still works",
        refused.phase === "live" && refused.cam === false);
  check("you join muted: push to talk", live.talking === false && refused.talking === false);
  check("denied ends the ask", run([join("r1"), spine("denied")]).phase === "out");
  check("left ends a live room", run([join("r1"), spine("joined"), spine("left")]).phase === "out");
}

// ── the camera is a switch, in either kind of call ──────────────────────────
{
  const video = run([join("r"), spine("joined-video")]);
  const toAudio = M.step(video, spine("cam-off"));
  check("a call that began with video carries on as audio when the camera stops",
        toAudio.phase === "live" && toAudio.cam === false && toAudio.room === "r");
  const audio = run([join("r"), spine("joined")]);
  check("a call that began as audio can add a camera",
        M.step(audio, spine("cam-on")).cam === true);
  check("a refused camera changes nothing and keeps the call",
        eq(M.step(audio, spine("cam-denied")), audio));
  check("screen sharing works in a call that began as audio",
        M.step(audio, spine("screen-on")).screen === true);
  check("stopping the camera leaves a share in place",
        run([join("r"), spine("joined-video"), spine("screen-on"), spine("cam-off")]).screen === true);
  check("the camera asks nothing of the mic: talk survives camera changes",
        run([join("r"), spine("joined"), { t: "talk", on: true }, spine("cam-on"), spine("cam-off")]).talking === true);
}

// ── reports that do not fit are ignored ─────────────────────────────────────
{
  check("the spine cannot put us in a room we did not ask for",
        run([spine("joined")]).phase === "out" && run([spine("joined-video")]).phase === "out");
  check("camera and screen reports mean nothing while out",
        ["cam-on", "cam-off", "screen-on", "screen-off", "screen-denied"].every(r => run([spine(r)]).phase === "out"));
  check("a report cannot turn a pending join live",
        ["cam-on", "screen-on"].every(r => run([join("r"), spine(r)]).phase === "joining"));
  check("talk intents mean nothing while out",
        eq(run([{ t: "talk", on: true }]), M.OUT));
  check("full changes nothing", eq(run([join("r"), spine("joined"), spine("full")]), run([join("r"), spine("joined")])));
}

// ── the room hop ────────────────────────────────────────────────────────────
{
  const hop = run([join("a"), spine("joined-video"), join("b"), spine("left"), spine("joined")]);
  check("a hop survives the old room's left landing between the ask and the answer",
        hop.phase === "live" && hop.room === "b" && hop.cam === false, JSON.stringify(hop));
  const hopDenied = run([join("a"), spine("joined"), join("b"), spine("left"), spine("denied")]);
  check("a hop whose mic is refused ends out, not in the old room", hopDenied.phase === "out");
}

// ── properties of every path ────────────────────────────────────────────────
{
  let seed = 7;
  const rnd = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; };
  const rooms = ["a", "b", "c"];
  const pick = () => {
    switch (rnd(4)) {
      case 0: return join(rooms[rnd(3)]);
      case 1: return { t: "talk", on: rnd(2) === 0 };
      default: return spine(M.SPINE_STATES[rnd(M.SPINE_STATES.length)]);
    }
  };
  let bad = null;
  for (let trial = 0; trial < 400 && !bad; trial++) {
    let s = M.OUT;
    for (let i = 0; i < 40 && !bad; i++) {
      const e = pick();
      try { s = M.step(s, e); } catch (err) { bad = `threw on ${JSON.stringify(e)}: ${err}`; break; }
      if (s.phase === "out" && Object.keys(s).length !== 1) bad = "out carries fields";
      if (s.phase !== "out" && !rooms.includes(s.room)) bad = "a room state without its room";
      if (s.phase !== "live" && ("cam" in s || "screen" in s || "talking" in s)) bad = "live flags outside live";
      if ((M.liveRoomOf(s) !== "") !== (s.phase === "live")) bad = "liveRoomOf disagrees with phase";
    }
  }
  check("400 random 40-event paths: never throws, out is bare, a room state names its room, live flags only while live",
        bad === null, bad || "");
}

// ── the topic ───────────────────────────────────────────────────────────────
{
  check("a meeting topic reads back as its slug",
        M.roomLabel(M.meetingTopic("scopeX", "kitchen")) === "kitchen");
  check("the network reads as the network", M.roomLabel(M.meetingTopic("scopeX", "network")) === "📻 the network");
  check("a topic that is no meeting shows as itself (an event's id)", M.roomLabel("event:band-practice") === "event:band-practice");
  check("a slug may hold slashes", M.roomLabel(M.meetingTopic("s", "a/b")) === "a/b");
  check("a slug is lower-case words joined by dashes",
        M.roomSlug("recipe", "Sourdough Loaf!") === "recipe-sourdough-loaf");
  check("punctuation and edges fall away; nothing to name it by is empty",
        M.roomSlug("  --Plan--  ") === "plan" && M.roomSlug("", "!!") === "");
  check("a slug survives the topic round trip",
        M.roomLabel(M.meetingTopic("s", M.roomSlug("recipe", "Garden Greens"))) === "recipe-garden-greens");
}

// ── what gets said ──────────────────────────────────────────────────────────
{
  check("only denied, cam-denied, screen-denied and full speak",
        M.SPINE_STATES.filter(s => M.noticeFor(s)).sort().join() === "cam-denied,denied,full,screen-denied");
  check("a refused mic is an error; the rest are warnings",
        M.noticeFor("denied").kind === "error" && M.noticeFor("full").kind === "warn");
}

done();
