// Section-aware chunking that carries provenance.
//
// Two properties matter more than chunk size tuning:
//
//   1. Every chunk knows its line range in text.md, so a retrieved passage can
//      be cited as `L1234-L1290` and re-read in full at extraction time.
//   2. Every chunk carries its heading path ("4. Water > 4.2 Keyline"), which
//      both improves embedding quality and tells a reader where they landed.
//
// Chunks overlap by a sentence or two so a fact split across a boundary still
// retrieves whole — the failure the user named as "unhealthy retrieval".

const HEADING = /^(#{1,6})\s+(.*\S)\s*$/;
// Numbered/lettered section headers common in scanned textbooks, e.g.
// "4.2 Keyline Cultivation" or "CHAPTER 7  WATER".
const IMPLICIT_HEADING =
  /^\s{0,6}(?:(?:CHAPTER|PART|SECTION|APPENDIX)\s+[\dIVXLC]+|(?:\d+\.){1,3}\d*)\s*[.:—-]?\s+\S.{0,60}$/;
// A table-of-contents line is shaped exactly like a heading but is not one:
// "20. Trench 31 inches deep .......  31". Left unfiltered, the TOC at the
// front of a book captures the heading path for every chunk after it.
const TOC_LINE = /(?:\.{3,}|\s{3,})\s*\d+\s*$|^\s*\d+\s*$/;

export function chunkText(text, opts = {}) {
  const targetChars = opts.targetChars ?? 1800;
  const maxChars = opts.maxChars ?? 2600;
  const overlapChars = opts.overlapChars ?? 220;

  const lines = text.split('\n');
  const blocks = paragraphBlocks(lines);

  const chunks = [];
  let cur = null;
  let headingPath = [];

  const flush = () => {
    if (cur && cur.text.trim().length >= 80) {
      chunks.push({ ...cur, ord: chunks.length, text: cur.text.trim() });
    } else if (cur && chunks.length) {
      // Too small to stand alone — fold it back into the previous chunk.
      const prev = chunks[chunks.length - 1];
      prev.text += '\n\n' + cur.text.trim();
      prev.lineEnd = cur.lineEnd;
    }
    cur = null;
  };

  for (const block of blocks) {
    const h = headingOf(block.text);
    if (h) {
      flush();
      headingPath = headingPath.slice(0, Math.max(0, h.level - 1));
      headingPath[h.level - 1] = h.title;
      headingPath.length = h.level;
      continue;
    }

    if (!cur) {
      cur = {
        heading: headingPath.filter(Boolean).join(' > '),
        lineStart: block.start,
        lineEnd: block.end,
        text: block.text,
      };
      continue;
    }

    const wouldBe = cur.text.length + 2 + block.text.length;
    if (wouldBe > maxChars || (cur.text.length >= targetChars && wouldBe > targetChars)) {
      const tail = tailOverlap(cur.text, overlapChars);
      flush();
      cur = {
        heading: headingPath.filter(Boolean).join(' > '),
        lineStart: block.start,
        lineEnd: block.end,
        text: tail ? tail + '\n\n' + block.text : block.text,
      };
    } else {
      cur.text += '\n\n' + block.text;
      cur.lineEnd = block.end;
    }
  }
  flush();
  return chunks;
}

/** Group lines into paragraph blocks, remembering 1-based line ranges. */
function paragraphBlocks(lines) {
  const blocks = [];
  let buf = [];
  let start = 1;
  lines.forEach((line, idx) => {
    const lineNo = idx + 1;
    if (line.trim() === '') {
      if (buf.length) {
        blocks.push({ text: buf.join('\n'), start, end: lineNo - 1 });
        buf = [];
      }
      return;
    }
    if (!buf.length) start = lineNo;
    buf.push(line);
    // A heading is its own block even without a blank line around it.
    if (headingOf(line) && buf.length > 1) {
      blocks.push({ text: buf.slice(0, -1).join('\n'), start, end: lineNo - 1 });
      buf = [line];
      start = lineNo;
    }
  });
  if (buf.length) blocks.push({ text: buf.join('\n'), start, end: lines.length });
  return blocks;
}

function headingOf(text) {
  const firstLine = text.split('\n')[0];
  const md = firstLine.match(HEADING);
  if (md) return { level: md[1].length, title: md[2] };
  if (TOC_LINE.test(firstLine)) return null;
  if (text.split('\n').length === 1 && IMPLICIT_HEADING.test(firstLine)) {
    const depth = (firstLine.trim().match(/^(\d+\.)+/)?.[0].split('.').filter(Boolean).length) ?? 1;
    return { level: Math.min(6, depth + 1), title: firstLine.trim() };
  }
  return null;
}

/** Last ~n chars of a chunk, snapped to a sentence boundary, for overlap. */
function tailOverlap(text, n) {
  if (n <= 0 || text.length <= n) return '';
  const tail = text.slice(-n);
  const cut = tail.search(/[.!?]\s+\S/);
  return (cut === -1 ? tail : tail.slice(cut + 1)).trim();
}
