// app/fuzzy.ts — one string-similarity primitive, reused everywhere a typed
// or misheard word must land on a KNOWN name (a spec, a place, a scope, a
// face) rather than fall through as if nothing were meant.
//
// One function, `bestMatch`, generic over whatever the caller is matching —
// specs, places, scopes all reduce to "a query string against a list of
// (key, name) candidates", so this is the one place that reduction lives,
// rather than three near-identical loops in app/utter.ts.
//
// ── THE ALGORITHM ────────────────────────────────────────────────────────
// Sørensen–Dice over character bigrams: cheap (no matrix, unlike Levenshtein),
// tolerant of transpositions and single-character typos ("mil"/"mill",
// "flor"/"flour"), and — with the substring bonus below — tolerant of a
// shortened or truncated word too ("the old mil" naming "the old mill").
// It is not phonetic (it will not catch "flour"/"flower" as a mishearing);
// that class of miss is what the AI normalizer (day/extract.ts `utter` pass)
// exists for, over the residual this module still fails to place.
//
// Pure and dependency-free, so it is exercised the same way parse() is:
// tests/browser/fuzzy-test.mjs, no DOM, no model, no network.

/** Character bigrams of a normalized string, with repeats counted (multiset). */
function bigrams(s: string): Map<string, number> {
  const m = new Map<string, number>();
  for (let i = 0; i < s.length - 1; i++) {
    const b = s.slice(i, i + 2);
    m.set(b, (m.get(b) || 0) + 1);
  }
  return m;
}

const norm = (s: string): string => s.toLowerCase().trim();

/**
 * How well QUERY names CANDIDATE, 0..1 — Sørensen–Dice over bigram
 * multisets: 2·|intersection| / (|a|+|b|), a bigram present twice in both
 * counting twice. Dice alone under-scores a short truncation against a long
 * candidate ("mil" against "the old mill"): it normalizes by the COMBINED
 * bigram count, so a short query's bigrams get diluted by a long
 * candidate's, however completely they're contained. When one string wholly
 * contains the other, the right question is instead the OVERLAP coefficient
 * — shared ÷ the SHORTER string's own bigram count, which reads as ~1
 * whenever the short one's bigrams are essentially a subset of the long
 * one's, independent of how long the long one is. Only taken when
 * containment actually holds, so two same-length but unrelated words never
 * borrow it ("flour"/"flower": neither contains the other, so Dice alone
 * stands, and correctly keeps them apart as the two distinct specs they are).
 *
 * The overlap boost is gated on the SHORTER side having at least 2 bigrams
 * (3+ characters): below that, "contains" stops being evidence of anything —
 * almost any 1-2 character fragment is a coincidental substring of some
 * longer string ("in" sits inside "capta-IN's log" purely by chance), so an
 * un-gated overlap coefficient would read that coincidence as a near-perfect
 * match. Plain Dice — which stays low for a genuinely unrelated pair however
 * short one side is — is what stands below the gate.
 */
export function similarity(query: string, candidate: string): number {
  const q = norm(query), c = norm(candidate);
  if (!q || !c) return 0;
  if (q === c) return 1;
  const ba = bigrams(q), bb = bigrams(c);
  const na = q.length - 1, nb = c.length - 1;
  if (na <= 0 || nb <= 0) return 0;
  let shared = 0;
  for (const [bg, ca] of ba) {
    const cb = bb.get(bg);
    if (cb) shared += Math.min(ca, cb);
  }
  const dice = (2 * shared) / (na + nb);
  const contains = Math.min(na, nb) >= 2 && (c.includes(q) || q.includes(c));
  // capped below 1: a containment match is strong, but true identity (the
  // q===c fast path above) must always outrank it — "bike" naming the exact
  // spec "bike" beats "bike" merely being a prefix of "bike repair".
  return contains ? Math.max(dice, Math.min(0.94, shared / Math.min(na, nb))) : dice;
}

export interface FuzzyCandidate<T> {
  /** what the query is compared against */
  name: string;
  value: T;
}
export interface FuzzyHit<T> {
  value: T;
  name: string;
  score: number;
}

// two candidates within this of each other are a TIE, not a winner and a
// runner-up — "garden" fits "community garden" and "city garden" equally,
// and guessing between two real, distinct places (by array order, arbitrarily)
// is worse than admitting the query doesn't single one out.
const TIE_MARGIN = 0.03;

/**
 * The best-scoring candidate for QUERY, or undefined when nothing clears
 * THRESHOLD (default 0.5 — high enough that unrelated short words rarely
 * collide, low enough that a real single-character typo or truncation still
 * clears it) OR when the top two are a tie (TIE_MARGIN) — an ambiguous
 * query resolves to nothing, not to whichever candidate happened to be
 * declared first.
 */
export function bestMatch<T>(
  query: string, candidates: FuzzyCandidate<T>[], threshold = 0.5,
): FuzzyHit<T> | undefined {
  let best: FuzzyHit<T> | undefined, secondScore = -1;
  for (const c of candidates) {
    const score = similarity(query, c.name);
    if (score >= threshold && (!best || score > best.score)) {
      if (best) secondScore = Math.max(secondScore, best.score);
      best = { value: c.value, name: c.name, score };
    } else if (best && score >= threshold) {
      secondScore = Math.max(secondScore, score);
    }
  }
  return best && best.score - secondScore < TIE_MARGIN ? undefined : best;
}

/**
 * BEST-MATCH-IN-TEXT — find CANDIDATES' names as an approximate SUBSTRING of
 * TEXT, not just against the whole of it: "need bricks at the old mil friday"
 * must find "the old mill" inside the sentence, not compare the sentence
 * whole. Slides a window of the candidate's own word-count (±1, so a
 * truncated or lengthened phrase still lines up) across TEXT's words and
 * scores each window the same way `similarity` does.
 *
 * Returns the best hit plus the WORD SPAN it occupies (start/end index into
 * TEXT.split(" ")), so a caller can remove exactly those words the way
 * `take()` removes a regex match — never approximate about what is consumed,
 * even though the match that found it was.
 */
export function bestMatchInText<T>(
  text: string, candidates: FuzzyCandidate<T>[], threshold = 0.5,
): (FuzzyHit<T> & { span: [number, number] }) | undefined {
  const words = text.split(/\s+/).filter(Boolean);
  let best: (FuzzyHit<T> & { span: [number, number] }) | undefined;
  let secondScore = -1;
  for (const c of candidates) {
    const n = c.name.split(/\s+/).filter(Boolean).length;
    // the candidate's OWN word count first: on a tied score, the window
    // shaped like the candidate wins over an adjacent width that happens
    // to tie it (a 2-word sub-window of a 3-word place can score exactly as
    // high as the full 3-word window once containment is in play).
    for (const w of [n, Math.max(1, n - 1), n + 1]) {
      if (w === 0) continue;
      for (let i = 0; i + w <= words.length; i++) {
        const window = words.slice(i, i + w).join(" ");
        const score = similarity(window, c.name);
        if (score < threshold) continue;
        if (!best || score > best.score) {
          // a later window of the SAME candidate at a tied score is not a
          // second opinion — it is one hit read twice at slightly different
          // widths — only a DIFFERENT candidate's score counts as a rival
          if (best && best.value !== c.value) secondScore = Math.max(secondScore, best.score);
          best = { value: c.value, name: c.name, score, span: [i, i + w] };
        } else if (best.value !== c.value) {
          secondScore = Math.max(secondScore, score);
        }
      }
    }
  }
  return best && best.score - secondScore < TIE_MARGIN ? undefined : best;
}
