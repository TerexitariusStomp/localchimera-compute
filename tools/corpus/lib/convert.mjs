// Source file -> plain markdown-ish text with STABLE line numbers.
//
// Line numbers are the provenance currency of this whole pipeline: a bring-over
// doc cites `L1234`, and that citation has to keep pointing at the same sentence
// months later. So conversion is deterministic and the converted text is written
// once to `text.md`; downstream stages only ever read that file.

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { extname } from 'node:path';

export function convertToText(path) {
  const ext = extname(path).toLowerCase();
  if (ext === '.pdf') return normalize(pdfToText(path));
  if (ext === '.html' || ext === '.htm') return normalize(htmlToText(readFileSync(path, 'utf8')));
  return normalize(readFileSync(path, 'utf8'));
}

function pdfToText(path) {
  // -layout keeps tables legible, which matters: the numeric tables are the
  // most valuable thing an agronomy text has.
  return execFileSync('pdftotext', ['-layout', '-enc', 'UTF-8', path, '-'],
                      { encoding: 'utf8', maxBuffer: 512 * 1024 * 1024 });
}

function htmlToText(html) {
  let s = html;
  s = s.replace(/<(script|style|nav|footer|header)[\s\S]*?<\/\1>/gi, ' ');
  s = s.replace(/<!--[\s\S]*?-->/g, ' ');
  // Headings become markdown so the chunker can see document structure.
  s = s.replace(/<h([1-6])[^>]*>([\s\S]*?)<\/h\1>/gi,
                (_, n, inner) => `\n\n${'#'.repeat(Number(n))} ${strip(inner)}\n\n`);
  // TABLE ROWS FIRST, before any per-tag newline rule can shred them. A row is
  // the unit of meaning in a data table — "radius 6 m, 73 per hectare, 175 m3"
  // says something its cells do not — and source HTML routinely puts each cell
  // on its own source line, so stripping tags tag-by-tag leaves a column of
  // orphaned numbers with the headers stranded above them. Collapsing each
  // <tr> to one tab-separated line keeps the row intact, which is the whole
  // reason a table is worth retrieving: the numeric tables are the most
  // valuable thing an engineering manual has.
  s = s.replace(/<tr[^>]*>([\s\S]*?)<\/tr>/gi, (_, row) => {
    const cells = [...row.matchAll(/<t[dh][^>]*>([\s\S]*?)(?=<t[dh]|<\/tr|$)/gi)]
      .map((m) => strip(m[1]).replace(/\s+/g, ' ').trim());
    return cells.some(Boolean) ? `\n${cells.join('\t')}\n` : '\n';
  });
  s = s.replace(/<li[^>]*>/gi, '\n- ');
  s = s.replace(/<(p|div|br|tr|table|section|article)[^>]*>/gi, '\n');
  s = s.replace(/<\/(p|div|tr|table|section|article)>/gi, '\n');
  s = s.replace(/<td[^>]*>/gi, '\t');
  return strip(s);
}

function strip(s) {
  return decodeEntities(s.replace(/<[^>]+>/g, ' '));
}

const ENTITIES = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ',
  mdash: '—', ndash: '–', rsquo: '’', lsquo: '‘',
  ldquo: '“', rdquo: '”', hellip: '…', deg: '°',
  times: '×', frac12: '½', frac14: '¼', middot: '·',
};

function decodeEntities(s) {
  return s
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&([a-z0-9]+);/gi, (m, name) => ENTITIES[name.toLowerCase()] ?? m);
}

function normalize(s) {
  return s
    .replace(/\r\n?/g, '\n')
    .replace(/\f/g, '\n')          // pdftotext page breaks
    .replace(/[ \t]+$/gm, '')
    .replace(/\n{4,}/g, '\n\n\n')  // cap runs so line numbers stay meaningful
    .replace(/­/g, '')        // soft hyphens from PDF extraction
    .trim() + '\n';
}
