// app/count.ts — a count of a stock, as the faces speak it.
//
// A person looks at a stock the books hold and says how much is there; the
// gateway compares the figure with the ledger and lands the difference
// (session/count-stock → planner count-stock, docs/observation/capture.md §3).
// This module is the words on either side of that call: reading a figure out of
// what a person typed or said, reading the gateway's reply, and saying what the
// count found. Pure, so the capture sheet, the inventory face and the calendar
// say the same thing and a unit test holds each sentence.

import { BLIND_REGIMES, COUNT_AGREES, COUNT_PREFIX, COUNT_REGIMES, COUNT_TECHNIQUES } from "./count-catalogue.js";

/** The three techniques a person carries (capture.md §2). */
export type Technique = typeof COUNT_TECHNIQUES[number];

/** What a count landed, as the gateway replies it. */
export interface CountReply {
  /** The adjustment's event id; empty when the count agrees with the ledger. */
  event: string;
  /** The count record's event id; empty when no plan asked for the count. */
  record: string;
  /** The counter's hours the count landed; zero when no plan asked for it. */
  hours: number;
  /** The count minus what the ledger read. */
  delta: number;
  /** What is on hand after the count. */
  onhand: number;
  /** "earlier" when a later count of the stock stands and this one is kept as a sighting. */
  sighting?: string;
  /** What the plan expected of the stock by the instant counted; null where no flow of the plan bears on it. */
  expected: Expected | null;
}

/** One flow of the plan that bears on a stock and that no event has met yet; the quantity is signed by what it does to the stock. */
export interface ExpectedFlow {
  id: string;
  /** produce, consume or move. */
  action: string;
  quantity: number;
  /** The ISO instant its period begins; empty where the plan states none. */
  when: string;
  /** The process it belongs to. */
  proc: string;
}

/** The range the plan leaves a stock in: the books with every draw it expects, and with every addition. */
export interface Expected {
  low: number;
  high: number;
  flows: ExpectedFlow[];
}

/** A refusal, in the gateway's own words. */
export interface CountRefusal {
  err: string;
}

/** How a planned count is disclosed (planner/formulas/counting.scm). */
export type Regime = "announced" | "undisclosed" | "random";

/** What a planned count's process names. */
export interface PlannedCount {
  regime: Regime;
  /** The resource id the count is of. */
  target: string;
  /** The custodian does not read this count ahead, and the counter states a figure before seeing the ledger's. */
  blind: boolean;
}

/** One target's place in the schedule of counts, as the gateway replies it. */
export interface CountRow {
  id: string;
  name: string;
  /** How many things one visit counts: the target and what is in it. */
  lines: number;
  /** The counter's hours for the visit. */
  hours: number;
  /** Seconds between counts. */
  interval: number;
  /** A counted four times a year or more, B twice, C once. */
  cls: string;
  /** ISO instants; `lastCount` empty when the target was never counted. */
  lastCount: string;
  due: string;
  overdue: boolean;
}

/** A reply the gateway gave, read: its JSON object, or the refusal it gave in words. */
export type Reply = Record<string, unknown> | CountRefusal;

/**
 * A door's reply, read once for every door that answers in JSON: an object, or
 * the refusal ("err:…" in the gateway's own words, or a sentence for an answer
 * that is no object).
 */
export function parseReply(raw: unknown): Reply {
  const s = typeof raw === "string" ? raw : "";
  if (s.startsWith("err:")) return { err: s.slice(4) || "refused" };
  if (!s.startsWith("{")) return { err: "the gateway gave no answer" };
  try {
    const j: unknown = JSON.parse(s);
    return j && typeof j === "object" && !Array.isArray(j) ? j as Record<string, unknown>
                                                          : { err: "the gateway's answer was unreadable" };
  } catch {
    return { err: "the gateway's answer was unreadable" };
  }
}

/** A finite number off the wire, from a number or its text; null for anything else (false and null are no figures). */
export function finite(v: unknown): number | null {
  if (typeof v === "number") return Number.isFinite(v) ? v : null;
  if (typeof v === "string" && v.trim() !== "") { const n = Number(v); return Number.isFinite(n) ? n : null; }
  return null;
}

/**
 * The rows a door's reply holds, each an object: the shape every list door
 * answers in ({rows: […]}). None when the reply is a refusal or unreadable.
 */
export function replyRows(raw: unknown): Record<string, unknown>[] {
  const j = parseReply(raw);
  if (refused(j) || !Array.isArray(j.rows)) return [];
  return j.rows.filter((r): r is Record<string, unknown> => !!r && typeof r === "object");
}

/** The schedule, read: its rows, or none when the reply is a refusal or unreadable. */
export function readSchedule(raw: unknown): CountRow[] {
  return replyRows(raw)
    .map(r => ({
      id: String(r.id ?? ""), name: String(r.name ?? ""),
      lines: finite(r.lines) || 1, hours: finite(r.hours) ?? 0,
      interval: finite(r.interval) ?? 0, cls: String(r.class ?? ""),
      lastCount: String(r.lastCount ?? ""), due: String(r.due ?? ""),
      overdue: r.overdue === true,
    }))
    .filter(r => r.id);
}

/** An interval as a person says it: "every 3 days", "every 6 weeks", "once a year". */
export function cadence(seconds: number): string {
  const days = seconds / 86400;
  if (!(days > 0)) return "";
  if (days >= 350) return "once a year";
  if (days >= 60) return `every ${Math.round(days / 30)} months`;
  if (days >= 14) return `every ${Math.round(days / 7)} weeks`;
  const d = Math.max(1, Math.round(days));
  return d === 1 ? "every day" : `every ${d} days`;
}


/**
 * A planned count's terms, read off its process: count~<regime>~<resource id>,
 * the grammar the planner lays (counting.scm count-process). Null for any
 * other process, a recipe's or an unplanned count's own technique.
 */
export function plannedCount(proc: string | null | undefined): PlannedCount | null {
  const s = String(proc ?? "");
  if (!s.startsWith(COUNT_PREFIX)) return null;
  const rest = s.slice(COUNT_PREFIX.length), cut = rest.indexOf("~");
  if (cut < 0) return null;
  const regime = rest.slice(0, cut), target = rest.slice(cut + 1);
  if (!COUNT_REGIMES.includes(regime) || !target) return null;
  return { regime: regime as Regime, target, blind: BLIND_REGIMES.includes(regime) };
}

/**
 * The figure in what a person typed or said: the first number in the text,
 * zero or more. A decimal comma reads as a decimal point, since "8,5 kg" is how
 * half of Europe writes it. Null when the text holds no figure.
 */
export function parseFigure(text: string): number | null {
  const m = /(\d+(?:[.,]\d+)?|[.,]\d+)/.exec(String(text ?? ""));
  if (!m) return null;
  // a minus sign directly before the figure makes it a figure this door refuses
  if (m.index > 0 && /[-−]/.test(text[m.index - 1])) return null;
  const n = Number(m[1].replace(",", "."));
  return Number.isFinite(n) && n >= 0 ? n : null;
}

/** The gateway's reply, read: a landed count, or the refusal it gave. */
export function readReply(raw: unknown): CountReply | CountRefusal {
  const j = parseReply(raw);
  if (refused(j)) return j;
  const delta = finite(j.delta), onhand = finite(j.onhand);
  if (delta === null || onhand === null) return { err: "the gateway's answer held no figures" };
  return { event: String(j.event ?? ""), record: String(j.record ?? ""),
           hours: finite(j.hours) ?? 0, delta, onhand,
           sighting: typeof j.sighting === "string" && j.sighting ? j.sighting : undefined,
           expected: readExpected(j.expected) };
}

/** Whether a reply is the gateway's refusal. */
export const refused = (r: unknown): r is CountRefusal =>
  !!r && typeof r === "object" && "err" in r && typeof (r as CountRefusal).err === "string";

/** A figure off the wire, where numbers ride as strings: its number, 0 when it is none. */
export const num = (v: unknown): number => { const n = parseFloat(String(v)); return isFinite(n) ? n : 0; };

/** A number as a face writes it: up to two decimals. */
export const figure = (n: number): string => (Number.isInteger(n) ? String(n) : String(Number(n.toFixed(2))));

/** A quantity as a face writes it: up to two decimals, the unit after a space. */
export function quantity(n: number, unit: string): string {
  return unit ? `${figure(n)} ${unit}` : figure(n);
}

/**
 * What the count found, in one sentence. The ledger is the subject, since the
 * count is what stands after: "the ledger read 1.5 kg more than is there".
 */
export function verdict(r: CountReply, unit: string): string {
  if (r.sighting === "earlier") return `kept as an earlier sighting; the ledger holds the later count and reads ${quantity(r.onhand, unit)}`;
  if (Math.abs(r.delta) < COUNT_AGREES) return `the ledger agrees: ${quantity(r.onhand, unit)}`;
  const off = quantity(Math.abs(r.delta), unit);
  return r.delta < 0
    ? `the ledger read ${off} more than is there; it now reads ${quantity(r.onhand, unit)}`
    : `the ledger read ${off} less than is there; it now reads ${quantity(r.onhand, unit)}`;
}

/**
 * The plan's range for a stock, read off the wire: null unless a flow of the
 * plan bears on the stock, since a range of one point says nothing the books'
 * own figure has not said.
 */
export function readExpected(raw: unknown): Expected | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  const low = finite(r.low), high = finite(r.high);
  const flows = (Array.isArray(r.flows) ? r.flows : []).flatMap((f): ExpectedFlow[] => {
    const o = f && typeof f === "object" ? f as Record<string, unknown> : {};
    const quantity = finite(o.quantity);
    return quantity === null ? [] : [{ id: String(o.id ?? ""), action: String(o.action ?? ""), quantity,
                                       when: String(o.when ?? ""), proc: String(o.proc ?? "") }];
  });
  return low === null || high === null || !flows.length ? null : { low, high, flows };
}

/** The range, as a face writes it: "7–15 kg", or the one figure where the ends meet. */
export function planRange(e: Expected, unit: string): string {
  return Math.abs(e.high - e.low) < COUNT_AGREES ? quantity(e.low, unit)
                                                  : `${figure(e.low)}–${quantity(e.high, unit)}`;
}

const FLOW_VERBS: Record<string, [string, string]> = {   // [adds to the stock, takes from it]
  produce: ["arriving", "leaving"], consume: ["arriving", "going"], move: ["arriving", "leaving"],
};

/** One flow, as a line of the list behind the range: "3 kg going · from 28 Sep, 08:00". */
export function flowLine(f: ExpectedFlow, unit: string): string {
  const [adds, takes] = FLOW_VERBS[f.action] ?? ["arriving", "leaving"];
  const when = f.when && !Number.isNaN(Date.parse(f.when))
    ? new Date(f.when).toLocaleString(undefined, { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" })
    : "";
  return `${quantity(Math.abs(f.quantity), unit)} ${f.quantity < 0 ? takes : adds}${when ? ` · from ${when}` : ""}`;
}

/** Where a figure stands against the plan's range: inside it, short of it, or over it. */
export function against(counted: number, e: Expected): "within" | "under" | "over" {
  return counted < e.low - COUNT_AGREES ? "under" : counted > e.high + COUNT_AGREES ? "over" : "within";
}

/** The plan's word on a count, in one sentence: how the figure stands against what the plan expected. */
export function planVerdict(counted: number, e: Expected, unit: string): string {
  const range = planRange(e, unit), at = against(counted, e);
  return at === "within" ? `inside what the plan expected: ${range}`
       : at === "under" ? `${quantity(e.low - counted, unit)} under what the plan expected: ${range}`
       : `${quantity(counted - e.high, unit)} over what the plan expected: ${range}`;
}

// ── a figure, weighed against a stock ────────────────────────────────────────
// Every screen that takes a figure for a stock (the typed count, a row of a photo
// read) asks the same three things of it before it lands, so they are asked here.

/** What a figure is weighed against: what the ledger reads of a stock, and what the plan expects of it. */
export interface Weighed {
  onhand: number;
  expected?: Expected | null;
}

/** How a figure stands: the ledger's own, inside what the plan expects, or under or over it (the ledger's figure where no plan bears). */
export type Standing = "agrees" | "within" | "under" | "over";

export function standing(qty: number, s: Weighed): Standing {
  if (Math.abs(qty - s.onhand) < COUNT_AGREES) return "agrees";
  if (s.expected) return against(qty, s.expected);
  return qty < s.onhand ? "under" : "over";
}

// how far outside its reference a figure is before a screen asks twice: more
// than half of it, and more than one unit
const FAR_SHARE = 0.5, FAR_FLOOR = 1;

/**
 * Whether QTY is far from what is held: outside the plan's range (the ledger's
 * figure where no plan bears) by more than half the end it passed and by more
 * than one unit. Such a figure lands on a second tap.
 */
export function farOff(qty: number, s: Weighed): boolean {
  const e = s.expected;
  const ref = e ? (qty < e.low ? e.low : qty > e.high ? e.high : qty) : s.onhand;
  const gap = Math.abs(qty - ref);
  return gap > FAR_FLOOR && gap > FAR_SHARE * ref;
}

/** How much short of what was to be there QTY is: the plan's low end, else the ledger's figure, less QTY. */
export function shortfall(qty: number, s: Weighed): number {
  return Math.max(0, (s.expected?.low ?? s.onhand) - qty);
}
