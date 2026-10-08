// app/qr.ts — a QR code, for a label.
//
// A label is the code a thing is known by, printed (docs/observation/
// capture.md §6), and the printed form a camera reads is a QR symbol. This is
// the encoder: text in, a square of dark and light modules out, and an SVG of
// it for the page that prints.
//
// What it covers is what a label needs: byte mode, error correction level M
// (about 15% of the symbol may be lost to a scuff or a fold), versions 1 to 10
// (up to 213 bytes). The symbol follows ISO/IEC 18004; the construction follows
// the standard's own order, so each step below names the clause it implements.

/** A symbol: `size` modules a side, `dark[y][x]` true where the module is dark. */
export interface Symbol {
  version: number;
  size: number;
  mask: number;
  dark: boolean[][];
}

const MIN_VERSION = 1;
const MAX_VERSION = 10;

// level M, per version (index 0 unused): error correction codewords per block,
// and the number of blocks (ISO/IEC 18004 table 9)
const ECC_PER_BLOCK = [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26];
const BLOCKS = [0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5];

// level M's two format bits
const LEVEL_M = 0;

/** Modules a side. */
export const sizeOf = (version: number): number => 17 + 4 * version;

/** The modules left for codewords once the function patterns are placed. */
function rawModules(version: number): number {
  let n = (16 * version + 128) * version + 64;
  if (version >= 2) {
    const align = Math.floor(version / 7) + 2;
    n -= (25 * align - 10) * align - 55;
    if (version >= 7) n -= 36;
  }
  return n;
}

/** Data codewords a version holds at level M. */
export const dataCodewords = (version: number): number =>
  Math.floor(rawModules(version) / 8) - ECC_PER_BLOCK[version] * BLOCKS[version];

/** Bytes of text a version holds: its data codewords less the header. */
export function capacity(version: number): number {
  const header = 4 + (version < 10 ? 8 : 16);
  return Math.floor((dataCodewords(version) * 8 - header) / 8);
}

// ── Reed–Solomon over GF(2^8), the field polynomial x^8+x^4+x^3+x^2+1 ──────

function mul(x: number, y: number): number {
  let z = 0;
  for (let i = 7; i >= 0; i--) {
    z = (z << 1) ^ ((z >>> 7) * 0x11d);
    z ^= ((y >>> i) & 1) * x;
  }
  return z;
}

/** The generator polynomial of the given degree, its leading 1 left off. */
function generator(degree: number): number[] {
  const g = new Array<number>(degree).fill(0);
  g[degree - 1] = 1;
  let root = 1;
  for (let i = 0; i < degree; i++) {
    for (let j = 0; j < g.length; j++) {
      g[j] = mul(g[j], root);
      if (j + 1 < g.length) g[j] ^= g[j + 1];
    }
    root = mul(root, 2);
  }
  return g;
}

/** The error correction codewords of a block of data. */
function remainder(data: number[], g: number[]): number[] {
  const r = new Array<number>(g.length).fill(0);
  for (const b of data) {
    const factor = b ^ r[0];
    r.shift();
    r.push(0);
    for (let i = 0; i < g.length; i++) r[i] ^= mul(g[i], factor);
  }
  return r;
}

// ── the codewords ──────────────────────────────────────────────────────────

/** The text's bytes as UTF-8. */
const bytesOf = (text: string): number[] => Array.from(new TextEncoder().encode(text));

/** The smallest version that holds `n` bytes, or null when none does. */
export function versionFor(n: number): number | null {
  for (let v = MIN_VERSION; v <= MAX_VERSION; v++) if (n <= capacity(v)) return v;
  return null;
}

/** The data codewords: mode, length, the bytes, the terminator and the padding (§7.4). */
function dataOf(bytes: number[], version: number): number[] {
  const bits: number[] = [];
  const put = (value: number, width: number): void => {
    for (let i = width - 1; i >= 0; i--) bits.push((value >>> i) & 1);
  };
  put(0b0100, 4);                                       // byte mode
  put(bytes.length, version < 10 ? 8 : 16);
  for (const b of bytes) put(b, 8);
  const room = dataCodewords(version) * 8;
  put(0, Math.min(4, room - bits.length));              // the terminator, as much as fits
  put(0, (8 - (bits.length % 8)) % 8);                  // to a whole codeword
  for (let pad = 0xec; bits.length < room; pad ^= 0xec ^ 0x11) put(pad, 8);
  const out: number[] = [];
  for (let i = 0; i < bits.length; i += 8) {
    let b = 0;
    for (let j = 0; j < 8; j++) b = (b << 1) | bits[i + j];
    out.push(b);
  }
  return out;
}

/** Data split into blocks, each given its error correction, then interleaved (§7.5, §7.6). */
function interleaved(data: number[], version: number): number[] {
  const blocks = BLOCKS[version], ecc = ECC_PER_BLOCK[version];
  const total = Math.floor(rawModules(version) / 8);
  const short = blocks - (total % blocks);              // blocks one codeword shorter
  const shortLen = Math.floor(total / blocks);
  const g = generator(ecc);
  const built: number[][] = [];
  for (let i = 0, k = 0; i < blocks; i++) {
    const len = shortLen - ecc + (i < short ? 0 : 1);
    const dat = data.slice(k, k + len);
    k += len;
    const check = remainder(dat, g);
    if (i < short) dat.push(0);                         // a place held, skipped below
    built.push(dat.concat(check));
  }
  const out: number[] = [];
  for (let i = 0; i < built[0].length; i++)
    built.forEach((block, j) => {
      if (i !== shortLen - ecc || j >= short) out.push(block[i]);
    });
  return out;
}

// ── the symbol ─────────────────────────────────────────────────────────────

/** Where the alignment patterns' centres fall, along either axis (annex E). */
function alignmentCentres(version: number): number[] {
  if (version === 1) return [];
  const n = Math.floor(version / 7) + 2;
  const step = Math.ceil((version * 4 + 4) / (n * 2 - 2)) * 2;
  const out = [6];
  for (let pos = sizeOf(version) - 7; out.length < n; pos -= step) out.splice(1, 0, pos);
  return out;
}

/** The eight masks, by their condition on a module's column x and row y (§7.8.2). */
const MASKS: ((x: number, y: number) => boolean)[] = [
  (x, y) => (x + y) % 2 === 0,
  (_x, y) => y % 2 === 0,
  x => x % 3 === 0,
  (x, y) => (x + y) % 3 === 0,
  (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0,
  (x, y) => ((x * y) % 2) + ((x * y) % 3) === 0,
  (x, y) => (((x * y) % 2) + ((x * y) % 3)) % 2 === 0,
  (x, y) => (((x + y) % 2) + ((x * y) % 3)) % 2 === 0,
];

/** The fifteen format bits for a mask at level M: five of data, ten of BCH, masked (§7.9). */
export function formatBits(mask: number): number {
  const data = (LEVEL_M << 3) | mask;
  let rem = data;
  for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
  return ((data << 10) | rem) ^ 0x5412;
}

/** The eighteen version bits, carried by version 7 and above (§7.10). */
function versionBits(version: number): number {
  let rem = version;
  for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25);
  return (version << 12) | rem;
}

interface Grid {
  size: number;
  dark: boolean[][];
  /** True where a module belongs to a function pattern and carries no data. */
  fixed: boolean[][];
}

function blank(version: number): Grid {
  const size = sizeOf(version);
  const rows = (): boolean[][] => Array.from({ length: size }, () => new Array<boolean>(size).fill(false));
  return { size, dark: rows(), fixed: rows() };
}

function fix(g: Grid, x: number, y: number, dark: boolean): void {
  g.dark[y][x] = dark;
  g.fixed[y][x] = true;
}

function drawFormat(g: Grid, mask: number): void {
  const bits = formatBits(mask);
  const bit = (i: number): boolean => ((bits >>> i) & 1) !== 0;
  for (let i = 0; i <= 5; i++) fix(g, 8, i, bit(i));
  fix(g, 8, 7, bit(6));
  fix(g, 8, 8, bit(7));
  fix(g, 7, 8, bit(8));
  for (let i = 9; i < 15; i++) fix(g, 14 - i, 8, bit(i));
  for (let i = 0; i < 8; i++) fix(g, g.size - 1 - i, 8, bit(i));
  for (let i = 8; i < 15; i++) fix(g, 8, g.size - 15 + i, bit(i));
  fix(g, 8, g.size - 8, true);                          // the module that is always dark
}

function drawFunctionPatterns(g: Grid, version: number): void {
  const size = g.size;
  // the timing patterns
  for (let i = 0; i < size; i++) {
    fix(g, 6, i, i % 2 === 0);
    fix(g, i, 6, i % 2 === 0);
  }
  // the three finder patterns, each with its light separator
  for (const [cx, cy] of [[3, 3], [size - 4, 3], [3, size - 4]])
    for (let dy = -4; dy <= 4; dy++)
      for (let dx = -4; dx <= 4; dx++) {
        const x = cx + dx, y = cy + dy;
        if (x < 0 || x >= size || y < 0 || y >= size) continue;
        const ring = Math.max(Math.abs(dx), Math.abs(dy));
        fix(g, x, y, ring !== 2 && ring !== 4);
      }
  // the alignment patterns, everywhere but under a finder
  const centres = alignmentCentres(version), last = centres.length - 1;
  centres.forEach((cx, i) => centres.forEach((cy, j) => {
    if ((i === 0 && j === 0) || (i === 0 && j === last) || (i === last && j === 0)) return;
    for (let dy = -2; dy <= 2; dy++)
      for (let dx = -2; dx <= 2; dx++)
        fix(g, cx + dx, cy + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
  }));
  drawFormat(g, 0);                                     // holds the places; the chosen mask's bits follow
  if (version >= 7) {
    const bits = versionBits(version);
    for (let i = 0; i < 18; i++) {
      const dark = ((bits >>> i) & 1) !== 0;
      const a = size - 11 + (i % 3), b = Math.floor(i / 3);
      fix(g, a, b, dark);
      fix(g, b, a, dark);
    }
  }
}

/** The codewords' bits, laid in two-module columns from the lower right, winding up and down (§7.7.3). */
function place(g: Grid, codewords: number[]): void {
  let i = 0;
  for (let right = g.size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;                         // the timing column is stepped over
    for (let v = 0; v < g.size; v++)
      for (let j = 0; j < 2; j++) {
        const x = right - j;
        const upward = ((right + 1) & 2) === 0;
        const y = upward ? g.size - 1 - v : v;
        if (g.fixed[y][x] || i >= codewords.length * 8) continue;
        g.dark[y][x] = ((codewords[i >>> 3] >>> (7 - (i & 7))) & 1) !== 0;
        i++;
      }
  }
}

function applyMask(g: Grid, mask: number): void {
  const on = MASKS[mask];
  for (let y = 0; y < g.size; y++)
    for (let x = 0; x < g.size; x++)
      if (!g.fixed[y][x] && on(x, y)) g.dark[y][x] = !g.dark[y][x];
}

/** How hard a masked symbol is to read: the standard's four penalties, summed (§7.8.3). */
function penalty(g: Grid): number {
  const n = g.size;
  let score = 0;
  const line = (at: (i: number) => boolean): void => {
    // runs of five or more alike
    let run = 1;
    for (let i = 1; i <= n; i++) {
      if (i < n && at(i) === at(i - 1)) { run++; continue; }
      if (run >= 5) score += 3 + (run - 5);
      run = 1;
    }
    // the finder's 1:1:3:1:1 with four light modules beside it
    for (let i = 0; i + 11 <= n; i++) {
      const s = Array.from({ length: 11 }, (_, k) => (at(i + k) ? "1" : "0")).join("");
      if (s === "10111010000" || s === "00001011101") score += 40;
    }
  };
  for (let y = 0; y < n; y++) line(x => g.dark[y][x]);
  for (let x = 0; x < n; x++) line(y => g.dark[y][x]);
  // two-by-two blocks alike
  for (let y = 0; y + 1 < n; y++)
    for (let x = 0; x + 1 < n; x++) {
      const c = g.dark[y][x];
      if (c === g.dark[y][x + 1] && c === g.dark[y + 1][x] && c === g.dark[y + 1][x + 1]) score += 3;
    }
  // the balance of dark and light
  let dark = 0;
  for (const row of g.dark) for (const m of row) if (m) dark++;
  score += Math.floor(Math.abs((dark * 100) / (n * n) - 50) / 5) * 10;
  return score;
}

/**
 * The symbol for a text. `mask` fixes the mask; left out, the one the
 * standard's penalties score lowest is chosen. Null when the text is longer
 * than version 10 holds.
 */
export function encode(text: string, mask?: number): Symbol | null {
  const bytes = bytesOf(text);
  const version = versionFor(bytes.length);
  if (version === null) return null;
  const codewords = interleaved(dataOf(bytes, version), version);
  const base = blank(version);
  drawFunctionPatterns(base, version);
  place(base, codewords);

  const masked = (m: number): Grid => {
    const g: Grid = { size: base.size, dark: base.dark.map(r => r.slice()), fixed: base.fixed };
    applyMask(g, m);
    drawFormat(g, m);
    return g;
  };
  let chosen = mask ?? 0;
  if (mask === undefined) {
    let best = Infinity;
    for (let m = 0; m < 8; m++) {
      const p = penalty(masked(m));
      if (p < best) { best = p; chosen = m; }
    }
  }
  return { version, size: base.size, mask: chosen, dark: masked(chosen).dark };
}

/**
 * The symbol as an SVG string, `px` a side, with the quiet zone of four light
 * modules a reader needs around it. One path, so a sheet of labels stays light.
 */
export function svg(symbol: Symbol, px: number): string {
  const quiet = 4, span = symbol.size + quiet * 2;
  let d = "";
  symbol.dark.forEach((row, y) => row.forEach((m, x) => {
    if (m) d += `M${x + quiet},${y + quiet}h1v1h-1z`;
  }));
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${px}" height="${px}" viewBox="0 0 ${span} ${span}" shape-rendering="crispEdges">`
       + `<rect width="${span}" height="${span}" fill="#ffffff"/><path d="${d}" fill="#000000"/></svg>`;
}
