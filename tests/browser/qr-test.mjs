// tests/browser/qr-test.mjs — a QR code, for a label
// (browser/app/qr.js, from ui/app/qr.ts).
//
// The encoder is checked against the standard and against a reader written
// here, apart from it: the reader takes a symbol's modules alone, reads the
// format bits, lifts the mask, walks the codewords out, takes the blocks apart
// and reads the text back. What is pinned:
//
//   • the sizes and capacities are ISO/IEC 18004's for level M;
//   • the function patterns stand where the standard puts them;
//   • the format bits are a valid BCH word naming level M and the mask used;
//   • every block's error correction is a Reed–Solomon word (its syndromes
//     are all zero);
//   • the text read back is the text given, for every version 1 to 10, every
//     mask, and text outside ASCII;
//   • a text longer than version 10 holds has no symbol.
//
// Run: node tests/browser/qr-test.mjs

const { encode, svg, sizeOf, capacity, dataCodewords, versionFor, formatBits } =
  await import("../../browser/app/qr.js");

import { harness } from './assert.mjs';
const { check, done } = harness();

// ── the reader, written apart from the encoder ─────────────────────────────

const ECC = [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26];
const BLK = [0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5];
const TOTAL = [0, 26, 44, 70, 100, 134, 172, 196, 242, 292, 346];   // codewords per version (table 1)
const ALIGN = [[], [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50]];

const MASK = [
  (x, y) => (x + y) % 2 === 0,
  (x, y) => y % 2 === 0,
  (x, y) => x % 3 === 0,
  (x, y) => (x + y) % 3 === 0,
  (x, y) => (Math.floor(y / 2) + Math.floor(x / 3)) % 2 === 0,
  (x, y) => (x * y) % 2 + (x * y) % 3 === 0,
  (x, y) => ((x * y) % 2 + (x * y) % 3) % 2 === 0,
  (x, y) => ((x + y) % 2 + (x * y) % 3) % 2 === 0,
];

// the modules that carry no data, from the standard's layout
function functionMap(version) {
  const n = 17 + 4 * version;
  const f = Array.from({ length: n }, () => new Array(n).fill(false));
  const box = (x0, y0, w, h) => {
    for (let y = y0; y < y0 + h; y++) for (let x = x0; x < x0 + w; x++)
      if (x >= 0 && y >= 0 && x < n && y < n) f[y][x] = true;
  };
  box(0, 0, 9, 9); box(n - 8, 0, 8, 9); box(0, n - 8, 9, 8);        // finders, separators, format
  box(6, 0, 1, n); box(0, 6, n, 1);                                  // timing
  const c = ALIGN[version], last = c.length - 1;
  c.forEach((cx, i) => c.forEach((cy, j) => {
    if ((i === 0 && j === 0) || (i === 0 && j === last) || (i === last && j === 0)) return;
    box(cx - 2, cy - 2, 5, 5);
  }));
  if (version >= 7) { box(n - 11, 0, 3, 6); box(0, n - 11, 6, 3); }
  return f;
}

// GF(2^8) by log tables, where the encoder multiplies bit by bit
const EXP = new Array(512), LOG = new Array(256);
for (let i = 0, x = 1; i < 255; i++) { EXP[i] = x; LOG[x] = i; x <<= 1; if (x & 0x100) x ^= 0x11d; }
for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
const gmul = (a, b) => (a && b) ? EXP[LOG[a] + LOG[b]] : 0;
// a received word evaluated at α^i, highest power first
const syndrome = (word, i) => word.reduce((acc, b) => gmul(acc, EXP[i]) ^ b, 0);

function read(symbol) {
  const n = symbol.size, version = (n - 17) / 4;
  // the format word beside the upper-left finder, bit 0 first
  const at = [[8, 0], [8, 1], [8, 2], [8, 3], [8, 4], [8, 5], [8, 7], [8, 8], [7, 8],
              [5, 8], [4, 8], [3, 8], [2, 8], [1, 8], [0, 8]];
  let word = 0;
  at.forEach(([x, y], i) => { if (symbol.dark[y][x]) word |= 1 << i; });
  word ^= 0x5412;
  // a BCH(15,5) word leaves no remainder under the generator 0x537
  let rem = word;
  for (let i = 14; i >= 10; i--) if ((rem >>> i) & 1) rem ^= 0x537 << (i - 10);
  const level = word >>> 13, mask = (word >>> 10) & 7;

  const fixed = functionMap(version);
  const bits = [];
  for (let right = n - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    const up = ((right + 1) & 2) === 0;
    for (let v = 0; v < n; v++) for (let j = 0; j < 2; j++) {
      const x = right - j, y = up ? n - 1 - v : v;
      if (fixed[y][x]) continue;
      bits.push((symbol.dark[y][x] !== MASK[mask](x, y)) ? 1 : 0);
    }
  }
  const total = TOTAL[version];
  const stream = [];
  for (let i = 0; i < total; i++) {
    let b = 0;
    for (let j = 0; j < 8; j++) b = (b << 1) | bits[i * 8 + j];
    stream.push(b);
  }
  // take the interleaving apart
  const blocks = BLK[version], ecc = ECC[version];
  const dataTotal = total - blocks * ecc;
  const shortData = Math.floor(dataTotal / blocks), long = dataTotal % blocks;
  const lens = Array.from({ length: blocks }, (_, i) => shortData + (i >= blocks - long ? 1 : 0));
  const dat = lens.map(() => []), chk = lens.map(() => []);
  let k = 0;
  for (let i = 0; i < shortData + 1; i++)
    for (let b = 0; b < blocks; b++) if (i < lens[b]) dat[b].push(stream[k++]);
  for (let i = 0; i < ecc; i++) for (let b = 0; b < blocks; b++) chk[b].push(stream[k++]);
  let clean = true;
  for (let b = 0; b < blocks; b++) {
    const w = dat[b].concat(chk[b]);
    for (let i = 0; i < ecc; i++) if (syndrome(w, i) !== 0) clean = false;
  }
  // the text: mode, length, bytes
  const data = dat.flat();
  const dbits = [];
  for (const b of data) for (let j = 7; j >= 0; j--) dbits.push((b >>> j) & 1);
  const take = (from, w) => dbits.slice(from, from + w).reduce((a, b) => (a << 1) | b, 0);
  const mode = take(0, 4), lw = version < 10 ? 8 : 16, len = take(4, lw);
  const bytes = [];
  for (let i = 0; i < len; i++) bytes.push(take(4 + lw + i * 8, 8));
  return { version, level, mask, bch: rem === 0, clean, mode, used: k, total,
           text: new TextDecoder().decode(new Uint8Array(bytes)) };
}

// ── the checks ─────────────────────────────────────────────────────────────

console.log("\n── sizes and capacities, level M ──");
{
  check("version 1 is 21 modules a side", sizeOf(1) === 21);
  check("version 10 is 57 modules a side", sizeOf(10) === 57);
  const data = [0, 16, 28, 44, 64, 86, 108, 124, 154, 182, 216];
  check("data codewords per version are the standard's",
        data.every((d, v) => v === 0 || dataCodewords(v) === d),
        data.map((_, v) => v && dataCodewords(v)).slice(1).join(","));
  const cap = [0, 14, 26, 42, 62, 84, 106, 122, 152, 180, 213];
  check("bytes of text per version are the standard's",
        cap.every((c, v) => v === 0 || capacity(v) === c),
        cap.map((_, v) => v && capacity(v)).slice(1).join(","));
  check("fourteen bytes fit version 1", versionFor(14) === 1);
  check("fifteen bytes need version 2", versionFor(15) === 2);
  check("213 bytes fit version 10", versionFor(213) === 10);
  check("214 bytes fit no version here", versionFor(214) === null);
}

console.log("\n── the format bits ──");
{
  // ISO/IEC 18004 annex C's worked example: level M, mask 5 → 100000011001110
  check("level M with mask 5 is the standard's worked example",
        formatBits(5) === 0b100000011001110, formatBits(5).toString(2));
  check("eight masks make eight different words",
        new Set([0, 1, 2, 3, 4, 5, 6, 7].map(formatBits)).size === 8);
}

console.log("\n── a label's symbol ──");
{
  const s = encode("playnet:A1B2C3");
  check("a label's code has a symbol", !!s);
  check("…at version 1, fourteen bytes being what it holds", s.version === 1 && s.size === 21);
  const finder = (x0, y0) => {
    for (let dy = 0; dy < 7; dy++) for (let dx = 0; dx < 7; dx++) {
      const ring = Math.max(Math.abs(dx - 3), Math.abs(dy - 3));
      if (s.dark[y0 + dy][x0 + dx] !== (ring !== 2)) return false;
    }
    return true;
  };
  check("the three finder patterns stand in their corners",
        finder(0, 0) && finder(s.size - 7, 0) && finder(0, s.size - 7));
  check("the fourth corner holds no finder", !finder(s.size - 7, s.size - 7));
  let timing = true;
  for (let i = 8; i < s.size - 8; i++)
    if (s.dark[6][i] !== (i % 2 === 0) || s.dark[i][6] !== (i % 2 === 0)) timing = false;
  check("the timing patterns alternate between the finders", timing);
  check("the module that is always dark is dark", s.dark[s.size - 8][8] === true);
  check("every row is as long as the symbol is wide",
        s.dark.length === s.size && s.dark.every(r => r.length === s.size));

  const r = read(s);
  check("the format word is a BCH word", r.bch);
  check("…naming level M", r.level === 0);
  check("…and the mask the symbol reports", r.mask === s.mask, `${r.mask} / ${s.mask}`);
  check("the error correction is a Reed–Solomon word", r.clean);
  check("the mode read back is byte mode", r.mode === 0b0100);
  check("the text read back is the text given", r.text === "playnet:A1B2C3", r.text);
}

console.log("\n── every version, read back ──");
{
  for (let v = 1; v <= 10; v++) {
    const text = "x".repeat(capacity(v) - 4) + "·Ω";     // to the last byte; the two characters outside ASCII are two bytes each
    const bytes = new TextEncoder().encode(text).length;
    const s = encode(text);
    const r = s && read(s);
    check(`version ${v}: ${bytes} bytes fill it and read back`,
          !!s && s.version === v && bytes === capacity(v) && r.bch && r.clean && r.text === text,
          s ? `v${s.version} mask ${s.mask} clean ${r.clean}` : "no symbol");
    check(`version ${v}: the codewords fill the symbol`, !!r && r.used === r.total, r ? `${r.used}/${r.total}` : "");
  }
}

console.log("\n── every mask, read back ──");
{
  const text = "playnet:Z9Y8X7 · bin";
  for (let m = 0; m < 8; m++) {
    const s = encode(text, m), r = read(s);
    check(`mask ${m} is the one used, and the text reads back`,
          s.mask === m && r.mask === m && r.clean && r.text === text);
  }
  const free = encode(text);
  check("left to choose, the encoder picks one of the eight", free.mask >= 0 && free.mask <= 7);
  check("…and the same one every time", encode(text).mask === free.mask);
}

console.log("\n── the edges ──");
{
  const empty = encode("");
  check("an empty text has a symbol, and reads back empty", !!empty && read(empty).text === "");
  check("a text longer than version 10 holds has no symbol", encode("x".repeat(214)) === null);
  const s = encode("playnet:A1B2C3");
  const out = svg(s, 120);
  check("the svg is as large as asked", /width="120" height="120"/.test(out));
  check("…with a quiet zone of four modules around the symbol",
        out.includes(`viewBox="0 0 ${s.size + 8} ${s.size + 8}"`));
  const darks = s.dark.flat().filter(Boolean).length;
  check("…and one square for every dark module", (out.match(/h1v1h-1z/g) || []).length === darks);
}

done();
