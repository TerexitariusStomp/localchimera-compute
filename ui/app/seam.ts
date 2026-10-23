// SPDX-License-Identifier: AGPL-3.0-or-later
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
import type { SeamHandlers, SeamPushes, SeamSink, Json } from "./seam-wire.js";
export type { SeamHandlers, SeamPushes, SeamSink, Json };

/**
 * A door's reply read as the table it is: the object, or null for a refusal
 * ("err:…"), an unanswered door, or an unreadable answer. The handler's type
 * (seam-wire.ts, generated from the seam table) says which table.
 */
export function readJson<T>(raw: Json<T> | string | null | undefined): T | null {
  const s = typeof raw === "string" ? raw : "";
  if (!s.startsWith("{")) return null;
  try { const j: unknown = JSON.parse(s); return j && typeof j === "object" ? j as T : null; }
  catch { return null; }
}

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
  [key: string]: unknown;
};

/** Drawable credit, priced server-side: hours still free to draw, those already claimed against it, the ceiling the claims are read against, the commons' pool for the voice share. */
export type Credit = Wide<W.WireCredit> & { [key: string]: unknown };

export type InventorySpec = Wide<Omit<W.WireInventorySpec, "id">> & { id: string; [key: string]: unknown };
export type InventoryResource = Wide<W.WireInventoryResource> & { spec?: string; [key: string]: unknown };
export interface Inventory {
  specs?: InventorySpec[];
  resources?: InventoryResource[];
}

// The ring face's event shape — the only thing a ribbon's `_pref` carries.
// ring.ts itself lives with the deleted dial faces; the type stays here.
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
/** One row of the order book (the claim-row table): a want asked, held or taken. */
export type ClaimRow = Omit<W.WireClaimRow, "state" | "total" | "fulfilled" | "remaining" | "snlt">
  & Wide<Pick<W.WireClaimRow, "total" | "fulfilled" | "remaining" | "snlt">>
  & { state: "asked" | "held" | "taken" };

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
/**
 * The matter graph, exactly as the planner's matter table emits it: a
 * substance and the colour it is drawn in; a node, a PROCESS (kind !==
 * "resource") or a RESOURCE, an `env` resource being an environment stock —
 * soil, air, water — the only ones whose imbalance counts as the rift; a link,
 * an element flow from one node to another keyed by substance. The browser
 * never derives composition, it only draws; `fx`/`fy` are the layout it writes.
 */
export type MatterNode = W.WireMatterNode & { fx?: number; fy?: number };
export type MatterLink = Omit<W.WireMatterLink, "flows"> & { flows?: Record<string, number> };
export interface MatterGraph {
  substances: W.WireMatterSubstance[];
  nodes: MatterNode[];
  links: MatterLink[];
}

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
  /** Drawable credit, derived server-side. */
  credit?: Credit;
  /** The scope snapshot, as the planner's snapshot table states it, locations included. */
  snapshot?: Partial<Omit<W.WireScopeSnapshotReply, "locations">> & { locations?: SnapshotLocation[]; [key: string]: unknown };
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
