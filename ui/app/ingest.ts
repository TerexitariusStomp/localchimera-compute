// app/ingest.ts — the planner's snapshot becomes the dial's day.
//
// day-boot calls this when the gateway's scope snapshot arrives. It is THE
// inbound seam: everything the commune knows enters the dial through this one
// function, and nothing else in the dial reads the wire.
//
// ── THE VALUEFLOWS READING ──────────────────────────────────────────────────
//   commitments  →  the calendar. Lived work, EconomicEvents.
//   intents      →  proposals awaiting your yes, and the ELIGIBLE field: work
//                   you hold the skill for but were not suggested for.
//   proposals    →  social invites directed at you, server-filtered.
//   classifications → the dial's own SPINE, derived rather than configured.
//
// ── THE WIRE'S ANSWER REPLACES ──────────────────────────────────────────────
// An arm the snapshot CARRIES replaces the day's list even when it is empty —
// a dialed commune with no proposals shows none, never the demo's rows
// standing in beside real ones. An arm the snapshot does not carry is left
// alone: the demo day stands until a wire answers about it, and a snapshot
// without a plan keeps the last schedule that had one.
//
// Written as named passes rather than one long function. They are independent —
// a snapshot may carry any subset — and naming them is what makes that visible.

import { seatDemo } from './demo/seat.js';
import { EXT, USER, markDayChanged } from './core.js';
import { replaceDay, offered } from './events.js';
import { hereOfInstant, resolveHere } from './gohere.js';
import { seam } from './seam.js';
import { desireFromNeeds } from './spine.js';
import { stage } from './stage.js';
import { setRecipes } from './recipe-graph.js';
import { drawPlanList } from './plan-column.js';
import { widOf } from './willingness.js';
import { isCategory } from './desire-projection.js';
import { renderMarkers } from './markers.js';
import { refreshContainers } from './regions.js';
import { theMap } from './mapview.js';
import { idHint } from './tabs/social/id.js';
import { drawRift } from './tabs/matter.js';
import { scopeSig } from './scope.js';
import type { DayEvent, EventLoc, ScopeRecipe } from './seam.js';
import type * as W from './wire-rows.js';

import { on, emit } from './bus.js';
import { S } from './state.js';
// The rows the planner sends are what the wire tables state (ui/app/wire-rows.ts,
// generated from module/playnet/wire/*.scm); the day reads each as a partial,
// since a snapshot carries what it has.
type Timed = W.WireClock;
/** A work-intent or commitment, as the planner serializes one. */
type WireWork = Partial<W.WireIntentRecord & W.WireCommitmentRecord>;
/** A lived EconomicEvent, as the planner serializes one. */
type WireEvent = Partial<W.WireEvent>;
/** A SpatialThing, as much of one as the day needs. */
type WireLocation = Partial<W.WireLocation> & { id: string };
/** The plan, as the solve serializes it. */
type WirePlan = Partial<W.WirePlan>;

/** The scope snapshot. Every field optional: a snapshot carries what it has. */
export interface ScopeSnapshot {
  recipes?: ScopeRecipe[];
  plan?: WirePlan;
  matter?: W.WireMatter;
  fragility?: { controls?: unknown[] };
  inventory?: { resources?: unknown[] };
  credit?: Record<string, unknown>;
  locations?: WireLocation[];
  commitments?: WireWork[];
  intents?: WireWork[];
  proposals?: (Timed & { id?: string; vfId?: string; label?: string;
                         scope?: string; from?: string; at?: string; date?: string;
                         /** a directed work offer, with its work terms */
                         offer?: boolean; spec?: string; proc?: string })[];
  events?: WireEvent[];
}

/** What ingest needs the dial itself to do. */
export interface IngestHost {
  /** A new day arrived: whatever card was open belonged to the old one. */
  clearSelection(): void;
}

let host: IngestHost;

/** A number off the wire, where floats ride as strings. */
const n = (v: unknown): number => { const x = parseFloat(String(v)); return isFinite(x) ? x : 0; };

/** An hour of the day from its parts. Nine in the morning is the default hour. */
const toT = (h?: number, m?: number): number => (h ?? 9) + (m ?? 0) / 60;

/** A wire row's clock span, end clamped past its start — every arm's opening. */
const spanOf = (r: Timed): { t0: number; t1: number } => {
  const t0 = toT(r.sh, r.sm);
  return { t0, t1: Math.max(toT(r.eh, r.em), t0 + 0.25) };
};

/** Greedy overlap-stacking, the same two lanes the demo data uses. */
function lanes<T extends { t0: number; t1: number; lane?: number }>(rows: T[]): T[] {
  const sorted = rows.slice().sort((a, b) => a.t0 - b.t0);
  let lastEnd = -1;
  for (const r of sorted) { r.lane = r.t0 < lastEnd ? 1 : 0; lastEnd = Math.max(lastEnd, r.t1); }
  return sorted;
}

// ── the passes ──────────────────────────────────────────────────────────────

/** The scope's own recipe library — the plan drill-down walks it. */
function ingestRecipes(snap: ScopeSnapshot): void {
  if (!Array.isArray(snap.recipes) || !snap.recipes.length) return;
  setRecipes(snap.recipes);
  drawPlanList();   // relink the plan rows to the real recipes
}

/**
 * The plan: coverage from the most recent solve.
 *
 * Willing counts come from the intents in THIS snapshot rather than from the
 * plan, so they are as fresh as the day is — a hand raised since the solve ran
 * still shows.
 */
function ingestPlan(snap: ScopeSnapshot): void {
  const plan = snap.plan;
  if (!plan || !Array.isArray(plan.needs)) return;
  const willBySpec: Record<string, number> = {};
  (snap.intents || []).forEach(i => {
    if (i.spec && (i.willing || []).length)
      willBySpec[i.spec] = (willBySpec[i.spec] || 0) + i.willing!.length;
  });
  /** A string field off the wire, defaulted. */
  const str = (v: unknown, or = ""): string => (v == null ? or : String(v));
  emit("plan", {
    ...plan,
    // "unknown" rather than a default: an infeasible solve provisions from
    // stock nobody has, and the plan face says so rather than showing a
    // percentage that reads as real.
    feasible: plan.feasible || "unknown",
    labourH: n(plan.labourH),
    produced: (plan.produced || []).map(y => ({ ...y, q: n(y.q) })),
    // The solve's ACTUAL production decomposition. Present once a solve has
    // run; absent offline, where the flow face reconstructs from recipes.
    flow: plan.flow ? plan.flow.map(pr => ({
      id: pr.id, spec: pr.spec, specId: pr.specId, name: pr.name,
      q: n(pr.q), u: pr.u || "", period: pr.period || "",
      in: (pr.in || []).map(f => ({ spec: f.spec, id: f.id, q: n(f.q), action: f.action })),
    })) : null,
    // The SCHEDULE, with its space-time coordinates kept: who works what where
    // at which clock moment, and every material flow at its own cell — hauls at
    // both ends, spanning runs at their arrival.
    schedule: plan.schedule ? {
      work: (plan.schedule.work || []).map(w => ({
        who: str(w.who), skill: str(w.skill), effort: n(w.effort),
        place: str(w.place), when: str(w.when), until: str(w.until), proc: str(w.proc),
      })),
      material: (plan.schedule.material || []).map(m => ({
        id: str(m.id), specId: str(m.specId),
        action: str(m.action), spec: str(m.spec), qty: n(m.qty),
        place: str(m.place), when: str(m.when), until: str(m.until), to: m.to ? str(m.to) : "",
        proc: str(m.proc), note: str(m.note),
      })),
    } : null,
    // every key the row carries rides through (`for`: whose own good it is)
    needs: plan.needs.map(nd => ({
      ...nd, met: n(nd.met), want: n(nd.want), runs: n(nd.runs), labourH: n(nd.labourH),
      willing: willBySpec[nd.id || ""] || 0,
    })),
  });
  // …and re-proportion the central WHEEL to this scope's aggregate demand: ONE
  // source of truth for the wheel's shape — the same per-scope fold the sidebar
  // shows, rather than a second reading of the same numbers.
  const sig = desireFromNeeds(plan.needs);
  if (sig) emit("desire", sig);
}

/**
 * The solve's SCHEDULE as calendar events: one DayEvent per work and material
 * row, each on its own real day (doy). The plan face's board reads the same
 * wire grouped by day×place; this is the calendar's reading of it, which is
 * what makes the whole production horizon navigable from the week grid and
 * filterable like any other source (the "sched" calendar).
 */
function ingestSchedule(snap: ScopeSnapshot): boolean {
  const s = snap.plan && snap.plan.schedule;
  if (!s) return false;
  const str = (v: unknown, or = ""): string => (v == null ? or : String(v));
  // WHAT EACH ACT NEEDS, joined once. The key is the three fields the solve
  // wrote from one source — a commitment's `when` and a requirement row's are
  // the same period-span call — so this is equality, not a time comparison.
  // Rows are looked up, never copied: several events at one act in one place in
  // one period share the one array, so there is nothing to drift.
  const needKey = (proc: string, place: string, when: string) => `${proc}\u0000${place}\u0000${when}`;
  const byAct = new Map<string, W.WireActRequires>();
  for (const r of (snap.plan?.requires || [])) {
    byAct.set(needKey(str(r.proc), str(r.place), str(r.when)), r);
  }
  // undefined when no row exists — "not published for this act", which the card
  // must not read as "this act needs nothing"
  const needsOf = (proc: string, place: string, when: string) => {
    const r = byAct.get(needKey(proc, place, when));
    if (!r) return {};
    // the rows are typed by the wire (WireActNeed): no coercion below
    const why = r.why;
    return {
      needs: (r.needs || []).map(x => ({
        kind: x.kind, name: x.name, label: x.label || x.name,
        qty: x.qty, unit: x.unit,
        met: x.met || "unknown",
      })),
      ...(why ? { why: { reason: why.reason, detail: (why.detail || []).map(d => str(d)) } } : {}),
    };
  };
  const rows: DayEvent[] = [];
  for (const w of (s.work || [])) {
    const h0 = hereOfInstant(str(w.when)), h1 = hereOfInstant(str(w.until));
    if (h0.doy == null) continue;
    // the day-arm's own law (wire(), below): a row with no stated clock is
    // UNCLOCKED — dated in its day, at no fabricated hour. The 9 here is
    // only lane math; the flag is what the hour grid reads.
    const unclocked = h0.t0 == null;
    const t0 = h0.t0 ?? 9;
    // a real until wins — on a LATER day it also spans the block across
    // midnight (doy1) and t1 becomes the end-day clock; otherwise the effort
    // spans forward within the day
    const cross = h1.doy != null && h1.t0 != null && h1.doy > h0.doy;
    const t1 = (h1.doy === h0.doy && h1.t0 != null) ? h1.t0 : t0 + n(w.effort);
    rows.push({ label: str(w.skill, "work"), doy: h0.doy, t0,
                t1: cross ? h1.t0! : Math.max(t1, t0 + 0.25),
                ...(cross ? { doy1: h1.doy! } : {}),
                ...(unclocked ? { unclocked: true } : {}),
                kind: "work", action: "work", lane: 0, status: "committed",
                from: str(w.who), proc: str(w.proc), ...placed(str(w.place)),
                ...needsOf(str(w.proc), str(w.place), str(w.when)) });
  }
  for (const m of (s.material || [])) {
    const h0 = hereOfInstant(str(m.when));
    if (h0.doy == null) continue;
    const t0 = h0.t0 ?? 9;
    const action = str(m.action, "produce");
    // a pickup's destination rides on its row (sched-mat `to`: the place its dropoff lands it)
    const dest = m.to ? locOf(str(m.to)) : null;
    // the row's own end, where it states one; else a half hour on the board
    const h1 = hereOfInstant(str(m.until));
    const t1 = (h1.doy === h0.doy && h1.t0 != null && h1.t0 > t0) ? h1.t0 : t0 + 0.5;
    rows.push({ label: `${action} ${str(m.spec)}`, doy: h0.doy, t0, t1,
                ...(h0.t0 == null ? { unclocked: true } : {}),
                kind: "work", action, lane: 0, status: "committed",
                spec: str(m.spec), specId: str(m.specId), rowId: str(m.id),
                proc: str(m.proc), ...placed(str(m.place)),
                // the row's own id and coordinates, kept verbatim: recordFlow
                // names the row by its id (the coordinates serve a caller without one)
                qty: n(m.qty), when: str(m.when), note: str(m.note),
                ...needsOf(str(m.proc), str(m.place), str(m.when)),
                ...(dest ? { toLoc: dest } : {}) });
  }
  // ONE column per (skill, span, place, day). The solve emits a work cell
  // per recipe process — a festival's 24 district recipes share one skill
  // and one band, and 24 identical full-height columns say less than one
  // that counts them. Material rows keep their identity untouched: each is
  // recorded by its own id (recordFlow).
  const seen = new Map<string, DayEvent>();
  const counts = new Map<string, number>();
  const compact: DayEvent[] = [];
  for (const r of rows) {
    if (r.action !== "work") { compact.push(r); continue; }
    const k = `${r.label}|${r.doy}|${r.t0}|${r.t1}|${r.place ?? ""}`;
    const m = seen.get(k);
    if (m) counts.set(k, (counts.get(k) ?? 1) + 1);
    else { seen.set(k, r); compact.push(r); }
  }
  seen.forEach((r, k) => {
    const n = counts.get(k);
    if (n) r.label = `${r.label} ×${n + 1}`;
  });
  return replaceDay({ sched: compact });
}

/**
 * The LIVED layer: economic events — what actually happened, dated like the
 * schedule. A move keeps both resolved ends (loc → toLoc), which is what the
 * map's journey arcs draw.
 */
function ingestLived(snap: ScopeSnapshot): boolean {
  if (!Array.isArray(snap.events)) return false;
  const rows: DayEvent[] = snap.events.map(r => {
    const to = r.to ? locOf(r.to) : null;
    // the lived row's label, composed HERE (the one derivation): what
    // happened to what — "harvest 30kg" reads as "harvest Garden greens"
    const what = r.specName || r.spec || "";
    const a = r.action || "";
    return { label: !what ? (a || "event") : a === "work" ? what : `${a} ${what}`.trim(),
             ...spanOf(r),
             kind: "work", action: r.action || "", lane: 0, tier: "lived",
             vfId: r.id, scope: r.scope, spec: r.spec, from: r.from || "",
             ...dated(r.date, r.endDate), ...placed(r.at),
             ...(to ? { toLoc: to } : {}) };
  });
  return replaceDay({ lived: rows });
}

/** The matter face: a substance-flow graph from the same solve. */
function ingestMatter(snap: ScopeSnapshot): void {
  const m = snap.matter;
  if (!m || !Array.isArray(m.links) || !m.links.length) return;
  S.matterFlow = {
    substances: m.substances || [],
    nodes: m.nodes || [],
    // Masses ride as strings; nodes carry no layout, since the renderer lays
    // them out itself.
    links: m.links.map(l => ({
      from: l.from, to: l.to,
      flows: Object.fromEntries(Object.entries(l.flows || {}).map(([k, v]) => [k, +String(v) || 0])),
    })),
  };
  if (stage.face === "rift") drawRift();
}

/** The federation's registered fragilities and live slack. */
function ingestFragility(snap: ScopeSnapshot): void {
  const f = snap.fragility;
  if (f && Array.isArray(f.controls) && f.controls.length) emit("fragility", f);
}

/**
 * The scope's on-hand stock. Stored on the seam so the fixed demo stock gives
 * way to the real ledger, and the section's own effect redraws.
 */
function ingestInventory(snap: ScopeSnapshot): void {
  if (!snap.inventory || !Array.isArray(snap.inventory.resources)) return;
  EXT.inventory = snap.inventory as typeof EXT.inventory;
  emit("inventory");
}

/** The citizen's live credit standing. Floats ride as strings. */
function ingestCredit(snap: ScopeSnapshot): void {
  const c = snap.credit;
  if (!c || typeof c !== "object") return;
  EXT.credit = {
    gross: n(c.gross), claimed: n(c.claimed), drawable: n(c.drawable),
    capacity: n(c.capacity), pool: n(c.pool), voice: n(c.voice),
    freeTime: n(c.freeTime), pending: n(c.pending),
  };
  emit("credit");
}

/**
 * The day itself: commitments, proposals, invites and the eligible field.
 *
 * Answers whether anything changed, so the caller repaints once rather than
 * once per arm.
 */
// ── the scope's venues, indexed once per snapshot ───────────────────────────
// Venue coordinates — public; only the USER's own position is coarsened —
// keyed by location id, so any pass that pins something resolves through one
// index. The NAME is kept for every SpatialThing (the schema allows one
// without coordinates); the coordinates only when finite, since those are
// what drive the pin.
let locIndex: Record<string, { name?: string; lat?: number; lng?: number }> = {};

function indexLocations(snap: ScopeSnapshot): void {
  locIndex = {};
  for (const L of (snap.locations || [])) {
    const lat = parseFloat(String(L.lat)), lng = parseFloat(String(L.lng));
    locIndex[L.id] = { name: L.name, ...(isFinite(lat) && isFinite(lng) ? { lat, lng } : {}) };
  }
}

/** The event-side reading of a location id: name and coords where known. */
const locOf = (id?: string): EventLoc | null => {
  if (!id) return null;
  const l = locIndex[id] || {};
  return { id, ...(l.name ? { name: l.name } : {}),
           ...(l.lat != null && isFinite(l.lat) ? { lat: l.lat, lng: l.lng } : {}) };
};
/** The same place as a map offset — what the markers and flyTo speak. */
const atOf = (loc: EventLoc | null): { dLat: number; dLng: number } | null =>
  (loc && loc.lat != null)
    ? { dLat: loc.lat - USER.lat, dLng: loc.lng! - USER.lng } : null;
/** Both spellings of one place, spread into an event under construction. */
const placed = (id?: string): Partial<DayEvent> => {
  const loc = locOf(id), at = atOf(loc);
  return { ...(loc ? { loc } : {}), ...(at ? { at } : {}),
           place: (loc && loc.name) || "" };
};

/**
 * The record's stated calendar day(s), spread in when the wire carries them:
 * doy from its date, doy1 when a stated end crosses midnight — t0 then counts
 * on doy and t1 on doy1.
 */
const dated = (iso?: string, endIso?: string): Partial<DayEvent> => {
  const d = iso ? hereOfInstant(iso).doy : null;
  if (d == null) return {};
  const d1 = endIso ? hereOfInstant(endIso).doy : null;
  return { doy: d, ...(d1 != null && d1 > d ? { doy1: d1 } : {}) };
};

function ingestDay(snap: ScopeSnapshot): boolean {
  // WHO AM I — the spine's signed identity, pushed across the seam at its
  // one write door (set-aid!). The device hint is only the pre-unlock
  // fallback: deriving "mine" from localStorage painted another person's
  // commitments as yours whenever the hint was stale.
  const me = (seam.data && seam.data.aid) || (idHint() || {}).aid || null;

  // THE label derivation — the one place presentation is composed, from the
  // wire's own name parts: "Proc: Spec" where both are named, else whichever
  // stands, else the spec id, else the verb of last resort.
  const labelOf = (r: WireWork): string => {
    const pn = r.procName || "", sn = r.specName || "";
    if (pn && sn) return `${pn}: ${sn}`;
    return pn || sn || r.spec || "work";
  };
  const wire = (r: WireWork): DayEvent => ({
    label: labelOf(r),
    ...spanOf(r),
    // the VF action rides verbatim; an intent/commitment with no stated
    // clock is UNCLOCKED — dated in its day, at no fabricated hour
    kind: "work", action: r.action || "work", lane: 0, vfId: r.id, scope: r.scope,
    ...(r.sh == null ? { unclocked: true } : {}),
    spec: r.spec, cell: r.cell,
    candidates: r.candidates || [],
    willing: r.willing || [],
    suggested: r.suggested || "",
    serves: r.serves || "",
    cats: r.categories || (r.serves ? [r.serves] : []),
    ...(r.status ? { status: r.status } : {}),   // the wire's own standing
    effort: n(r.effort), done: n(r.done),        // asked vs already recorded
    ...(r.pull ? { pull: n(r.pull) } : {}),      // the plan's pull, where a solve priced it
    ...(Array.isArray(r.arcs) && r.arcs.length ? { arcs: r.arcs } : {}),
    ...dated(r.date, r.endDate),  // a dated record lands on its own column(s)
    ...placed(r.at),   // loc + at + place — every wired event carries its venue
  });

  // A commitment is YOURS only with your name on it (provider = your AID) —
  // the accept is what binds a person. The deployment fold also persists
  // SCOPE-addressed commitments (provider unbound, the commune's own plan
  // cells), and those already ride the sched lane as the production
  // schedule — so the day's own list carries exactly what binds YOU.
  const cs = (snap.commitments || [])
    .filter(r => me && r.provider === me)
    .map(wire);
  /**
   * WHERE AN INTENT LANDS — the one decision table, acceptDoor's sibling:
   *
   *   demand     another's consume/use — the scope's standing terms. They
   *              drive the plan and land on no list of yours: accepting one
   *              would finish the intent and extinguish the very demand the
   *              plan runs on. (Your OWN declared need stays a card.)
   *   suggested  a work intent naming YOU — a proposal awaiting your yes.
   *   theirs     suggested to someone else — their card, not your day: the
   *              materialization mints one suggestion PER willing worker,
   *              and showing every clone to every gardener drew nine
   *              identical shifts where the shared thing is the ONE open
   *              ni| intent beneath them.
   *   eligible   open work you hold the skill for — the open-shifts rail,
   *              and that rail alone (never doubled as a proposal).
   *   open       unsuggested, unskilled-for — a proposal for anyone.
   */
  const tierOf = (r: WireWork): "demand" | "suggested" | "eligible" | "open" | "theirs" => {
    if (r.action && r.action !== "work" && r.receiver && me && r.receiver !== me) return "demand";
    if (me && r.suggested === me) return "suggested";
    if (r.suggested) return me ? "theirs" : "open";
    if (me && (r.candidates || []).includes(me)) return "eligible";
    return "open";
  };
  const routed = (snap.intents || []).map(r => ({ tier: tierOf(r), e: wire(r) }));
  const allIntents = routed.filter(x => x.tier !== "demand").map(x => x.e);
  // Willing-state comes straight from the planner, so the local `offered`
  // set survives a re-solve.
  const is: DayEvent[] = routed
    .filter(x => x.tier === "suggested" || x.tier === "open")
    .map(x => ({ ...x.e, status: "proposed", from: (x.e.scope as string) || "the plan" }));
  // Directed proposals: a SOCIAL INVITE (a person proposed an event — accept
  // routes to acceptInvite) or a DIRECTED WORK OFFER (the presentation
  // caller's proposal — accept routes to acceptWorkOffer). The wire says
  // which; the offer carries its work terms (spec, proc) so the card's
  // willing button has a planner key.
  const invites: DayEvent[] = (snap.proposals || []).map(r => ({
    label: r.label || "event",
    ...spanOf(r),
    kind: r.offer ? "work" : "free", action: r.offer ? "work" : "use", lane: 0,
    vfId: r.vfId || r.id, scope: r.scope, from: r.from || "someone",
    ...(r.offer ? { offer: true, spec: r.spec, proc: r.proc } : { social: true }),
    status: "proposed", ...dated(r.date), ...placed(r.at),
  }));
  // ELIGIBLE is work you hold the skill for but were not suggested for — the
  // field you can raise your hand into. Pinned at its venue when coords resolve.
  const elig: DayEvent[] = routed
    .filter(x => x.tier === "eligible")
    .map(x => x.e)
    .map(i => ({ label: i.label, t0: i.t0, t1: i.t1, kind: "work", action: "work",
                 serves: i.serves, skill: i.spec, spec: i.spec, cell: i.cell,
                 scope: i.scope, vfId: i.vfId, from: "open slot", place: i.place || "",
                 ...(i.doy != null ? { doy: i.doy } : {}),
                 ...(i.loc ? { loc: i.loc } : {}), ...(i.at ? { at: i.at } : {}) }));

  // exactly the arms this snapshot carries — an arm it answered about
  // replaces (empty included), one it did not stays as it was
  const changed = replaceDay({
    ...(Array.isArray(snap.commitments) ? { evs: lanes(cs) } : {}),
    ...(Array.isArray(snap.intents) || Array.isArray(snap.proposals)
        ? { proposals: lanes(is.concat(invites)) } : {}),
    ...(me && Array.isArray(snap.intents) ? { eligible: elig } : {}),
  });
  // Reconcile willingness from the plan, so a hand raised on another device
  // shows here and one withdrawn there stops showing.
  if (me) allIntents.forEach(i => {
    const wid = widOf(i);
    if ((i.willing as string[]).includes(me)) offered.add(wid); else offered.delete(wid);
  });

  if (me && allIntents.length && stage.mode === "earth" && theMap()) renderMarkers();
  return changed;
}

/**
 * Derive the dial's SPINE from the planner's own classifications.
 *
 * Path-structured URIs ("vf:Food/Grain") split on "/" into a tree whose leaf
 * ids ARE the classification — which is what makes a work-intent's `serves`
 * match the leaf you are looking at, with no mapping table in between.
 *
 * Categories only: isCategory excludes the non-category tags that still ride in
 * classifiedAs, and it is the same predicate the shop's folksonomy shelves use.
 */
function ingestSpine(snap: ScopeSnapshot): void {
  const cats = new Set<string>();
  for (const r of (snap.intents || []).concat(snap.commitments || []))
    for (const c of (r.categories || [])) if (isCategory(c)) cats.add(c);
  if (!cats.size) return;
  const label = (seg: string): string => { const a = seg.split(":"); return a[a.length - 1] || seg; };
  interface TaxNode { id: string; label: string; children?: TaxNode[] }
  const byId = new Map<string, TaxNode>();
  const tax: TaxNode = { id: "all", label: "all", children: [] };
  for (const uri of cats) {
    let path = "", parent = tax;
    for (const s of uri.split("/")) {
      path = path ? path + "/" + s : s;
      let node = byId.get(path);
      if (!node) {
        node = { id: path, label: label(s) };
        byId.set(path, node);
        (parent.children || (parent.children = [])).push(node);
      }
      parent = node;
    }
  }
  emit("taxonomy", tax);
}

/**
 * THE SCOPE FACET — the one place the standpoint narrows the wire.
 *
 * The snapshot is the UNION over every membership (the spine folds one per
 * commune, scope-tagged). At earth (scopeSig null) the union passes whole;
 * with a commune dialed, that commune's rows remain. A scope is a filter
 * over one world, never a world of its own — the per-scope artifacts
 * (plan, inventory, credit, recipes) already arrive led by the dialed
 * scope, so only the row arrays facet here. Untagged rows always pass.
 */
function facet(snap: ScopeSnapshot): ScopeSnapshot {
  const sc = scopeSig();
  if (!sc) return snap;
  const has = <T extends { scope?: string }>(rows?: T[]): T[] | undefined =>
    Array.isArray(rows) ? rows.filter(r => !r.scope || r.scope === sc) : rows;
  return { ...snap, commitments: has(snap.commitments), intents: has(snap.intents),
           proposals: has(snap.proposals), events: has(snap.events) };
}

/** Install the inbound seam. */
export function initIngest(h: IngestHost): void {
  host = h;
  on("ingest", (raw: unknown) => {
    const snap = facet(raw as ScopeSnapshot);
    indexLocations(snap);
    ingestRecipes(snap);
    ingestPlan(snap);
    // captured first so a schedule- or events-only snapshot still repaints —
    // inlined into the || below, short-circuit would skip the later passes
    const schedChanged = ingestSchedule(snap);
    const livedChanged = ingestLived(snap);
    ingestMatter(snap);
    ingestFragility(snap);
    ingestInventory(snap);
    ingestCredit(snap);
    if (ingestDay(snap) || schedChanged || livedChanged) {
      host.clearSelection();
      markDayChanged();   // panels, and the rim and chords, redraw from one call
    }
    ingestSpine(snap);
    refreshContainers();  // the live SpatialThing forest may have changed
    resolveHere();        // a ?ev= deep link waits for its id to exist
  });
  // with no gateway the demo world is pushed through this same door, once the page has stood up
  setTimeout(seatDemo, 0);
}
