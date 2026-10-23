// SPDX-License-Identifier: AGPL-3.0-or-later
// Leads: turn a corpus into a research work-list.
//
// Some sources are worth reading for their FACTS. Others are worth reading for
// what they tell you EXISTS — a documentary names a technique, a project, an
// organisation, and each name is a thread to pull in the primary literature
// where the buildable numbers actually live.
//
// This module treats a corpus as an index of leads rather than a source of
// data. It reports, for every term the profile declares and for candidate names
// it did not, how often the term appears, in which sources, and where to hear
// it said — so the output is a list of things to go and research, each with the
// citation that motivated it.
//
// The distinction matters for provenance: a fact discovered THROUGH a video and
// sourced FROM a manual should cite the manual, and record the video only as
// how it was found.

const STOP_PHRASE = new Set([
  'this', 'that', 'the', 'and', 'but', 'when', 'what', 'now', 'here', 'there',
  'they', 'we', 'you', 'it', 'so', 'if', 'how', 'why', 'united states',
  'today show', 'thousand years', 'state university', 'new york',
]);

/** Occurrences of a declared term, with a citation for the first few. */
export function findTerm(db, term, { examples = 2 } = {}) {
  const like = `%${term.toLowerCase()}%`;
  const rows = db.prepare(
    `SELECT c.id, c.source, c.heading, c.line_start, c.line_end, c.text
     FROM chunks c WHERE lower(c.text) LIKE ? ORDER BY c.source, c.ord`).all(like);

  const bySource = new Map();
  for (const r of rows) {
    if (!bySource.has(r.source)) bySource.set(r.source, []);
    bySource.get(r.source).push(r);
  }

  return {
    term,
    count: rows.length,
    sources: [...bySource.keys()],
    examples: rows.slice(0, examples).map((r) => ({
      source: r.source,
      lines: [r.line_start, r.line_end],
      where: locate(r.heading, r.text, term),
    })),
  };
}

/**
 * Capitalised multi-word names the profile has NOT declared — the leads you
 * did not know to look for. Deliberately crude: it is a suggestion list for a
 * human to triage, not an extraction claiming to be right.
 */
export function candidateNames(db, { declared = [], min = 3, limit = 30 } = {}) {
  const known = new Set(declared.map((d) => d.toLowerCase()));
  const rows = db.prepare('SELECT source, text FROM chunks').all();
  const counts = new Map();
  const seenIn = new Map();

  for (const r of rows) {
    const matches = r.text.match(/\b[A-Z][a-z]{2,}(?: [A-Z][a-z]{2,}){1,2}\b/g) ?? [];
    for (const m of matches) {
      const key = m.toLowerCase();
      if (STOP_PHRASE.has(key)) continue;
      if (known.has(key)) continue;
      // A name already covered by a declared term adds nothing.
      if ([...known].some((k) => key.includes(k))) continue;
      counts.set(key, (counts.get(key) ?? 0) + 1);
      if (!seenIn.has(key)) seenIn.set(key, new Set());
      seenIn.get(key).add(r.source);
      if (!counts.has(`display:${key}`)) counts.set(`display:${key}`, m);
    }
  }

  return [...counts.entries()]
    .filter(([k, v]) => !k.startsWith('display:') && v >= min)
    .sort((a, b) => b[1] - a[1])
    .slice(0, limit)
    .map(([k, n]) => ({
      name: counts.get(`display:${k}`) ?? k,
      count: n,
      sources: [...(seenIn.get(k) ?? [])],
    }));
}

/** A short locator: the heading, plus the nearest [mm:ss] marker before the hit. */
function locate(heading, text, term) {
  const idx = text.toLowerCase().indexOf(term.toLowerCase());
  const before = text.slice(0, idx < 0 ? 0 : idx);
  const stamps = before.match(/\[\d{2}:\d{2}\]/g);
  const stamp = stamps ? stamps[stamps.length - 1] : null;
  const video = (heading ?? '').match(/\[([\w-]{11})\]/);
  const title = (heading ?? '').split('>').pop()?.trim() ?? '';
  return {
    video: video ? video[1] : null,
    stamp: stamp ? stamp.slice(1, -1) : null,
    title,
    url: video && stamp ? youtubeAt(video[1], stamp.slice(1, -1)) : null,
  };
}

function youtubeAt(id, mmss) {
  const [m, s] = mmss.split(':').map(Number);
  return `https://www.youtube.com/watch?v=${id}&t=${m * 60 + s}`;
}
