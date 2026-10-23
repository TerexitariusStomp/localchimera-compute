// SPDX-License-Identifier: AGPL-3.0-or-later
// SQLite-backed corpus store: chunks + FTS5 keyword index + float32 vectors.
//
// Uses node:sqlite (built into Node 22+), so the whole retrieval layer has
// exactly one npm dependency (the embedding runtime) and nothing else.
//
// Vectors live as raw float32 BLOBs rather than in a vector extension: a
// book-scale corpus is tens of thousands of chunks, and a brute-force dot
// product over normalized vectors at that size costs single-digit
// milliseconds — well under the cost of embedding the query itself.

import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

const SCHEMA = `
CREATE TABLE IF NOT EXISTS sources (
  slug        TEXT PRIMARY KEY,
  title       TEXT NOT NULL,
  author      TEXT,
  year        TEXT,
  license     TEXT,
  url         TEXT,
  sha256      TEXT,
  path        TEXT,
  lines       INTEGER,
  indexed_at  TEXT
);

CREATE TABLE IF NOT EXISTS chunks (
  id          INTEGER PRIMARY KEY,
  source      TEXT NOT NULL REFERENCES sources(slug) ON DELETE CASCADE,
  ord         INTEGER NOT NULL,
  heading     TEXT,
  line_start  INTEGER NOT NULL,
  line_end    INTEGER NOT NULL,
  text        TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS chunks_by_source ON chunks(source, ord);

CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
  text, heading,
  content='chunks', content_rowid='id', tokenize='porter unicode61'
);

CREATE TABLE IF NOT EXISTS vectors (
  chunk_id    INTEGER PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
  vec         BLOB NOT NULL
);

CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
`;

export function openStore(path) {
  mkdirSync(dirname(path), { recursive: true });
  const db = new DatabaseSync(path);
  db.exec('PRAGMA journal_mode = WAL');
  db.exec('PRAGMA foreign_keys = ON');
  db.exec(SCHEMA);
  return db;
}

export function setMeta(db, key, value) {
  db.prepare('INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value')
    .run(key, String(value));
}

export function getMeta(db, key) {
  return db.prepare('SELECT value FROM meta WHERE key=?').get(key)?.value ?? null;
}

/** Drop a source and everything derived from it, so re-indexing is idempotent. */
export function dropSource(db, slug) {
  const ids = db.prepare('SELECT id FROM chunks WHERE source=?').all(slug).map((r) => r.id);
  const delFts = db.prepare("INSERT INTO chunks_fts(chunks_fts, rowid, text, heading) VALUES('delete', ?, ?, ?)");
  const get = db.prepare('SELECT id, text, heading FROM chunks WHERE id=?');
  for (const id of ids) {
    const row = get.get(id);
    if (row) delFts.run(row.id, row.text, row.heading ?? '');
  }
  db.prepare('DELETE FROM vectors WHERE chunk_id IN (SELECT id FROM chunks WHERE source=?)').run(slug);
  db.prepare('DELETE FROM chunks WHERE source=?').run(slug);
  db.prepare('DELETE FROM sources WHERE slug=?').run(slug);
}

export function putSource(db, src) {
  db.prepare(`INSERT INTO sources(slug,title,author,year,license,url,sha256,path,lines,indexed_at)
              VALUES(?,?,?,?,?,?,?,?,?,?)`)
    .run(src.slug, src.title, src.author ?? null, src.year ?? null, src.license ?? null,
         src.url ?? null, src.sha256 ?? null, src.path ?? null, src.lines ?? 0,
         new Date().toISOString());
}

/** Insert chunks, mirroring each into the FTS index. Returns the new row ids. */
export function putChunks(db, slug, chunks) {
  const ins = db.prepare(
    'INSERT INTO chunks(source,ord,heading,line_start,line_end,text) VALUES(?,?,?,?,?,?)');
  const fts = db.prepare(
    'INSERT INTO chunks_fts(rowid, text, heading) VALUES(?,?,?)');
  const ids = [];
  db.exec('BEGIN');
  try {
    for (const c of chunks) {
      const info = ins.run(slug, c.ord, c.heading ?? '', c.lineStart, c.lineEnd, c.text);
      const id = Number(info.lastInsertRowid);
      fts.run(id, c.text, c.heading ?? '');
      ids.push(id);
    }
    db.exec('COMMIT');
  } catch (e) {
    db.exec('ROLLBACK');
    throw e;
  }
  return ids;
}

export function putVectors(db, pairs) {
  const ins = db.prepare('INSERT OR REPLACE INTO vectors(chunk_id, vec) VALUES(?,?)');
  db.exec('BEGIN');
  try {
    for (const [id, vec] of pairs) {
      ins.run(id, Buffer.from(new Float32Array(vec).buffer));
    }
    db.exec('COMMIT');
  } catch (e) {
    db.exec('ROLLBACK');
    throw e;
  }
}

/** All vectors, as one packed Float32Array plus a parallel id array. */
export function loadVectors(db, dim) {
  const rows = db.prepare('SELECT chunk_id, vec FROM vectors ORDER BY chunk_id').all();
  const ids = new Int32Array(rows.length);
  const mat = new Float32Array(rows.length * dim);
  rows.forEach((row, i) => {
    ids[i] = row.chunk_id;
    const v = new Float32Array(row.vec.buffer, row.vec.byteOffset, dim);
    mat.set(v, i * dim);
  });
  return { ids, mat, count: rows.length };
}

export function getChunks(db, ids) {
  if (!ids.length) return [];
  const holes = ids.map(() => '?').join(',');
  const rows = db.prepare(
    `SELECT c.*, s.title, s.author, s.license FROM chunks c
     JOIN sources s ON s.slug = c.source WHERE c.id IN (${holes})`).all(...ids);
  const byId = new Map(rows.map((r) => [r.id, r]));
  return ids.map((id) => byId.get(id)).filter(Boolean);
}

export function stats(db) {
  const sources = db.prepare(
    `SELECT s.slug, s.title, s.license, s.lines,
            (SELECT COUNT(*) FROM chunks c WHERE c.source = s.slug) AS chunks
     FROM sources s ORDER BY s.slug`).all();
  const vectors = db.prepare('SELECT COUNT(*) AS n FROM vectors').get().n;
  return { sources, vectors, model: getMeta(db, 'embedding_model'), dim: Number(getMeta(db, 'embedding_dim')) };
}
