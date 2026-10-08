// ui/app/conform.ts — ONE door for "ask the model for a shape" in the browser.
//
// The twin of (playnet ai conform) on the gateway, same loop, same names:
// a reply is untrusted text; `read` lifts the first structure out of it,
// `check` says why it does not conform (or null when it does), and a failing
// reply is asked again with that reason and the previous output quoted back,
// `retries` times. Then the FLOOR ships — the deterministic answer the caller
// already has, given the last readable candidate so it can salvage the good
// part of a partly-bad reply. The AI can only refine; it can never invent
// behaviour the floor would not.
//
// The loop's shape is the self-healing pipe of the match repo
// (match/src/lib/core/ai/ai-pipe.ts); Zod is the schema there, and here a
// schema is the two functions the pass owns, so nothing new is served.
//
// `ask` is the gateway's AI handler shape — (system, user) → reply text — read
// at call time by the caller (the seam's handlers.ai), never held here.
// A throwing ask goes to the floor at once: a retry cannot fix an absent
// gateway, and the caller has already said what to ship then.

export type Ask = (system: string, user: string) => Promise<string | undefined> | string | undefined;

export interface Conform<C, R> {
  ask: Ask;
  system: string;
  user: string;
  /** the first structure in the reply, or null when nothing is readable */
  read: (raw: string) => C | null;
  /** null when the candidate conforms; else the reason, as words for the model
   *  (may be a promise: a check that asks the planner's lint door awaits it) */
  check: (candidate: C) => string | null | Promise<string | null>;
  /** the result, from a conforming candidate */
  accept: (candidate: C) => R;
  /** the deterministic answer, given the last readable candidate (or null) */
  floor: (last: C | null) => R;
  /** re-asks after the first; default 1 */
  retries?: number;
  /** the re-ask's wording; default `healPrompt` */
  heal?: (original: string, raw: string, reason: string) => string;
}

export const DEFAULT_RETRIES = 1;

/** The first {…} object in RAW (outermost braces), parsed; null on anything else. */
export function readFirstJSONObject(raw: string): Record<string, unknown> | null {
  const a = raw.indexOf("{"), b = raw.lastIndexOf("}");
  if (a < 0 || b <= a) return null;
  try {
    const v = JSON.parse(raw.slice(a, b + 1));
    return v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : null;
  } catch (_) { return null; }
}

/** What the model sees on a re-ask: its output, why it failed, the request again. */
export function healPrompt(original: string, raw: string, reason: string): string {
  return `Your previous response failed validation. Here is what went wrong.\n\n` +
    `Previous output:\n${raw || "(no text)"}\n\n` +
    `Validation errors:\n${reason}\n\n` +
    `Reply again, corrected, in exactly the shape the original request asks for ` +
    `and nothing else.\n\n` +
    `Original request:\n${original}`;
}

const UNREADABLE = "the reply carried nothing readable in the required shape";

export async function conform<C, R>(c: Conform<C, R>): Promise<R> {
  const retries = c.retries ?? DEFAULT_RETRIES;
  const heal = c.heal || healPrompt;
  let user = c.user, last: C | null = null;
  for (let attempt = 0; ; attempt++) {
    let raw: string;
    try { raw = String((await c.ask(c.system, user)) || ""); }
    catch (_) { return c.floor(last); }                 // transport: floor, no retry
    const candidate = c.read(raw);
    const reason = candidate === null ? UNREADABLE : await c.check(candidate);
    if (reason === null) return c.accept(candidate as C);
    if (candidate !== null) last = candidate;
    if (attempt >= retries) return c.floor(last);
    user = heal(c.user, raw, reason);
  }
}
