// app/tabs/share.ts — the SHARE BAR: needs, offers, and lending as universal
// layout chrome — a footer drawer at the stage's foot, present on EVERY face
// the way the header is. Collapsed: the creation pill and a chip strip of your
// slots. Expanded: the full share surface (slot cards, the lent rail, the
// honesty note). The share nav button toggles the drawer; no face switch.
//
// The free-association unification, on ValueFlows: the SAME slot card
// expresses a NEED (a standing <intent> the plan provisions — your true
// order book) and a CAPACITY (an owned <economic-resource> with its
// recurring availability). One creation pill, two rails, everything edited
// inline (app/slots/*). Editing IS declaring: every commit re-declares
// through the deterministic-id upsert (declare-need / declare-means), so
// the server record is the single source of truth and this face carries
// no draft state at all.
//
// SOCIALIZATION lives here too, on the card that declared the means: an
// offer is the first half (you own this, this much — the ownership a grant
// projects from), the 🤲 section is the second (for this long, to this
// commons), and the rail carries every live grant with its recall. One
// surface for the whole act, so there is no second place to keep in step.
//
// Shopping becomes supplementary by construction: a need slot asks the
// PLAN first; the shop's claim path is the fallback when communal
// provision can't satisfy it and the draw goes to your credit.
//
// TWO STANDPOINTS, read left to right as a phrase — My Needs, Our Offers:
//   My   your leaf: the slots you declared, edited inline, ↵ declares. What
//        you add here is what folds up.
//   Our  the FOLD at the scope the breadcrumb stands in (planner service
//        our-slots: the ^demand-node / ^means-pool cells): everyone's needs
//        and offers SUMMED per thing · place · window, no one's name in them,
//        your own share named inside the sum. A sum is read, never written,
//        so under Our the pill is the sift alone and ↵ declares nothing.
// The bar says which job it is doing: the same name input is the declaration's
// name under My and the sift under Our; the draft reads back as one line
// before ↵; a chip that holds a value shows it.

import { EXT, HANDLERS, PLAN, USER, askJSON } from '../../core.js';
import { signal, effect, type Signal } from '../../reactive.js';
import { blankSlot, specOf, locationOptions, knownSpecs, knownEmoji, humanDate, fmtArcs, fmtWhere,
         UNITS, unitReading } from '../../slots/model.js';
import { classifySlot } from '../../slots/classify.js';
import { whereEditor } from '../../slots/editors.js';
import { slotCard } from '../../slots/card.js';
import type { AskDisplacement } from '../../slots/criteria.js';
import type { Tension } from '../../slots/model.js';
import { draftPanel } from '../../slots/draft.js';
import { metOf } from '../../slots/met.js';
import { searchFilter, TIME_MODES, type TimeMode } from '../../search.js';
import { passesRhythm } from '../map/atlas.js';
import { readJSON, writeJSON } from '../../store.js';
import { setFace } from '../../faces.js';
import { applyHere, hereOfInstant } from '../../gohere.js';
import { allScopes } from '../../scope.js';
import { parse as readUtterance, FACE_WORDS } from '../../utter.js';
import type { Reading, UtterContext } from '../../utter.js';
import { runPass, aiAvailable } from '../../day/extract.js';
import { skillsPanel, claimSkills } from './standing.js';
import { contactsPanel } from '../contacts.js';
import { connectIn } from '../../connect-link.js';
import { propose, onPropose } from '../../connect.js';
import { resourcesPanel } from '../shop.js';
import { figure } from '../../count.js';
import { currentPlace, sharing, sharedNow, mountLocationPanel, locationAsk } from './location.js';
import { idHint } from './id.js';
import { pressToSpeak, onSpeechModel, speechModel, type ModelState } from '../../voice/audio.js';
import { bytes } from '../../storage-health.js';
import { voiceSink } from '../../voice/sink.js';
import { logEntry } from './log.js';
import { showChat } from './chat.js';
import { trackUnread, unreadOf } from '../../unread.js';
import { hint } from '../../core.js';
import { SOCIAL_DEMO_POOL } from '../../demo/social-pool.js';
import type { SocialDemoRow } from '../../demo/social-pool.js';
import type { Slot, SlotKind, Arc } from '../../slots/model.js';
import type { PillAccess } from '../../slots/draft.js';
import { armTwice } from '../../slots/editors.js';
import { grants, grantOf, grantLine, recall as recallGrant, lendControl } from '../../lend.js';
import { ceilingOf, spoken, hostingSentence } from '../../slots/declarations.js';
import { mk } from '../../dom.js';

import { on } from '../../bus.js';
import { scopeSig, scopeName } from '../../scope.js';
import { K } from "../../keys.js";
import { S as dialState } from '../../state.js';
/**
 * Both rails as the my-slots wire carries them, plus whether this is the local
 * DEMO. `demo` is not decoration: it is the switch between mutating locally and
 * declaring through the upsert, so it travels with the lists rather than beside
 * them.
 */
interface SlotLists { needs: Slot[]; means: Slot[]; demo: boolean }

/**
 * One cell of the fold at the scope you stand in — the OUR reading. A need is
 * declared once, by a person; what the scope holds is the sum per (spec, place,
 * window, kind), with no one's name in it. `mine` is your own share of that
 * sum, joined from your leaf — the one thing about a person the cell says, and
 * only about you.
 */
export interface Cell { spec: string; where: string; from: string; until: string;
                        tension: string; unit: string; qty: number; mine: number;
                        /** the demo fold carries the fixture's own name and glyph; the wire carries the spec id */
                        name?: string; emoji?: string }
export interface Fold { needs: Cell[]; means: Cell[]; demo: boolean }

// ── state: the server's slot lists + a local demo fallback ────────────────
const slots = signal<SlotLists>({ needs: [], means: [], demo: true });
/**
 * Your declared needs, for any face that shows them elsewhere — the calendar
 * draws their rhythm as standing bands. A signal read, so a reader's effect
 * follows every refresh of the slot lists.
 */
export const myNeeds = (): Slot[] => slots().needs;
/** Your declared offers, the same way — the Resources card reads its good's offer here. */
export const myMeans = (): Slot[] => slots().means;
// the fold — the scope's needs and offers SUMMED (planner service our-slots,
// the ^demand-node / ^means-pool cells); fetched once at init and again on
// switching into "Our" so it isn't stale the first time it's actually looked at.
const social = signal<Fold>({ needs: [], means: [], demo: true });
/** The fold at the scope you stand in — everyone's needs and offers, summed. A tracked read. */
export const ourFold = (): Fold => social();
// the demo twin of the fold: app/demo/social-pool.ts folded the same way the
// server folds — summed per (spec, place), your rows ("you") as `mine`. The
// SAME fixture the match ring stands up offline, and the one your OWN mySlots
// demo (below) is cut from, so "My" and "Our" can't drift apart offline the
// way two independently-authored demos always eventually do.
const toSlot = (r: SocialDemoRow): Slot =>
  ({ id: r.id, spec: r.spec, name: r.name, emoji: r.emoji, note: r.note,
     qty: r.qty, unit: r.unit, where: "", arcs: r.arcs, cats: r.cats });
const foldDemo = (rows: SocialDemoRow[], yours: (r: SocialDemoRow) => boolean): Cell[] => {
  const cells = new Map<string, Cell>();
  for (const r of rows) {
    const k = `${r.spec}\t`;
    const c = cells.get(k) || { spec: r.spec, where: "", from: "", until: "", tension: "",
                                unit: r.unit || "each", qty: 0, mine: 0, name: r.name, emoji: r.emoji };
    c.qty += Number(r.qty) || 0;
    if (yours(r)) c.mine += Number(r.qty) || 0;
    cells.set(k, c);
  }
  return [...cells.values()];
};
export function refreshSocial(): void {
  if (!HANDLERS.ourSlots) {
    social.set({ needs: foldDemo(SOCIAL_DEMO_POOL.needs, r => r.who === "you"),
                 means: foldDemo(SOCIAL_DEMO_POOL.means, r => r.owner === "you"), demo: true });
    return;
  }
  HANDLERS.ourSlots().then(reply => {
    if (typeof reply !== "string" || !reply || reply.startsWith("err:")) return;
    try {
      const v = JSON.parse(reply);
      const num = (s: unknown) => { const x = parseFloat(s as string); return isFinite(x) ? x : 0; };
      const fix = (list: Cell[]) => (list || []).map(c => ({ ...c, qty: num(c.qty), mine: num(c.mine) }));
      social.set({ needs: fix(v.needs), means: fix(v.means), demo: false });
    } catch (_) { /* a malformed reply leaves the last fold standing */ }
  });
}

// ── a cell's face: the sum, the place, the window, and your share of it ──
// A read, not a card: there is nothing to edit in a sum. The name and glyph
// come from the specs the dial already knows (a cell carries the spec id, as
// the fold does); a spec the dial has never seen shows its id.
function cellFace(c: Cell, kind: SlotKind, locs: ReturnType<typeof locationOptions>): HTMLElement {
  const names = knownSpecs(EXT, PLAN), glyphs = knownEmoji(EXT, PLAN);
  const name = c.name || names.get(c.spec) || c.spec;
  const emoji = c.emoji || glyphs.get(c.spec) || glyphs.get(name.toLowerCase()) || (kind === "need" ? "🌱" : "🤲");
  const el = mk("div", `slot-card slot-${kind} slot-ro slot-cell`);
  el.dataset.spec = c.spec;
  const head = mk("div", "slot-head");
  head.append(mk("span", "slot-emoji", emoji), mk("span", "slot-name", name),
              mk("span", "slot-qty-ro", figure(c.qty)), mk("span", "slot-unit", c.unit || ""));
  el.appendChild(head);
  const sums = mk("div", "slot-sums");
  const sum = (icon: string, text: string) => { if (text) sums.appendChild(mk("span", "slot-sum slot-sum-ro", `${icon} ${text}`)); };
  sum("📍", c.where ? fmtWhere(c.where, locs) : "");
  sum("🕐", c.from || c.until
      ? `${c.from ? humanDate(c.from) || c.from : "…"} → ${c.until ? humanDate(c.until) || c.until : "…"}` : "");
  if (c.tension && c.tension !== "des") sum("◆", c.tension === "right" ? "a right" : "a need");
  el.appendChild(sums);
  if (c.mine > 0)
    el.appendChild(mk("div", "slot-who slot-mine", `of which yours: ${figure(c.mine)} ${c.unit || ""}`));
  return el;
}
/** The inventory drawer's non-slot-declaring views ride here rather than in
 *  the rail: `skills` (claimed, not declared with a quantity), `resources`
 *  (the shop's own goods, browsed — the certificate's own reading rides at
 *  its top now too, shop.ts's own resourcesPanel) and `contacts` — `rail` only matters
 *  while this is `"slots"`. Once there are several mutually-exclusive display
 *  states a single enum is the right shape, not another boolean bolted onto
 *  the rest. */
export const drawerMode = signal<"slots" | "skills" | "resources" | "contacts">("resources");   // Requests/Offers are hidden for now, so the sheet opens on Resources
export const rail = signal<SlotKind>("need");      // the creation pill's rail — need ⇄ offer, everywhere it's read
// My ⇄ Our: whose reading the drawer shows. "mine" is mySlots — your own
// standing orders, edited inline, the rail this bar always declared through.
// "social" is the fold at the current scope (ourSlots) — the scope's needs
// and offers as summed cells, read-only because a sum has no author to edit
// it; the per-person pool the map pins stays the map's (slotsAt / matchSlots).
export const scope = signal<"mine" | "social">("mine");
// The bar's default: My and Our both sit in the drawer at once, side by
// side under whichever rail (Needs/Offers) is lit — the My/Our switch
// (segMine/segSocial, setScope) stays fully wired below, just not
// attached to the toolbar, so a future control placed elsewhere can flip
// this back to one exclusive standpoint at a time the way it always has.
const showBoth = signal(true);
const open = signal(false);             // the drawer: collapsed strip ⇄ full surface
const note = signal("");
// the drawer's sift (app/search.ts): the pill's own fields ARE the filter —
// the name drives the query, and a rhythm dialled into the panel's own time
// tab narrows the list the same way, so there is no second clock to set and
// nothing to name and save; the toolbar IS the filter, not a control beside it.
//
// EXPORTED: the toolbar is chrome on every face (app.html mounts it once,
// outside any one face), so it is the one search a citizen never has to
// re-open — markers.ts ANDs it into the map's own pin filter (matchesShare
// below its own mapsearch one), the same way the map's search already
// narrows what it draws. One state, read by whichever surface is on screen.
// the day's default horizon (next24h, not the usual "any"): the map's pill
// and the bar's clock read the same dial, so it is built in at construction
// rather than set right after — defaultTimeBy carries the same value to
// every "is anything narrowed" reading (active(), reset(), mapsearch's own),
// so none of them mistake this rest state for the more common "any".
export const F = searchFilter({
  fields: r => [r.name, r.spec, r.note, r.provider, r.who, r.owner, ...((r.cats as string[]) || [])],
  defaultTimeBy: "next24h",
});
// where things stand, for the search radius: a row carries its own point (the map's rows) or names a place
// (a slot's `where`); a place is a point in the scope's registry; the radius is measured from the searched
// place, else from where you are
const placePt = (id: string): { lat: number; lng: number } | null => {
  const l = id ? locationOptions(EXT).find(x => x.id === id) : undefined;
  return l && l.lat != null && l.lng != null ? { lat: l.lat, lng: l.lng } : null;
};
F.setGeo({
  ofRow: (r: { lat?: unknown; lng?: unknown; where?: unknown }) =>
    typeof r.lat === "number" && typeof r.lng === "number" ? { lat: r.lat, lng: r.lng } : placePt(String(r.where ?? "")),
  ofPlace: placePt,
  home: () => ({ lat: USER.lat, lng: USER.lng }),
});
/** "2 km", "500 m" — the radius as the chip says it. */
export const radiusWord = (km: number): string => km < 1 ? `${Math.round(km * 1000)} m` : `${km} km`;
// the slider's scale: step 0 is 100 m, widening geometrically to 50 km at the step before the last; the last is "anywhere"
const RADIUS_STEPS = 100;
const kmOfStep = (i: number): number => {
  if (i >= RADIUS_STEPS) return 0;
  const km = 0.1 * Math.pow(500, i / (RADIUS_STEPS - 1));
  return km < 1 ? Math.round(km * 20) / 20 || 0.1 : km < 10 ? Math.round(km * 10) / 10 : Math.round(km);
};
const stepOfKm = (km: number): number => km <= 0 ? RADIUS_STEPS : Math.max(0, Math.min(RADIUS_STEPS - 1, Math.round((RADIUS_STEPS - 1) * Math.log(km / 0.1) / Math.log(500))));
// the panel's OWN rhythm and place, whatever is currently dialled into the
// when/where tabs before a declare — not yet a Slot, so not F's shape, but a
// filter all the same: a rhythm narrows to what overlaps it (passesRhythm,
// atlas.ts — the same window-overlap check `timeBy` rides), a place narrows
// to exactly that spot. Both read empty = unconstrained, same as F at rest.
// EXPORTED for the same reason F is: markers.ts filters map pins by them too.
export const draftWhen = signal<Arc[]>([]);
export const draftWhere = signal<string>("");

// the housing need (d0) is the one the demo pool AUTOMATCHES: the same slot
// the map draws with its green matched ring (app/tabs/pool.js
// demo:need-mine) and the plan answers with "A night's shelter ×2" —
// matched from Ana's socialized bed (d4's twin in the social pool,
// dm-ana-bed), consented via the rim's "a bed at Ana's" proposal. The
// offer side of that same story (d4) is what you'd lend into the commons —
// once lent it stands on the map as a 🏠 like Ana's.
// cats travel on toSlot for the We view (classification is what the ring and
// the match wire score over) but NOT here: metOf (slots/met.ts) falls back to
// matching a bare need's cats against the demo plan's own rows when the spec
// doesn't, and this mySlots view predates cats existing on any of these rows
// at all — carrying them through would silently let a need borrow another
// row's allocation by classification alone.
const DEMO: { needs: Slot[]; means: Slot[] } = {
  needs: SOCIAL_DEMO_POOL.needs.filter(r => r.who === "you").map(r => ({ ...toSlot(r), cats: undefined })),
  means: SOCIAL_DEMO_POOL.means.filter(r => r.owner === "you").map(r => ({ ...toSlot(r), cats: undefined })),
};

// ── the offline twin: your slots as you last saw them ─────────────────────
// free-association keeps its slots in the browser first and syncs after
// (§4 L0); ours are server truth, but the last my-slots reply is kept in the
// browser under the signed-in AID, so a reload — or a gateway that is slow
// or gone — shows your standing orders at once, marked as such, and every
// declare lands in the lists BEFORE its reply (optimism), reconciled by the
// refresh that follows. One signal either way: `slots`.
const twinKey = (): string | null => { const h = idHint(); return h && h.aid ? K.slotsTwin + h.aid : null; };
const remember = (needs: Slot[], means: Slot[]): void => {
  const k = twinKey(); if (k) writeJSON(k, { needs, means, at: Date.now() });
};
const recall = (): { needs: Slot[]; means: Slot[]; at: number } | null => {
  const k = twinKey(); return k ? readJSON(k, null as { needs: Slot[]; means: Slot[]; at: number } | null) : null;
};
// the lists as they stand, with SLOT put in or taken out of KIND's rail
const withSlot = (cur: SlotLists, kind: SlotKind, slot: Slot | null, spec: string): SlotLists => {
  const key = kind === "need" ? "needs" : "means";
  const list = cur[key];
  const i = list.findIndex(s => s.spec === spec);
  const next = slot === null ? list.filter(s => s.spec !== spec)
             : i >= 0 ? list.map((s, k) => k === i ? slot : s) : [...list, slot];
  return { ...cur, [key]: next };
};
const stale = signal(false);            // showing the twin, not a fresh reply

// your own declaration comes back through the push too, and so does a
// grant landing. An open drawer follows the pool at once; a closed one only
// remembers that it moved, and refreshes when it next opens.
let poolMoved = false;
on("slotsChanged", () => {
  if (!HANDLERS.mySlots) return;
  if (open.peek()) refresh(); else poolMoved = true;
});
function refresh(): void {
  poolMoved = false;
  if (!HANDLERS.mySlots) { slots.set({ ...DEMO, demo: true }); return; }
  // the twin first, so a slow or absent gateway still shows your slots
  if (slots.peek().demo) {
    const t = recall();
    if (t) { slots.set({ needs: t.needs, means: t.means, demo: false }); stale.set(true); }
  }
  HANDLERS.mySlots().then(reply => {
    if (typeof reply !== "string" || reply.startsWith("err:")) return;
    try {
      const v = JSON.parse(reply);
      const num = (s: unknown) => { const x = parseFloat(s as string); return isFinite(x) ? x : 0; };
      // the wire carries numbers as strings; voice too, and "" (a capacity, or
      // an unattached need) reads as 0 — which is what the fold reads it as
      const fix = (list: Slot[]) => (list || []).map(s => ({ ...s, qty: num(s.qty), voice: num(s.voice) || 0,
                                                              tension: s.tension || undefined }));
      const needs = fix(v.needs), means = fix(v.means);
      slots.set({ needs, means, demo: false });
      stale.set(false);
      remember(needs, means);
    } catch (_) {}
  });
}

// ── declaring: editing IS the write (deterministic-id upsert) ─────────────
// A slot's cats (folksonomy term-ids) ride each declare as JSON — the match
// ring scores over them. A slot declared without any gets the classify pass
// (slots/classify.js) and is re-declared with the terms it came back with:
// the deterministic-id upsert makes the enrichment just another edit, the
// same floor-then-AI shape as the log's suggest().
export function declare(kind: SlotKind, slot: Slot): void {
  const arcs = JSON.stringify(slot.arcs || []);
  // the lists move NOW — demo or live; live is reconciled by the refresh the
  // reply triggers, and the twin remembers what you meant meanwhile
  slots.set(withSlot(slots.peek(), kind, slot, slot.spec));
  if (slots.peek().demo) return;
  remember(slots.peek().needs, slots.peek().means);
  const done = (reply: unknown) => {
    note.set(typeof reply === "string" && reply.startsWith("err:") ? reply.slice(4) : "");
    refresh();
    if (!(slot.cats || []).length && (slot.qty || 0) > 0)
      classifySlot(kind, slot).then(cats => {
        if (cats.length) declare(kind, { ...slot, cats });
      });
  };
  const cats = JSON.stringify(slot.cats || []);
  // the criteria sidecar rides as one JSON object; "" when nothing is set
  const crit = slot.criteria && Object.keys(slot.criteria).length ? JSON.stringify(slot.criteria) : "";
  if (kind === "need")
    HANDLERS.declareNeed!(slot.spec, slot.qty, slot.unit || "each", slot.where || "",
                         arcs, slot.note || "", slot.emoji || "",
                         slot.from || "", slot.until || "", slot.name || "",
                         cats, crit, slot.tension || "", slot.voice || 0).then(done);
  else
    HANDLERS.declareMeans!(slot.spec, slot.qty, slot.unit || "each",
                          slot.where || "", arcs, slot.note || "", slot.emoji || "",
                          slot.name || "", cats, crit).then(done);
}
export function retire(kind: SlotKind, slot: Slot): void {
  slots.set(withSlot(slots.peek(), kind, null, slot.spec));
  if (slots.peek().demo) return;
  remember(slots.peek().needs, slots.peek().means);
  if (kind === "need") HANDLERS.retireNeed!(slot.spec).then(() => refresh());
  else declare("capacity", { ...slot, qty: 0 });   // zero-qty means = retired
}

// ── lending: the second half, on the card that declared the first ─────────
// The offer already declared the ownership a grant projects from, so the card
// mounts the one lend control (app/lend.ts) over its own slot. The span
// declaration rides beside it: the scope's word on where this pool stands,
// spoken as a governor (slots/declarations.ts); the slot's id is the resource
// the declaration names, so an undeclared draft has none.
const lendOf = (slot: Slot) => ({
  grant: grantOf(slot),
  build: () => lendControl({ spec: slot.spec, name: slot.name || slot.spec, unit: slot.unit, qty: Number(slot.qty) || 1 },
    { span: HANDLERS.declareSpan && slot.id && scopeSig() && !slots.peek().demo
        ? { places: locationOptions(EXT), at: slot.where || "",
            declare: (place: string) => HANDLERS.declareSpan!(scopeSig() || "", slot.id!, place) }
        : undefined }),
});

// a new place, named here: a <spatial-thing> in the scope (declare-place),
// whose id the slot takes at once; offline the name itself is the place
async function newPlace(name: string, lat: number, lon: number, address: string): Promise<string | null> {
  if (!HANDLERS.declarePlace || slots.peek().demo) return name;
  const r = await HANDLERS.declarePlace(name, lat, lon, address);
  return typeof r === "string" && !r.startsWith("err:") ? r : null;
}

// the scaffold's own rail switch — the ONE way the rail changes once the bar
// stands, so the lit segment, the placeholder, the glyph and the unit follow
// the rail wherever the change comes from (a tap, a reading, a map pin)
let railCtl: ((r: SlotKind | "skill" | "resource" | "contact") => void) | null = null;

// ── the stage ─────────────────────────────────────────────────────────────

// The emoji · quantity · unit chip at the pill's right end is built and wired
// in full but NOT attached while this is false: the words carry the amount
// ("need 3 kilograms of flour" — app/utter.ts reads it), a bare sentence
// declares one, and the rail's default unit stands. Flip it to put the chip
// back; nothing else changes.
const SHOW_QTY_UNIT = false;

// the rail switch — Requests ⇄ Offers, one horizontal segmented control, made
// wherever the reading is. The rail is ONE signal, so every instance lights
// the same segment and any click moves them all (and the draft's kind, the
// placeholder and the drawer's list with them). Built fresh per call: the map
// search redraws its header on every keystroke and owns its own copy.
let railPainted = false;
/** `skills`/`resources`/`contacts`: add the drawer's own extra segments;
 *  the map search's copy stays a plain Requests ⇄ Offers pair. */
export function railSwitch(skills = false, resources = false, contacts = false): HTMLElement {
  const el = mk("div", "share-rail share-rail-h");
  const segs: [SlotKind | "skill" | "resource" | "contact", string, string, string, string][] = [
    ["need", "🎯", "Requests", "requests — say what you need; the plan provisions it", "seg-need"],
    ["capacity", "🎁", "Offers", "offers — share what you can give", "seg-offer"],
    ...(resources ? [["resource", "🍞", "Resources", "resources — everything the shop offers, and the certificate's own reading at the top", "seg-resource"] as [SlotKind | "skill" | "resource" | "contact", string, string, string, string]] : []),
    ...(skills ? [["skill", "🛠️", "Skills", "skills — what you can do; the plan asks you only for work you claim", "seg-skill"] as [SlotKind | "skill" | "resource" | "contact", string, string, string, string]] : []),
    ...(contacts ? [["contact", "👥", "Contacts", "contacts — who you can reach, and how you know them", "seg-contact"] as [SlotKind | "skill" | "resource" | "contact", string, string, string, string]] : []),
  ];
  for (const [r, glyph, word, tip, cls] of segs) {
    const seg = mk("a", `share-seg ${cls}`);
    seg.append(mk("span", "share-seg-i", glyph), mk("span", "share-seg-l", word));
    seg.title = tip;
    seg.dataset.rail = r === "need" ? "need" : r === "capacity" ? "offer" : r;
    seg.addEventListener("click", () => {
      if (railCtl) railCtl(r);
      else if (r === "skill") drawerMode.set("skills");
      else if (r === "resource") drawerMode.set("resources");
      else if (r === "contact") drawerMode.set("contacts");
      else { drawerMode.set("slots"); rail.set(r); }
    });
    el.append(seg);
  }
  paintRail(el);
  if (!railPainted) {
    railPainted = true;
    effect(() => { rail(); drawerMode(); document.querySelectorAll<HTMLElement>(".share-rail-h").forEach(paintRail); });
  }
  return el;
}
function paintRail(el: HTMLElement): void {
  const mode = drawerMode.peek(), need = rail.peek() === "need";
  el.querySelector(".seg-need")!.classList.toggle("on", mode === "slots" && need);
  el.querySelector(".seg-offer")!.classList.toggle("on", mode === "slots" && !need);
  el.querySelector(".seg-skill")?.classList.toggle("on", mode === "skills");
  el.querySelector(".seg-resource")?.classList.toggle("on", mode === "resources");
  el.querySelector(".seg-contact")?.classList.toggle("on", mode === "contacts");
}

// ── the sheet's view slot ──────────────────────────────────────────────────
// Other surfaces (app/account.ts, app/face-dock.ts) put their content in the
// sheet the inventory rises in, so every pull-up is the same sheet: same grip,
// same drag to the whole height, same way out. A view has an owner; a later
// view replaces an earlier one, and the inventory and the type picker close it.
let viewHost: HTMLElement | null = null;
let viewOwner: string | null = null;
let viewGone: (() => void) | null = null;
let closePanelHook: (() => void) | null = null;   // set once the draft panel exists
/** The sheet rises to a height that depends on what opened it: the inventory and the type picker at about
 *  half the page, a view at the height it asks for (`full`: the whole page, under the header). A drag on the
 *  grip changes it from there. */
let sheetEl: HTMLElement | null = null;
const riseTo = (full: boolean): void => { sheetEl?.classList.toggle("full", full); };

/** Show `el` in the sheet, rising to the whole height when `full`. `gone` runs when the view leaves, whichever way it does. */
export function openSheetView(owner: string, el: HTMLElement, gone: () => void, full = false, fit = false): void {
  if (!viewHost) return;
  closeSheetView();
  riseTo(full);
  // `fit`: the sheet is as tall as the view needs (a result card, a bundle's cards) rather than a standing height,
  // so what is short leaves the page its room
  viewHost.toggleAttribute("data-fit", fit);
  open.set(false);
  closePanelHook?.();
  viewHost.replaceChildren(el);
  viewHost.classList.add("on");
  viewOwner = owner; viewGone = gone;
}
/** Put the view away — only `owner`'s, when one is named. */
export function closeSheetView(owner?: string): void {
  if (!viewHost || !viewOwner || (owner && owner !== viewOwner)) return;
  const gone = viewGone;
  viewOwner = null; viewGone = null;
  viewHost.classList.remove("on");
  viewHost.replaceChildren();
  gone?.();
}
/** The height the sheet takes at the foot of the page right now (0 while it is away) — the map pads its camera by it. */
export const sheetHeight = (): number => {
  const r = sheetEl?.getBoundingClientRect();
  return r && r.height > 0 && getComputedStyle(sheetEl!).display !== "none" ? Math.round(r.height) : 0;
};
/** What fills the sheet right now: a view's owner, "inventory", or null when it is away. A tracked-free read. */
export const sheetHolds = (): string | null => viewOwner ?? (open.peek() ? "inventory" : null);
/** Whether `owner`'s view is the one showing. */
export const sheetViewIs = (owner: string): boolean => viewOwner === owner;
// a tap outside the bar (and the sheets it hosts) puts a view away, as a tap outside a menu does
document.addEventListener("pointerdown", ev => {
  const t = ev.target as Element | null;
  if (viewOwner && t && !t.closest("#sharebar") && !t.closest(".scopepick")) closeSheetView();
});

/**
 * The sheet's grip, the way a map's bottom sheet works: drag it and the sheet
 * follows the finger; let go and it settles — whole (`full`), at the height its
 * content wants, or away. A tap on the grip flips whole ⇄ content-height.
 */
function wireSheet(sheet: HTMLElement, grab: HTMLElement, dismiss: () => void): void {
  const fullH = (): number => Math.max(160, window.innerHeight
    - (parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--barh")) || 56));
  let y0 = 0, h0 = 0, moved = false, live = false;
  grab.addEventListener("pointerdown", ev => {
    live = true; moved = false; y0 = ev.clientY;
    h0 = sheet.getBoundingClientRect().height;
    grab.setPointerCapture(ev.pointerId);
    sheet.classList.add("dragging");
  });
  grab.addEventListener("pointermove", ev => {
    if (!live) return;
    if (Math.abs(ev.clientY - y0) > 4) moved = true;
    if (!moved) return;
    const h = Math.max(0, Math.min(fullH(), h0 + (y0 - ev.clientY)));
    sheet.style.height = h + "px";
    sheet.style.maxHeight = "none";
  });
  const settle = (ev: PointerEvent): void => {
    if (!live) return;
    live = false;
    sheet.classList.remove("dragging");
    const h = sheet.getBoundingClientRect().height;
    sheet.style.height = ""; sheet.style.maxHeight = "";
    if (!moved) { sheet.classList.toggle("full"); return; }
    const was = sheet.classList.contains("full");
    sheet.classList.remove("full");
    const rest = sheet.getBoundingClientRect().height;       // the content's own height, capped
    sheet.classList.toggle("full", h > (rest + fullH()) / 2);
    if (h < Math.min(120, (was ? fullH() : rest) / 2) && ev.clientY > y0) dismiss();
  };
  grab.addEventListener("pointerup", settle);
  grab.addEventListener("pointercancel", settle);
}

// the creation pill is built ONCE (a rebuilt input loses keyboard focus on
// every slots refresh — the shop's search taught this); the rail toggle
// restyles it in place, and only the lists below re-render reactively.
function ensureScaffold(bar: HTMLElement): void {
  if (bar.querySelector(".share-pill")) return;
  const row = mk("div", "sharebar-row");
  // the drawer's handle closes the expression group (ctl, below), after the pill.
  const handle = mk("a", "sharebar-handle");
  handle.addEventListener("click", () => { if (!open()) riseTo(false); open.set(!open()); });
  const drawer = mk("div", "share-drawer");
  // the sheet: the search bar stays at the foot of the app and everything it
  // opens (the inventory, the type picker) rises above it, over the page —
  // pull the grip up to see it whole, down to put it away (wireSheet).
  const sheet = mk("div", "share-sheet");
  const grab = mk("div", "sheet-grab");
  grab.title = "pull up to see it whole · down to put it away";
  grab.append(mk("span", "sheet-grip"));
  // the sheet's VIEW slot: the account menu and the faces menu are shown here, in the
  // same sheet as the inventory (openSheetView) — one surface for everything that rises
  const view = mk("div", "sheet-view");
  viewHost = view;
  sheetEl = sheet;
  sheet.append(grab, view, drawer);
  // ── the draft controls: [pill: 👤 🎙️ 📷 name · emoji·qty·unit 🕐 time · 📍 location]
  // (↵ declares). The Requests ⇄ Offers rail is railSwitch() — it stands where the
  // reading is: above the inventory, and beside the map search's result count.
  // My ⇄ Our: which inventory the list below is drawn from — your own (edited
  // inline) or the whole social pool (read-only, the same rows the map pins).
  // Sits before the Requests/Offers switch so the pair reads as a phrase — "My Requests", "Our Offers": it answers "whose", the rail answers
  // "which side of it".
  const scopeBtn = mk("div", "share-rail share-scope");
  const segMine = mk("a", "share-seg seg-mine");
  segMine.append(mk("span", "share-seg-i", "🙋"), mk("span", "share-seg-l", "My"));
  segMine.title = "your own needs and offers — edited inline; what you add here is what folds up";
  const segSocial = mk("a", "share-seg seg-social");
  segSocial.append(mk("span", "share-seg-i", "🌐"), mk("span", "share-seg-l", "Our"));
  segSocial.title = "the scope's needs and offers — everyone's, summed; yours shown inside the sum";
  scopeBtn.append(segMine, segSocial);
  const setScope = (s: "mine" | "social") => {
    if (scope() === s) return;
    scope.set(s);
    if (s === "social") refreshSocial();
    restyleScope();
    restyle();
  };
  segMine.addEventListener("click", () => setScope("mine"));
  segSocial.addEventListener("click", () => setScope("social"));
  const restyleScope = () => {
    const mine = scope() === "mine";
    segMine.classList.toggle("on", mine);
    segSocial.classList.toggle("on", !mine);
  };
  restyleScope();

  const pill = mk("div", "share-pill");
  const nameIn = mk("textarea", "share-name");
  nameIn.rows = 1; nameIn.placeholder = "Express…";
  nameIn.setAttribute("enterkeyhint", "go");
  // no <datalist> here on purpose — the browser's own autocomplete popup
  // would sit on top of the panel below with a second, unstyled, un-drilled
  // reading of the SAME specs; the panel IS the picker now.
  const qtyGrp = mk("div", "share-qtygrp");
  const emojiBtn = mk("button", "share-emoji", "🌱");
  emojiBtn.type = "button"; emojiBtn.title = "choose emoji";
  const qtyInput = mk("input", "share-qty");
  qtyInput.type = "number"; qtyInput.min = "0"; qtyInput.value = "1";
  const unitBtn = mk("button", "share-unit", "each");
  unitBtn.type = "button";
  // the unit SAYS what the declaration is (slots/model.ts UNITS · unitReading):
  // count = stock, X/day X/week = rate, bare hours on an offer = budget
  unitBtn.title = "choose unit — count = stock · X a day, X a week = rate · bare hours on an offer = budget";
  qtyGrp.append(emojiBtn, qtyInput, unitBtn);
  // ✕ empties the sentence — the "discard" the spoken box used to carry
  const clear = mk("button", "share-clear", "✕");
  clear.type = "button"; clear.title = "clear"; clear.hidden = true;
  clear.addEventListener("click", () => { clearName(); nameIn.focus(); });
  // the bar's hearing mark: while the mic is held ("listening") and after it is
  // let go ("transcribing") three dots pulse beside the words, the sign that a
  // transcription is under way and its text is about to land in the bar
  const hearing = mk("span", "share-hearing");
  hearing.setAttribute("role", "status");
  hearing.append(mk("span", "share-hearing-l"), mk("i"), mk("i"), mk("i"));
  // a state (listening, transcribing) pulses; a note (a refused mic, nothing
  // heard) says what happened for a few seconds, so no outcome is silent
  let noteTimer: ReturnType<typeof setTimeout> | undefined;
  const hearAs = (what: string | null, note = false): void => {
    clearTimeout(noteTimer);
    pill.classList.toggle("hearing", what !== null);
    pill.classList.toggle("hearing-note", note);
    hearing.firstElementChild!.textContent = what ?? "";
    if (note) noteTimer = setTimeout(() => hearAs(null), 4500);
  };
  pill.append(hearing, nameIn, clear);       // the mark stands beside the words it is about
  if (SHOW_QTY_UNIT) pill.append(qtyGrp);
  pill.classList.toggle("has-qty", SHOW_QTY_UNIT);
  // A popover's own dismiss: closes on any click that lands outside both
  // the box and the control that opened it — the clock and the pin each
  // wire one call of this rather than repeating the same listener body.
  const closeOnOutsideClick = (isOpen: Signal<boolean>, selector: string): void => {
    document.addEventListener("click", ev => {
      const t = ev.target as HTMLElement;
      // a target the popover itself just redrew is gone from the page, and
      // that is no click outside it
      if (isOpen() && t.isConnected && !t.closest(selector)) isOpen.set(false);
    });
  };
  const togs = mk("div", "share-togs");
  const togTime = mk("a", "share-tog share-tog-time");
  togTime.append(mk("span", "share-tog-i", "🕐"), mk("span", "share-tog-l", "time"));
  const togWhere = mk("a", "share-tog share-tog-where");
  togWhere.append(mk("span", "share-tog-i", "📍"), mk("span", "share-tog-l", "location"));
  togs.append(togTime, togWhere);
  // the clock opens the SAME four time modes the map's search pill offers,
  // upward — one dial (F.timeBy) read by every surface; "custom" unfolds a
  // from/to strip on the bar's own side, and the declaration's rhythm keeps
  // its door as the last entry.
  togs.style.position = "relative";
  const timeMenuOpen = signal(false);
  // the popover is ONE view, never two stacked: "list" is the four modes and
  // the rhythm door; picking Custom swaps the SAME box to "custom" (its own
  // from/to), with a back arrow to return — nothing scrolls past anything
  // else, and the box never grows two sections tall.
  const timeMenuPage = signal<"list" | "custom">("list");
  const timeMenu = mk("div", "share-time-menu");   // opens upward, docked to the clock
  togs.append(timeMenu);
  const cIn = (sig: { set(v: string): void }, type: string) => {
    const i = mk("input", "share-tin") as HTMLInputElement;
    i.type = type; i.onchange = () => sig.set(i.value); return i; };
  // date and time each take the box's own full width, stacked, rather than
  // sitting side by side: a native date/time input renders at its own
  // minimum regardless of a flex-shrink asked of it, and two of them plus a
  // label overflow any box wide enough to still feel like ONE small popover.
  const trow = (label: string, d: { set(v: string): void }, t: { set(v: string): void }): HTMLElement => {
    const r = mk("div", "share-trow");
    r.append(mk("span", "share-tlbl", label), cIn(d, "date"), cIn(t, "time"));
    return r;
  };
  effect(() => {
    const openM = timeMenuOpen();
    timeMenu.style.display = openM ? "flex" : "none";
    if (!openM) return;
    timeMenu.innerHTML = "";
    if (timeMenuPage() === "custom") {
      const head = mk("a", "share-time-back");
      head.append(mk("span", null, "←"), mk("span", null, "any time · now · next 24h"));
      head.addEventListener("click", ev => { ev.stopPropagation(); timeMenuPage.set("list"); });
      timeMenu.append(head, trow("from", F.t0d, F.t0t), trow("to", F.t1d, F.t1t));
      return;
    }
    for (const [v, l] of TIME_MODES) {
      const o = mk("a", "share-time-opt" + (F.timeBy() === v ? " on" : ""), l);
      o.addEventListener("click", ev => {
        ev.stopPropagation();
        F.timeBy.set(v as TimeMode);
        // every mode but "between" reads as one tap and closes; "between"
        // swaps this SAME popover to its own from/to view instead
        if (v === "between") timeMenuPage.set("custom"); else timeMenuOpen.set(false);
      });
      timeMenu.append(o);
    }
    const rr = mk("a", "share-time-opt share-time-rhythm", "a rhythm for what you declare…");
    rr.addEventListener("click", ev => { ev.stopPropagation(); timeMenuOpen.set(false); dockNear(togTime); panelRef?.show("when"); });
    timeMenu.append(rr);
  });
  closeOnOutsideClick(timeMenuOpen, ".share-time-menu, .share-tog-time");

  // the sentence read back BEFORE anything happens — app/utter.ts: the name
  // is one utterance, `[locus-delta] [act]`, and this line shows its READINGS,
  // ranked: the lit one is what ↵ does, the others are a tap away. A locus
  // reading (go · open) runs free; an act reading (need · offer · log) fills
  // the pill from the words and declares on ↵. Under
  // Our only the locus readings show — a sum has no draft.
  const preview = mk("div", "share-preview");
  let readings: Reading[] = [];
  let lit = 0;
  // a reading that only moves the locus — runs free on ↵, writes nothing
  const isLocus = (r: Reading): boolean =>
    r.verb === "go" || r.verb === "face" || r.verb === "web" || r.verb === "search";
  // the name is spent: a locus move ran, a log landed, a search opened
  const clearName = (): void => { fields.set({ name: "" }); lit = 0; };
  const utterCtx = (): UtterContext => ({
    faces: FACE_WORDS,
    places: locationOptions(EXT).map(l => ({ id: l.id, name: l.name,
                                             ...(l.lat != null ? { lat: l.lat, lng: l.lng } : {}) })),
    specs: knownSpecs(EXT, PLAN),
    units: UNITS.map(u => ({ id: u.id, label: u.label })),
    scopes: allScopes().map(s => ({ id: s.id, name: s.name })),
    rail: rail(), now: new Date(),
  });
  // a locus move: free, nothing written. gohere's applyHere is the ONE door
  // for this — scope first, then the face, then the place/instant leg — so
  // the bar never re-derives which of goToMapPlace/goToCalendarTime/setFace
  // applies; it just hands over whatever coordinates the sentence named.
  const move = (r: Reading): void => {
    const l = r.locus;
    const here = { ...(l.instant ? hereOfInstant(l.instant.iso) : {}),
                   ...(l.place && l.place.lat != null ? { lat: l.place.lat, lng: l.place.lng } : {}),
                   ...(l.scope ? { scope: l.scope.id } : {}) };
    applyHere(here, l.face);
    hint(`${r.label.replace(/^[^:]*: /, "→ ")}`, "success");
  };
  // the web, on the explicit bang only — it LEAVES playnet, and says so
  const web = (r: Reading): void => {
    if (!r.query) return;
    hint("leaving playnet for the web — the query travels", "notice");
    window.open(`https://html.duckduckgo.com/html/?q=${encodeURIComponent(r.query)}`, "_blank", "noopener");
  };
  // an act reading: the words become the pill — name, amount, unit, the
  // place and the spec the recognisers found — and ↵ declares it
  const applyAct = (r: Reading): void => {
    const a = r.act!;
    if (a.kind !== "log") setRail(a.kind);
    fields.set({ name: a.name, ...(a.qty != null ? { qty: a.qty } : {}), ...(a.unit ? { unit: a.unit } : {}) });
    if (panelRef) {
      if (r.locus.place) panelRef.draft.where = r.locus.place.id;
      if (a.spec) panelRef.draft.spec = a.spec;
    }
  };
  // what ↵ does with the lit reading: a locus move runs, a log lands, an act
  // fills the pill and declares
  const run = (r: Reading): void => {
    if (r.verb === "web") { web(r); return; }
    if (r.verb === "go" || r.verb === "face") { move(r); clearName(); return; }
    if (r.verb === "search") { search(r); clearName(); return; }
    if (r.verb === "log") { logEntry(r.act!.name); hint("logged ✓ — the log face carries it", "success"); clearName(); return; }
    applyAct(r); submit();
  };
  // a corpus question: open the federation corpus face with the query
  // already running — the same "locus move" shape as go/face (free, writes
  // nothing), just landing on a search instead of a place or a tab
  const search = (r: Reading): void => {
    setFace("corpus");
    void import('../corpus.js').then(m => m.setPendingQuery(r.query || r.residual));
    hint(`🔎 searching the corpus: ${r.query || r.residual}`, "success");
  };

  // the pill's own reading of its state: emoji shown, unit label, unit reading
  let emoji = "";                     // "" = the rail's default glyph
  const emojiOf = () => emoji || (rail() === "need" ? "🌱" : "🤲");
  const unitLabel = () => (UNITS.find(u => u.id === unitBtn.dataset.unit) || {}).label || unitBtn.dataset.unit || "each";
  const setUnit = (u: string) => {
    unitBtn.dataset.unit = u; unitBtn.textContent = unitLabel();
    unitBtn.title = unitReading(u, rail()) || "choose unit — count = stock · X a day, X a week = rate · bare hours on an offer = budget";
    renderPreview();
  };
  let panelRef: ReturnType<typeof draftPanel> | null = null;   // set once the panel exists below
  // the readings row, from whatever `readings` currently holds
  // whether a phrase is the sentence in the pill, give or take case and spacing
  const same = (t: string): ((s: string) => boolean) => {
    const n = (x: string): string => x.toLowerCase().replace(/\s+/g, " ").trim();
    const base = n(t);
    return s => n(s) === base;
  };
  const renderReadings = () => {
    preview.classList.toggle("on", readings.length > 0);
    preview.replaceChildren();
    if (!readings.length) return;
    const d = panelRef ? panelRef.draft : null;
    const reading = unitReading(unitBtn.dataset.unit || "each", rail());
    // The sentence is already in the pill: a reading says what it would DO with
    // it — its verb, and only what it adds (an amount, a place, a moment, a name
    // the words were cut down to) — never the words again.
    const typed = same(nameIn.value);
    const VERB: Record<string, string> = { need: "🌱 need", offer: "🤲 offer", log: "📓 log", search: "🔎 search",
                                           go: "🗺 go", face: "◉ open", web: "🌐 web" };
    readings.slice(0, 4).forEach((r, i) => {
      const a = mk("a", "share-read" + (i === lit ? " on" : "") + (r.ai ? " ai" : ""));
            const moves = r.verb === "go" || r.verb === "face";      // these read as their destination
      let label = moves ? r.label : (VERB[r.verb] || r.label);
      // the name the words were cut down to — worth showing only when something
      // WAS cut out of them (an amount, a place, a moment); otherwise it is the
      // sentence again
      const cut = !!(r.act && (r.act.qty != null || r.locus.place || r.locus.instant));
      const said = cut && r.act && !typed(r.act.name) ? r.act.name : "";
      // the lit act reading is the draft as it will land: the pill's own
      // amount and unit when the words named none, the dialled place and
      // rhythm when the words named none
      if (i === lit && r.act && r.act.kind !== "log") {
        const qty = r.act.qty != null ? r.act.qty : (+qtyInput.value || 1);
        const unit = r.act.unit ? ((UNITS.find(u => u.id === r.act!.unit) || { label: r.act.unit }).label) : unitLabel();
        const where = r.locus.place ? r.locus.place.name
                    : d && d.where ? fmtWhere(d.where, locationOptions(EXT)) : "anywhere";
        const when = r.locus.instant ? r.locus.instant.label : d && d.arcs.length ? fmtArcs(d.arcs) : "any time";
        label = VERB[r.verb] + (said ? ` · ${said}` : "") + ` · ${qty} ${unit}`
              + (reading && !r.act.unit ? ` (${reading})` : "") + `  ·  📍 ${where}  ·  🕐 ${when}`;
      } else if (!moves) {
        const extra = [said,
                       r.act && r.act.qty != null ? `${r.act.qty}${r.act.unit ? " " + r.act.unit : ""}` : "",
                       r.locus.place ? `📍 ${r.locus.place.name}` : "",
                       r.locus.instant ? `🕐 ${r.locus.instant.label}` : ""].filter(Boolean);
        if (extra.length) label += " · " + extra.join(" · ");
      }
      a.textContent = (r.ai ? "✨ " : "") + label;
      a.title = (r.ai ? "read with AI help — " : "") + (i === lit ? (r.act ? "↵ declares this" : "↵ goes there") : "tap to read it this way");
      a.addEventListener("click", () => {
        if (i === lit && (isLocus(r) || r.verb === "log")) { run(r); return; }
        lit = i; renderReadings();
      });
      preview.appendChild(a);
    });
    const top = readings[lit];
    preview.appendChild(mk("span", "share-preview-go",
      top.verb === "log" ? "↵ logs" : top.act ? "↵ declares"
      : top.verb === "web" ? "↵ leaves for the web" : "↵ goes · nothing written"));
  };
  // the AI step, over the RESIDUAL only: it may rewrite the words into more of
  // the floor's own vocabulary (app/day/extract.ts `utter` pass — a NORMALIZER,
  // never a resolver), and the rewrite is re-parsed by the exact same floor.
  // Only asked when the floor itself found nothing to stand on — a locus, a
  // known spec, an explicit cue — so it never fires on a sentence the
  // deterministic parser already read confidently, and it can only ever surface
  // a reading the parser would also produce for those words.
  // "confident" means the floor pinned an actual COORDINATE — a face, a
  // scope, a place, an instant, or a known spec — not merely that a verb cue
  // was typed. "need bricks tuesday" is a confident NEED cue but, if "tuesday"
  // weren't in the floor's vocabulary, would still have nothing concrete to
  // stand on; that is exactly the case the AI step exists for.
  //
  // ONE ask per sentence: the readings the AI added are kept under the words
  // they answer (the ask carries the words alone — rail and standpoint only
  // shape the merge), and every redraw of the same sentence — a quantity
  // edit, a chip set, a rail flip — re-merges them rather than asking again. The ask waits for the typing to pause; a key
  // typed since retires the pending one, and a reply for a key no longer on
  // screen is dropped. A paid call per keystroke is what this rules out.
  const hasCoord = (r: Reading): boolean =>
    !!(r.locus.face || r.locus.scope || r.locus.place || r.locus.instant || r.act?.spec);
  const confidentFloor = (rs: Reading[]): boolean => rs.length > 0 && hasCoord(rs[0]);
  const AI_PAUSE = 400;                              // ms of stillness before the ask
  const ai = { key: "", extra: [] as Reading[], pending: "", timer: 0 };
  const withAI = (rs: Reading[], extra: Reading[]): Reading[] => {
    const fresh = extra.filter(r => !rs.some(o => o.label === r.label));
    return fresh.length ? [...fresh, ...rs].sort((a, b) => b.score - a.score).slice(0, 4) : rs;
  };
  const askAI = (text: string, ctx: UtterContext): void => {
    const key = text;
    if (key === ai.pending) return;                    // already on its way
    clearTimeout(ai.timer); ai.pending = "";           // whatever waited was for other words
    if (!text || key === ai.key || confidentFloor(readings) || !aiAvailable()) return;
    ai.pending = key;
    ai.timer = window.setTimeout(() => {
      runPass("utter", {
        text, faces: ctx.faces.map(f => f.label), places: ctx.places.map(p => p.name),
        scopes: (ctx.scopes || []).map(s => s.name),
      }).then(got => {
        if (ai.pending !== key) return;                // a sentence typed since
        ai.pending = "";
        const rewrite = got && got.rewrite;
        const more = rewrite ? readUtterance(rewrite, ctx).filter(r => confidentFloor([r])) : [];
        ai.key = key;
        ai.extra = more.map(r => ({ ...r, ai: true }));
        if (!ai.extra.length) return;
        lit = 0;
        renderPreview();
      });
    }, AI_PAUSE);
  };
  // the name grows to its words (up to four lines), and the pill notes it holds some
  const grow = (): void => {
    nameIn.style.height = "auto";
    nameIn.style.height = `${Math.min(nameIn.scrollHeight, 92)}px`;
    pill.classList.toggle("has-text", !!nameIn.value);
  };
  const renderPreview = () => {
    const name = nameIn.value.trim();
    clear.hidden = !name;
    grow();
    const mine = scope() === "mine";
    const ctx = utterCtx();
    readings = name ? readUtterance(name, ctx) : [];
    if (!mine || drawerMode.peek() !== "slots") readings = readings.filter(isLocus);
    if (ai.key === name) readings = withAI(readings, mine ? ai.extra : ai.extra.filter(isLocus));
    lit = Math.min(lit, Math.max(0, readings.length - 1));
    renderReadings();
    askAI(name, ctx);
  };
  setUnit("each");

  // ── the pill's fields, as the draft panel reaches them ──────────────────
  const fields: PillAccess = {
    get: () => ({ name: nameIn.value.trim(), emoji: emojiOf(),
                  qty: +qtyInput.value || 1, unit: unitBtn.dataset.unit || "each" }),
    set: p => {
      // a PROGRAMMATIC fill — a drill-pick, a voice reading — moves the query
      // too, the same as a keystroke would: the pill's name is the one thing
      // driving F.query, whichever hand moved it.
      if (p.name !== undefined) { nameIn.value = p.name; F.query.set(p.name); }
      if (p.emoji !== undefined) { emoji = p.emoji; emojiBtn.textContent = emojiOf(); }
      if (p.qty !== undefined) qtyInput.value = String(p.qty);
      if (p.unit !== undefined) setUnit(p.unit);
      renderPreview();
    },
    focus: w => (w === "name" || !SHOW_QTY_UNIT ? nameIn : qtyInput).focus(),
  };
  // Docks the shared panel directly under whichever control opened it — the
  // name, the emoji/unit buttons, the mic — rather than a fixed corner of
  // the bar, so it never reads as a stray box far from what triggered it.
  // Left-aligned to that control, clamped to the bar's own width; the CSS
  // right:0 default only ever shows for a caller that skips this.
  const dockNear = (el: HTMLElement): void => {
    const br = bar!.getBoundingClientRect(), er = el.getBoundingClientRect();
    const w = panel.el.offsetWidth || 260;
    const left = Math.max(0, Math.min(er.left - br.left, br.width - w));
    panel.el.style.left = `${left}px`;
    panel.el.style.right = "auto";
  };
  // ── the expanded draft panel (slots/draft.ts): everything set before ↵ ──
  // A plain `function` (hoisted), not a `const`: it closes over `panel` and
  // `whereMenuOpen` before either is declared below, and reads them only
  // when CALLED, by which point both exist — the standard shape for setup
  // code that a config object and its own later declarations refer to
  // circularly.
  const followShared = signal(true);   // Search follows Sharing until a place is picked under Search
  function syncTogs(): void {
    const d = panel.draft, t = panel.tab();
    // "set" reads either hand on the clock: a declared rhythm, or the
    // filter dial away from its resting "any time"
    togTime.classList.toggle("set", d.arcs.length > 0 || F.timeBy() !== "any");
    // two facts share this chip and stay apart: the SEARCH place (what the bar
    // filters by) and SHARING (what the plan is told of where you are). The
    // place name says the first; a green dot says the second, so searching
    // another city never reads as having stopped sharing. Search FOLLOWS
    // sharing — wherever you share, that is where it looks — until a place is
    // picked under Search, which is then the override. Only that pick files a
    // new entry at a place: following filters, it does not declare.
    const sh = sharing();
    const following = !d.where && followShared() && !!sh.placeId;
    const eff = d.where || (following ? sh.placeId! : "");
    const effName = eff === sh.placeId ? sh.place : eff ? fmtWhere(eff, locationOptions(EXT)) : "";
    togWhere.classList.toggle("set", !!d.where || F.radiusKm() > 0);
    // the radius is measured from the searched place; with none searched, from where you are
    F.center.set(eff ? placePt(eff) : null);
    togWhere.classList.toggle("sharing", sh.mode !== "off");
    togWhere.classList.toggle("live", sh.mode === "live");
    togTime.classList.toggle("on", t === "when" || timeMenuOpen());
    togWhere.classList.toggle("on", t === "where" || whereMenuOpen());
    togTime.title = d.arcs.length ? `when: ${fmtArcs(d.arcs)}` : "when — the horizon offers filter by; custom unfolds a from/to";
    const shWords = sh.mode === "off" ? "" : `sharing ${sh.mode === "live" ? "live" : "here, now"}${sh.place ? ` (${sh.place})` : ""}`;
    const seWords = eff ? `searching ${effName}${following ? " (where you share)" : ""}` : "";
    togWhere.title = [shWords, seWords].filter(Boolean).join(" · ") || "where — share where you are, or set a place to search";
    // a chip that holds a value SHOWS it — "Fri 14:00", "community garden" —
    // and falls back to naming its slot when empty; the .set colour alone
    // was how a need landed at the wrong place
    const TL: Record<string, string> = { any: "any time", now: "now", next24h: "next 24h", between: "custom" };
    togTime.querySelector(".share-tog-l")!.textContent = d.arcs.length ? fmtArcs(d.arcs) : (TL[F.timeBy()] || "time");
    const where0 = eff ? effName : sh.mode === "off" ? "location" : (sh.place || (sh.mode === "live" ? "live" : "here"));
    togWhere.querySelector(".share-tog-l")!.textContent = F.radiusKm() > 0 ? `${where0 === "location" ? "around me" : where0} · ${radiusWord(F.radiusKm())}` : where0;
    renderPreview();
    // the draft's rhythm and place double as a live filter the moment
    // they're dialled in — no ↵ needed, the same way the name already did
    draftWhen.set(d.arcs);
    draftWhere.set(eff);
  }
  const panel = draftPanel({
    pill: fields,
    kind: rail, setKind: r => setRail(r),
    here: currentPlace,
    onNewPlace: newPlace,
    onChange: () => { syncTogs(); placePanel(); },
    canDeclare: () => drawerMode.peek() === "slots",
    topIsBar: () => topOpen.peek(),
  });
  panelRef = panel;
  closePanelHook = () => panel.close();
  // the type picker is wide: it rides in the sheet, above the bar, beside the
  // inventory; the small popovers (unit, emoji, place) stay docked to the bar
  function placePanel(): void {
    if (panel.el.classList.contains("sp-wide")) closeSheetView();   // the picker takes the sheet
    const home = panel.el.classList.contains("sp-wide") ? sheet : bar;
    if (panel.el.parentElement === home) return;
    if (home === sheet) grab.after(panel.el); else bar.insertBefore(panel.el, sheet);
  }
  // Esc puts away what is up: the inventory first, else an open picker or popover (the account and faces
  // menus answer Esc themselves, the account stepping back out of a page before it closes)
  document.addEventListener("keydown", ev => {
    if (ev.key !== "Escape" || viewOwner) return;
    if (open.peek()) { ev.preventDefault(); open.set(false); return; }
    if (panel.tab() !== null) { ev.preventDefault(); panel.close(); }
  });
  wireSheet(sheet, grab, () => {
    closeSheetView();
    open.set(false);
    panel.close();
    const fb = document.getElementById("fbbtn");
    if (fb?.classList.contains("on")) fb.click();
  });
  togTime.addEventListener("click", () => {
    // opening goes straight to whichever view matches the live dial — no
    // reason to show the list first when "between" is already picked
    if (!timeMenuOpen()) timeMenuPage.set(F.timeBy() === "between" ? "custom" : "list");
    timeMenuOpen.update(v => !v);
  });
  // the pin's popover holds two different things under two tabs, so the one
  // never reads as the other:
  //   Sharing — what the PLAN is told of where you are (not shared · here ·
  //             following me) and where you will be: location.ts's panel.
  //   Search  — the place this bar filters by and files a new entry under: the
  //             same list-then-detail menu the clock opens, whereEditor
  //             (slots/editors.ts) reused wholesale, its chrome scoped-restyled
  //             to read as this popover's rows instead of the accordion's chips.
  // Searching another city changes only the second; the first keeps going, and
  // the chip's green dot says so.
  const whereMenuOpen = signal(false);
  const whereTab = signal<"search" | "sharing">("search");
  const whereMenu = mk("div", "share-where-menu");
  togs.append(whereMenu);
  const modes = mk("div", "share-where-modes");
  const modeBtn: Record<string, HTMLElement> = {};
  for (const [id, label, title] of [
    ["sharing", "📍 Sharing", "what the plan is told of where you are"],
    ["search", "🔎 Search", "the place this bar searches and files new entries under"],
  ] as const) {
    const b = mk("a", "share-where-mode", label);
    b.title = title;
    b.addEventListener("click", () => whereTab.set(id));
    modeBtn[id] = b; modes.append(b);
  }
  const sharingBody = mk("div", "share-where-sharing");
  const redrawSharing = mountLocationPanel(sharingBody);
  const searchBody = mk("div", "share-where-search");
  effect(() => {
    const openM = whereMenuOpen(), tab = whereTab();
    whereMenu.style.display = openM ? "flex" : "none";
    if (!openM) return;
    for (const id in modeBtn) modeBtn[id].classList.toggle("on", id === tab);
    // the radius is a sliding scale: 100 m at the left, widening by feel to 50 km, and "anywhere" at the far right
    const radiusRow = mk("div", "share-radius");
    const readout = mk("span", "share-radius-v");
    const note = mk("div", "share-radius-note");
    const paintRadius = (km: number): void => {
      readout.textContent = km > 0 ? radiusWord(km) : "anywhere";
      note.textContent = km > 0
        ? `the map, the results and the resources narrow to ${radiusWord(km)} around ${panel.draft.where ? fmtWhere(panel.draft.where, locationOptions(EXT)) : "you"}`
        : "no limit — everything the filters allow";
    };
    const head = mk("div", "share-radius-h");
    head.append(mk("span", null, "within"), readout);
    const slider = mk("input", "share-radius-range");
    slider.type = "range"; slider.min = "0"; slider.max = String(RADIUS_STEPS); slider.step = "1";
    slider.setAttribute("aria-label", "search radius");
    slider.value = String(stepOfKm(F.radiusKm.peek()));
    slider.addEventListener("input", () => { const km = kmOfStep(Number(slider.value)); paintRadius(km); F.radiusKm.set(km); });
    const ends = mk("div", "share-radius-ends");
    ends.append(mk("span", null, "100 m"), mk("span", null, "anywhere"));
    paintRadius(F.radiusKm.peek());
    radiusRow.append(head, slider, ends, note);
    searchBody.replaceChildren(whereEditor(panel.draft.where, locationOptions(EXT), {
      onNewPlace: newPlace,
      // Search's first row: follow what is shared. Offered while something is
      // shared, and the row that is lit until another place is picked.
      follow: sharedNow().mode === "off" ? undefined : {
        label: "My location",
        note: sharedNow().place ? `searching where you share — ${sharedNow().place}` : "searching where you share, once a fix lands",
        on: followShared.peek() && !panel.draft.where,
        pick: () => { followShared.set(true); panel.draft.where = ""; whereMenuOpen.set(false); },
      },
      onCommit: where => {
        followShared.set(false);     // a place picked here is the override
        panel.draft.where = where;   // syncTogs() reads panel.draft.where itself — one source, no duplicate set
        whereMenuOpen.set(false);    // a real commit reads as done, same as the clock's plain modes
      },
    }), radiusRow);
    whereMenu.replaceChildren(modes, tab === "sharing" ? sharingBody : searchBody);
    if (tab === "sharing") redrawSharing();
  });
  // asked from elsewhere (the profile's "change where you are")
  effect(() => { if (locationAsk()) { whereTab.set("sharing"); whereMenuOpen.set(true); } });
  closeOnOutsideClick(whereMenuOpen, ".share-where-menu, .share-tog-where");
  togWhere.addEventListener("click", () => whereMenuOpen.update(v => !v));
  // syncTogs also reruns on its OWN — every signal it reads is named here —
  // so the clock/pin badges update the instant F.timeBy or a popover's open
  // state changes, not only on the next unrelated draftPanel render (the
  // trap: onChange alone only fires from show/close/setDraft, and the time
  // popover's clicks move F.timeBy directly, through none of those). Placed
  // after both popovers exist: it runs once immediately, synchronously,
  // reading timeMenuOpen/whereMenuOpen before either signal would exist.
  effect(() => { F.timeBy(); F.radiusKm(); timeMenuOpen(); whereMenuOpen(); syncTogs(); });
  // the name doubles as the type search: a tap on it opens the picker, typing
  // sifts it. A tap, not focus — submit() hands focus back to the name after
  // every declare, and that hand-back must not pop the picker open each time.
  // type sits back in normal flow (CSS .sp-wide) — no docking, and any
  // left/right a PRIOR unit/emoji popover left inline would otherwise
  // fight that layout, so this clears it rather than calling dockNear.
  // Resources browses the same taxonomy — its goods ARE specs filed under
  // it — so the picker opens there too; picking one only narrows the search
  // (fields.set moves nameIn/F.query), since Enter is already off in this
  // mode. A skill is a word, not a spec, so Skills stays search-only.
  const typeBrowsable = () => drawerMode.peek() === "slots" || drawerMode.peek() === "resources";
  const openType = () => { if (panel.tab() === null && typeBrowsable()) { riseTo(false); panel.el.style.left = ""; panel.el.style.right = ""; panel.show("type"); } };
  // with the priority bar drawn, an empty field's tap leaves the terms to it;
  // the picker rises when one of its terms is tapped
  nameIn.addEventListener("click", openType);
  nameIn.addEventListener("input", () => {
    topOpen.set(!!nameIn.value.trim());
    if (topOpen.peek()) panel.close();   // the row above the bar is the chooser now, not the sheet
    panel.draft.spec = null; panel.draft.cats = [];
    F.query.set(nameIn.value);               // the name doubles as the search
    lit = 0;
    renderPreview();
    if (!typeBrowsable()) return;   // skills only ever search
    // the row above the bar is the chooser while something is typed; the
    // picker rises once one of its terms is tapped
    if (panel.tab() === null && nameIn.value.trim() && !topOpen.peek()) openType();
    else if (panel.tab() === "type") panel.refresh();
  });
  emojiBtn.addEventListener("click", () => { dockNear(emojiBtn); panel.toggle("emoji"); });
  unitBtn.addEventListener("click", () => { dockNear(unitBtn); panel.toggle("unit"); });

  const restyle = () => {
    const need = rail() === "need";
    const mine = scope() === "mine";
    const mode = drawerMode();
    const skills = mode === "skills", resources = mode === "resources", contacts = mode === "contacts";
    const bare = skills || resources || contacts;   // no declaring in any of the drawer's read-only views
    // the bar has two jobs and says which one it is doing. Under MY it is the
    // creation pill: name · qty · unit · time · place. Under OUR there is nothing to
    // declare — a sum is read, not written — so the pill is the sift alone,
    // and the quantity leaves with the job they belong to.
    bar.classList.toggle("sb-sift", !mine);
    qtyGrp.style.display = mine && !bare ? "" : "none";
    // the clock is a map filter first, a declare-rhythm field second: it stays
    // up on every one of the drawer's read-only views (Skills/Resources/
    // Attributes), the same way the place chip already does, since a filter
    // set browsing the map shouldn't vanish for a quick look at your skills.
    // Under My/Our (Requests/Offers) the older rule still holds — a cell is
    // keyed by a window, not a rhythm: the rhythm chip sifts nothing under
    // Our, so it leaves there; the place chip stays regardless.
    togTime.style.display = bare || mine ? "" : "none";
    // the lit switch already says which rail this is, so the placeholder names
    // the THING rather than repeating the verb — and stays short enough to read
    // whole in the width the switch leaves it.
    nameIn.placeholder = skills ? "Claim a skill…" : resources ? "Search resources…" : contacts ? "Find a contact, or paste a link…"
      : mine ? (need ? "Express…" : "Share capacity…")
             : (need ? "Sift our needs…" : "Sift our offers…");
    emojiBtn.textContent = emojiOf();
    const u = unitBtn.dataset.unit;
    if (u === "each" || u === "hours") setUnit(need ? "each" : "hours");
    renderPreview();
  };
  // "skill"/"resource"/"contact" are the drawer's other views: the bar then
  // claims skills, only searches, or declares nothing at all, and the rail
  // beneath it keeps the kind it last had
  const setRail = (r: SlotKind | "skill" | "resource" | "contact") => {
    const mode = r === "skill" ? "skills" : r === "resource" ? "resources" : r === "contact" ? "contacts" : "slots";
    if (mode === drawerMode.peek() && (mode !== "slots" || rail() === r)) return;
    drawerMode.set(mode);
    if (r !== "skill" && r !== "resource" && r !== "contact") rail.set(r);
    restyle();
  };
  railCtl = setRail;
  // ↵ takes the LIT reading: a locus move runs; an act fills the pill from
  // the words and declares
  const enter = () => {
    const r = readings[lit];
    if (!r) { submit(); return; }
    if (isLocus(r) || r.verb === "log") { run(r); return; }
    applyAct(r); submit();
  };
  const submit = () => {
    const f = fields.get();
    if (!f.name) return;
    // under Resources the pill only ever searches — a good is declared from
    // its own tile (shop.ts's want this / offer this), never from here
    if (drawerMode.peek() === "resources") return;
    // under Contacts the pill finds, and a person's link in it connects
    if (drawerMode.peek() === "contacts") {
      const link = connectIn(f.name);
      if (link) { propose(link); fields.set({ name: "", emoji: "", qty: 1 }); restyle(); }
      return;
    }
    // under Skills the bar claims: the words are the skill, no quantity, no place
    if (drawerMode.peek() === "skills") {
      claimSkills([{ skill: f.name }]);
      hint(`skill claimed: ${f.name}`, "success");
      fields.set({ name: "", emoji: "", qty: 1 });
      lit = 0;
      nameIn.focus();
      return;
    }
    const kind = rail(), d = panel.draft;
    const known = d.spec || ([...knownSpecs(EXT, PLAN)].find(([, l]) => l === f.name) || [])[0];
    const slot: Slot = { ...blankSlot(kind), ...f,
      emoji: f.emoji || (kind === "need" ? "🌱" : "🤲"),
      unit: f.unit || "each",
      spec: known || specOf(f.name),
      arcs: d.arcs, where: d.where };
    if (d.cats.length) slot.cats = d.cats;
    declare(kind, slot);
    hint(`${kind === "need" ? "need" : "offer"} declared: ${slot.emoji} ${f.name} · ${slot.qty} ${slot.unit}`, "success");
    fields.set({ name: "", emoji: "", qty: 1 });
    panel.reset();
    lit = 0;
    nameIn.focus();          // declaring one thing usually means declaring three
  };
  nameIn.addEventListener("keydown", ev => {
    if (ev.key === "Enter") { ev.preventDefault(); enter(); return; }
    // ↑ ↓ move the lit reading; the dropdown is keyboard-first
    if (ev.key === "ArrowDown" && readings.length) { ev.preventDefault(); lit = (lit + 1) % Math.min(4, readings.length); renderPreview(); }
    if (ev.key === "ArrowUp" && readings.length) { ev.preventDefault(); lit = (lit + Math.min(4, readings.length) - 1) % Math.min(4, readings.length); renderPreview(); }
  });
  qtyInput.addEventListener("keydown", ev => { if (ev.key === "Enter") submit(); });
  qtyInput.addEventListener("input", renderPreview);
  // the whole expression as one flex group, so a wrap never splits it mid-phrase
  const ctl = mk("div", "share-ctl");
  // scopeBtn (My/Our) stays fully built above, just not attached here —
  // showBoth is the bar's whole answer to "whose" until a future control
  // reattaches it (or something else) and sets showBoth accordingly.
  // the backpack closes the group, after the pill: on a phone the whole
  // expression wraps as one line and the handle wraps with it, never onto a
  // row of its own above
  // (with the feedback 💬 beside it in dev mode: one trailing group, so the
  // two wrap together, right-aligned, rather than one stranded on its own row)
  const end = mk("div", "share-end");
  end.append(handle);
  ctl.append(pill, end);

  // the universal mic: the footer is on every face, so this is the one spot
  // that always records — hold to speak, and the words land in the Express
  // input (the live caption while held, the release text on let-go) for the
  // speaker to read before choosing what they are. At the pill's left end;
  // the shared pressToSpeak dance (app/audio.js) does everything else.
  //
  // "The one spot" is a claim about the whole footer, so another surface that
  // wants spoken words claims THIS mic rather than growing a second one — the
  // input is simply the sink when nobody else has asked (voice/sink.js).
  const mic = mk("button", "share-mic", "🎙️");
  mic.id = "sbmic";
  // The words land in the Express input itself — the live caption while the
  // button is held, the release text after — and the readings row under the
  // bar says what they are (go · open · search · need · offer · 📓 log). One
  // line of text, one sentence, one set of verbs: nothing opens beside the bar.
  let before: string | null = null;          // what the input held as the mic went down
  const hear = (t: string, live: boolean): void => {
    const sink = voiceSink();
    if (sink) { sink.hear(t, live); return; }
    if (live) {
      before ??= nameIn.value;
      nameIn.value = t; nameIn.classList.add("live"); grow();
      return;
    }
    nameIn.classList.remove("live");
    const kept = before ?? ""; before = null;
    fields.set({ name: t || kept });            // heard nothing: the input is as it was
    lit = 0;
    nameIn.focus(); nameIn.setSelectionRange(nameIn.value.length, nameIn.value.length);
  };
  const HEAR = { listening: "listening — release to read", busy: "transcribing — the words land in the bar",
                 refused: "microphone refused", tap: "that was a tap — type in the bar; hold to speak",
                 idle: "hold to speak — the words land in the bar, for you to read · tap to type instead" };
  pressToSpeak(mic, {
    onLive: t => hear(t, true),
    onText: t => hear(t, false),
    onState: s => {
      mic.title = s;
      hearAs(s.startsWith(HEAR.listening) ? "listening" : s === HEAR.busy ? "transcribing"
        : s === HEAR.refused ? "the microphone is blocked — allow it for this site"
        : s === HEAR.tap ? "hold the mic to speak"
        : s.startsWith("heard nothing") ? "heard nothing — hold and speak"
        : s.startsWith("transcription failed") ? "could not transcribe — try again" : null,
        !s.startsWith(HEAR.listening) && s !== HEAR.busy && s !== HEAR.idle);
      if (s.startsWith("heard nothing")) hear("", false);
    },
    words: { busy: HEAR.busy, refused: HEAR.refused, idle: HEAR.idle,
             listening: HEAR.listening,
             tap: HEAR.tap,
             nothing: "heard nothing — hold and speak" },
  });
  // the speech model's first download (~80 MB, once per browser): a ring fills
  // round the mic and a quiet line beside it says how much has come and how
  // long is left; a green ring shows when it is ready. A cached model loads too
  // fast to show anything.
  const modelNote = mk("span", "share-modelnote");
  modelNote.setAttribute("role", "status");
  hearing.after(modelNote);
  const left = (s: number): string => s < 90 ? `${s} s` : `${Math.round(s / 60)} min`;
  let ringTimer: ReturnType<typeof setTimeout> | undefined, ringShown = false;
  const paintModel = (m: ModelState): void => {
    mic.style.setProperty("--p", String(Math.round(m.frac * 100)));
    const line = m.stage === "prepare" ? "preparing the speech model…"
      : `speech model · ${bytes(m.loadedMb * 1e6)} of ${bytes(m.totalMb * 1e6)}`
        + (m.etaS ? ` · about ${left(m.etaS)} left` : "");
    mic.classList.toggle("prepare", m.stage === "prepare");
    mic.title = line; modelNote.textContent = line;
  };
  onSpeechModel(m => {
    if (m.phase === "loading") {
      if (ringShown) paintModel(m);
      else if (!ringTimer) ringTimer = setTimeout(() => {
        ringShown = true; mic.classList.add("loading"); pill.classList.add("model-loading");
        paintModel(speechModel());
      }, 400);
      return;
    }
    clearTimeout(ringTimer); ringTimer = undefined;
    mic.classList.remove("loading", "prepare");
    pill.classList.remove("model-loading"); modelNote.textContent = "";
    if (m.phase === "ready" && ringShown) {
      ringShown = false;
      mic.classList.add("ready"); mic.title = "the speech model is ready — hold to speak";
      setTimeout(() => mic.classList.remove("ready"), 2200);
    } else ringShown = false;
  });
  // a TAP (not a hold) goes to the input for typing: the same bar, the same
  // readings, keyboard instead of voice
  let downAt = 0;
  mic.addEventListener("pointerdown", () => { downAt = performance.now(); });
  mic.addEventListener("click", () => {
    if (performance.now() - downAt >= 350) return;
    const sink = voiceSink();
    if (sink?.type) sink.type(); else nameIn.focus();
  });
  // the mic lives INSIDE the pill, at its left end — the mirror of the qty/unit
  // chip at the right — so it travels with the expression at every width
  pill.prepend(mic);
  // …and the clock and the pin at its right end: when and where the sentence
  // holds are part of the expression, not a pair of chips beside it
  pill.append(togs);
  row.append(ctl);
  // the top-level terms, a row of their own directly above the bar — a sibling
  // of the bar row, so the earth and the backpack keep their place. Opened by
  // an empty tap on the field; a pick, typing or a tap outside puts it away.
  const topOpen = signal(false);
  const topRow = mk("div", "sb-toprow");
  const renderTop = (): void => {
    topRow.replaceChildren();
    for (const n of dialState.root?.children || []) {
      const seg = mk("a", "sp-seg", n.name || n.id);
      seg.style.setProperty("--seg-col", n.col || "#9a9384");
      seg.addEventListener("click", () => {
        topOpen.set(false); riseTo(false); panel.el.style.left = ""; panel.el.style.right = "";
        panel.openAt(n);
      });
      topRow.append(seg);
    }
  };
  effect(() => { if (topOpen()) renderTop(); topRow.classList.toggle("on", topOpen()); });
  closeOnOutsideClick(topOpen, ".sb-toprow, .share-name");
  const railRow = mk("div", "share-railrow");
  railRow.append(railSwitch(true, true, true));
  drawer.append(railRow, mk("div", "share-lists"), mk("div", "share-lent-col"));
  bar.append(row, topRow, preview, panel.el, sheet);
  restyle();
}

function draw() {
  // reading rail() here subscribes this effect to it: flipping need ⇄ offer in
  // the expression re-renders the drawer, which is what makes ONE switch govern
  // both what you are declaring and which of your slots you are looking at.
  const S = slots(); const So = social(); note(); grants(); const old = stale();
  F.query(); F.timeBy(); F.sort(); F.t0d(); F.t1d(); F.t0t(); F.t1t();   // the sift re-renders the lists
  const need = rail() === "need";
  const mine = scope() === "mine";
  const mode = drawerMode();
  const skills = mode === "skills";
  const resources = mode === "resources";
  const contacts = mode === "contacts";
  const bar = document.getElementById("sharebar");
  if (!bar) return;
  ensureScaffold(bar);
  if (open()) closeSheetView();             // the inventory and a view share the sheet: one at a time
  bar.classList.toggle("sb-open", !!open());
  bar.classList.toggle("sb-closed", !open());
  const handle = bar.querySelector<HTMLElement>(".sharebar-handle");
  if (handle) {
    // one glyph, not a chevron-plus-word — open/shut already reads from the
    // drawer itself (sb-open/sb-closed on the bar); the title carries the rest.
    handle.textContent = "🎒";
    handle.title = `${open() ? "collapse" : "open"} the inventory — ${S.needs.length} need${
      S.needs.length === 1 ? "" : "s"}, ${S.means.length} offer${
      S.means.length === 1 ? "" : "s"} of yours declared; My ⇄ Our chooses whose, Requests ⇄ Offers which side`;
  }
  const locs = locationOptions(EXT);

  const lists = bar.querySelector(".share-lists")!;
  lists.replaceChildren();
  // the Skills view is the whole drawer: what you can do, claimed and read
  // back — no My/Our columns, nothing lent, no scope hosting beneath it
  if (skills) {
    bar.querySelector<HTMLElement>(".share-lent-col")!.replaceChildren();
    lists.appendChild(skillsPanel());
    return;
  }
  // the Resources view: the shop's own goods, filterable, inside the drawer
  // — a second mount of shop.ts's own data (resourcesPanel), never a copy of
  // it; "open full view →" is the one door out to the full face (setFace,
  // already how a slot card's own "claim" button gets there)
  if (resources) {
    bar.querySelector<HTMLElement>(".share-lent-col")!.replaceChildren();
    const wrap = mk("div", "share-resources");
    wrap.append(resourcesPanel());
    lists.appendChild(wrap);
    return;
  }
  // the Contacts view: the book from contacts.ts, narrowed by the bar's words
  if (contacts) {
    bar.querySelector<HTMLElement>(".share-lent-col")!.replaceChildren();
    lists.appendChild(contactsPanel(F.query));
    return;
  }
  const cols = mk("div", "share-cols");
  // "mine" edits inline (slotCard, the deterministic-id upsert on every
  // change). "social" is the FOLD at the scope you stand in — the cells a
  // ^demand-node / ^means-pool holds, everyone's summed — shown with
  // cellFace: a sum is read, never edited, and carries no one's name but
  // your own share of it.
  const names = knownSpecs(EXT, PLAN);
  const cellRow = (c: Cell): Slot =>          // a cell in the sift's shape: name + spec + place
    ({ id: `cell:${c.spec}`, spec: c.spec, name: c.name || names.get(c.spec) || c.spec, where: c.where, qty: c.qty, unit: c.unit,
       emoji: "", note: "", arcs: [] });
  const col = (kind: SlotKind, title: string, empty: string, all: Slot[] | Cell[], mine: boolean) => {
    const c = mk("div", "share-col");
    // the sift: the pill's own fields — name (query), the panel's dialled
    // rhythm (passesRhythm — overlap, not equality) and place (exact match)
    // — no separate clock, no sort control, the toolbar IS the filter
    const when = draftWhen(), where = draftWhere();
    const rowOf = (x: Slot | Cell): Slot => (mine ? x as Slot : cellRow(x as Cell));
    const kept = (all as (Slot | Cell)[]).filter(x => {
      const r = rowOf(x);
      return F.passes(r) && (mine ? passesRhythm(r, when) : true) && (!where || r.where === where);
    });
    c.appendChild(mk("h3", "share-h", title
      + (kept.length !== all.length ? ` · ${kept.length} of ${all.length} match` : "")));
    if (!all.length) c.appendChild(mk("div", "share-ghost", empty));
    else if (!kept.length) c.appendChild(mk("div", "share-ghost",
      mine ? "nothing of yours matches — clear the name or the clock"
           : "nothing in the scope's sum matches — clear the name or the place"));
    if (!mine) {
      for (const x of kept) c.appendChild(cellFace(x as Cell, kind, locs));
      return c;
    }
    for (const s of kept as Slot[])
      c.appendChild(slotCard(s, {
        kind, locs, here: currentPlace(),
        met: kind === "need" ? metOf(s) : null,
        onClaim: () => setFace("shop"),
        onContribute: () => setFace("plan"),
        onPropose: () => showChat({ label: `${s.emoji || ""} ${s.name || s.spec}`.trim(),
                                    vfId: `slot:${s.id || s.spec}` }),
        onNewPlace: newPlace,
        lend: kind === "capacity" ? lendOf(s) : null,
        onChat: () => showChat({ label: `${s.emoji || ""} ${s.name || s.spec}`.trim(),
                                 vfId: `slot:${s.id || s.spec}` }),
        unread: unreadOf(`slot:${s.id || s.spec}`),
        // the ⚖️ editor's price chip: the last solve's marginal read of this
        // spec — shown before the kind and voice are stated. Demo and
        // handlerless worlds price nothing (askJSON's fallback), chip silent.
        displacementOf: kind === "need" && !slots.peek().demo
          ? () => askJSON<AskDisplacement | null>(
                    () => HANDLERS.needDisplacement?.(s.spec, s.qty || 1), null)
          : undefined,
        // the attachment as the spec reads it: this row's share of the
        // citizen's own hand — voices are relative to each other, never
        // absolute (solve/emphasis.scm); a right takes no voice and enters no hand
        handShare: kind === "need"
          ? (() => { const hand = slots.peek().needs
                       .filter(n => n.tension !== "floor")
                       .reduce((t, n) => t + (n.voice || 0), 0);
                     return hand > 0 && s.tension !== "floor" ? (s.voice || 0) / hand : 0; })()
          : undefined,
        // the constitution's gate: a right or a need is the table's statement
        // (ratified-kinds); the editor reads the grant and records the rite.
        // Offline nothing gates — the demo commits every kind directly.
        gate: kind === "need" && !slots.peek().demo && HANDLERS.ratifyKind
          ? { ratified: () => askJSON<{ spec: string; kind: Tension; by: string }[]>(
                                 () => HANDLERS.ratifiedKinds?.(), [])
                           .then(gs => { const g = gs.find(x => x.spec === s.spec);
                                         return g ? { kind: g.kind, by: g.by } : null; }),
              ratify: (k: Tension) => HANDLERS.ratifyKind!(s.spec, k).then(r => r === "ok") }
          : undefined,
        onChange: patch => {
          const spec = patch.name ? specOf(patch.name) : s.spec;
          if (spec !== s.spec) retire(kind, s);   // a rename moves the id
          declare(kind, { ...s, ...patch, spec });
        },
        onDelete: () => retire(kind, s),
      }));
    return c;
  };
  // one column per standpoint shown at once (showBoth, the bar's default):
  // My and Our both sit under whichever rail is lit, side by side — not one
  // at a time behind a switch. A future toggle can set showBoth false and
  // this falls back to exactly the one-column-at-a-time reading below.
  const at = scopeName();
  const needCol = (m: boolean) => col("need",
    m ? `my needs${S.demo ? " · demo" : old ? " · as you last saw them" : ""}`
      : `our needs · the sum at ${at}${So.demo ? " · demo" : ""}`,
    m ? "say what you need — the plan provisions it; credit is only the fallback."
      : "nothing is asked for in this scope yet — add yours under My; it folds up here.",
    m ? S.needs : So.needs, m);
  const capCol = (m: boolean) => col("capacity",
    m ? `my offers${S.demo ? " · demo" : old ? " · as you last saw them" : ""}`
      : `our offers · the standing capacity at ${at}${So.demo ? " · demo" : ""}`,
    m ? "share what you can give — hours, tools, care; the pattern is when."
      : "no capacity stands in this scope yet — add yours under My; it folds up here.",
    m ? S.means : So.means, m);
  const rowCol = need ? needCol : capCol;
  cols.classList.toggle("share-cols-both", showBoth());
  if (showBoth()) cols.append(rowCol(true), rowCol(false));
  else cols.append(rowCol(mine));
  lists.appendChild(cols);
  // the conversations about the cards on show: read once a minute, live after
  if (open() && mine && !S.demo)
    trackUnread((need ? S.needs : S.means).map(s => `slot:${s.id || s.spec}`));

  // lending, and the note below, are both things you DO — they only apply
  // to your own inventory, not to a read-only browse of everyone else's.
  const lentCol = bar.querySelector<HTMLElement>(".share-lent-col")!;
  if (!mine || need) lentCol.replaceChildren(); else drawLent(lentCol);

  // the scope's hosting willingness rides the Our Offers rail: what the scope
  // will host and up to how much a day, spoken by one of its governors — the
  // consent a foreign span into its places needs, and the ceiling the means
  // consensus binds (slots/declarations.ts). The reply reads back the refusal
  // when the speaker is no governor.
  if (!mine && !need && HANDLERS.declareHosting && scopeSig() && !So.demo) {
    const strip = mk("div", "share-hosting railnote");
    strip.appendChild(mk("b", null, `${at} hosts · `));
    const spec = mk("input", "share-skill-input");
    spec.placeholder = "pools of (spec id)…";
    const ceil = mk("input", "share-skill-input");
    ceil.placeholder = "up to (unit-hours a day)";
    ceil.style.marginLeft = "0.6em";
    const go = mk("a", "share-skill-chip", "declare");
    go.title = "declare the hosting willingness as a governor of this scope";
    go.style.marginLeft = "0.6em";
    const speak = () => {
      const sp = spec.value.trim(), c = ceilingOf(ceil.value);
      if (!sp) { hint("name the spec the scope hosts"); return; }
      if (c === null) { hint("the ceiling is a positive number of unit-hours a day"); return; }
      spoken(HANDLERS.declareHosting!(scopeSig() || "", sp, c), hostingSentence(at, sp, c)).then(w => {
        hint(w.text, w.ok ? "success" : undefined);
        if (w.ok) { spec.value = ""; ceil.value = ""; }
      });
    };
    for (const i of [spec, ceil]) i.addEventListener("keydown", ev => { if (ev.key === "Enter") speak(); });
    go.addEventListener("click", speak);
    strip.append(spec, ceil, go);
    lists.appendChild(strip);
  }

  const foot = mk("div", "share-foot");
  foot.innerHTML = !mine
    ? (need
       ? `<b>the scope's need</b> — everyone's, summed per thing · place · window; no one's name
          travels, only your own share shows. Add yours under <b>My</b>; it folds up here.`
       : `<b>the scope's capacity</b> — everyone's standing service, summed per thing · place.
          Add yours under <b>My</b>; it folds up here.`)
    : need
    ? `a need is a standing order the plan tries to meet — <b>communal first,
       credit as fallback</b>`
    : `an offer with a rhythm feeds the labour pools and the matcher · tap <b>🤲</b> on one
       to lend a means of production into the commons — custody moves, your right stays,
       and recall is yours`;
  lists.appendChild(foot);
  if (note()) lists.appendChild(mk("div", "share-err", note()));
}

// ── the rail: everything you have lent, and what is actually enforced ─────
// The offer cards carry the grants over means you still declare; this is the
// COMPLETE list, so a grant whose means you have since withdrawn is still
// visible and still recallable. Recall arms on the first tap.
function drawLent(el: HTMLElement): void {
  if (!el) return;
  const gs = grants();
  el.replaceChildren();
  el.appendChild(mk("h3", null, "lent into the commons"));
  if (!gs.length) {
    el.appendChild(mk("div", "railnote",
      "Nothing lent yet. Tap 🤲 on an offer to lend a means of production into the commons — custody moves for a while, your right stays."));
  }
  const byId = new Map(slots().means.map(m => [m.spec, m]));
  for (const g of gs) {
    const m = byId.get(g.spec!);
    const row = mk("div", "share-lent");
    row.appendChild(mk("div", "share-lent-head",
      `${m && m.emoji ? m.emoji + " " : "⛭ "}${(m && m.name) || g.spec}`));
    row.appendChild(mk("div", "share-lent-sub",
      grantLine(g, { name: (m && m.name) || g.spec || "", unit: m ? m.unit : "" }) + (m ? "" : " · the offer is withdrawn")));
    const rec = mk("a", "share-recall");
    armTwice(rec, { rest: "recall", armed: "sure?", onConfirm: () => {
      recallGrant(g).then(r => { if (!r.ok) note.set(r.says); });
    } });
    row.appendChild(rec);
    el.appendChild(row);
  }
  const honest = mk("div", "railnote share-honest");
  honest.innerHTML = `<b>Honest about what's enforced.</b> Recall is instant and
    yours. Care terms are recorded, not yet enforced. The plan gains the capacity
    but does <i>not</i> hedge against your recall.`;
  el.appendChild(honest);
}

let wired = false;
export function initShareBar() {
  if (wired) return;
  wired = true;
  effect(draw);
  effect(() => { if (open() && poolMoved) refresh(); });   // the deferred wake
  refresh();
  refreshSocial();
}
// the door for old ?face=share / #share / #socialize links: open the drawer
// where the face used to be. The bar's own inventory button carries it otherwise.
export function initShare() {
  initShareBar();
  open.set(true);
  refresh();
}

// the map's tap-through lands HERE: open the drawer on the right rail, then
// scroll the spec's card into view and flash it — a tap on a 🏠 answers with
// the card that acts on it (your need's card, or the offer card a lend starts
// from), never with silence.
/** Open the drawer on the Contacts view. */
export function revealContacts(): void {
  if (railCtl) railCtl("contact"); else drawerMode.set("contacts");
  open.set(true);
}
/** Open the drawer on the Skills view — the inventory drawer's own real skills screen. */
export function revealSkills(): void {
  initShareBar();
  if (railCtl) railCtl("skill"); else drawerMode.set("skills");
  open.set(true);
}
// a person's link read anywhere (camera, address, bar) lands on their card
onPropose(revealContacts);
export function revealSlot(spec: string, kind: SlotKind): void {
  initShareBar();
  const r: SlotKind = kind === "capacity" ? "capacity" : "need";
  if (railCtl) railCtl(r); else rail.set(r);
  open.set(true);
  refresh();
  setTimeout(() => {            // after the drawer's redraw settles
    const card = document.querySelector(`.slot-card[data-spec="${spec}"]`);
    if (!card) return;
    card.scrollIntoView({ behavior: "smooth", block: "center" });
    card.classList.add("flash");
    setTimeout(() => card.classList.remove("flash"), 1600);
  }, 120);
}
