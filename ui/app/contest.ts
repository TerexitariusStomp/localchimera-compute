// app/contest.ts — the counts of a stock, and the contests of them.
//
// A count is a person's word that so much is there. The record says it
// happened; a member of the scope may say it did not, through the one door work
// is contested through (docs/observation/capture.md §8), and the scope's
// franchise decides. This module reads the two replies the contest screen is
// made of — the counts of a stock and the contests open — and says each count in
// a sentence. Pure, so the capture sheet and a unit test read them the same way.

import { replyRows, finite, quantity } from "./count.js";
import { humanDate } from "./slots/model.js";
import { CONTEST_PREFIX, COUNT_PREFIX, COUNT_TECHNIQUES, COUNT_TECHNIQUE_PREFIX } from "./count-catalogue.js";

/** One count of a stock, as the gateway replies it. */
export interface CountEntry {
  /** The count's event id: its adjustment where it found the ledger off, else its record. */
  id: string;
  /** The ballot a contest of this count is; absent, it is `contest:` and the id. */
  ballot?: string;
  /** The figure the count found; null for a count that states none. */
  counted: number | null;
  /** The instant the count was made, ISO. */
  at: string;
  /** The count minus what the ledger read, signed as the adjustment landed; nothing when it agreed. */
  delta: number;
  unit: string;
  /** The AID that counted. */
  counter: string;
  /** How: count:stated, count:label, count:photo, or a planned run's. */
  technique: string;
  /** The hash of the picture the count names; empty when none. */
  evidence: string;
  /** The reader is the counter. */
  mine: boolean;
}

/** What the reader may do about a contest. */
export type Role = "attach" | "vote" | "none";

/** One contest open in the scope, as it stands to the reader. */
export interface ContestEntry {
  /** The ballot: contest: and the count's adjustment id. */
  id: string;
  eventId: string;
  /** work or count. */
  kind: string;
  /** The stock a count is of; empty for work. */
  resource: string;
  worker: string;
  by: string;
  reason: string;
  role: Role;
}

/** The counts a reply holds, newest first as sent; none when it is a refusal or unreadable. */
export function readHistory(raw: unknown): CountEntry[] {
  return replyRows(raw).map(r => ({
    id: String(r.id ?? ""), ...(r.ballot ? { ballot: String(r.ballot) } : {}),
    counted: finite(r.counted),
    at: String(r.at ?? ""), delta: finite(r.delta) ?? 0, unit: String(r.unit ?? ""),
    counter: String(r.counter ?? ""), technique: String(r.technique ?? ""),
    evidence: String(r.evidence ?? ""), mine: r.mine === true,
  })).filter(c => c.id);
}

/** The contests a reply holds. */
export function readContests(raw: unknown): ContestEntry[] {
  return replyRows(raw).map((r): ContestEntry => ({
    id: String(r.id ?? ""), eventId: String(r.eventId ?? ""), kind: String(r.kind ?? ""), resource: String(r.resource ?? ""),
    worker: String(r.worker ?? ""), by: String(r.by ?? ""), reason: String(r.reason ?? ""),
    role: r.role === "attach" || r.role === "vote" ? r.role : "none",
  })).filter(c => c.id);
}

/** The contests of this person's own counts, by the stock each is of: the ones they may attach a picture to. */
export function contestedBy(entries: ContestEntry[]): Map<string, ContestEntry> {
  return new Map(entries.filter(c => c.role === "attach" && c.resource).map(c => [c.resource, c]));
}

/** The ballot a count's contest is. */
export const ballotOf = (c: Pick<CountEntry, "id" | "ballot">): string => c.ballot || `${CONTEST_PREFIX}${c.id}`;

/** The open contest of a count, if there is one. */
export const contestOf = (c: Pick<CountEntry, "id" | "ballot">, open: ContestEntry[]): ContestEntry | undefined =>
  open.find(o => o.id === ballotOf(c));

const HOW: Record<(typeof COUNT_TECHNIQUES)[number], string> = {
  stated: "by their word", label: "off a label", photo: "from a photograph",
};

/** How a count was come by, in a word. */
export function howCounted(technique: string): string {
  const named = COUNT_TECHNIQUES.find(t => technique === COUNT_TECHNIQUE_PREFIX + t);
  if (named) return HOW[named];
  return technique.startsWith(COUNT_PREFIX) ? "on a planned count" : "";
}

/** What a count found, in a sentence: "counted 8 kg, found 2 kg fewer than the ledger read, by their word". */
export function countLine(c: Pick<CountEntry, "delta" | "unit" | "technique"> & { counted?: number | null }): string {
  const size = quantity(Math.abs(c.delta), c.unit);
  const how = howCounted(c.technique);
  const found = c.delta < 0 ? `found ${size} fewer than the ledger read`
              : c.delta > 0 ? `found ${size} more than the ledger read`
              : "found the ledger right";
  const said = typeof c.counted === "number" ? `counted ${quantity(c.counted, c.unit)}, ${found}` : found;
  return how ? `${said}, ${how}` : said;
}

/** The date of a count, as a face says it: the day, as a person reads one (slots/model.ts humanDate). */
export const countDay = (at: string): string => (at ? humanDate(at.slice(0, 10)) || at.slice(0, 10) : "");

/** What leads a count's row: the figure it found where it states one, who counted, and the day. */
export function countHead(c: Pick<CountEntry, "at" | "unit"> & { counted?: number | null }, who: string): { figure: string; rest: string } {
  return { figure: typeof c.counted === "number" ? quantity(c.counted, c.unit) : "", rest: [who, countDay(c.at)].filter(Boolean).join(" · ") };
}

/** What a count found, without the figure its row already leads with: "3 kg fewer than the ledger read, by their word". */
export function foundLine(c: Pick<CountEntry, "delta" | "unit" | "technique">): string {
  const size = quantity(Math.abs(c.delta), c.unit);
  const how = howCounted(c.technique);
  const found = c.delta < 0 ? `${size} fewer than the ledger read` : c.delta > 0 ? `${size} more than the ledger read` : "the ledger was right";
  return how ? `${found}, ${how}` : found;
}

/** A counter's AID, shortened for a line. */
export const shortAid = (aid: string): string => (aid.length > 10 ? `${aid.slice(0, 6)}…` : aid);

/** An image URL for a picture held as base64 JPEG; empty for none. */
export const pictureUrl = (b64: string): string => (b64 ? `data:image/jpeg;base64,${b64}` : "");
