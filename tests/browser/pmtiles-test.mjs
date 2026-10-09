// tests/browser/pmtiles-test.mjs — PMTiles on the device (browser/app/pmtiles.js)
//
// The same fixture the Guile reader is checked against (tests/fixtures/map/
// tiny.pmtiles, written by tools/pmtiles-tiny.scm): tile 0/0/0 in the root
// directory, 1/0/0 and 1/0/1 as one run and 2/1/1 alone in a leaf, every other
// tile a hole, each body the gzipped text "z/x/y". What is pinned is that the
// two readers agree — the spec's worked tile ids, the run, the leaf hop, the
// holes — so a pack kept on a device reads exactly as the gateway reads it;
// and that an AREA cut out of an archive and written back is an archive the
// same reader opens, with the figure the directory promised.
//
// Run: node tests/browser/pmtiles-test.mjs

import fs from 'node:fs';
import { tileId, lngLatToTile, tilesIn, boundsMeet, readHeader, openPack, blobSource, rangeSource,
         entriesIn, bytesOf, slicesFor, writePack, encodeDirectory, decodeDirectory }
  from '../../browser/app/pmtiles.js';

let pass = 0, fail = 0;
const check = (label, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`  ${ok ? 'ok' : 'FAIL'}: ${label}${ok ? '' : ` — got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
  ok ? pass++ : fail++;
};

// ── tile ids and tile math ───────────────────────────────────────────────
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
check('Berlin Mitte at z14 is its Web Mercator tile', lngLatToTile(13.4, 52.52, 14), [8801, 5373]);
check('…and the tile the gateway served lies east of it', lngLatToTile(13.51, 52.5, 14), [8806, 5374]);
check('the whole world at z0 is one tile', tilesIn([-180, -85, 180, 85], 0), [[0, 0]]);
check('Berlin at z1 is the north-east tile', tilesIn([13.05, 52.33, 13.77, 52.68], 1), [[1, 0]]);
check('extents that overlap meet; ones that do not, do not',
      [boundsMeet([0, 0, 2, 2], [1, 1, 3, 3]), boundsMeet([0, 0, 1, 1], [2, 2, 3, 3])], [true, false]);

// ── the directory codec round-trips ─────────────────────────────────────
{ const dir = [[0, 1, 0, 10], [1, 2, 10, 20], [5, 1, 30, 5], [9, 0, 0, 40]];
  check('encode → decode is the identity, contiguous offsets as zeros', decodeDirectory(encodeDirectory(dir)), dir); }

// ── the fixture ──────────────────────────────────────────────────────────
const bytes = fs.readFileSync('tests/fixtures/map/tiny.pmtiles');
const blob = new Blob([bytes]);
const h = readHeader(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + 127));
check('the header: compression, zooms, bounds', [h.internal, h.tiles, h.minZoom, h.maxZoom, h.bounds], ['gzip', 'gzip', 0, 2, [13, 52.3, 13.8, 52.7]]);

const pack = await openPack(blobSource(blob));
const text = async (p, z, x, y) => { const t = await p.tile(z, x, y); return t && new TextDecoder().decode(t); };
check("a root entry's tile", await text(pack, 0, 0, 0), '0/0/0');
check("a leaf entry's tile", await text(pack, 1, 0, 0), '1/0/0');
check('the second tile of a run shares its bytes', await text(pack, 1, 0, 1), '1/0/0');
check('a tile after the run', await text(pack, 2, 1, 1), '2/1/1');
check("a hole inside the leaf's range is null", await text(pack, 1, 1, 1), null);
check('a hole past the last entry is null', await text(pack, 2, 3, 3), null);
check('a zoom past max-zoom is null', await text(pack, 3, 0, 0), null);
check('the metadata carries the build', (await pack.metadata())['planetiler:osm:osmosisreplicationtime'], '2026-10-08T04:00:00Z');
check('a file that is not an archive is refused', (() => { try { readHeader(new TextEncoder().encode('x'.repeat(127)).buffer); return 'opened'; } catch (e) { return /not a PMTiles/.test(e.message); } })(), true);

// ── a range source, as the gateway answers one ───────────────────────────
{ const calls = [];
  globalThis.fetch = async (url, init) => {
    const m = /bytes=(\d+)-(\d+)/.exec(init.headers.Range); calls.push(m[0]);
    const part = bytes.subarray(+m[1], +m[2] + 1);
    return new Response(part, { status: 206 });
  };
  const remote = await openPack(rangeSource('/tiles/osm/tiny.pmtiles'));
  check('a remote archive reads through Range requests', await text(remote, 2, 1, 1), '2/1/1');
  check('…the header, the root, the leaf and the tile, each one range', calls.length, 4);
  globalThis.fetch = undefined; }

// ── cutting an area ──────────────────────────────────────────────────────
// the whole world to z1 touches 0/0/0 and the run 1/0/0+1/0/1 (two tiles, one range), not 1/1/1 (a hole)
const needs = await entriesIn(pack, [-180, -85, 180, 85], 1);
check('the needs of an area are its tiles that exist', needs.map(d => `${d.z}/${d.x}/${d.y}`), ['0/0/0', '1/0/0', '1/0/1']);
check('a run counts its bytes once', bytesOf(needs), needs[0].length + needs[1].length);
check('the read plan merges the neighbouring ranges into one slice', slicesFor(needs).length, 1);
check('…and keeps them apart when no gap is tolerated (the two ranges touch)', slicesFor(needs, 8 * 1024 * 1024, -1).length, 2);
check('a slice limit holds', slicesFor(needs, needs[0].length).length, 2);

// write the cut, read it back
const cut = await writePack(needs, d => pack.stored(d.z, d.x, d.y),
                            { name: 'cut', bounds: [13, 52, 14, 53], maxZoom: 1, build: '2026-10-08T04:00:00Z' }, 'gzip');
const again = await openPack(blobSource(cut));
check('the cut opens: header bounds are the area, zooms are what it holds',
      [again.header.bounds, again.header.minZoom, again.header.maxZoom], [[13, 52, 14, 53], 0, 1]);
check('…its tiles read as before', [await text(again, 0, 0, 0), await text(again, 1, 0, 0), await text(again, 1, 0, 1)], ['0/0/0', '1/0/0', '1/0/0']);
check('…what it never held is still a hole', await text(again, 1, 1, 0), null);
check('…its data section is exactly the figure promised', again.header.dataLen, bytesOf(needs));
check('…the run collapsed to one entry', (await entriesIn(again, [-180, -85, 180, 85], 1)).filter(d => d.z === 1).every(d => d.offset === needs[1].offset - needs[1].offset + needs[0].length), true);
check('…and its metadata names the build', (await again.metadata())['planetiler:osm:osmosisreplicationtime'], '2026-10-08T04:00:00Z');

console.log(`\n=== Results: ${pass} passed, ${fail} failed ===`);
process.exit(fail ? 1 : 0);
