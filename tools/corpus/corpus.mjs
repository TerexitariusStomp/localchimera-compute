#!/usr/bin/env node
// corpus — a generic textbook -> retrieval -> knowledge-extraction pipeline.
//
// The pipeline is domain-agnostic. A domain is a directory under docs/corpus/
// holding two committed Scheme files:
//
//   manifest.scm  — which texts, where they come from, under what license
//   profile.scm   — what constructs to extract from this branch of literature,
//                   and the retrieval probes that find them
//
// Everything else (the texts, the converted markdown, the SQLite index, the
// model cache) is generated and gitignored. Adding a new field of literature
// is two Scheme files and a `build` — no code changes.
//
//   node tools/corpus/corpus.mjs fetch  permaculture
//   node tools/corpus/corpus.mjs build  permaculture
//   node tools/corpus/corpus.mjs query  permaculture "how deep should a swale be"
//   node tools/corpus/corpus.mjs probe  permaculture --target biofertilizer
//   node tools/corpus/corpus.mjs stats  permaculture

import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync, statSync } from 'node:fs';
import { dirname } from 'node:path';
import {
  loadManifest, loadProfile, listDomains, dbPath, modelCache, domainDir,
} from './lib/manifest.mjs';
import { convertToText } from './lib/convert.mjs';
import { chunkText } from './lib/chunk.mjs';
import { getEmbedder, embedPassages, DEFAULT_MODEL } from './lib/embed.mjs';
import {
  openStore, putSource, putChunks, putVectors, dropSource, setMeta, getMeta, stats as storeStats,
} from './lib/store.mjs';
import { search } from './lib/search.mjs';
import { ytdlpAvailable, listPlaylist, playlistToMarkdown } from './lib/youtube.mjs';
import { findTerm, candidateNames } from './lib/leads.mjs';

const args = process.argv.slice(2);
const cmd = args[0];
const domain = args[1];
const flags = parseFlags(args.slice(2));

// Pressbooks (the OSU open-textbook host) and several UN edges 403 a bare
// programmatic agent, so present as a browser. Nothing fetched here sits behind
// a paywall or a login — this is politeness theatre on their edge, not a lock.
const BROWSER_HEADERS = {
  'user-agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
              + '(KHTML, like Gecko) Chrome/126.0 Safari/537.36',
  accept: '*/*',
};

const COMMANDS = { fetch, build, query, probe, leads, stats, domains, help };

const run = COMMANDS[cmd] ?? help;
try {
  await run();
} catch (err) {
  console.error(`\n✗ ${err.message}\n`);
  process.exit(1);
}

// ---------------------------------------------------------------- commands

async function fetch() {
  const m = requireDomain();
  console.log(`corpus: ${m.title} — ${m.sources.length} sources\n`);
  let ok = 0, skipped = 0, missing = [];

  for (const src of m.sources) {
    if (existsSync(src.path)) {
      console.log(`  ✓ ${src.slug} — already present`);
      ok++;
      continue;
    }

    if (src.kind === 'youtube-playlist') {
      if (!ytdlpAvailable()) {
        console.log(`  ! ${src.slug} — needs yt-dlp on PATH (or CORPUS_YTDLP)`);
        skipped++;
        continue;
      }
      console.log(`  ↓ ${src.slug} — enumerating playlist …`);
      try {
        const videos = listPlaylist(src.playlist);
        const { markdown, transcribed } = playlistToMarkdown(src.playlist, videos, {
          onProgress: (i, n, v, gotIt) =>
            process.stdout.write(`      [${String(i).padStart(2)}/${n}] `
                                 + `${gotIt ? '✓' : '·'} ${v.title.slice(0, 62)}\n`),
        });
        mkdirSync(dirname(src.path), { recursive: true });
        writeFileSync(src.path, markdown);
        console.log(`    ${transcribed}/${videos.length} transcripts, `
                    + `${(markdown.length / 1024).toFixed(0)} KB`);
        ok++;
      } catch (e) {
        console.log(`    FAILED (${e.message})`);
        skipped++;
      }
      continue;
    }

    // A chaptered document: fetch each part and join in declared order.
    if (src.urls?.length) {
      process.stdout.write(`  ↓ ${src.slug} — ${src.urls.length} parts `);
      try {
        const parts = [];
        for (const u of src.urls) {
          const res = await globalThis.fetch(u, { redirect: 'follow', headers: BROWSER_HEADERS });
          if (!res.ok) throw new Error(`HTTP ${res.status} on ${u}`);
          parts.push(await res.text());
          process.stdout.write('.');
        }
        const joined = parts.join('\n\n<hr/>\n\n');
        mkdirSync(dirname(src.path), { recursive: true });
        writeFileSync(src.path, joined);
        console.log(` ${(joined.length / 1024).toFixed(0)} KB`);
        ok++;
      } catch (e) {
        console.log(` FAILED (${e.message})`);
        skipped++;
      }
      continue;
    }

    if (!src.url) {
      console.log(`  · ${src.slug} — ${src.license}, awaiting your own copy`);
      missing.push(src);
      continue;
    }
    process.stdout.write(`  ↓ ${src.slug} … `);
    try {
      const res = await globalThis.fetch(src.url, {
        redirect: 'follow',
        headers: BROWSER_HEADERS,
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const buf = Buffer.from(await res.arrayBuffer());
      mkdirSync(dirname(src.path), { recursive: true });
      writeFileSync(src.path, buf);
      const sha = createHash('sha256').update(buf).digest('hex');
      const size = (buf.length / 1024 / 1024).toFixed(1);
      if (src.sha256 && src.sha256 !== sha) {
        console.log(`CHECKSUM MISMATCH\n      manifest: ${src.sha256}\n      actual:   ${sha}`);
      } else {
        console.log(`${size} MB  sha256:${sha.slice(0, 12)}…`);
      }
      ok++;
    } catch (e) {
      console.log(`FAILED (${e.message})`);
      skipped++;
    }
  }

  console.log(`\n${ok} present, ${skipped} failed, ${missing.length} awaiting a supplied copy`);
  if (missing.length) {
    console.log('\nIn-copyright texts the manifest knows about but will not download.');
    console.log('Drop your own copy at the path below and re-run build:\n');
    for (const s of missing) {
      console.log(`  ${s.title}${s.author ? ' — ' + s.author : ''}`);
      console.log(`    ${s.path}\n`);
    }
  }
}

async function build() {
  const m = requireDomain();
  const force = flags.force === true;
  const model = flags.model ?? DEFAULT_MODEL;

  const db = openStore(dbPath(domain));
  const prevModel = getMeta(db, 'embedding_model');
  if (prevModel && prevModel !== model) {
    throw new Error(
      `index was built with ${prevModel}; rebuild from scratch to switch to ${model} `
      + `(delete ${dbPath(domain)})`);
  }

  console.log(`Loading embedding model ${model} …`);
  const emb = await getEmbedder(model, { cacheDir: modelCache() });
  setMeta(db, 'embedding_model', model);
  setMeta(db, 'embedding_dim', emb.dim);

  const done = new Set(
    db.prepare('SELECT slug, sha256 FROM sources').all().map((r) => `${r.slug}:${r.sha256}`));

  for (const src of m.sources) {
    if (!existsSync(src.path)) {
      console.log(`  · ${src.slug} — no file, skipping`);
      continue;
    }
    const sha = createHash('sha256').update(readFileSync(src.path)).digest('hex');
    if (!force && done.has(`${src.slug}:${sha}`)) {
      console.log(`  ✓ ${src.slug} — up to date`);
      continue;
    }

    process.stdout.write(`  → ${src.slug}: converting … `);
    const text = convertToText(src.path);
    mkdirSync(dirname(src.textPath), { recursive: true });
    writeFileSync(src.textPath, text);
    const lines = text.split('\n').length;

    const chunks = chunkText(text);
    process.stdout.write(`${lines} lines, ${chunks.length} chunks, embedding `);

    dropSource(db, src.slug);
    putSource(db, { ...src, sha256: sha, lines });
    const ids = putChunks(db, src.slug, chunks);

    const vecs = await embedPassages(emb, chunks.map(passageText), {
      onProgress: (d, t) => {
        if (d % 320 === 0 || d === t) process.stdout.write('.');
      },
    });
    putVectors(db, ids.map((id, i) => [id, vecs[i]]));
    console.log(' done');
  }

  const s = storeStats(db);
  console.log(`\nIndex: ${s.sources.length} sources, ${s.vectors} embedded chunks (${s.model}, ${s.dim}d)`);
  console.log(`  ${dbPath(domain)}`);
}

/** Heading path is prepended so a chunk embeds with its structural context. */
function passageText(c) {
  return c.heading ? `${c.heading}\n\n${c.text}` : c.text;
}

async function query() {
  const q = flags._.join(' ');
  if (!q) throw new Error('usage: corpus query <domain> "<question>" [--limit N] [--source SLUG]');
  const { db, emb } = await openForSearch();
  const hits = await search(db, emb, q, {
    limit: Number(flags.limit ?? 8),
    source: flags.source ?? null,
  });
  printHits(q, hits);
}

/**
 * Run every probe declared by the domain profile and emit a cited retrieval
 * pack — the raw material a bring-over doc is written from. This is the
 * generic seam: the profile says what this branch of literature is FOR, the
 * pipeline neither knows nor cares whether that is agronomy or anything else.
 */
async function probe() {
  const profile = loadProfile(domain);
  if (!profile) throw new Error(`domain "${domain}" has no profile.scm`);
  const { db, emb } = await openForSearch();

  const wanted = flags.target ? String(flags.target).split(',') : null;
  const targets = profile.targets.filter((t) => !wanted || wanted.includes(t.name));
  if (!targets.length) throw new Error(`no matching target (have: ${profile.targets.map((t) => t.name).join(', ')})`);

  const perProbe = Number(flags.limit ?? 6);
  const out = [];
  out.push(`# ${profile.name} — retrieval pack`);
  out.push('');
  out.push(`Generated by \`tools/corpus/corpus.mjs probe ${domain}\`. Every passage below is`);
  out.push('cited as `source:Lstart-Lend` against the converted `texts/<slug>/text.md`.');
  out.push('Read the cited range in full before inscribing anything as a fact.');
  out.push('');

  for (const t of targets) {
    out.push(`## ${t.name} → \`${t.construct}\``);
    if (t.description) out.push(`\n${t.description}\n`);
    if (t.fields.length) out.push(`**Fields to fill:** ${t.fields.join(', ')}\n`);

    for (const p of t.probes) {
      const hits = await search(db, emb, p, { limit: perProbe });
      out.push(`### probe: “${p}”`);
      out.push('');
      if (!hits.length) out.push('_no passages retrieved_\n');
      for (const h of hits) {
        out.push(`- **${h.source}:L${h.line_start}-L${h.line_end}**`
                 + `${h.heading ? ` · ${h.heading}` : ''} · sim ${fmtSim(h)}`);
        out.push(`  > ${excerpt(h.text, 320).replace(/\n/g, '\n  > ')}`);
      }
      out.push('');
      process.stderr.write(`  probed ${t.name}: ${p} → ${hits.length}\n`);
    }
  }

  const text = out.join('\n');
  if (flags.out) {
    writeFileSync(String(flags.out), text);
    console.error(`\nwrote ${flags.out}`);
  } else {
    console.log(text);
  }
}

/**
 * Read a corpus as an INDEX OF LEADS rather than a source of facts.
 *
 * Some sources earn their place by telling you what exists. A documentary names
 * a technique and a project; each name is a thread to pull in the primary
 * literature, where the numbers you can actually build from live. This emits
 * that work-list: what to research, and the citation that motivated it.
 */
async function leads() {
  const profile = loadProfile(domain);
  if (!profile?.index?.length) {
    throw new Error(`domain "${domain}" declares no (index …) vocabulary in profile.scm`);
  }
  const path = dbPath(domain);
  if (!existsSync(path)) throw new Error(`no index yet — run: corpus build ${domain}`);
  const db = openStore(path);

  const out = [];
  out.push(`# ${profile.name} — research work-list`);
  out.push('');
  out.push(`Generated by \`corpus leads ${domain}\`. Each entry is something the`);
  out.push('corpus says EXISTS, with where it was heard. Facts come from the primary');
  out.push('literature these names lead to — cite that, and record the lead as');
  out.push('provenance for how it was found.');
  out.push('');

  const declared = [];
  for (const cls of profile.index) {
    out.push(`## ${cls.name}`);
    if (cls.description) out.push(`\n${cls.description}\n`);

    const found = cls.terms
      .map((t) => findTerm(db, t))
      .filter((r) => r.count > 0)
      .sort((a, b) => b.count - a.count);
    const absent = cls.terms.filter((t) => !found.some((f) => f.term === t));
    declared.push(...cls.terms);

    for (const f of found) {
      const ex = f.examples[0];
      const where = ex?.where?.url
        ? `[${ex.where.title || ex.source} @${ex.where.stamp}](${ex.where.url})`
        : `${ex?.source ?? ''}:L${ex?.lines?.[0] ?? '?'}`;
      out.push(`- **${f.term}** — ${f.count} mentions across `
               + `${f.sources.length} source(s). Heard at ${where}`);
    }
    if (absent.length) {
      out.push('');
      out.push(`_Declared but absent from this corpus: ${absent.join(', ')}._`);
    }
    out.push('');
  }

  const cands = candidateNames(db, { declared, min: Number(flags.min ?? 4) });
  if (cands.length) {
    out.push('## candidates — names the profile did not declare');
    out.push('');
    out.push('Crude capitalised-phrase extraction, for triage rather than trust.');
    out.push('');
    for (const c of cands) {
      out.push(`- ${c.name} — ${c.count} mentions (${c.sources.length} source(s))`);
    }
    out.push('');
  }

  const text = out.join('\n');
  if (flags.out) {
    writeFileSync(String(flags.out), text);
    console.error(`wrote ${flags.out}`);
  } else {
    console.log(text);
  }
}

async function stats() {
  requireDomain();
  const path = dbPath(domain);
  if (!existsSync(path)) throw new Error(`no index yet — run: corpus build ${domain}`);
  const db = openStore(path);
  const s = storeStats(db);
  console.log(`\n${domain}: ${s.vectors} embedded chunks · ${s.model} (${s.dim}d)`);
  console.log(`index size: ${(statSync(path).size / 1024 / 1024).toFixed(1)} MB\n`);
  const w = Math.max(...s.sources.map((r) => r.slug.length), 8);
  for (const r of s.sources) {
    console.log(`  ${r.slug.padEnd(w)}  ${String(r.chunks).padStart(6)} chunks  `
                + `${String(r.lines).padStart(7)} lines  ${r.license}`);
  }
  console.log();
}

async function domains() {
  const ds = listDomains();
  if (!ds.length) return console.log('no corpus domains yet');
  for (const d of ds) {
    const m = loadManifest(d);
    const indexed = existsSync(dbPath(d)) ? storeStats(openStore(dbPath(d))).vectors : 0;
    console.log(`  ${d.padEnd(18)} ${String(m.sources.length).padStart(3)} sources  `
                + `${String(indexed).padStart(6)} chunks indexed`);
  }
}

async function help() {
  console.log(`
corpus — textbook -> retrieval -> knowledge extraction

  fetch   <domain>              download the openly-licensed sources
  build   <domain> [--force]    convert, chunk, embed, index
  query   <domain> "<q>"        hybrid BM25 + vector search, cited
  probe   <domain> [--target T] run the profile's probes -> retrieval pack
  stats   <domain>              what is indexed
  domains                       list corpus domains

flags: --limit N  --source SLUG  --out FILE  --model NAME  --force
`);
}

// ----------------------------------------------------------------- helpers

function requireDomain() {
  if (!domain) throw new Error(`usage: corpus ${cmd} <domain>   (have: ${listDomains().join(', ') || 'none'})`);
  return loadManifest(domain);
}

async function openForSearch() {
  requireDomain();
  const path = dbPath(domain);
  if (!existsSync(path)) throw new Error(`no index yet — run: corpus build ${domain}`);
  const db = openStore(path);
  const model = getMeta(db, 'embedding_model') ?? DEFAULT_MODEL;
  const emb = await getEmbedder(model, { cacheDir: modelCache() });
  return { db, emb };
}

function printHits(q, hits) {
  console.log(`\n“${q}” — ${hits.length} passages\n`);
  for (const h of hits) {
    const cite = `${h.source}:L${h.line_start}-L${h.line_end}`;
    console.log(`── ${cite}  ${fmtSim(h)}${h.heading ? `  · ${h.heading}` : ''}`);
    console.log(`   ${h.title}${h.author ? ', ' + h.author : ''}`);
    console.log();
    console.log(indent(excerpt(h.text, 700), '   '));
    console.log();
  }
  if (hits.length) {
    console.log(`Read a passage in full:  sed -n '<start>,<end>p' `
                + `"${domainDir(domain)}/texts/<slug>/text.md"\n`);
  }
}

function fmtSim(h) {
  const parts = [];
  if (h.similarity != null) parts.push(h.similarity.toFixed(3));
  if (h.sparseRank) parts.push(`bm25#${h.sparseRank}`);
  return parts.join(' ') || '—';
}

// Function declarations, not const arrows: `await run()` executes at the top
// of this module, before any const further down has initialized.
function excerpt(s, n) {
  return s.length <= n ? s : s.slice(0, n).replace(/\s+\S*$/, '') + ' …';
}

function indent(s, pad) {
  return s.split('\n').map((l) => pad + l).join('\n');
}

/** Split argv into flags and bare words, so a flag's VALUE never leaks into
 *  the query text (`query … --limit 3` must not search for "3"). */
function parseFlags(rest) {
  const out = { _: [] };
  for (let i = 0; i < rest.length; i++) {
    const arg = rest[i];
    if (!arg.startsWith('--')) { out._.push(arg); continue; }
    const key = arg.slice(2);
    const next = rest[i + 1];
    if (next === undefined || next.startsWith('--')) out[key] = true;
    else { out[key] = next; i++; }
  }
  return out;
}
