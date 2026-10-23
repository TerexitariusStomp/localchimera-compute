// SPDX-License-Identifier: AGPL-3.0-or-later
// Hybrid retrieval: dense (cosine over normalized embeddings) fused with
// sparse (SQLite FTS5/BM25) by reciprocal rank fusion.
//
// The hybrid is the point. Dense retrieval alone smears exact tokens — a query
// for "34.3 g/kg" or "Tithonia diversifolia" drifts to semantically-adjacent
// prose and silently misses the table that holds the number. BM25 alone misses
// "closing the nutrient loop" when the book says "returning residues to soil".
// Agronomy texts need both: they are half concept, half exact quantity.

import { loadVectors, getChunks } from './store.mjs';
import { embedQuery } from './embed.mjs';

const RRF_K = 60;

export async function search(db, emb, query, opts = {}) {
  const limit = opts.limit ?? 8;
  const pool = opts.pool ?? Math.max(40, limit * 6);
  const sourceFilter = opts.source ?? null;

  const dense = await denseSearch(db, emb, query, pool);
  const sparse = sparseSearch(db, query, pool);

  const scores = new Map();
  const note = (ids, key) => {
    ids.forEach((id, rank) => {
      const e = scores.get(id) ?? { id, rrf: 0 };
      e.rrf += 1 / (RRF_K + rank + 1);
      e[key] = rank + 1;
      scores.set(id, e);
    });
  };
  note(dense.map((d) => d.id), 'denseRank');
  note(sparse.map((s) => s.id), 'sparseRank');

  const denseScore = new Map(dense.map((d) => [d.id, d.score]));
  let ranked = [...scores.values()].sort((a, b) => b.rrf - a.rrf);

  const rows = getChunks(db, ranked.map((r) => r.id));
  let hits = rows.map((row) => {
    const s = scores.get(row.id);
    return {
      ...row,
      rrf: s.rrf,
      similarity: denseScore.get(row.id) ?? null,
      denseRank: s.denseRank ?? null,
      sparseRank: s.sparseRank ?? null,
    };
  });
  if (sourceFilter) hits = hits.filter((h) => h.source === sourceFilter);
  return hits.slice(0, limit);
}

async function denseSearch(db, emb, query, k) {
  const { ids, mat, count } = loadVectors(db, emb.dim);
  if (!count) return [];
  const q = await embedQuery(emb, query);
  const dim = emb.dim;
  const scored = new Array(count);
  for (let i = 0; i < count; i++) {
    const base = i * dim;
    let dot = 0;
    for (let d = 0; d < dim; d++) dot += mat[base + d] * q[d];
    scored[i] = { id: ids[i], score: dot };
  }
  scored.sort((a, b) => b.score - a.score);
  return scored.slice(0, k);
}

function sparseSearch(db, query, k) {
  const match = toFtsQuery(query);
  if (!match) return [];
  try {
    return db.prepare(
      `SELECT rowid AS id, bm25(chunks_fts) AS score FROM chunks_fts
       WHERE chunks_fts MATCH ? ORDER BY score LIMIT ?`).all(match, k);
  } catch {
    return []; // a query that FTS5 rejects just means dense-only for this turn
  }
}

/** Quote every term so punctuation and numbers can't be read as FTS operators. */
function toFtsQuery(query) {
  const terms = query
    .toLowerCase()
    .split(/[^\p{L}\p{N}.\-/]+/u)
    .map((t) => t.replace(/^[.\-/]+|[.\-/]+$/g, ''))
    .filter((t) => t.length > 1 && !STOPWORDS.has(t));
  if (!terms.length) return null;
  return terms.map((t) => `"${t.replace(/"/g, '')}"`).join(' OR ');
}

const STOPWORDS = new Set(
  ('a an the of for and or to in on at is are was were be been it its this that these those with '
   + 'from by as how what which when where why do does can could should would we you they i')
    .split(' '));
