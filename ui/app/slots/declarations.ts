// app/slots/declarations.ts — the scope's three declarations, as the cards speak them
//
// A scope makes three signed statements about itself (federation-flow-map.md
// §7.4), each spoken by one of its governors and read by the solve where it
// lies: where a resource's service pool STANDS (a span declaration), what the
// scope will HOST and up to how much (hosting willingness — the consent a
// foreign span into its places needs, and the ceiling the means consensus
// binds), and what REGIME a recipe's domain is in (a regime claim — thin
// tails and a stable process together license statistics in that domain's
// standing; anything else reads probability-free). The seam doors are
// declareSpan, declareHosting and claimRegime; this module holds what the
// three cards share and what is pure enough to pin in a test: the choices, the
// reading of a regime, the ceiling's parse, the reply's reading and the
// sentences the cards read back.

export const REGIME_TAILS = ["thin", "fat", "unknown"] as const;
export const REGIME_PROCESS = ["stable", "shifting", "unknown"] as const;
/** The word a regime claim starts from on both axes: nothing claimed yet. */
export const REGIME_UNSAID = "unknown";
export type Tails = typeof REGIME_TAILS[number];
export type Process = typeof REGIME_PROCESS[number];

/** What a regime claim licenses: statistics under thin tails AND a stable process, probability-free reading otherwise (recipe-standing.md). */
export function regimeReads(tails: string, process: string): "statistics" | "probability-free" {
  return tails === "thin" && process === "stable" ? "statistics" : "probability-free";
}

/** A hosting ceiling as typed: a positive finite number of unit-hours a day, or null. */
export function ceilingOf(raw: string | number): number | null {
  const n = typeof raw === "number" ? raw : parseFloat(String(raw).trim());
  return Number.isFinite(n) && n > 0 ? n : null;
}

/** A door's reply read for the card: "" when the declaration stands ("ok"), else the refusal's text with the wire's "err:" prefix dropped. */
export function declarationReply(reply: unknown): string {
  if (reply === "ok") return "";
  const s = String(reply == null ? "refused" : reply).replace(/^err:/, "").trim();
  return s || "refused";
}

/**
 * A declaration's word read back for its card: the door's reply resolved to
 * `ok` and the text to show — the sentence that now stands, or the refusal.
 * The three cards share this one reading, so a refusal looks the same on
 * each and a success always reads as the act it was.
 */
export function spoken(reply: Promise<unknown>, said: string): Promise<{ ok: boolean; text: string }> {
  return reply.then(r => {
    const refusal = declarationReply(r);
    return refusal ? { ok: false, text: refusal } : { ok: true, text: `declared — ${said}` };
  }, e => ({ ok: false, text: declarationReply(e instanceof Error ? e.message : String(e)) }));
}

export function hostingSentence(scope: string, spec: string, ceiling: number): string {
  return `${scope} hosts pools of ${spec} up to ${ceiling} unit-hour${ceiling === 1 ? "" : "s"} a day`;
}

export function spanSentence(name: string, place: string): string {
  return `the ${name} pool stands at ${place}`;
}

export function regimeSentence(recipe: string, tails: string, process: string): string {
  return `${recipe}: ${tails} tails, ${process} process — reads ${regimeReads(tails, process)}`;
}
