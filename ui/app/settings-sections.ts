// app/settings-sections.ts — what settings actually contains.
//
// Kept apart from app/settings.js on purpose: that file knows how to render a
// registry and nothing about this system; this one knows the system and nothing
// about rendering. Every row here reaches a control that already exists and
// already works — nothing declares a setting the code does not honour.
//
// Which is now CHECKED rather than asserted: SettingRow is a union discriminated
// on `kind`, so a row claiming "select" without options(), or handing set() the
// wrong argument type, does not reach the registry at all.

import { registerSettings } from './settings.js';
// SettingRow is discriminated on `kind`, and a .map() callback widens a literal
// to string unless it is told what it is building — hence the annotations below.
import type { SettingRow } from './settings.js';
import { SHOW_SOURCE } from './source.js';
import { THEMES, theme, setTheme } from './theme.js';
import { CALENDARS, calOn, setCalOn } from './calendars.js';
import { zones, addZone, removeZone, labelZone, knownZones, zoneOffsetLabel } from './voice/worldclock.js';
import { weekStart, setWeekStart, homeFace, setHomeFace, devMode, setDevMode } from './prefs.js';
import { CURRENCIES, currency, setCurrency, currencyInForce, currencyForHere, perHour, fmtMoney } from './money.js';
import { tabCatalogue, tabShown, setTabShown, resetTabs } from './faces.js';
import { locationMode, setLocationMode, homeName } from './tabs/social/location.js';
import { devicesSection, passcodeSection, forgetSection, recoveryFriends, identifierBlock, identity, openIdentityDoor, idHint, voteConsentGiven, recordVoteConsent, forgetVoteConsent } from './tabs/social/id.js';
import { registerProfileSettings } from './profile.js';
import { registerDwellingSettings } from './dwelling.js';
import { dietPanel, bodyPanel, healthPanel, registerTimeSettings } from './attributes.js';
import { standingBlock, whereBlock } from './tabs/social/standing.js';
import type { LocationMode } from './tabs/social/location.js';
import * as ambient from '../lib/ambient.js';
import { createSleepSpansBlock } from './sleep.js';
import { createAwayBlock } from './away.js';
import { reachBlock } from './reach-view.js';
import { bodiesBlock } from './bodies-view.js';
import { render } from './template.js';
import { effect } from './reactive.js';
import type { Fragment } from './template.js';
import { storageRows } from './storage-view.js';
import { mapPacksBlock } from './map-packs-view.js';
import { POI_FAMILIES, familyFaces, poiFamilyOn, setPoiFamily } from './basemap.js';
import { theMap } from './mapview.js';
import { reportBlock } from './report.js';
import { TERMS_HREF, PRIVACY_HREF, ACCESSIBILITY_HREF } from './legal-product.js';
// nothing here repaints anything: every row writes through a signal, and the
// surfaces that read it — the rail, the grid, the dial's bridge effect in
// main.js — follow on their own. That is the point of the spine.

// the zone the add-picker is holding, before it is added
let pendingZone = "";

export function registerAllSettings(): void {
  registerProfileSettings({ diet: dietPanel, body: bodyPanel, health: healthPanel });
  registerDwellingSettings();
  registerTimeSettings();
  registerSettings({
    id: "general", title: "general", order: 10,
    sections: [
      { id: "look", title: "look and feel",
        note: "The theme maps every colour on its way into the DOM (app/theme.js), "
            + "so a pick re-hues the whole site — including anything already painted.",
        rows: () => [
          { kind: "toggle", label: "ambient sound",
            note: "a quiet generative bed that follows the dial's hour and blend — lib/ambient.js",
            get: () => ambient.playing(),
            set: v => { if (ambient.playing() !== v) ambient.toggle(); } },
          { kind: "select", label: "theme",
            // each theme carries its own one-line reading of itself — show the
            // live one's rather than a generic caption
            note: (THEMES.find(t => t.id === theme()) || {}).hint || "the palette the whole site wears",
            options: () => THEMES.map(t => ({ value: t.id, label: t.label || t.id })),
            get: () => theme(), set: v => setTheme(v) },
          { kind: "select", label: "the week starts on",
            note: "governs the mini-month and the week grid together",
            options: () => [{ value: "1", label: "Monday" }, { value: "0", label: "Sunday" }],
            get: () => String(weekStart()), set: v => setWeekStart(+v) },
          { kind: "select", label: "read credit in",
            // the rate is what the commons spent to acquire the currency, off the shop's own shelf — never a market quote
            note: (() => { const c = currencyInForce(); const r = perHour(c);
                           return (r ? `one credit-hour draws ${fmtMoney(c, r.amount)} at what the commons spent to acquire it`
                                     : `this commons holds no ${c} — its rate appears once it acquires some`)
                                + (currency() ? "" : ` · following ${currencyForHere() ? "where this device is" : "the default"}`); })(),
            options: () => [{ value: "", label: `where I am (${currencyForHere() || "USD"})` }, ...CURRENCIES.map(c => ({ value: c.code, label: `${c.code} · ${c.name}` }))],
            get: () => currency(), set: v => setCurrency(v) },
        ] },
      { id: "tabs", title: "tabs",
        note: "Where the page opens, and which faces the top row names. The row starts with "
            + "the map, the calendar and the forum; switch on the rest as you come to use them. A face you are standing on "
            + "stays named, and every face stays reachable by its URL and by voice.",
        rows: () => [
          { kind: "select", label: "home",
            note: "the face the page opens on when the address names none",
            options: () => tabCatalogue().map(t => ({ value: t.id, label: `${t.emoji} ${t.label}` })),
            get: () => homeFace(), set: v => setHomeFace(v) },
          ...tabCatalogue().map((t): SettingRow => ({
            kind: "toggle", label: `${t.emoji}  ${t.label}`, note: t.note,
            get: () => tabShown(t.id), set: v => setTabShown(t.id, v),
          })),
          { kind: "button", label: "back to the three", note: "map · calendar · forum",
            text: "reset", action: resetTabs },
        ] },
      { id: "where", title: "where you are",
        note: "Position moves both sides of your economy at once: the planner reads it as "
            + "your commute origin, as the cell your labour sits in, and as the cell your "
            + "reproduction floors sit in. What crosses the wire is a PLACE the scope already "
            + "knows — never a coordinate, never a trace.",
        rows: () => [
          { kind: "select", label: "sharing", note: "the same three tiers as the 📍 location chip in the bottom bar",
            // these three ARE LocationMode's members, and `satisfies` is what
            // keeps that true if anyone edits the list — so the assertion below
            // rests on something checked rather than on a reader's memory. A
            // select hands back whatever string the DOM has.
            options: () => ([
              { value: "live", label: "live location — a fresh fix while the page is open" },
              { value: "here", label: "here, now — one fix when you ask" },
              { value: "off",  label: "not shared — the plan uses your registered home" },
            ] satisfies { value: LocationMode; label: string }[]),
            get: () => locationMode(), set: v => setLocationMode(v as LocationMode) },
          { kind: "note", text: homeName() ? `home: ${homeName()} — the place the plan falls back to when nothing is shared; the start face registers it` : "no home registered — the plan cannot place you until one is; the start face registers it" },
        ] },
      { id: "dev", title: "developer",
        rows: () => [
          { kind: "toggle", label: "dev mode",
            note: "shows the maintainers' tools: the feedback 💬 in the bottom bar (a note about playnet itself) and the map's layer inspector",
            get: () => devMode(), set: v => setDevMode(v) },
        ] },
    ],
  });

  registerSettings({
    id: "day", title: "the day", order: 20,
    sections: [
      { id: "calendars", title: "calendars",
        note: "Each of these is a real SOURCE of the day, not a folder. Turning one off "
            + "removes it from the dial's ribbons, the week grid, the map's markers and the "
            + "panel's lists together — they all read one switch.",
        rows: () => [
          ...CALENDARS.map((c): SettingRow => ({
            kind: "swatch", label: c.name, note: c.hint, ink: c.ink,
            get: () => calOn(c.id), set: v => setCalOn(c.id, v),
          })),
          { kind: "note",
            text: "A calendar per commune waits on the wire: events arrive without a scope, "
                + "so that checkbox would filter nothing yet." },
        ] },
      { id: "views", title: "dial views",
        note: "The dial's optional constructions. These are the very inputs the dial reads "
            + "(#chords, #spirals, …) — moved here, not copied, so there is one source of truth.",
        rows: () => [
          { kind: "adopt", node: () => document.getElementById("ctl") },
        ] },
      { id: "clocks", title: "world clock",
        note: "Other people's hours, named — a federation is not in one place. The rail on the "
            + "calendar face shows these, live, with a day/night glyph.",
        rows: () => [
          ...zones().map((z): SettingRow => ({
            kind: "text", label: zoneOffsetLabel(z.tz),
            note: "a label of your own — what you call these people",
            placeholder: "label", get: () => z.label || "",
            set: v => labelZone(z.tz, v),
          })),
          ...zones().map((z): SettingRow => ({
            kind: "button", label: `remove ${z.tz.replace(/_/g, " ")}`, text: "remove",
            action: () => removeZone(z.tz),
          })),
          { kind: "select", label: "add a time zone",
            note: "your browser's own tz database — no table here to go stale",
            options: () => [{ value: "", label: "— pick a zone —" },
                            ...knownZones().map(z => ({ value: z, label: z.replace(/_/g, " ") }))],
            get: () => pendingZone,
            set: v => { pendingZone = v; if (v) { addZone(v); pendingZone = ""; } } },
          { kind: "note",
            text: "Daylight here is the civil 07:00–19:00: a zone name carries no latitude, "
                + "so a true sunrise per zone is not something these rows can honestly claim." },
        ] },
    ],
  });

  // A mount for a sheet block: the block draws into a fresh element the
  // settings pane adopts, so one implementation serves wherever it is shown.
  const mount = (draw: (f: d3.Selection) => void) => () => {
    const el = document.createElement("div");
    el.className = "idform-block";
    draw(d3.select(el));
    return el;
  };
  // The same, for a Fragment-producing block (app/template.js's html/render —
  // the walk's own idiom, not d3): one persistent element, one effect that
  // re-renders it into that element on every signal the block reads.
  // MEMOIZED — settings.ts's draw() calls a section's rows() fresh on every
  // open, close and section switch (it is wrapped in effect(draw)), so a
  // row built by calling this inline would mint a new element and a new
  // effect every time, leaking the old effect (still rendering into a
  // detached node) and losing whatever draft was mid-type. Called once per
  // BLOCK reference — which is why createSleepSpansBlock()/createAwayBlock()
  // below are also bound once, not inside rows() — this returns the SAME
  // element on every later call, and rows() just hands it back.
  const mountFragment = (block: () => Fragment) => {
    let el: HTMLElement | null = null;
    return (): HTMLElement => {
      if (!el) { el = document.createElement("div"); effect(() => render(el!, block())); }
      return el;
    };
  };
  const sleepSpansBlock = mountFragment(createSleepSpansBlock());
  const awayBlockSettings = mountFragment(createAwayBlock());
  const reachBlockSettings = mountFragment(reachBlock);
  const mapPacksSettings = mountFragment(mapPacksBlock);
  // one element for the life of the page: a change in progress survives a
  // look at another section, and its own effect follows who is signed in
  let passcodeEl: HTMLElement | null = null;
  const passcodeBlockSettings = (): HTMLElement => {
    if (!passcodeEl) { passcodeEl = mount(passcodeSection)(); }
    return passcodeEl;
  };
  // one element for the life of the page: its own effect follows who is signed in
  let identifierEl: HTMLElement | null = null;
  const identifierBlockSettings = (): HTMLElement => {
    if (!identifierEl) { identifierEl = mount(identifierBlock)(); }
    return identifierEl;
  };
  registerSettings({
    id: "rest", title: "your rest", order: 33,
    sections: [
      { id: "sleep", title: "asleep",
        note: "The span (or spans) of the day you sleep — the plan never schedules a shift into any of "
            + "them. One is the common case, stated in the walk; add a second for a night-shift split "
            + "(each its own weekday restriction) or a biphasic pattern (a main span and a nap).",
        rows: () => [ { kind: "custom", build: sleepSpansBlock } ] },
      { id: "away", title: "days away",
        note: "Ill, resting, or simply away — declared, never explained. No proof, no cap: the plan "
            + "finds nobody on the days you name, hands your shifts to others, and every floor you are "
            + "owed stands regardless of what you contribute.",
        rows: () => [ { kind: "custom", build: awayBlockSettings } ] },
    ],
  });
  registerSettings({
    id: "profile", title: "your profile", order: 29,
    sections: [
      { id: "profile-where", title: "where you are",
        note: "The place the commons holds for you, and the days you have declared ahead. "
            + "Sharing itself is set under general → where you are, or from the 📍 location chip in the bottom bar.",
        rows: () => [ { kind: "custom", build: mount(f => whereBlock(f)) } ] },
      { id: "standing", title: "skills",
        note: "What you say you can do, and how far the record bears it out.",
        rows: () => [ { kind: "custom", build: mount(standingBlock) } ] },
      { id: "reach", title: "how to reach you",
        note: "Your ways to be reached are yours, and are kept on this device. Tell this commune one "
            + "and it notifies you there; put some on a card for a contact, from their row in Contacts. "
            + "Each telling is yours to take back.",
        rows: () => [ { kind: "custom", build: reachBlockSettings } ] },
      { id: "bodies", title: "legal bodies",
        note: "An association, a cooperative, the operator: declared in the scope by a recognised "
            + "person, stewarded by the people it names, and given its identifier by k of its stewards "
            + "signing the inception from their own seats. The law reads what it holds.",
        rows: () => [ { kind: "custom", build: bodiesBlock } ] },
    ],
  });

  registerSettings({
    id: "keys", title: "keys and devices", order: 31,
    sections: [
      { id: "device", title: "stay signed in",
        note: "Your passcode is the root of your identity and stays cold. A key of this device's "
            + "own, which you authorize once, signs for you day to day and signs in after a refresh; "
            + "every such key is listed and can be retired from any device.",
        rows: () => [ { kind: "custom", build: mount(devicesSection) } ] },
      { id: "passcode", title: "change your passcode",
        note: "Your passcode is the only key to your identity. Changing it makes a new one the "
            + "only key, on every device — what to do when someone else may have seen it.",
        rows: () => [ { kind: "custom", build: passcodeBlockSettings } ] },
      { id: "recovery", title: "if you lose your passcode",
        note: "It cannot be reset — but it can be split among people you trust.",
        rows: () => [ { kind: "custom", build: mount(recoveryFriends) } ] },
      { id: "forget", title: "forget me",
        note: "Erase every record this commune holds about you, in one act, and optionally "
            + "retire the identity for good. Your signed key log stays, as records about an "
            + "identifier nobody can resolve to you.",
        rows: () => [ { kind: "custom", build: mount(forgetSection) } ] },
      { id: "places", title: "places on the map",
        note: "What OpenStreetMap knows of a place — its parks, stations, schools, restaurants — "
            + "labelled on the map, family by family. Off, a family is not drawn; the dial's own "
            + "pins always are.",
        rows: () => POI_FAMILIES.map(f => ({
          kind: "toggle" as const, label: f.label, note: familyFaces(f), redraws: false,
          get: () => poiFamilyOn(f.id),
          set: (v: boolean) => setPoiFamily(f.id, v, theMap()),
        })) },
      { id: "maps", title: "offline maps",
        note: "A region kept here draws with no network at all — the map reads it off this device "
            + "before asking the gateway. A download lands in slices and resumes where it stopped.",
        rows: () => [ { kind: "custom", build: mapPacksSettings } ] },
      { id: "storage", title: "what this device keeps",
        note: "Your key event log, this device's key, your log, your pictures and any map regions "
            + "you keep are in this browser's storage. The passcode is the one thing kept nowhere.",
        rows: storageRows },
    ],
  });

  registerSettings({
    id: "you", title: "you and the commons", order: 30,
    sections: [
      { id: "identity", title: "identity",
        note: "Your identifier names you and is not secret; your passcode is the key, and it is "
            + "not stored on this device and never was. The keys that stand in for it are under "
            + "\"keys and devices\". Your name, your standing and signing out are in the identity "
            + "sheet — the person button at the left of the bottom bar opens your account, and the sheet from there.",
        rows: () => [
          { kind: "custom", build: identifierBlockSettings },
          { kind: "button", label: "the identity sheet",
            // rows() is read inside the pane's effect, so this follows who is signed in
            note: identity() ? "profile, standing, vouching, sign out" : "sign in, or create your identity",
            text: "open it",
            action: () => openIdentityDoor() },
        ] },
      ...(SHOW_SOURCE ? [{ id: "doors", title: "the gateway's doors",
        note: "Everything this app asks the gateway is a door, declared once and documented "
            + "by topic. The same doors answer HTTP with a device signature, and MCP at api/mcp.",
        rows: (): SettingRow[] => [
          { kind: "link", label: "the door reference", href: "api/docs/", text: "open ↗" },
          { kind: "link", label: "the MCP tool list", href: "api/mcp-tools.json", text: "open ↗" },
        ] }] : []),
      { id: "report", title: "report a concern",
        note: "Tell this gateway's operator about unlawful or harmful content or conduct, or a child at risk. "
            + "It is read by a person, not acted on by a machine.",
        rows: () => [ { kind: "custom", build: reportBlock } ] },
      { id: "notices", title: "notices",
        note: "Article 13 information stays reachable, not flashed once at the door.",
        rows: () => [
          { kind: "link", label: "terms of use", href: TERMS_HREF, text: "read ↗" },
          { kind: "link", label: "privacy notice", href: PRIVACY_HREF, text: "read ↗" },
          { kind: "link", label: "accessibility statement", href: ACCESSIBILITY_HREF, text: "read ↗" },
          { kind: "note",
            html: "The notices disclose the gaps deliberately — what is kept, what is erased by "
                + "<b>forget me</b> (below) and what stays as data about a pseudonym, and who the "
                + "controller is for <i>this</i> gateway." },
          (() => {
            const aid = () => (idHint() || {}).aid || "";
            const on = () => voteConsentGiven(aid());
            return { kind: "toggle", label: "a vote you cast may be recorded against your identity",
              note: on()
                ? "agreed — withdraw it here any time; you can still vote, and will be asked again the next time you cast one"
                : "not yet agreed — you will be asked the first time you cast a vote",
              get: on,
              set: (v: boolean) => { const a = aid(); if (!a) return; if (v) recordVoteConsent(a); else forgetVoteConsent(a); } };
          })(),
          { kind: "note",
            html: "<b>AI features</b> (the voice assistant, drafting, photo reads, transcription this device "
                + "could not do on its own) send what you submit to an AI service the operator "
                + "selects — nano-gpt, by default. Its \"zero data retention\" and \"TEE\" (Trusted Execution Environment) "
                + "routes are the provider's own best-effort claims, not something the operator or "
                + "nano-gpt can verify end to end: a TEE route does not by itself encrypt a request "
                + "all the way to the model, and nano-gpt says so itself. Ask the operator which "
                + "provider this gateway uses if it differs (privacy notice, §4.3)." },
        ] },
    ],
  });
}
