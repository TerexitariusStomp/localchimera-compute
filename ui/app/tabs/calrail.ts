// app/tabs/calrail.ts — the calendar face's RAIL: the month, the calendars, the
// clocks, the people.
//
// The shape is the one everyone already knows from a calendar's left rail, with
// each piece bound to something this system actually has:
//
//   the mini-month   moves the WHOLE dial (goToDate — the same door the date
//                    label's picker uses), so the clock, the week grid and every
//                    panel follow one viewed day. Days that carry something are
//                    dotted; today is ringed; the viewed day is filled.
//   the calendars    the five real sources of the day (app/calendars.js) with
//                    their own inks — a checkbox is a filter over the dial, the
//                    grid, the map and the panel at once, not a folder.
//   the clocks       a time zone list, live, with a day/night glyph. Zones are
//                    chosen in settings (app/settings.js) and kept per device.
//   the people       your contacts, searched by name or AID; a result selects
//                    the contact the way the contacts panel does.
//
// It draws through the same `day` notifier the rest of the face uses, so an
// accepted proposal or a fresh planner snapshot re-dots the month by itself.

import { effect, signal } from '../reactive.js';
import { S } from '../state.js';
import { evs, pending, eligible, sched, lived, turnAnchor } from '../events.js';
import { FACET_DIMS, facetValues, facetOn, facetActive, toggleFacet, clearFacets,
         facetsRev } from '../facets.js';
import { recipeById } from '../recipe-graph.js';
import type { DayEvent } from '../seam.js';
import { eventRing } from '../day/mytime.js';
import { day, markDayChanged, HANDLERS, hint } from '../core.js';
import { book, nameOf } from '../contact-book.js';
import { gateHint } from '../day/respond.js';
import { goToDate } from '../daterow.js';
import { selectEvent } from '../ribbons.js';
import { baseYear, dateOf, FULLMON } from '../timefmt.js';
import { CALENDARS, calOn, setCalOn, calsRev } from '../calendars.js';
import { weekStart } from '../prefs.js';
import { calView, setCalView, VIEWS } from './calendar.js';
import { closePanelIfNarrow } from '../panel.js';
import { zones, zoneNow } from '../voice/worldclock.js';
import { mk } from '../dom.js';

// which month the mini-month is showing: an offset in months from the viewed
// day's own month, so ‹ › browse without moving the dial (a DAY tap does that).
const monthOff = signal(0);
const search = signal("");

// ── the mini-month ────────────────────────────────────────────────────────
// The first column is the reader's own (app/prefs.js), shared with the week
// grid, so the two week-shaped surfaces never disagree about a day's column.
const LETTERS = ["S", "M", "T", "W", "T", "F", "S"];
const headLetters = () => LETTERS.slice(weekStart()).concat(LETTERS.slice(0, weekStart()));
const doyOf = (date: Date) =>
  Math.round((Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate())
              - Date.UTC(baseYear, 0, 1)) / 86400000);

// a day "carries something" when any visible source puts an event on it: the
// planner's day and its proposals sit on the viewed day, your own events carry
// their own recurrence. This is the month's only claim, so it reads only what
// the calendars above it leave switched on.
function busyDays(y: number, m: number, viewedDoy: number): Set<number> {
  const out = new Set<number>();
  const planCount = (calOn("plan") ? evs.length : 0)
                  + (calOn("props") ? pending().length : 0)
                  + (calOn("open") ? eligible.length : 0);
  if (planCount) out.add(viewedDoy);
  if (calOn("mine")) {
    const days = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
    for (const it of eventRing.items()) {
      if (it.repeat) {                        // every weekday it repeats on, this month
        for (let d = 1; d <= days; d++) {
          const dt = new Date(Date.UTC(y, m, d));
          const name = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"][dt.getUTCDay()];
          const set = it.days || [];
          if (!set.length || set.some(x => x.slice(0, 3) === name)) out.add(doyOf(dt));
        }
      } else if (it.doy != null) out.add(it.doy);
    }
  }
  return out;
}

function drawMonth(host: HTMLElement): void {
  const viewedDoy = Math.floor(turnAnchor() / 24);
  const viewed = dateOf(viewedDoy);
  const todayDoy = Math.floor(S.nowAbs / 24);
  const shown = new Date(Date.UTC(viewed.getUTCFullYear(), viewed.getUTCMonth() + monthOff(), 1));
  const y = shown.getUTCFullYear(), m = shown.getUTCMonth();
  const busy = busyDays(y, m, viewedDoy);

  const head = mk("div", "cr-mhead");
  head.append(mk("span", "cr-mname", `${FULLMON[m]} ${y}`));
  const nav = mk("span", "cr-mnav");
  const prev = mk("a", "cr-marrow", "‹"); prev.title = "the month before";
  const next = mk("a", "cr-marrow", "›"); next.title = "the month after";
  prev.onclick = () => monthOff.set(monthOff() - 1);
  next.onclick = () => monthOff.set(monthOff() + 1);
  nav.append(prev, next);
  head.append(nav);
  host.append(head);

  const grid = mk("div", "cr-month");
  headLetters().forEach(d => grid.append(mk("span", "cr-wd", d)));
  // lead with the tail of the previous month so the columns line up, exactly as
  // the grid you are used to — those cells stay reachable, just quiet.
  const lead = (new Date(Date.UTC(y, m, 1)).getUTCDay() - weekStart() + 7) % 7;
  const total = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
  const cells: Date[] = [];
  for (let i = 0; i < lead; i++) cells.push(new Date(Date.UTC(y, m, -lead + i + 1)));
  for (let d = 1; d <= total; d++) cells.push(new Date(Date.UTC(y, m, d)));
  while (cells.length % 7) cells.push(new Date(Date.UTC(y, m, total + (cells.length % 7))));
  for (const dt of cells) {
    const doy = doyOf(dt);
    const out = dt.getUTCMonth() !== m;
    const a = mk("a", "cr-day" + (out ? " out" : "")
      + (doy === todayDoy ? " today" : "") + (doy === viewedDoy ? " on" : "")
      + (busy.has(doy) ? " busy" : ""), String(dt.getUTCDate()));
    a.title = dt.toISOString().slice(0, 10);
    a.onclick = () => {
      goToDate(dt.getUTCFullYear(), dt.getUTCMonth(), dt.getUTCDate());
      monthOff.set(0);
      markDayChanged();       // the dial moved: repaint the grid, the panels, this rail
      closePanelIfNarrow();   // step aside so the day just chosen is the thing shown
    };
    grid.append(a);
  }
  host.append(grid);
}

// ── the mini-month, mounted elsewhere ─────────────────────────────────────
// The SAME month the calendar rail draws, hosted by another face — the map's
// side panel uses it to move the viewed day, and with it every time-filtered
// marker (offers clip to the turn window; the pool clips to a slot's own
// [from,until] + arcs). One month, two hosts, one viewed day: a tap here IS
// goToDate, so the dial, the grid and the map can never disagree about when.
// AFTER runs after each redraw (the host's own repaint hook, e.g. the map's
// renderMarkers); the effect re-fires on day/month/week-start changes.
let miniHosts = new Set<Element>();       // guards double-mounting one host element
export function initMiniMonth(host: HTMLElement | null, after?: () => void): void {
  if (!host || miniHosts.has(host)) return;
  miniHosts.add(host);
  effect(() => { day(); monthOff(); weekStart(); calsRev();
                 host.replaceChildren(); drawMonth(host);
                 if (after) after(); });
}

// ── the views ────────────────────────────────────────────────────────────
// The drawer's view switcher — a phone calendar's first list. Each row is the
// SAME choice the grid header's select offers (calendar.ts's one signal), so a
// tap here moves the grid, and on a phone it puts the drawer away too.
function drawViews(host: HTMLElement): void {
  const cur = calView();
  const list = mk("div", "cr-views");
  for (const [m, lbl] of VIEWS) {
    const row = mk("a", "cr-view" + (m === cur ? " on" : ""));
    const ic = m === "month" ? "▦" : m === "week" ? "▥" : "▮".repeat(parseInt(m) || 1);
    row.append(mk("span", "cr-vic", ic), mk("span", "cr-vname", lbl));
    row.onclick = () => { setCalView(m); closePanelIfNarrow(); };
    list.append(row);
  }
  host.append(list);
}

// ── the clocks ────────────────────────────────────────────────────────────
function drawClocks(host: HTMLElement): void {
  const zs = zones();
  if (!zs.length) return;
  const box = mk("div", "cr-clocks");
  for (const z of zs) {
    const row = mk("div", "cr-clock");
    row.append(mk("span", "cr-czone", z.label || z.tz.split("/").pop()!.replace(/_/g, " ")));
    const t = zoneNow(z.tz);
    row.append(mk("span", "cr-ctime", t.clock));
    row.append(mk("span", "cr-cday", t.day ? "☀" : "☾"));
    row.title = z.tz;
    box.append(row);
  }
  host.append(box);
}

// ── the calendars ─────────────────────────────────────────────────────────
function drawCalendars(host: HTMLElement): void {
  host.append(mk("h3", null, "my calendars"));
  const list = mk("div", "cr-cals");
  for (const c of CALENDARS) {
    const row = mk("label", "cr-cal");
    const box = document.createElement("input");
    box.type = "checkbox"; box.checked = calOn(c.id);
    box.style.accentColor = c.ink;
    // the setter is the whole act: it notifies, and every reader — this rail, the
    // settings section, and main.js's repaint effect — follows on its own
    box.onchange = () => setCalOn(c.id, box.checked);
    const swatch = mk("span", "cr-swatch");
    swatch.style.background = c.ink;
    row.append(box, swatch, mk("span", "cr-calname", c.name));
    row.title = c.hint;
    list.append(row);
  }
  host.append(list);
  drawFacets(host);
  drawWitness(host);
}

// ── to witness: peers' work awaiting your co-signature ────────────────────
// The k-of-n trust floor's inbox: each row is a collecting ceremony over
// someone else's lived work; ✍ signs its statement with YOUR key (the
// signing happens in day-boot's vat — the key never reaches this module)
// and at quorum the credential strengthens to its multisig form. The rows
// ride a signal refreshed beside the rail's own redraw, and set only on
// change so the redraw effect cannot chase its own fetch.
// kind narrows what is being vouched for: "work" (a peer's lived effort —
// skill/hours filled) or "enroll" (a candidate's personhood — worker holds
// the candidate AID, sponsor the introducing PHC-holder).
interface WitnessRow { said: string; kind: string; worker: string;
                       sponsor: string; skill: string;
                       hours: string; count: number; quorum: number;
                       /** may I sign this one — the ceremony's own rule, asked ahead */
                       eligible?: boolean;
                       /** an enrollment I already vouch for by relationship credential */
                       vouched?: boolean }
const witnessRows = signal<WitnessRow[]>([]);
let witnessLast = "";
export function refreshWitness(): void {
  if (!HANDLERS.witnessInbox) return;
  HANDLERS.witnessInbox().then((j: string) => {
    if (typeof j !== "string" || j === witnessLast) return;
    try { const rows = JSON.parse(j); witnessLast = j; witnessRows.set(rows); }
    catch (e) { /* a non-JSON error reply changes nothing */ }
  });
}

function drawWitness(host: HTMLElement): void {
  const rows = witnessRows();
  if (!rows.length) return;
  host.append(mk("h3", null, "to witness"));
  const box = mk("div", "cr-witness");
  for (const r of rows) {
    const row = mk("div", "cr-wrow");
    const enroll = r.kind === "enroll";
    row.append(mk("span", "cr-wwhat",
                  enroll
                    ? `personhood · ${nameOf(r.worker)}` +
                      (r.sponsor ? ` · via ${nameOf(r.sponsor)}` : "")
                    : `${r.skill || "work"} · ${r.hours} h · ${nameOf(r.worker)}`));
    row.append(mk("span", "cr-wcount", `${r.count}/${r.quorum}`));
    if (enroll && r.vouched) row.append(mk("span", "cr-wnote", "you vouch for them"));
    // the rule asked ahead: a chip you cannot take up is dark and says why,
    // rather than a tap that answers nothing
    const eligible = r.eligible !== false;
    const sign = mk("a", "cr-wsign" + (eligible ? "" : " off"), enroll ? "✍ witness" : "✍ co-sign");
    sign.title = !eligible
      ? (enroll ? "only a recognised person may witness — tap your name (top-right) to request recognition"
                : "only a recognised person may co-sign")
      : enroll
      ? "sign that you have met this person — your signature becomes an edge on their personhood credential"
      : "sign this statement with your own key — quorum strengthens its credential";
    sign.onclick = () => {
      if (!HANDLERS.witnessAttest || !eligible) return;
      HANDLERS.witnessAttest(r.said).then((reply: string) => {
        if (typeof reply === "string" && reply.startsWith("err:") && !gateHint(reply))
          hint(reply.replace(/^err:/, ""), "warn");
        witnessLast = ""; refreshWitness();
      });
    };
    row.append(sign);
    box.append(row);
  }
  host.append(box);
}

// ── the facets: which KINDS are showing ───────────────────────────────────
// One chip row per dimension, under the calendars: the calendars pick the
// SOURCES, these pick the KINDS (VF action, status, scope, recipe) — the same
// passesFacets the grid, the rim and the map all read. A chip renders only
// for a value the day actually holds, and a dimension with a single value
// offers no choice, so it hides until it has one (or until one of its facets
// is active, which must stay reachable to clear).
function drawFacets(host: HTMLElement): void {
  const all: DayEvent[] = [...evs, ...pending(), ...eligible, ...sched, ...lived];
  const box = mk("div", "cr-facets");
  for (const dim of FACET_DIMS) {
    const vals = facetValues(dim, all);
    if (vals.length < 2 && !facetActive(dim)) continue;
    const row = mk("div", "cr-fdim");
    row.append(mk("span", "cr-fname", dim));
    for (const v of vals) {
      const label = dim === "recipe" ? ((recipeById(v) || {}).name || v) : v;
      const chip = mk("span", "cr-fchip", label);
      if (facetActive(dim)) chip.classList.add(facetOn(dim, v) ? "on" : "off");
      chip.onclick = () => toggleFacet(dim, v);
      row.append(chip);
    }
    if (facetActive(dim)) {
      const x = mk("span", "cr-fclear", "×");
      x.title = "show every " + dim;
      x.onclick = () => clearFacets(dim);
      row.append(x);
    }
    box.append(row);
  }
  if (box.childElementCount) { host.append(mk("h3", null, "show only"), box); }
}

// ── the people ────────────────────────────────────────────────────────────
// The field is built ONCE and never replaced. Re-creating a text input on every
// keystroke — or merely re-parenting it, which is a remove plus an insert — takes
// the focus with it, so the first character typed would be the last. Only the hit
// list below it is redrawn. (share.js carries the same warning: the shop's search
// taught this.)
function buildPeople(host: HTMLElement): HTMLElement {
  const wrap = mk("div", "cr-people");
  const field = mk("div", "cr-search");
  field.append(mk("span", "cr-sic", "⚇"));
  const inp = document.createElement("input");
  inp.type = "text"; inp.placeholder = "search for people"; inp.className = "cr-sin";
  inp.value = search.peek();
  inp.oninput = () => search.set(inp.value);
  // Escape clears the search and lets go — the list closes, the field stays yours
  inp.onkeydown = (e: KeyboardEvent) => { if (e.key === "Escape") { search.set(""); inp.value = ""; } };
  field.append(inp);
  wrap.append(field, mk("div", "cr-hits-host"));
  host.append(wrap);
  return wrap;
}

function drawHits(box: HTMLElement): void {
  box.replaceChildren();
  const q = search().trim().toLowerCase();
  if (!q) return;
  const hits = book()
    .filter(c => (c.alias || "").toLowerCase().includes(q)
              || (c.aid || "").toLowerCase().includes(q))
    .slice(0, 6);
  const res = mk("div", "cr-hits");
  if (!hits.length) res.append(mk("div", "cr-nohit", "nobody by that name in your contacts."));
  for (const c of hits) {
    const row = mk("a", "cr-hit");
    const av = mk("span", "cr-av", (c.alias || "?").slice(0, 1).toUpperCase());
    if (c.online) av.classList.add("on");
    row.append(av);
    const t = mk("span", "cr-hitt");
    t.append(mk("b", null, c.alias || c.aid));
    t.append(mk("span", "cr-hitsub", c.rel ? `${c.rel}${c.aid ? " · " + c.aid : ""}` : (c.aid || "")));
    row.append(t);
    // a person is not an event: selecting one clears the event selection and
    // clears the search; this rail owns no contact card.
    row.onclick = () => {
      selectEvent(null);
      search.set("");
      const inp = document.querySelector<HTMLInputElement>("#calrail .cr-sin");
      if (inp) inp.value = "";
    };
    res.append(row);
  }
  box.append(res);
}

// ── the rail ──────────────────────────────────────────────────────────────
// One host per piece, each redrawn by its own effect. The alternative — one
// effect that rebuilds the whole rail — is what ate the search field's focus:
// an effect must not reach outside the DOM it owns.
let wired = false;
export function initCalRail(): void {
  if (wired) return;
  wired = true;
  const host = document.getElementById("calrail");
  if (!host) return;
  const viewsHost = mk("div", "cr-h-views");
  const monthHost = mk("div", "cr-h-month");
  const clockHost = mk("div", "cr-h-clocks");
  const peopleHost = mk("div", "cr-h-people");
  const calHost = mk("div", "cr-h-cals");
  host.replaceChildren(viewsHost, monthHost, clockHost, peopleHost, calHost);
  buildPeople(peopleHost);                       // the field: built once, never again
  // buildPeople appended it two lines up.
  const hitsBox = peopleHost.querySelector<HTMLElement>(".cr-hits-host")!;

  // the views: the calendar face's own signal, read through its exported hand
  effect(() => { calView(); viewsHost.replaceChildren(); drawViews(viewsHost); });
  // the month: the same mount every other host uses (the map's side panel
  // included) — one effect body, one set of dependencies, wherever it hangs
  initMiniMonth(monthHost);
  // the clocks: the zone list
  effect(() => { zones(); clockHost.replaceChildren(); drawClocks(clockHost); });
  // the hits: the query alone — the field above them is untouched
  effect(() => { search(); drawHits(hitsBox); });
  // the calendars: their own switches
  effect(() => { calsRev(); facetsRev(); day(); witnessRows();
                 // a new snapshot can bring new facet values AND new witness
                 // requests; the fetch sets its signal only on change, so the
                 // redraw cannot chase it
                 refreshWitness();
                 calHost.replaceChildren(); drawCalendars(calHost); });
  // an ask can arrive while nothing else on the rail changes — a newcomer
  // asking to be recognised, a peer's work — so the inbox is re-read on its
  // own cadence too; the fetch sets its signal only on change
  setInterval(() => { if (host.isConnected) refreshWitness(); }, 60000);
  // the clocks tick on their own — a minute is the smallest thing they show. This
  // writes the two text nodes in place rather than rebuilding: a redraw every 20s
  // would fight anything the reader is doing in the rail.
  setInterval(() => {
    if (!host.isConnected) return;
    const box = clockHost.querySelector(".cr-clocks");
    if (!box) return;
    zones().forEach((z, i) => {
      const row = box.children[i];
      if (!row) return;
      const t = zoneNow(z.tz);
      row.children[1].textContent = t.clock;
      row.children[2].textContent = t.day ? "☀" : "☾";
    });
  }, 20000);
}
