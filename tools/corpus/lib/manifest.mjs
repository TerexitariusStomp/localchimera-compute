// Read the committed Scheme manifest / profile for a corpus domain.

import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readAll, field, fields, isSymbol, plain } from './sexp.mjs';

export const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
export const CORPUS_ROOT = join(REPO_ROOT, 'docs', 'corpus');

export const domainDir = (domain) => join(CORPUS_ROOT, domain);
export const dbPath = (domain) => join(domainDir(domain), '.index', 'corpus.db');
export const modelCache = () => join(CORPUS_ROOT, '.models');

export function loadManifest(domain) {
  const path = join(domainDir(domain), 'manifest.scm');
  if (!existsSync(path)) throw new Error(`no manifest for domain "${domain}" at ${path}`);
  const forms = readAll(readFileSync(path, 'utf8'));
  const top = forms.find((f) => Array.isArray(f) && isSymbol(f[0], 'corpus'));
  if (!top) throw new Error(`${path}: expected a top-level (corpus …) form`);

  const sources = fields(top, 'source').map((s) => {
    const slug = field(s, 'slug');
    const file = field(s, 'file') ?? join('texts', slug, 'source');
    return {
      slug,
      title: field(s, 'title') ?? slug,
      author: field(s, 'author') ?? null,
      year: field(s, 'year') != null ? String(field(s, 'year')) : null,
      license: field(s, 'license') ?? 'unknown',
      url: field(s, 'url') ?? null,
      // (urls "…" "…") — a chaptered document fetched as parts and joined in
      // order. Common for FAO/UN manuals published as one page per chapter.
      urls: (fields(s, 'urls')[0] ?? []).slice(1).map(plain),
      sha256: field(s, 'sha256') ?? null,
      note: field(s, 'note') ?? null,
      suppliedByUser: field(s, 'supplied-by-user') === true,
      // "document" (default) fetches a url; "youtube-playlist" pulls captions.
      kind: field(s, 'kind') ?? 'document',
      playlist: field(s, 'playlist') ?? null,
      file,
      path: join(domainDir(domain), file),
      textPath: join(domainDir(domain), 'texts', slug, 'text.md'),
    };
  });

  return {
    domain,
    title: field(top, 'title') ?? domain,
    description: field(top, 'description') ?? null,
    profile: field(top, 'profile') ?? 'profile.scm',
    sources,
  };
}

export function loadProfile(domain) {
  const manifest = loadManifest(domain);
  const path = join(domainDir(domain), manifest.profile);
  if (!existsSync(path)) return null;
  const forms = readAll(readFileSync(path, 'utf8'));
  const top = forms.find((f) => Array.isArray(f) && isSymbol(f[0], 'profile'));
  if (!top) throw new Error(`${path}: expected a top-level (profile …) form`);

  // (index (class "technique" (terms "zai" …)) …) — the vocabulary a corpus is
  // mined for LEADS rather than facts.
  const indexForm = fields(top, 'index')[0];
  const classes = indexForm
    ? fields(indexForm.slice(1), 'class').map((c) => ({
        name: plain(c[1]),
        description: field(c, 'description') ?? null,
        terms: (fields(c, 'terms')[0] ?? []).slice(1).map(plain),
      }))
    : [];

  return {
    name: field(top, 'name') ?? domain,
    goal: field(top, 'goal') ?? null,
    index: classes,
    targets: fields(top, 'target').map((t) => ({
      name: plain(field(t, 'name')),
      construct: plain(field(t, 'construct')),
      description: field(t, 'description') ?? null,
      probes: (fields(t, 'probes')[0] ?? []).slice(1).map(plain),
      fields: (fields(t, 'fields')[0] ?? []).slice(1).map(plain),
    })),
  };
}

export function listDomains() {
  if (!existsSync(CORPUS_ROOT)) return [];
  return readdirSync(CORPUS_ROOT, { withFileTypes: true })
    .filter((d) => d.isDirectory() && !d.name.startsWith('.')
                && existsSync(join(CORPUS_ROOT, d.name, 'manifest.scm')))
    .map((d) => d.name);
}
