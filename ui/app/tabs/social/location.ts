// app/tabs/location.ts — the location chip: where you are, to the plan.
//
// Position is the one fact that moves BOTH sides of a person's economy at once.
// The planner reads `agent-position` as the commute origin and as the cell a
// citizen's labour sits in (planner.scm), and as the cell their reproduction
// floors sit in (live.scm scope-consumption) — so a person standing in the park
// is a person whose skills are reachable from the park and whose nutrition is
// wanted at the park. Sharing it re-routes the plan toward you.
//
// What crosses the wire is a PLACE, never a trace: setPositionHere hands raw
// coordinates to the spine, which snaps them to the scope's nearest known
// SpatialThing (service.scm nearest-location) and stores that id alone.
//
// Three states, matching the three tiers agent-position already resolves:
//   live  a watched fix, throttled, until you turn it off (the default)
//   here  one fix, this period — refresh it from the panel
//   off   nothing sent; the plan uses your registered home
//
// The bottom bar's location chip reads the state; its popover holds the whole
// of where-you-are under a "Sharing" tab (share.ts mounts `mountLocationPanel`
// there): named rows, the current one ticked, chosen deliberately. The same
// panel carries the trajectory — a place named for a future period, which the
// planner honours as a declared expected position ("the park, Saturday") — so
// present and future position are read and written in one place, beside (and
// apart from) the "Search" tab, which only filters what the bar shows.

import { HANDLERS, EXT } from '../../core.js';
import { locationOptions } from '../../slots/model.js';
import { html, render } from '../../template.js';
import { signal, effect } from '../../reactive.js';

// the chosen mode survives a reload; the fix itself never persists (a stale
// position is worse than none — the plan would route to where you were).
import type { LatLng } from '../../geom.js';
import { readStr, writeStr, readJSON, writeJSON } from '../../store.js';
import { K } from "../../keys.js";

/** How much of your position the commons is told. */
export type LocationMode = "off" | "here" | "live";

/** One tier, held to across chip and sheet so the two read as one statement. */
interface LocationTier {
  id: LocationMode;
  glyph: string;
  /** Names the choice in the sheet. */
  name: string;
  /** Reads it back on the chip, where there is room for a place name. */
  short: string;
  hint: string;
}

/**
 * The live position state. The chosen MODE survives a reload; the fix itself
 * never persists — a stale position is worse than none, since the plan would
 * route to where you were.
 */
interface LocationState {
  mode: LocationMode;
  /** The place id the spine snapped us to. */
  place: string | null;
  /** navigator.geolocation watch handle. */
  watch: number;
  /** The heartbeat that keeps a stationary sharer's fix fresh (setInterval handle). */
  beat: number;
  /** When we last sent, in ms. */
  at: number;
  /** The coords we last sent, for the move test. */
  from: LatLng | null;
  /** period (0 = now, then days ahead) → place id, declared from this dial. */
  ahead: Map<number, string>;
}

const MODE_KEY = K.locationMode;
// Data-protection-by-default (GDPR Art 25(2)): a device that has never chosen
// shares nothing until it does. `live`/`here` are opt-in only, picked in the
// location panel; this governs the FIRST load, never overriding a stored
// choice (readStr above always wins when one exists).
const DEFAULT_MODE: LocationMode = "off";
const LOC: LocationState = {
  mode: (readStr(MODE_KEY) as LocationMode) || DEFAULT_MODE,
  place: null,        // the place id the spine snapped us to
  watch: -1,          // navigator.geolocation watch handle
  beat: -1,           // the heartbeat's interval handle
  at: 0,              // when we last sent, ms
  from: null,         // the coords we last sent, for the move test
  ahead: new Map<number, string>(),   // period → place id, the futures declared from this dial
};

// A watched position fires far faster than a plan re-solves. Send on a real
// move or a quiet minute, whichever comes first, so the spine sees travel
// rather than GPS jitter.
const QUIET_MS = 60000;
// The spine keeps a fix as a lease (20 minutes): a page that is closed ends its
// own sharing. A watched fix only fires on movement, so a person who stays put
// re-sends the one they have at this beat and the lease never lapses under them.
const BEAT_MS = 5 * 60000;
const MOVED_M = 60;
const metres = (a: LatLng, b: LatLng): number => {
  const R = 6371000, rad = (d: number): number => d * Math.PI / 180;
  const dLat = rad(b.lat - a.lat), dLng = rad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 +
            Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
};

// the scope's places, by the same reader the share face's slots use
const placeName = (id: string | null): string | null => {
  const l = locationOptions(EXT).find(x => x.id === id);
  // a place the fix itself made (place:AID:here) reaches the scope's list a
  // poll after the reply; until it does it is simply where you are
  return l ? l.name : id && id.startsWith("place:") ? "where you are" : id;
};

// ── the wire ──────────────────────────────────────────────────────────────
// The spine replies with the place it snapped to, so the chip can say WHERE
// the commons now thinks you are rather than that a message was sent.
async function send(coords: LatLng): Promise<void> {
  LOC.at = Date.now(); LOC.from = coords;
  lastFix.set(coords);   // this tab's own read of "where you are" — the map glyph and the floors' climate, nothing routes on it
  fixState.set("fixed");
  if (!HANDLERS.setPositionHere) { redraw(); return; }   // offline or signed out: the fix is still this tab's
  const r = await HANDLERS.setPositionHere(0, coords.lat, coords.lng);
  LOC.place = (typeof r === "string" && !r.startsWith("err:") && r !== "ok") ? r : null;
  redraw();
}

function fix(coords: LatLng): void {
  if (LOC.mode === "live" && LOC.from &&
      Date.now() - LOC.at < QUIET_MS && metres(LOC.from, coords) < MOVED_M) return;
  send(coords);
}

function start() {
  if (!navigator.geolocation) { fixState.set("unsupported"); return; }
  fixState.set("asking");
  const take = (p: GeolocationPosition): void => fix({ lat: p.coords.latitude, lng: p.coords.longitude, alt: p.coords.altitude });
  // the browser's refusal is a fact the face can act on (allow the site, or state a home), so it is kept, never swallowed
  const refused = (e: GeolocationPositionError): void => { fixState.set(e.code === e.PERMISSION_DENIED ? "denied" : "failed"); };
  if (LOC.mode === "here") navigator.geolocation.getCurrentPosition(take, refused,
    { timeout: 8000 });
  if (LOC.mode === "live" && LOC.watch < 0)
    LOC.watch = navigator.geolocation.watchPosition(take, refused,
      { enableHighAccuracy: true, maximumAge: 15000 });
  if (LOC.mode === "live" && LOC.beat < 0)
    LOC.beat = window.setInterval(() => { if (LOC.mode === "live" && LOC.from) send(LOC.from); }, BEAT_MS);
}

function stop() {
  if (LOC.watch >= 0 && navigator.geolocation) navigator.geolocation.clearWatch(LOC.watch);
  LOC.watch = -1;
  if (LOC.beat >= 0) window.clearInterval(LOC.beat);
  LOC.beat = -1;
}

// What you share is your statement, kept once at your home so every device
// reads the same: the spine refuses a fix while it says off, and a fix it has
// is a lease. Declared before the first fix of a mode is sent.
const declare = (m: LocationMode): Promise<unknown> =>
  HANDLERS.setLocationSharing
    ? Promise.resolve(HANDLERS.setLocationSharing(m)).catch(() => undefined)
    : Promise.resolve();

// off clears period 0 back to your home — the plan stops routing toward a
// position you are no longer sharing.
function setMode(m: LocationMode): void {
  if (m === LOC.mode) { if (m === "here") start(); return; }   // re-tap "here" = refresh
  stop();
  LOC.mode = m; writeStr(MODE_KEY, m);
  if (m === "off") {
    LOC.place = null; LOC.from = null; lastFix.set(null);
    if (HANDLERS.setLocationSharing) declare(m);          // the spine ends the fix it holds
    else if (HANDLERS.setPosition) HANDLERS.setPosition(0, "");
  } else declare(m).then(() => { if (LOC.mode === m) start(); });
  redraw();
}

// ── the chip ──────────────────────────────────────────────────────────────
// One glyph per tier, held to across chip and sheet so the two read as one
// statement: ○ nothing shared, ◉ a fix, ◎ a following fix.
// `name` names the choice in the sheet, `short` reads it back on the chip —
// the header row has room for a place name, not for a sentence.
const MODES: LocationTier[] = [
  { id: "live", glyph: "◎", name: "live location", short: "live",
    hint: "a fresh fix while this page is open" },
  { id: "here", glyph: "◉", name: "here, now", short: "here",
    hint: "one fix for this period, taken when you ask" },
  { id: "off",  glyph: "○", name: "not shared", short: "location",
    hint: "the plan uses your registered home" },
];
const MODE = (id: LocationMode): LocationTier => MODES.find(m => m.id === id) || MODES[0];

// Sharing IS an identity act — setPositionHere writes against the session
// AID (this file's own header: "the plan reads agent-position as... a
// citizen's" — there is no anonymous position to hold). The panel always
// draws; `authed` only changes what its rows DO — share, or open the SAME
// sign-in door tapping your name does (onNeedsIdentity, wired by id.ts) — so
// the feature is discoverable before it is usable.
let authed = false;   // until id.ts says the door is open
let onNeedsIdentity: (() => void) | null = null;

/** Wire the identity door: whether sharing can act, and where "sign in first" leads. */
export function locationDoor(open: boolean, needsIdentity: (() => void) | null): void {
  authed = open; onNeedsIdentity = needsIdentity;
  if (open && !adopted) void adopt();
  if (!open) adopted = false;
  redraw();
}

// On sign-in the spine's statement is the one that stands: a device adopts the
// mode its person declared (from another device, or an earlier day), and a
// person who never declared has theirs — this device's choice, live by default —
// declared for them.
let adopted = false;
async function adopt(): Promise<void> {
  adopted = true;
  if (!HANDLERS.locationSharing) return;
  const m = await HANDLERS.locationSharing();
  if (m === "live" || m === "here" || m === "off") {
    if (m === LOC.mode) return;
    stop();
    LOC.mode = m; writeStr(MODE_KEY, m);
    if (m === "off") { LOC.place = null; LOC.from = null; lastFix.set(null); }
    else if (m === "live") start();
    redraw();
  } else if (m === "undeclared") {
    await declare(LOC.mode);
  }
}

// Every change to what is shared bumps this; readers (`sharing`, the panel)
// subscribe through it.
const tick = signal(0);
function redraw(): void { tick.update(n => n + 1); }

/** What is shared now, read without subscribing — for code that wants the value, not the edge. */
export const sharedNow = (): { mode: LocationMode; place: string | null; placeId: string | null } => {
  const on = authed && LOC.mode !== "off";     // signed out, nothing is shared whatever the mode says
  return { mode: on ? LOC.mode : "off", place: on ? placeName(LOC.place) : null, placeId: on ? LOC.place : null };
};

/** What the bar's chip shows of sharing: the mode, and the place the commons snapped to. Subscribes. */
export const sharing = (): ReturnType<typeof sharedNow> => { tick(); return sharedNow(); };

// Something elsewhere (the profile's "change") asks for the panel; the bar
// opens it on the Sharing tab.
export const locationAsk = signal(0);

// ── the panel ─────────────────────────────────────────────────────────────
// Periods are the daily spans set-daily-horizon! lays out, so period t = t days
// from today. `do-set-position` accepts any period and agent-position honours it
// as a manual expected override — so a declared future needs no machinery
// beyond this form.
const DAYS: string[] = ["today", "tomorrow", "in 2 days", "in 3 days", "in 4 days", "in 5 days", "in 6 days"];

// what the reader has picked in the two selects, held here so a fix landing
// (which redraws the panel) never resets a half-made choice
const pick = { when: "0", where: "", say: "" };

/**
 * Mount the whole of where-you-are into `el`, redrawn in place on every
 * change. Returns the redraw, for the caller to run when it shows `el`.
 * Built through the shared renderer (app/template.ts), which is what lets the
 * panel read as the one expression it is rather than as forty appends.
 */
export function mountLocationPanel(el: HTMLElement): () => void {
  el.classList.add("locpanel");
  const draw = (): void => {
    const places = locationOptions(EXT);
    // what the commons actually holds: the place a fix snapped to. This is the
    // only position that left the dial — the coordinates never did.
    const now = !authed            ? "sign in to share where you are."
              : LOC.mode === "off" ? "nothing is being shared."
              : LOC.place          ? `the commons places you at ${placeName(LOC.place)}.`
              : LOC.mode === "live" ? "waiting for a fix…"
              : "no fix yet.";
    const choose = (m: LocationMode): void => {
      if (!authed) { if (onNeedsIdentity) onNeedsIdentity(); return; }
      setMode(m);
    };
    render(el, html`
      <div class="locpanel-h">where you are</div>
      ${MODES.map(m => html`
        <div class="locmode${m.id === LOC.mode && authed ? " on" : ""}" onclick=${() => choose(m.id)}>
          <span class="locglyph">${m.glyph}</span>
          <span class="locmode-t"><b>${m.name}</b><span class="locmode-h">${m.hint}</span></span>
        </div>`)}
      <div class="locpanel-now">${now}${authed && LOC.mode === "here" &&
        html`<a class="locrefresh" onclick=${() => start()}>take a fresh fix</a>`}</div>

      <div class="locpanel-h locpanel-h2">where you will be</div>
      ${!places.length
        ? html`<div class="locpanel-empty">this scope has no named places yet — a position snaps to one of them.</div>`
        // NO whitespace between these: they are inline-level, and a newline in
        // the markup is a text node the browser renders as a space.
        : [html`<div class="locpanel-row"><select class="locsel locwhen" onchange=${(ev: Event) => { pick.when = (ev.target as HTMLSelectElement).value; }}>${DAYS.map((d, i) =>
               html`<option value="${i}">${d}</option>`)}</select><select class="locsel locwhere" onchange=${(ev: Event) => { pick.where = (ev.target as HTMLSelectElement).value; }}><option value="">— home —</option>${
               places.map(p => html`<option value="${p.id}">${p.name}</option>`)}</select><button class="locset" onclick=${setAhead}>set</button></div>`,
           html`<div class="locpanel-say">${pick.say}</div>`,
           // …and what has been declared, so the panel answers the question it
           // asks. The spine holds these but reads back none of them, so this is
           // the record of what THIS dial declared — said plainly rather than
           // dressed as the plan's.
           LOC.ahead.size > 0 && html`<div class="locahead">${
             [...LOC.ahead.keys()].sort((a, b) => a - b).map(t => html`
               <div class="locahead-r"><span class="locahead-d">${
                 DAYS[t] || `in ${t} days`}</span><span class="locahead-p">${
                 placeName(LOC.ahead.get(t)!)}</span><a class="locahead-x" title="back to your home" onclick=${async () => {
                   if (!HANDLERS.setPosition) return;
                   if ((await HANDLERS.setPosition(t, "")) === "ok") { LOC.ahead.delete(t); redraw(); }
                 }}>×</a></div>`)}</div>`]}`);
    // the two selects hold no state of their own between draws, so what the
    // reader had picked is put back after the markup lands
    const when = el.querySelector<HTMLSelectElement>(".locwhen"), where = el.querySelector<HTMLSelectElement>(".locwhere");
    if (when) when.value = pick.when;
    if (where) where.value = pick.where;
  };
  effect(() => { tick(); draw(); });   // the subscription is the effect's; `draw` alone reads nothing
  return draw;
}

/** Declare where you will be on a chosen day — or say why the spine refused. */
async function setAhead(ev: Event): Promise<void> {
  if (!authed) { if (onNeedsIdentity) onNeedsIdentity(); return; }
  if (!HANDLERS.setPosition) return;
  const panel = (ev.currentTarget as Element).closest(".locpanel")!;
  const t = Number((panel.querySelector(".locwhen") as HTMLSelectElement).value);
  const p = String((panel.querySelector(".locwhere") as HTMLSelectElement).value);
  const r = await HANDLERS.setPosition(t, p);
  if (r !== "ok") {
    pick.say = String(r || "err").replace(/^err:/, "");
    redraw();
    return;
  }
  pick.say = "";
  if (p) LOC.ahead.set(t, p); else LOC.ahead.delete(t);
  redraw();
}

// The place a shared position resolved to, for anything that wants to be told
// "here" — the share face's where-editor pins a need to it. Null while location
// sharing is off, so "here" simply does not appear.
export const currentPlace = (): string | null => (LOC.mode === "off" ? null : LOC.place);

/**
 * Where you are, as the profile reads it: the sheet's own three facts — how
 * much is shared, the place the commons snapped you to, and the days declared
 * ahead — by name, never by coordinate.
 */
export function locationSummary(): { mode: LocationMode; modeName: string; place: string | null; ahead: { day: string; place: string }[] } {
  return {
    mode: LOC.mode, modeName: MODE(LOC.mode).name,
    place: LOC.mode === "off" ? null : placeName(LOC.place),
    ahead: [...LOC.ahead.keys()].sort((a, b) => a - b)
      .map(t => ({ day: DAYS[t] || `in ${t} days`, place: placeName(LOC.ahead.get(t)!) || "" })),
  };
}

/** Open the location panel from elsewhere — the profile's "change" reaches the same one door. */
export function openLocationSheet(): void { locationAsk.update(n => n + 1); }

// This session's own fix — a signal so the map tab's glyph can follow it live,
// never persisted (a stale position is worse than none, per above).
export const lastFix = signal<LatLng | null>(null);

/** What the browser said when asked for a fix: nothing yet, asking, a fix, or why there is none. */
export type FixState = "idle" | "asking" | "fixed" | "denied" | "failed" | "unsupported";
export const fixState = signal<FixState>("idle");

// ── the registered home ───────────────────────────────────────────────────
// The floor every position rule falls back to (live.scm agent-cell: live fix →
// committed work → declared future → home): with no home the plan cannot place
// you at all. It is the agent record's primary location, set through the
// set-home door as a place the scope knows or as your own place:AID:home from
// coordinates. What is kept here is the reader's copy — the place id and, when
// it was made from coordinates, those — so the walk and the floors can read it
// before the commons has answered, and after a reload.
export interface Home { place: string; name?: string; lat?: number; lng?: number }
const HOME_KEY = K.home;
export const home = signal<Home | null>(readJSON<Home | null>(HOME_KEY, null));

/**
 * Register a home: a known place id, or "" with coordinates for your own place.
 * Replies the place id the commons took, or the reason it did not; either way
 * the local copy is kept, so a home stated offline stands until you sign in.
 */
export async function setHome(place: string, lat?: number, lng?: number): Promise<{ ok: boolean; said: string }> {
  const name = place ? placeName(place) || place : undefined;
  const local: Home = { place, ...(name ? { name } : {}), ...(lat != null && lng != null ? { lat, lng } : {}) };
  home.set(local); writeJSON(HOME_KEY, local);
  if (!HANDLERS.setHome) return { ok: true, said: "kept on this device — told to the commons when you sign in" };
  const r = await HANDLERS.setHome(place, lat ?? 0, lng ?? 0);
  if (typeof r === "string" && !r.startsWith("err:")) {
    const kept: Home = { ...local, place: r === "ok" ? place : r };
    home.set(kept); writeJSON(HOME_KEY, kept);
    return { ok: true, said: `the commons holds your home as ${placeName(kept.place) || "your own place"}` };
  }
  return { ok: false, said: typeof r === "string" ? r.replace(/^err:\s*/, "") : "the commons did not answer" };
}

/** The home, as a sentence: its place name, or that none is registered yet. */
export const homeName = (): string | null => { const h = home(); return h ? (placeName(h.place) || h.name || (h.lat != null ? "your own place" : h.place)) : null; };

/** Where the floors read you from: this session's fix, else the home's coordinates when it has them. */
export const positionForFloors = (): LatLng | null => {
  const f = lastFix(); if (f) return f;
  const h = home(); return h && h.lat != null && h.lng != null ? { lat: h.lat, lng: h.lng } : null;
};

/** A globe facing the fix's own hemisphere: 🌎 the Americas, 🌍 Europe/Africa, 🌏 Asia/Oceania.
 *  With no fix yet, the browser's own timezone stands in for "roughly where you are". */
export function mapGlobe(): string {
  const lng = lastFix()?.lng ?? (() => {
    try {
      const off = -new Date().getTimezoneOffset();    // minutes east of UTC
      return off / 4;                                 // ~15°/hour, a rough longitude
    } catch (_) { return 0; }
  })();
  return lng < -30 ? "🌎" : lng < 60 ? "🌍" : "🌏";
}

// A signed-out or offline dial shares nothing; drop any watch and forget the fix.
export function locationOff(): void {
  stop(); LOC.place = null; LOC.from = null; LOC.ahead.clear(); redraw();
}

// The mode, for settings: the same three tiers, set through the same door the
// sheet's rows use — so a change there stops/starts the watch and re-labels the
// chip exactly as a tap would.
export const locationMode = (): LocationMode => LOC.mode;
export const setLocationMode = (m: LocationMode): void => setMode(m);

// Resume a watch the citizen left running, once the door is open again. Only
// `live` resumes: `here` is one deliberate fix per tap, and renderId runs on a
// poll, so re-fetching it here would take a fix the citizen never asked for.
export function locationResume(): void {
  if (LOC.mode === "live" && LOC.watch < 0) start();
}
