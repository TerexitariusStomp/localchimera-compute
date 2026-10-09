// tests/browser/pmtiles-test.mjs — the device-side PMTiles reader (browser/app/pmtiles.js)
//
// The same fixture the Guile reader is checked against (tests/fixtures/map/
// tiny.pmtiles, written by tools/pmtiles-tiny.scm): tile 0/0/0 in the root
// directory, 1/0/0 and 1/0/1 as one run and 2/1/1 alone in a leaf, every other
// tile a hole, each body the gzipped text "z/x/y". What is pinned is that the
// two readers agree — the spec's worked tile ids, the run, the leaf hop, the
// holes — so a pack kept on a device reads exactly as the gateway reads it.
//
// Run: node tests/browser/pmtiles-test.mjs

import fs from 'node:fs';
import { tileId, readHeader, openPack } from '../../browser/app/pmtiles.js';

let pass = 0, fail = 0;
const check = (label, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`  ${ok ? 'ok' : 'FAIL'}: ${label}${ok ? '' : ` — got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
  ok ? pass++ : fail++;
};

check('tile id 0/0/0', tileId(0, 0, 0), 0);
check('tile id 1/0/0', tileId(1, 0, 0), 1);
check('tile id 1/0/1', tileId(1, 0, 1), 2);
check('tile id 1/1/1', tileId(1, 1, 1), 3);
check('tile id 1/1/0', tileId(1, 1, 0), 4);
check('tile id 2/0/0', tileId(2, 0, 0), 5);
{ const z = 5, n = 2 ** z, base = tileId(z, 0, 0), ids = [];
  for (let x = 0; x < n; x++) for (let y = 0; y < n; y++) ids.push(tileId(z, x, y));
  ids.sort((a, b) => a - b);
  check("a zoom's ids are a permutation of its range", ids.every((v, i) => v === base + i) && ids.length === n * n, true); }
check('a Berlin tile at z15 has the id the Guile reader gives it', tileId(15, 8806, 5374), 487177917);
check('an id past 2^31 stays exact (z20 base = (4^20-1)/3)', tileId(20, 0, 0), (4 ** 20 - 1) / 3);

const bytes = fs.readFileSync('tests/fixtures/map/tiny.pmtiles');
const blob = new Blob([bytes]);
const h = readHeader(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + 127));
check('the header: compression, zooms, bounds', [h.internal, h.tiles, h.minZoom, h.maxZoom, h.bounds], ['gzip', 'gzip', 0, 2, [13, 52.3, 13.8, 52.7]]);

const pack = await openPack(blob);
const text = async (z, x, y) => { const t = await pack.tile(z, x, y); return t && new TextDecoder().decode(t); };
check("a root entry's tile", await text(0, 0, 0), '0/0/0');
check("a leaf entry's tile", await text(1, 0, 0), '1/0/0');
check('the second tile of a run shares its bytes', await text(1, 0, 1), '1/0/0');
check('a tile after the run', await text(2, 1, 1), '2/1/1');
check("a hole inside the leaf's range is null", await text(1, 1, 1), null);
check('a hole past the last entry is null', await text(2, 3, 3), null);
check('a zoom past max-zoom is null', await text(3, 0, 0), null);
check('a file that is not an archive is refused', (() => { try { readHeader(new TextEncoder().encode('x'.repeat(127)).buffer); return 'opened'; } catch (e) { return /not a PMTiles/.test(e.message); } })(), true);

console.log(`\n=== Results: ${pass} passed, ${fail} failed ===`);
process.exit(fail ? 1 : 0);
