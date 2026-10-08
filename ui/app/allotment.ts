// app/allotment.ts — the week's photo reads, as a face says them.
//
// An unplanned photo read draws on a weekly allotment (docs/observation/
// capture.md §5). The gateway's `allotment` door replies how many remain, of how
// many, when the week opens again and whether a picture can be read here at all.
// This module reads that reply and says it in a line; the capture sheet and the
// store face share it. Pure, so a unit test holds each sentence.

import { parseReply, refused, finite } from "./count.js";

/** The week's photo reads, as the allotment door replies them. */
export interface Allot {
  remaining: number;
  perWeek: number;
  opens: string;
  /** A vision model is configured; without one the door reads nothing. */
  sees: boolean;
}

/** The allotment a reply holds, or null for a refusal or an unreadable answer. */
export function readsOf(raw: unknown): Allot | null {
  const j = parseReply(raw);
  if (refused(j)) return null;
  return { remaining: finite(j.remaining) ?? 0, perWeek: finite(j.perWeek) ?? 0,
           opens: String(j.opens ?? ""), sees: j.sees === true };
}

/** Ask the door (the handler, when the seam has one) and read what it says. */
export const askReads = (door: (() => Promise<unknown>) | undefined): Promise<Allot | null> =>
  door ? door().then(readsOf).catch(() => null) : Promise.resolve(null);

/** Whether a photograph can be read now: a model that reads, and a read left. */
export const canRead = (r: Allot | null): boolean => !!r && r.sees && r.remaining > 0;

/** The line under the camera: what is left of the week, or why a read is not to be had. */
export function readsLine(r: Allot | null): string {
  if (!r) return "";
  if (!r.sees) return "no vision model reads pictures here yet: a photograph is kept as the evidence of a count you state";
  const opens = r.opens ? ` · new reads ${r.opens.slice(0, 10)}` : "";
  return `${r.remaining} of ${r.perWeek} photo reads left this week${opens}`;
}

/**
 * Why a photograph cannot be read now, in words a face can show; empty when it
 * can. A read that fulfils a planned count (PLANNED) draws on the plan, so the
 * week's reads being spent does not stop it.
 */
export function whyNotRead(r: Allot | null, planned = false): string {
  if (!r) return "sign in to have a model read pictures";
  if (!r.sees) return "no vision model reads pictures here yet";
  if (!planned && r.remaining <= 0) return `this week's photo reads are spent${r.opens ? ` · new reads ${r.opens.slice(0, 10)}` : ""}`;
  return "";
}
