// SPDX-License-Identifier: AGPL-3.0-or-later
// YouTube playlists as a corpus source kind.
//
// A great deal of practical knowledge is published as video and never written
// down. The spoken track is still text — it is just held in captions. This
// module turns a playlist into one line-stable document per playlist, so the
// rest of the pipeline (chunk, embed, retrieve, cite) treats it exactly like a
// book and nothing downstream needs to know the difference.
//
// Provenance survives the trip: each video becomes a `## [videoId] Title`
// heading, and a `[mm:ss]` marker is emitted whenever the timeline advances
// past the stamp interval. So a retrieved passage cites both a line range in
// text.md AND a timestamp that plays in a browser.
//
// Requires yt-dlp on PATH (or at CORPUS_YTDLP).

import { execFileSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const YTDLP = process.env.CORPUS_YTDLP || 'yt-dlp';
const STAMP_EVERY_SEC = 30;

export function ytdlpAvailable() {
  try {
    execFileSync(YTDLP, ['--version'], { stdio: 'pipe' });
    return true;
  } catch {
    return false;
  }
}

/** Video ids + titles in playlist order. */
export function listPlaylist(playlistId) {
  const out = execFileSync(
    YTDLP,
    ['--flat-playlist', '--print', '%(id)s\t%(title)s',
     `https://www.youtube.com/playlist?list=${playlistId}`],
    { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'] });
  return out.split('\n')
    .map((l) => l.trim())
    .filter(Boolean)
    .map((l) => {
      const [id, ...rest] = l.split('\t');
      return { id, title: rest.join('\t') || id };
    })
    // Private/deleted entries surface with no usable id.
    .filter((v) => /^[\w-]{11}$/.test(v.id));
}

/**
 * Fetch one video's English captions and return cleaned, timestamped text.
 * Returns null when a video has no English track at all.
 */
export function fetchTranscript(videoId) {
  const dir = mkdtempSync(join(tmpdir(), 'corpus-yt-'));
  try {
    execFileSync(
      YTDLP,
      ['--skip-download', '--write-auto-subs', '--write-subs',
       '--sub-langs', 'en,en-US,en-GB', '--sub-format', 'vtt',
       '--retries', '3', '--socket-timeout', '30',
       '-o', join(dir, '%(id)s.%(ext)s'),
       `https://www.youtube.com/watch?v=${videoId}`],
      { stdio: 'pipe', timeout: 180_000 });

    const vtt = readdirSync(dir).find((f) => f.endsWith('.vtt'));
    if (!vtt) return null;
    return vttToText(readFileSync(join(dir, vtt), 'utf8'));
  } catch {
    return null;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/**
 * VTT -> prose.
 *
 * YouTube's auto-caption VTT is a rolling two-line display: each cue repeats
 * the previous cue's text and appends inline per-word timing tags. Read
 * naively it triples the corpus and wrecks retrieval, since every phrase
 * appears several times. So: strip the inline tags, then keep only lines not
 * already carried by the cue before them.
 */
export function vttToText(vtt) {
  const lines = vtt.split(/\r?\n/);
  const out = [];
  let lastEmitted = '';
  let nextStamp = 0;
  let cueStart = 0;

  for (const raw of lines) {
    const line = raw.trim();
    if (!line || line === 'WEBVTT') continue;
    if (/^(Kind|Language|NOTE|STYLE|REGION):?/i.test(line)) continue;

    const time = line.match(/^(\d{2}):(\d{2}):(\d{2})\.\d{3}\s+-->/);
    if (time) {
      cueStart = Number(time[1]) * 3600 + Number(time[2]) * 60 + Number(time[3]);
      continue;
    }
    if (/^\d+$/.test(line)) continue; // cue index

    const text = line
      .replace(/<\d{2}:\d{2}:\d{2}\.\d{3}>/g, '')  // inline word timings
      .replace(/<\/?c[^>]*>/g, '')                 // <c> karaoke spans
      .replace(/<[^>]+>/g, '')
      .replace(/\s+/g, ' ')
      .trim();
    if (!text || text === lastEmitted) continue;

    // The rolling window means a new cue often just extends the previous one.
    if (lastEmitted && (lastEmitted.endsWith(text) || lastEmitted.includes(text))) continue;
    const novel = lastEmitted && text.startsWith(lastEmitted)
      ? text.slice(lastEmitted.length).trim()
      : text;
    if (!novel) continue;

    if (cueStart >= nextStamp) {
      out.push(`\n[${stamp(cueStart)}]`);
      nextStamp = cueStart + STAMP_EVERY_SEC;
    }
    out.push(novel);
    lastEmitted = text;
  }

  return out.join(' ')
    .replace(/\s*\n\s*/g, '\n')
    .replace(/ {2,}/g, ' ')
    .trim();
}

function stamp(sec) {
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
}

/**
 * Whole playlist -> one markdown document. Paragraphs are wrapped so that a
 * line number identifies a small span of speech rather than a whole talk.
 */
export function playlistToMarkdown(playlistId, videos, { onProgress } = {}) {
  const parts = [`# YouTube playlist ${playlistId}`, ''];
  let got = 0;

  videos.forEach((v, i) => {
    const text = fetchTranscript(v.id);
    onProgress?.(i + 1, videos.length, v, !!text);
    if (!text) return;
    got++;
    parts.push(`## [${v.id}] ${v.title}`);
    parts.push('');
    parts.push(`https://www.youtube.com/watch?v=${v.id}`);
    parts.push('');
    for (const para of text.split('\n')) {
      const p = para.trim();
      if (p) { parts.push(wrap(p, 88)); parts.push(''); }
    }
  });

  return { markdown: parts.join('\n') + '\n', transcribed: got };
}

function wrap(s, width) {
  const words = s.split(' ');
  const lines = [];
  let cur = '';
  for (const w of words) {
    if (cur.length + w.length + 1 > width) { lines.push(cur); cur = w; }
    else cur = cur ? `${cur} ${w}` : w;
  }
  if (cur) lines.push(cur);
  return lines.join('\n');
}
