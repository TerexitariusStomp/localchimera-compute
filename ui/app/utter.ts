// app/utter.ts — one sentence, read into the dial's two primitives.
//
// Everything a citizen does on the dial is one of two things: MOVE THE LOCUS
// (where the reader stands — a face, a place, an instant) or RECORD AN ACT (a
// need, an offer, a log entry — always through the ➕, always signed). So every
// input — typed, spoken, a tapped button, a shared link — is one sentence:
//
//     utterance := [locus-delta] [act]
//
// with HOLES: whatever coordinate the sentence leaves unsaid is filled from
// where the reader already stands. "garden friday" moves the locus and records
// nothing; "need flour" records an act here and now; "offer bike at the park
// saturday" does both. The readings this module returns are the ways of
// filling the holes, ranked — the dropdown IS the disambiguation.
//
// ── THE FLOOR IS DETERMINISTIC ──────────────────────────────────────────────
// Recognisers consume tokens coordinate by coordinate — a bang (`!map`), a
// face word, a date or clock time or weekday, a known place name, a quantity
// with its unit, a verb cue. What survives is the RESIDUAL, and the residual
// is the act's name. A sentence with no residual never needs a model; the AI
// pass (day/extract.ts) is a further resolver over the residual only, and it
// returns readings of this same shape — it never gets to invent a verb.
//
// ── LOCUS MOVES ARE FREE; ACTS COST A ➕ ─────────────────────────────────────
// A reading whose verb is `go` or `face` runs on Enter, with nothing written.
// A reading that carries an act fills the pill and still waits for the ➕: the
// fuzzy half may be aggressive precisely because it cannot write by itself.
//
// Pure: every fact it reads — the faces, the places, the specs, the units, the
// clock — arrives in the context, so the parser runs the same under node
// (tests/browser/utter-test.mjs) as in the page.

import type { SlotKind } from './slots/model.js';
import { bestMatch, bestMatchInText } from './fuzzy.js';

export interface UtterFace { id: string; label: string; aliases?: string[] }
export interface UtterPlace { id: string; name: string; lat?: number; lng?: number }
export interface UtterUnit { id: string; label: string }
export interface UtterScope { id: string; name: string }
export interface UtterContext {
  faces: UtterFace[];
  places: UtterPlace[];
  /** spec id → human label; a residual that names one is a known spec */
  specs: Map<string, string>;
  units: UtterUnit[];
  /** the scopes a citizen can stand in — the breadcrumb's own list */
  scopes?: UtterScope[];
  /** the rail that is lit — the default verb for a bare act */
  rail: SlotKind;
  /** local "now" — weekdays and "tomorrow" resolve against it */
  now: Date;
}

/** A coordinate of the reader's standing. Absent = the hole stays filled from here. */
export interface LocusDelta {
  face?: string;
  place?: UtterPlace;
  /** civil ISO — a date, or a date with a time when `hasTime` */
  instant?: { iso: string; hasTime: boolean; label: string };
  /** the scope to stand in — "our needs in Cascadia", "the Berlin commune" */
  scope?: UtterScope;
}
export interface ActDelta {
  kind: SlotKind | "log";
  name: string;
  qty?: number;
  unit?: string;
  spec?: string;
}
export type Verb = "go" | "face" | "need" | "offer" | "log" | "web" | "search";
export interface Reading {
  verb: Verb;
  locus: LocusDelta;
  act?: ActDelta;
  /** the words no recogniser claimed */
  residual: string;
  /** 0..1 — how much of the sentence this reading accounts for, and how explicitly */
  score: number;
  /** one line, as the preview shows it */
  label: string;
  /** a web search — the query, carried only on an EXPLICIT bang */
  query?: string;
  /** set by the bar when this reading came from the AI normalizer's rewrite,
   *  not the deterministic floor — utter.ts itself never sets this */
  ai?: boolean;
}

// ── tokens ──────────────────────────────────────────────────────────────────
const DAYS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
const DAY_SHORT = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
const two = (n: number): string => (n < 10 ? "0" : "") + n;
const isoDate = (d: Date): string => `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())}`;
const norm = (s: string): string => s.toLowerCase().replace(/[’']/g, "'").replace(/\s+/g, " ").trim();

// the recognisers work on one lowercase string and blank out what they take,
// so the residual falls out as whatever is left standing
interface Scan { text: string; taken: string[] }
// every match is offered in turn until the recogniser accepts one — "3 hours
// … 2pm" holds two numbers, and only the second is a time
const take = (sc: Scan, re: RegExp, on: (m: RegExpMatchArray) => boolean | void): void => {
  const g = new RegExp(re.source, re.flags.includes("g") ? re.flags : re.flags + "g");
  for (const m of sc.text.matchAll(g)) {
    if (m.index == null) continue;
    if (on(m) === false) continue;
    sc.taken.push(m[0].trim());
    sc.text = (sc.text.slice(0, m.index) + " " + sc.text.slice(m.index + m[0].length)).replace(/\s+/g, " ").trim();
    return;
  }
};
// the longest name first, so "community garden" beats "garden"
const byLength = <T extends { name?: string; label?: string }>(xs: T[]): T[] =>
  [...xs].sort((a, b) => ((b.name || b.label || "").length - (a.name || a.label || "").length));

// removes a fuzzy hit's WORD SPAN from the scan the same way take() removes a
// regex match — exact about what is consumed, even though the match that
// found it was approximate (app/fuzzy.ts bestMatchInText)
function consumeSpan(sc: Scan, span: [number, number]): void {
  const words = sc.text.split(/\s+/).filter(Boolean);
  sc.taken.push(words.slice(...span).join(" "));
  sc.text = [...words.slice(0, span[0]), ...words.slice(span[1])].join(" ").trim() + " ";
}
const escapeRe = (s: string): string => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// ── the coordinates ────────────────────────────────────────────────────────
// ONE recogniser underlies faces, scopes and places: a candidate NAME, tried
// exactly (optionally between a PREFIX alternation — "at"/"in"/"show me" —
// and a SUFFIX one — "face"/"commune"), and — the exact phrasing failing —
// via the same fuzzy primitive every candidate list falls back to
// (app/fuzzy.ts bestMatchInText), so a typo or mishearing of a face word
// resolves exactly as readily as one of a place or scope. WORDS narrows which
// candidates are even tried (faces split multi-/single-word candidates —
// see readFaceStrong/Weak below); omitted, every candidate is tried.
interface NamedCandidate<T> { name: string; value: T }
function readNamed<T>(
  sc: Scan, candidates: NamedCandidate<T>[],
  opts: { prefix?: string; suffix?: string; words?: "multi" | "single" } = {},
): T | undefined {
  const pre = opts.prefix ? `(?:(?:${opts.prefix})\\s+)?` : "";
  const suf = opts.suffix ? `(?:\\s+(?:${opts.suffix}))?` : "";
  const pool = opts.words
    ? candidates.filter(c => c.name.includes(" ") === (opts.words === "multi"))
    : candidates;
  for (const c of byLength(pool)) {
    if (!c.name) continue;
    let hit = false;
    take(sc, new RegExp(`(^|\\s)${pre}(?:the\\s+)?${escapeRe(norm(c.name))}${suf}(?=\\s|$)`, "i"),
         () => { hit = true; });
    if (hit) return c.value;
  }
  const fz = bestMatchInText(sc.text, pool);
  if (fz) { consumeSpan(sc, fz.span); return fz.value; }
  return undefined;
}

// bang ("!map") is unambiguous on its own — no ordinary act ever contains a
// "!" — and always tried, even before the cue runs.
function readFaceBang(sc: Scan, ctx: UtterContext): string | undefined {
  let face: string | undefined;
  take(sc, /(^|\s)!([a-z]+)(?=\s|$)/, m => {
    const f = ctx.faces.find(f => f.id === m[2] || f.label === m[2] || (f.aliases || []).includes(m[2]));
    if (!f) return false;
    face = f.id;
  });
  return face;
}
const faceNames = (ctx: UtterContext): NamedCandidate<string>[] =>
  ctx.faces.flatMap(f => [f.label, f.id, ...(f.aliases || [])].filter(Boolean).map(name => ({ name, value: f.id })));
const FACE_PREFIX = "show(?: me)?|open|go to|goto|to";
const FACE_SUFFIX = "face|view|tab";

// a multi-word alias ("the captain's log", "the map") is unambiguous — a
// specific PHRASE naming a face is a much stronger signal than a cue word
// sharing one of its words ("captain's log" vs. the bare verb "log"). Tried
// before the cue even runs, so it never loses a word to it.
function readFaceStrong(sc: Scan, ctx: UtterContext): string | undefined {
  return readFaceBang(sc, ctx) ?? readNamed(sc, faceNames(ctx), { prefix: FACE_PREFIX, suffix: FACE_SUFFIX, words: "multi" });
}

// A single-word label/id/alias is also an ordinary English word too often —
// "log", "shop", "plan", "match" — that a real act's name might contain ("a
// log for the fire"). Run only when nothing has yet claimed a verb (a bare
// "log" navigates) or the cue itself IS "go" ("go to log"); once need/offer/
// log has fired, every remaining word belongs to the act's name.
function readFaceWeak(sc: Scan, ctx: UtterContext): string | undefined {
  return readNamed(sc, faceNames(ctx), { prefix: FACE_PREFIX, suffix: FACE_SUFFIX, words: "single" });
}

function readScope(sc: Scan, ctx: UtterContext, allowBare: boolean): UtterScope | undefined {
  // same reasoning as readFace's ALLOWBARE: a scope's name is prose too, and
  // must not fragment an act's name once a need/offer/log cue has fired
  if (!allowBare) return undefined;
  return readNamed(sc, (ctx.scopes || []).map(s => ({ name: s.name, value: s })),
                   { prefix: "in|at|for", suffix: "commune" });
}

function readPlace(sc: Scan, ctx: UtterContext): UtterPlace | undefined {
  return readNamed(sc, ctx.places.map(p => ({ name: p.name, value: p })),
                   { prefix: "at|in|to|near|around" });
}

function readInstant(sc: Scan, ctx: UtterContext): LocusDelta["instant"] | undefined {
  const now = ctx.now;
  let date: Date | null = null, dateLabel = "";
  let time: { h: number; m: number } | null = null;
  // a civil date
  take(sc, /(^|\s)(\d{4})-(\d{2})-(\d{2})(?=\s|$)/, m => {
    date = new Date(+m[2], +m[3] - 1, +m[4]); dateLabel = m[0].trim();
  });
  // today · tomorrow · tonight
  if (!date) take(sc, /(^|\s)(today|tonight|tomorrow)(?=\s|$)/, m => {
    date = new Date(now.getFullYear(), now.getMonth(), now.getDate() + (m[2] === "tomorrow" ? 1 : 0));
    dateLabel = m[2];
    if (m[2] === "tonight") time = { h: 20, m: 0 };
  });
  // a weekday — the next one, this one if today still is
  if (!date) take(sc, new RegExp(`(^|\\s)(?:(?:on|next|this)\\s+)?(${[...DAYS, ...DAY_SHORT].join("|")})(?=\\s|$)`), m => {
    const i = Math.max(DAYS.indexOf(m[2]), DAY_SHORT.indexOf(m[2]));
    const d = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const ahead = (i - d.getDay() + 7) % 7;
    d.setDate(d.getDate() + ahead);
    date = d; dateLabel = DAYS[i];
  });
  // a clock time: 14:30 · 2pm · 2:30 pm · at 9
  take(sc, /(^|\s)(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?(?=\s|$)/, m => {
    const hasMark = !!m[3] || !!m[4];
    const hasAt = /(^|\s)at\s+\d/.test(m[0]);
    if (!hasMark && !hasAt) return false;          // a bare number is a quantity, not a time
    let h = +m[2]; const mm = +(m[3] || 0);
    if (m[4] === "pm" && h < 12) h += 12;
    if (m[4] === "am" && h === 12) h = 0;
    if (h > 23 || mm > 59) return false;
    time = { h, m: mm };
  });
  if (!date && !time) return undefined;
  const d: Date = date || new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const t = time as { h: number; m: number } | null;
  const iso = isoDate(d) + (t ? `T${two(t.h)}:${two(t.m)}` : "");
  const label = [dateLabel || (t ? "today" : ""), t ? `${two(t.h)}:${two(t.m)}` : ""].filter(Boolean).join(" ");
  return { iso, hasTime: !!t, label };
}

function readQuantity(sc: Scan, ctx: UtterContext): { qty: number; unit: string } | undefined {
  let out: { qty: number; unit: string } | undefined;
  const units = byLength(ctx.units.map(u => ({ ...u, name: u.label })));
  const alt = units.flatMap(u => [u.label, u.id]).filter(Boolean).map(escapeRe).join("|");
  take(sc, new RegExp(`(^|\\s)(\\d+(?:[.,]\\d+)?)\\s*(${alt})(?=\\s|$)`, "i"), m => {
    const u = ctx.units.find(u => u.label.toLowerCase() === m[3].toLowerCase() || u.id.toLowerCase() === m[3].toLowerCase());
    out = { qty: parseFloat(m[2].replace(",", ".")), unit: u ? u.id : m[3] };
  });
  if (out) return out;
  // a bare count: "3 loaves" — the number with the word after it as the unit
  take(sc, /(^|\s)(\d+(?:[.,]\d+)?)(?=\s|$)/, m => { out = { qty: parseFloat(m[2].replace(",", ".")), unit: "" }; });
  return out;
}

type Cue = "need" | "offer" | "log" | "go" | "search";
function readCue(sc: Scan): Cue | undefined {
  let cue: Cue | undefined;
  take(sc, /(^|\s)(i\s+)?(need|needs|want|wants|looking for|we need|require)(?=\s|$)/, () => { cue = "need"; });
  if (cue) return cue;
  take(sc, /(^|\s)(i\s+)?(offer|offering|can give|can do|have spare|to share|available|lend|can lend)(?=\s|$)/, () => { cue = "offer"; });
  if (cue) return cue;
  take(sc, /(^|\s)(log|note|record|did|worked on|remember)(?=\s|$)/, () => { cue = "log"; });
  if (cue) return cue;
  take(sc, /(^|\s)(go|take me|show me|where is|navigate)(?=\s|$)/, () => { cue = "go"; });
  if (cue) return cue;
  // the corpus's own verb — an explicit imperative ("search", "look up")
  // or a bare question word ("what fixes nitrogen", "how deep should a
  // swale be"). Checked LAST, after every economy/navigation cue: "how much
  // flour do I need" hits the "need" cue first and stays a need, exactly as
  // it should — a question word only wins when nothing more specific fired.
  take(sc, /(^|\s)(search|look\s?up|find out|research)(?=\s|$)/, () => { cue = "search"; });
  if (cue) return cue;
  take(sc, /(^|\s)(what|how|why|which)(?=\s|$)/, () => { cue = "search"; });
  return cue;
}

// ── the readings ───────────────────────────────────────────────────────────
const fmtAct = (a: ActDelta): string =>
  `${a.kind === "need" ? "🌱 need" : a.kind === "capacity" ? "🤲 offer" : "📓 log"}: ${a.name}`
  + (a.qty != null ? ` · ${a.qty}${a.unit ? " " + a.unit : ""}` : "");
const fmtLocus = (l: LocusDelta, faces: UtterFace[]): string =>
  [l.face ? `◉ ${(faces.find(f => f.id === l.face) || { label: l.face }).label}` : "",
   l.scope ? `⊕ ${l.scope.name}` : "",
   l.place ? `📍 ${l.place.name}` : "",
   l.instant ? `🕐 ${l.instant.label}` : ""].filter(Boolean).join(" · ");

/**
 * Read TEXT into ranked readings — the first is the one Enter takes. Never
 * empty for a non-empty sentence: the last resort is the lit rail's act with
 * the whole sentence as its name, which is what the bar always did.
 */
export function parse(text: string, ctx: UtterContext): Reading[] {
  const raw = norm(text);
  if (!raw) return [];
  const sc: Scan = { text: " " + raw + " ", taken: [] };
  // an explicit web bang owns the whole sentence: nothing else is read out of it
  let webQuery: string | null = null;
  take(sc, /(^|\s)!(ddg|web|w)(?=\s|$)/, () => { webQuery = sc.text.replace(/(^|\s)!(ddg|web|w)(?=\s|$)/, "").trim(); });
  if (webQuery !== null) {
    return [{ verb: "web", locus: {}, residual: "", score: 1, query: webQuery,
              label: `🌐 web: ${webQuery || "…"}` }];
  }
  const strongFace = readFaceStrong(sc, ctx);
  const cue = readCue(sc);
  // captured right after the cue phrase alone is removed — a search
  // QUESTION wants every real word kept ("what grows well in Cascadia"
  // should search "Cascadia" too), unlike an act or a locus move, where a
  // recognised place/scope/face is pulled OUT into its own coordinate
  const afterCue = sc.text;
  const allowBare = !cue || cue === "go";
  const face = strongFace || (allowBare ? readFaceWeak(sc, ctx) : undefined);
  const scope = readScope(sc, ctx, allowBare);
  const place = readPlace(sc, ctx);
  const instant = readInstant(sc, ctx);
  const q = readQuantity(sc, ctx);
  const locus: LocusDelta = { ...(face ? { face } : {}), ...(scope ? { scope } : {}),
                              ...(place ? { place } : {}), ...(instant ? { instant } : {}) };
  const hasLocus = !!(face || scope || place || instant);
  // articles and joiners left over from the phrases above carry no meaning
  const stripped = sc.text.replace(/(^|\s)(a|an|the|some|of|for|at|in|on|to|and|me|please)(?=\s|$)/g, " ")
                          .replace(/\s+/g, " ").trim();
  // a cue word ("search", "need", "offer", "go") that ate the WHOLE
  // sentence, with no locus and nothing else left, is indistinguishable
  // from "this word IS the thing being named" — a bare "search" can't
  // sensibly search for nothing. Falling back to the untouched RAW text
  // here (rather than the cue-consumed empty string) restores parse()'s
  // own documented contract — never empty for a non-empty sentence — by
  // routing through the SAME multi-ranked-reading fallback below that any
  // ordinary unrecognised word already gets, rather than a special case.
  const residual = (stripped || hasLocus || !cue) ? stripped : raw;
  const words = raw.split(" ").length;
  const claimed = Math.min(1, sc.taken.join(" ").split(" ").filter(Boolean).length / words);

  const out: Reading[] = [];
  const push = (r: Reading) => { if (!out.some(o => o.label === r.label)) out.push(r); };
  const knownSpec = (name: string): string | undefined => {
    const n = name.toLowerCase();
    for (const [id, label] of ctx.specs) if (label.toLowerCase() === n || id.toLowerCase() === n) return id;
    // the residual is already isolated to one name (not a sentence to search
    // within), so the plain, un-windowed fuzzy match is the right primitive
    const fz = bestMatch(name, [...ctx.specs].map(([id, label]) => ({ name: label, value: id })));
    return fz?.value;
  };
  const act = (kind: SlotKind | "log", score: number): Reading => {
    const a: ActDelta = { kind, name: residual, ...(q ? { qty: q.qty, ...(q.unit ? { unit: q.unit } : {}) } : {}) };
    const spec = kind !== "log" ? knownSpec(residual) : undefined;
    if (spec) a.spec = spec;
    return { verb: kind === "need" ? "need" : kind === "capacity" ? "offer" : "log",
             locus, act: a, residual, score: score + (spec ? 0.1 : 0),
             label: [fmtAct(a), fmtLocus(locus, ctx.faces)].filter(Boolean).join("  ·  ") };
  };
  const go = (score: number): Reading => ({
    verb: (face || scope) && !place && !instant ? "face" : "go", locus, residual, score,
    label: `${(face || scope) && !place && !instant ? "◉ open" : "🗺 go"}: ${fmtLocus(locus, ctx.faces)}`,
  });
  const searchQuery = afterCue
    .replace(/(^|\s)(a|an|the|some|of|for|please)(?=\s|$)/g, " ")
    .replace(/\s+/g, " ").trim();
  const search = (score: number): Reading => ({
    verb: "search", locus: {}, residual: searchQuery, score, query: searchQuery,
    label: `🔎 search: ${searchQuery}`,
  });

  // an explicit cue names the verb
  if (cue === "go" && hasLocus) push(go(0.9 + claimed * 0.1));
  if (cue === "search" && searchQuery) push(search(0.9));
  if (cue === "need" && residual) push(act("need", 0.85 + claimed * 0.1));
  if (cue === "offer" && residual) push(act("capacity", 0.85 + claimed * 0.1));
  if (cue === "log" && residual) push(act("log", 0.85));
  // no residual: the sentence IS a locus — moving is the reading
  if (hasLocus && !residual) push(go(0.8 + claimed * 0.2));
  // residual + the lit rail: the act the bar always meant, with the locus folded in
  if (residual) {
    push(act(ctx.rail, hasLocus ? 0.6 : 0.5));
    push(act(ctx.rail === "need" ? "capacity" : "need", 0.3));
    push(act("log", 0.2));
  }
  // a locus beside an act is also, on its own, somewhere to go
  if (hasLocus && residual) push(go(0.4));
  return out.sort((a, b) => b.score - a.score);
}

/** The faces as the parser reads them — the nav bar's words and a few spoken aliases. */
export const FACE_WORDS: UtterFace[] = [
  { id: "map",      label: "map",        aliases: ["earth", "the map"] },
  { id: "cal",      label: "calendar",   aliases: ["cal", "week", "schedule"] },
  { id: "time",     label: "clock",      aliases: ["dial", "the clock", "turn"] },
  { id: "plan",     label: "plan",       aliases: ["the plan", "coverage"] },
  { id: "shop",     label: "shop",       aliases: ["order book", "claim", "claims"] },
  { id: "store",    label: "store",      aliases: ["stock", "inventory", "pantry", "what is held"] },
  { id: "family",   label: "family",     aliases: ["purse", "household"] },
  { id: "match",    label: "match",      aliases: ["ring", "matches"] },
  { id: "log",      label: "log",        aliases: ["captain's log", "journal"] },
  { id: "law",      label: "law",        aliases: ["legal"] },
  { id: "frag",     label: "constraints", aliases: ["fragility", "fragilities", "wheel"] },
  { id: "eco",      label: "ecology",    aliases: ["ecological", "bioregion"] },
  { id: "rift",     label: "matter",     aliases: ["metabolism", "rift"] },
  { id: "forum",    label: "forum", aliases: ["governance", "proposals", "votes", "inbox"] },
  { id: "recipes",  label: "recipes",    aliases: ["recipe", "library"] },
  { id: "corpus",   label: "corpus",     aliases: ["the corpus", "literature", "sources", "the archive"] },
  { id: "taxonomy", label: "taxonomy",   aliases: ["spine", "folksonomy"] },
];
