// app/seam.ts — THE SEAM: the one object the app shares with its capability
// spine (day-boot.js + day-boot.wasm — gateway CapTP, KERI login, the planner).
//
// Next to a leaf at RUNTIME — its runtime imports are bus.ts and the generated
// seam-wire.ts, both leaves; every other import is `import type`, which the
// emit erases — so it is
// evaluated before anything that touches the seam. (The type it borrows is
// ring.ts's, and ring.ts reaches back here through events.ts; the cycle exists
// only in the type graph, where cycles are fine, and never in the emitted
// JavaScript, where this one would deadlock the boot.)
//
// day-boot.js imports this same object and only MUTATES its fields, never
// replaces it, so late-arriving handlers and data are seen at call time.
// Standalone (no spine loaded) the app keeps its demo fallbacks.
//
// Two sides fill this object and neither can see the other's shape at build
// time: the app is TypeScript, the spine is Scheme compiled to wasm. The types
// below are the contract written down — what the app may assume is there and
// what the spine promises to call. Payloads the spine owns are `unknown`
// rather than `any`, so a reader has to narrow rather than assume.

import { emit } from './bus.js';
import { SEAM_PUSHES, SEAM_WIRE } from "./seam-wire.js";
import type * as W from "./wire-rows.js";
import type { SeamHandlers, SeamPushes, SeamSink } from "./seam-wire.js";
export type { SeamHandlers, SeamPushes, SeamSink };

// ── what the two sides exchange ─────────────────────────────────────────────

/**
 * Gateway state, pushed to the app by the spine. The vocabulary is day-boot.scm's
 * own (seam-status!), and it is wider than a connected/not pair:
 *
 *   no-gateway   none is configured. There is no commune to reach from here.
 *   connecting   one is being reached. NOT the same as away, and reading it as
 *                away is what made the chip say "no commune here" while it was
 *                in the middle of finding one.
 *   connected    the door is open.
 *   error:…      the attempt failed, with its reason after the colon.
 *   ok:<aid>|<k0>  authenticated — sent by the auth path rather than the
 *                connect path, which is why the reader tests the prefix.
 *
 * A template type rather than a bare string: the two prefixed forms carry a
 * payload, and every reader of them splits on the colon.
 */
export type GatewayStatus =
  | "no-gateway" | "connecting" | "connected"
  | `error:${string}` | `ok:${string}`;

/** A fan-out subscriber. Both fan-outs below hand every listener the payload. */
export type Listener<T> = (value: T) => void;
/** A socialization grant's verb — lend the service, or lend a quantity to spend. */
export type GrantKind = "use" | "consume";

/**
 * The gateway capability handlers, filled after connect.
 *
 * Named members are the ones a converted module actually calls, declared the
 * same way d3.d.ts declares d3 — on first real use, so each is a claim someone
 * checked against day-boot rather than a guess. The index signature keeps the
 * rest reachable while their callers are still plain JS; it narrows as they
 * convert.
 */
// Both halves are GENERATED: ui/app/seam-wire.ts, emitted by
// `make protocol-emit` from module/playnet/protocol/seam.scm — one entry per
// handler the spine registers, with the doors each sends, and one per push it
// makes. This file re-exports the types (above) so every importer reads them
// from the seam.

/**
 * A row of the wire as the page reads it where a snapshot carries what it has:
 * every key of the row the planner's table states (wire-rows.ts, generated from
 * module/playnet/wire/*.scm and doors/record-rows.scm), optional, a figure
 * also as the string a demo or a draft writes it.
 */
export type Wide<T> = { [K in keyof T]?: T[K] extends number | null ? number | string : T[K] };

/** One reading of a recipe channel's curve: the stress and the capture at it. */
export type ScopeCurvePoint = Wide<W.WireCurvePoint>;
/** One claim an event fulfilled: what was intended (already scaled by what the day's conditions allowed) against what the event realized. */
export type ScopeRecipeClaim = Wide<W.WireClaim>;
/** One run behind a stressor's curve: the day it happened, the (severity, capture) pair plotted, and the raw claims behind that capture. */
export type ScopeRecipeRun = Wide<Omit<W.WireChannelPoint, "claims">> & { claims?: ScopeRecipeClaim[] };
/** One stressor of a recipe's response (solve/recipe-response.scm): the curve of what its runs captured at each stress delivered. */
export type ScopeRecipeChannel = Wide<Omit<W.WireRecipeChannel, "curve" | "bend" | "points">> & {
  curve?: ScopeCurvePoint[];
  bend?: Wide<W.WireBend>;
  points?: ScopeRecipeRun[];
};
/** One flow of a recipe step; demo flows carry an emoji where real ones carry the spec's name. */
export type ScopeFlow = Wide<W.WireRecipeFlow> & { emoji?: string };
export type ScopeRecipeStep = Wide<Omit<W.WireRecipeStep, "in" | "out" | "tags" | "hours">> & {
  hours?: number;
  tags?: string[];
  in?: ScopeFlow[];
  out?: ScopeFlow[];
  emoji?: string;
  eligible?: string;
};
/**
 * A recipe from the scope's library, as the log's extraction reads it — the
 * structural subset, not a claim about the whole recipe. `need` is the need it
 * is for, when the plan matched it to one.
 */
export type ScopeRecipe = Wide<Omit<W.WireRecipe, "steps" | "profile">> & {
  steps?: ScopeRecipeStep[];
  profile?: ScopeRecipeChannel[];
  emoji?: string;
  need?: string;
};

/** A gift under an ecological agent's care: emoji, name, quantity-in-words. */
export interface EcoResource {
  e: string;
  n: string;
  q?: string;
}

/**
 * An ecological agent of the commons — a ValueFlows <agent> with
 * type = 'ecological-agent': `kind` is its classified-as, `place` its
 * primary-location, `resources` those primary-accountable to it.
 */
export interface EcoAgent {
  id: string;
  kind: string;
  kindLabel?: string;
  emoji: string;
  name: string;
  place?: string;
  note?: string;
  resources?: EcoResource[];
}

/**
 * A place in the scope snapshot, as the order's WHERE picker reads it: coordinates
 * resolved server-side through the containment climb, `containedIn` the id of the
 * place this one is inside (null at the outermost), `boundary` its extent (a GeoJSON
 * geometry as a JSON string), `slack` the per-place demand shortfall, met over want.
 */
export type SnapshotLocation = Wide<Omit<W.WireLocation, "slack">> & {
  slack?: number | string | null;
  /** Some rows spell it long. */
  long?: number | string;
  /** A human-readable address, when the citizen who named it gave one. */
  address?: string;
  [key: string]: unknown;
};

/** Drawable credit, priced server-side: hours still free to draw, those already claimed against it, the ceiling the claims are read against, the commons' pool for the voice share. */
export type Credit = Wide<W.WireCredit> & { pending?: number; [key: string]: unknown };

export type InventorySpec = Wide<Omit<W.WireInventorySpec, "id">> & { id: string; [key: string]: unknown };
export type InventoryResource = Wide<W.WireInventoryResource> & { spec?: string; [key: string]: unknown };
export interface Inventory {
  specs?: InventorySpec[];
  resources?: InventoryResource[];
}

import type { RingItem } from './ring.js';

/**
 * A place on an event: the server's location id, with the name and coordinates
 * the scope's locations table resolves for it. The id alone still identifies
 * the place when the table holds no coordinates for it.
 */
export interface EventLoc {
  id: string;
  name?: string;
  lat?: number;
  lng?: number;
}

/** One thing an act needs, as the solve states it. */
export interface EventNeed {
  /** consume | use | work | obtain-entity | obtain-person | pay | tell */
  kind: string;
  /** The id — a spec or a demand name. The join key; never the display string. */
  name: string;
  /** The same thing, resolved for reading. */
  label: string;
  qty?: number | null;
  unit?: string | null;
  /**
   * "held" · "missing" · "unknown" (nobody checked). The third is not the
   * second: no fee is observed being paid, and an unobserved fee is not a
   * reason to say the act cannot happen.
   */
  met: string;
}

export interface DayEvent {
  label: string;
  /** Turn-hours, 0..24. */
  t0: number;
  t1: number;
  /**
   * The absolute day this event occupies (days since epoch, the same doy
   * turnAnchor()/24 yields); t0/t1 are hours within it. Absent = the dial's
   * ONE viewed day, which is where anchor-column events live.
   */
  doy?: number;
  /**
   * The day the event ENDS, when its span crosses midnight: t0 counts on
   * doy, t1 on doy1, and every day between is fully covered. Absent = the
   * span lives inside its one day.
   */
  doy1?: number;
  /** work | free — which rail it reads on. */
  kind?: string;
  /** Which ribbon row it draws in. */
  lane?: number;
  /** consume | work | use | deliver-service — the VF action. */
  action?: string;
  /** The need it serves, by classification id. */
  serves?: string;
  place?: string;
  /**
   * The planner's own id for the thing this event is, when it has one. It is
   * also the CHAT TOPIC and the walkie ROOM — one id, not three
   * (meeting-station.md, Layer 0).
   */
  vfId?: string;
  /** Offset from the user, as core's places are. */
  at?: { dLat: number; dLng: number };
  /** Where it happens, as the server names it. `at` is derived from this. */
  loc?: EventLoc;
  /** A move's destination — the other end of the journey. */
  toLoc?: EventLoc;
  /** The process this row belongs to, as the solve names it. */
  proc?: string;
  /** A material row's own id in the plan: what recordFlow names to confirm it. */
  rowId?: string;
  /** A material row's spec, by id (`spec` carries the label the row shows). */
  specId?: string;
  /**
   * What this act needs HERE — its own material and labour flows, and what the
   * law asks of it at this place. Joined from the plan's `requires` on
   * (proc, place, when), which is an equality on three fields the solve wrote
   * from one source.
   *
   * THREE STATES, and the difference matters: a list means the solve published
   * what this act needs (an EMPTY list means it needs nothing here, which is a
   * real answer); `undefined` means no row was found, which is not an answer at
   * all. A reader must not draw "nothing needed" for an act it simply has no
   * row for — rides and lived events have none by construction.
   */
  needs?: EventNeed[];
  /** Why this act is absent from the plan, when it is. Absent on acts that ran. */
  why?: { reason: string; detail?: string[] };
  /** The recipe behind it, when the plan states one. */
  recipeId?: string;
  from?: string;
  /** "proposed" until you accept it. */
  status?: string;
  /**
   * Which commune this belongs to. Carried on the event rather than read from
   * the current scope, because a response has to reach the scope the item CAME
   * from — you can be looking at another one by the time you answer.
   */
  scope?: string;
  /** A social invite rather than an assignment out of a solve. */
  social?: boolean;
  /** A DIRECTED WORK OFFER — the presentation caller's proposal
   *  (offers.scm offer-work); accept routes to acceptWorkOffer. */
  offer?: boolean;
  /**
   * The plan's PULL on an open shift: λ(skill, place@period), the dual of
   * the located labour balance it was minted from — what the plan gains per
   * hour of this skill at this place. Absent where no solve priced it.
   */
  pull?: number;
  /** The record stated no clock: dated in its day, at no fabricated hour —
   *  lists and the month place it; the hour grid does not. */
  unclocked?: boolean;
  /**
   * The (skill, cell) pair willingness is offered over. Willingness is not a
   * claim on THIS slot: the solver matches across everyone who offered for the
   * pair, which is what makes it over-subscribable.
   */
  spec?: string;
  cell?: string;
  /** "open" for a work-intent you are merely eligible for; "lived" for the record. */
  tier?: string;
  /** Its observation already happened this session — the card's verb retires. */
  recorded?: boolean;
  /**
   * A personal event's link back to the ring item it IS. Present only on the
   * ribbons personalEvs() shapes, and its presence is the test for "mine, and
   * therefore editable in place" everywhere the rim asks.
   */
  _pid?: string;
  _pref?: RingItem;
  /**
   * Where this event ended up standing on the CURRENT turn — its midpoint in
   * turn-units, and the radius of the lane it drew in. Stamped by the ribbon
   * pass and read by the chords, which is the whole reason it is remembered:
   * a chord starts at the ribbon it comes from, so it must not recompute a
   * position the ribbons might have clipped or re-angled. Null when the event
   * does not stand on this turn at all.
   */
  _tmid?: number | null;
  _r?: number;
  [key: string]: unknown;
}

/**
 * A live custody grant: a capacity you have lent into a commons. Custody moved,
 * the right stayed — so this is not a sale and there is nothing to buy back,
 * only a recall.
 *
 * Declared HERE, at the root, because the my-grants push is what carries it;
 * slots/editors.ts re-exports it so the card and the share bar speak of one
 * type rather than two that happen to match.
 */
export interface Grant {
  /** The custody attestation's SAID — what a recall names. */
  id: string;
  /**
   * Which capacity is lent. A CARD only sees the grant over its own spec, so it
   * never reads this; the share bar does, to pick that one out of the list.
   */
  spec?: string;
  /** "" or absent means all of it. */
  qty?: number | string | null;
  /** An ISO day; absent is open-ended, and the watcher never hands it back. */
  until?: string | null;
  /** The grant's verb; absent reads as "use". */
  kind?: GrantKind;
  /** The steward rule as criteria JSON; "" or absent = anyone may be assigned to it. */
  eligible?: string;
}

/** One standing payout, as my-payouts reports it. */
/** One row of a citizen's order book (session/my-claims): a want the plan has
 *  not answered (asked), a claim commitment the plan holds for them (held) or
 *  one confirmed in full (taken). Quantities and the good's crystallized SNLT
 *  ride as strings, the wire's spelling. */
export interface ClaimRow {
  id: string;
  spec: string;
  name: string;
  place: string;
  when: string;
  total: string;
  fulfilled: string;
  remaining: string;
  snlt: string;
  state: "asked" | "held" | "taken";
}

/** One standing payout, as my-payouts reports it; `state` is "pending" | "sending" | "sent:<txid>" | "failed:<reason>". */
export type Payout = W.WirePayout;

/** One open debt the commons carries to you — what it owes back for a
 *  purchase you fronted, once accepted (economy/debts.scm). Face AMOUNT
 *  never changes; REMAINING is what is still open after any part-payments. */
export interface Debt {
  id: string;
  spec: string;
  amount: number;
  unit: string;
  remaining: number;
  due: string;
  since: string;
}

/** Someone's open ask to be recognised, as a person who may sign it sees it. */
export interface ContactAsk {
  /** The ceremony's id — what a witness signs. */
  said: string;
  /** Signatures so far. */
  count: number;
  /** Signatures the commune asks for. */
  quorum: number;
  /** You have signed it. */
  signed?: boolean;
}
/** Someone in the contact book: how you know them, whether they are here, and what the two of you have signed. */
export interface Contact {
  alias: string;
  aid: string;
  /** The kind you know them as — your own tag, one of rel-catalogue.ts's kinds or your own word. */
  rel: string;
  /** Reachable now, from mesh/gateway presence. */
  online: boolean;
  /** They hold a live personhood credential the gateway can read. */
  recognised?: boolean;
  /** The kind your standing vouch for them states; absent while you have signed nothing. */
  mine?: string;
  /** The kind their standing vouch for you states; absent while they have signed nothing. */
  theirs?: string;
  /** Their key log was checked when you connected. */
  verified?: boolean;
  /** Their open ask to be recognised, while there is one you may sign. */
  ask?: ContactAsk;
  /** The card they gave you, opened: the JSON text its giver wrote (reach.ts readCard); "" when this device cannot open it. Absent while they have given none. */
  card?: string;
  /** When your own card to them was made; absent while you have given none. */
  given?: string;
}

/**
 * A scope you can be in, and its path from earth down — the crumb walks it, and
 * the picker filters over it.
 *
 * `path` is absent for a scope with no geography (the founding commune), which
 * is exactly the case that drops out of the picker's list for free rather than
 * by naming it. `id` is required because it IS the identity: it is what
 * `seam.scope` holds and what the roster is searched by.
 */
export interface ScopeRef {
  id: string;
  name: string;
  path?: { id: string; name: string }[];
}

/** One need in the scope's plan: how met it is, and what fills it. */
export interface PlanNeed {
  /** The classification id, so a band opens straight onto its need. */
  id: string;
  label: string;
  emoji: string;
  /** 0..1 — how much of it the solve actually provisions. */
  met: number;
  recipeId: string | null;
  runs: number;
  labourH: number;
  suggested: string[];
  willing: number;
  /** How much of it was asked for, where the need states a quantity. */
  want?: number | string;
  /** Whose good this is: a want stated for oneself is delivered on the
   *  citizen's own good, id "spec~aid" — absent on the scope's own rows. */
  for?: string;
}

/** A line of the solve's ledger: what the scope made. */
export interface Produced {
  emoji: string;
  q: number;
  u: string;
  /** The spec, shown in the ledger when the line carries no emoji. */
  spec?: string;
}

/** The PLAN, as live.scm's plan-scope hands it over. */
export interface Plan {
  scope?: string;
  needs?: PlanNeed[];
  /** The portion the plan keeps back per good — its own processes' draw this
   *  horizon plus the reserve, the deductions before anything is shared out. */
  kept?: { spec: string; name?: string; q: number | string }[];
  produced?: Produced[];
  /**
   * The solve's OWN totals. Authoritative where present — the ledger prefers
   * them and derives from the rows only for the demo plan, which carries
   * neither.
   */
  coverage?: number;
  labourH?: number;
  /**
   * The solver's ACTUAL chosen flows — one entry per process that ran. Absent
   * offline, where the plan face reconstructs an equivalent array from recipe
   * topology instead.
   */
  flow?: Production[];
  /** When the solve placed each commitment — read by the schedule board. */
  schedule?: Schedule;
  /**
   * Whether the solve stayed inside the limits it was given. A STRING from the
   * wire, not a boolean — the plan face tests `=== "no"`, which is what caught
   * the boolean this was first declared as.
   */
  feasible?: string;
  /**
   * "yes" while a decision's re-solve has not landed (stale-while-revalidating):
   * the plan face shows the schedule and says it is being re-solved. A string
   * from the wire, like `feasible`.
   */
  stale?: string;
  /**
   * The discrete layer's verdict, present only when a recipe declared a minimum
   * batch or a whole count (or a mover rode): how many batch keys the tree
   * searched (2^keys configurations), how many nodes it solved, whether it was
   * exhausted — `certified` is a STRING "yes"/"no" like `feasible` — and the
   * gap it left when it was not. `recourseRelaxed` names the recourse columns
   * a two-stage (robust) solve kept continuous; the wire may send an empty
   * list as `[]` or `{}`, so it is read through Array.isArray.
   */
  discrete?: { keys?: number; nodes?: number; budget?: number; certified?: string; gap?: number; recourseRelaxed?: unknown };
  /** Where each mover stands: mover id → cell (place@period) → presence. */
  placement?: Record<string, Record<string, number>>;
}

/** A labour commitment the solve placed: which process, when, how much effort. */
export type WorkCommitment = Wide<W.WireSchedWork> & { [key: string]: unknown };

/** A material commitment the solve placed — the produce/consume/pickup/dropoff/use that realises the plan at its cell. */
export type MaterialCommitment = Wide<W.WireSchedMat> & { [key: string]: unknown };

/** The solve's placed commitments. */
export interface Schedule {
  work?: WorkCommitment[];
  material?: MaterialCommitment[];
}

/**
 * One flow into a production: what it drew in, and how.
 *
 * `spec` and `id` are required because plan.js's own header states the shape
 * that way — a production's inputs are {spec, id, q, action} on both the live
 * wire and the reconstructed path.
 */
export type ProductionFlow = Wide<Omit<W.WireFlowIn, "spec" | "id">> & { spec: string; id: string; emoji?: string };

/** A process that ran: its output, and what it drew in to make it. */
export type Production = Wide<Omit<W.WireFlowProd, "id" | "spec" | "specId" | "in">> & {
  id: string;
  spec: string;
  specId: string;
  in?: ProductionFlow[];
};

/**
 * The snapshot bag day-boot fills and the faces read (main.js's EXT).
 *
 * Named members are the ones a converted module reads, on the same
 * declare-on-first-use policy as SeamHandlers; the index signature keeps the
 * rest reachable while their readers are still plain JS.
 */
export interface SeamData {
  inventory?: Inventory;
  contacts?: Contact[];
  /** Every grant you have made, from the my-grants push. */
  grants?: Grant[];
  plan?: Plan;
  /** Drawable credit, derived server-side. */
  credit?: Credit;
  /** The scope's recipe library, as the store serialized it. */
  recipes?: ScopeRecipe[];
  /** The scope snapshot, locations included. */
  snapshot?: { locations?: SnapshotLocation[]; [key: string]: unknown };
  /** The day's lived events. A LIVE array — the host mutates it in place. */
  events?: DayEvent[];
  /** Intents directed at you, awaiting a yes. */
  proposals?: DayEvent[];
  /** Slots you could fill by offering willingness — not assignments. */
  eligible?: DayEvent[];
  /** The scopes this member belongs to. */
  scopes?: ScopeRef[];
  /** The spine's signed identity — THE "who am I" fact, from set-aid!. */
  aid?: string;
  /** The ecological agents the ecology face speaks with. */
  ecoAgents?: EcoAgent[];
  /**
   * The key-pool's model menu, for the orb's picker. An entry is either a
   * [value, label] pair or a bare id that is its own label — which is how a
   * pool that ships names without descriptions still renders.
   */
  models?: (string | [string, string])[];
  [key: string]: unknown;
}

/**
 * The seam itself: what the spine and the app exchange, and nothing else.
 *
 * `data` and `handlers` are the two containers both sides mutate and are
 * always present. Both halves are declared once in the protocol seam table
 * (module/playnet/protocol/seam.scm) and generated into seam-wire.ts:
 * `handlers` is app → spine; the SeamPushes methods are spine → app, fixed
 * forwarders onto app/bus.ts installed below. Traffic between app modules
 * rides the bus directly and never appears here.
 */
export interface Seam extends SeamPushes {
  /** Snapshot data pushed in by the spine (scope, models, contacts, …). */
  data: SeamData;
  /** Gateway capability handlers, filled after connect. */
  handlers: SeamHandlers;

  /**
   * The current scope id, or NULL for earth — the whole commons, which is a
   * real place to be and not the absence of one. An ACCESSOR over scope.ts's
   * signal, installed there; the spine writes it (setScope), the app reads
   * the signal.
   */
  scope?: string | null;
}

// ── the object ──────────────────────────────────────────────────────────────

// One module instance, so one object: the app imports it, day-boot.js (an ES
// module too) imports it and hands its push functions to the wasm, and the UX
// harness imports it into the page for its probes. Nothing hangs off window.
// The cast outruns the truth for exactly the lines below, which install the
// two containers and every push before any importer can look.
export const seam: Seam = {} as Seam;

seam.data = {};
seam.handlers = {};

// ── the push half ───────────────────────────────────────────────────────────
// Every push the spine makes lands on the bus under its own name: the topic IS
// the push, typed from SeamPushes in bus.ts. Installed for every name in the
// table, so a push that arrives before its reader is a push nobody wanted yet,
// never a missing method.
// The one loose cast: the loop is generic over the table, and each push's
// arguments are typed at the reader (bus.ts) from the same SeamPushes.
const forward = emit as (topic: string, ...args: unknown[]) => void;
for (const name of SEAM_PUSHES)
  (seam as unknown as Record<string, (...args: unknown[]) => void>)[name] =
    (...args) => forward(name, ...args);

// ── the sinks ───────────────────────────────────────────────────────────────
// What the wasm calls, by the name it imports: strings off the wire. Each sink
// reads its arguments as the table says (a JSON one parsed, a raw one as it
// is), keeps the first under seam.data for a reader that arrives later, and
// raises the push. day-boot.js hands these to the wasm — on the page directly,
// or through the spine worker by name — and adds the page's own plumbing
// (the trace, the scope setter, the status side effects) around them.
// A wire argument that does not parse is a spine bug, reported and dropped:
// the push it carried never lands, and the seam keeps its last good value.
export const seamSinks = {} as Record<SeamSink, (...wire: string[]) => void>;
for (const sink of Object.keys(SEAM_WIRE) as SeamSink[]) {
  const { push, args: kinds, keep } = SEAM_WIRE[sink];
  seamSinks[sink] = (...wire) => {
    let args: unknown[];
    try { args = wire.map((w, i) => kinds[i] === "json" ? JSON.parse(w) : w); }
    catch (e) { console.warn(`[seam] bad ${sink} from the spine:`, e); return; }
    if (keep) (seam.data as Record<string, unknown>)[keep] = args[0];
    forward(push, ...args);
  };
}
