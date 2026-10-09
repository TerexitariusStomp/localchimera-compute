// app/pmtiles.ts — PMTiles v3 on the device: read, cut, write.
//
// The browser twin of module/playnet/utils/pmtiles.scm, over a byte SOURCE
// rather than a file: the 127-byte header, gzipped or plain directories, the
// Hilbert tile id, a binary search per directory with leaf hops, and a tile's
// bytes as a byte range. A source is one function, (offset, length) → bytes:
// a Blob kept on the device, or a gateway archive read by HTTP Range — the
// same reader serves both, which is what lets an AREA be cut on the device
// out of the gateway's region archives (entriesIn + writePack) with nothing
// new on the server. The two readers are checked against the same fixture
// (tests/fixtures/map/tiny.pmtiles; tests/browser/pmtiles-test.mjs).
//
// This module imports nothing and touches no DOM, so node loads it as it is.
const MAGIC = "PMTiles";
const HEADER = 127;
// ── tile ids and tile math ───────────────────────────────────────────────
/** The PMTiles id of tile z/x/y: every tile of the zooms below, then its place on the curve. */
export function tileId(z, x, y) {
    let base = 0;
    for (let i = 0; i < z; i++)
        base += 4 ** i;
    if (z === 0)
        return 0;
    let d = 0;
    for (let s = 2 ** (z - 1); s > 0; s = Math.floor(s / 2)) {
        const rx = (x & s) ? 1 : 0, ry = (y & s) ? 1 : 0;
        d += s * s * ((3 * rx) ^ ry);
        if (ry === 0) {
            if (rx === 1) {
                x = s - 1 - x;
                y = s - 1 - y;
            }
            const t = x;
            x = y;
            y = t;
        }
    }
    return base + d;
}
/** The tile at zoom Z under a coordinate (Web Mercator), clamped to the grid. */
export function lngLatToTile(lng, lat, z) {
    const n = 2 ** z;
    const clamp = (v) => Math.max(0, Math.min(n - 1, Math.floor(v)));
    const latR = Math.max(-85.0511, Math.min(85.0511, lat)) * Math.PI / 180;
    return [clamp((lng + 180) / 360 * n),
        clamp((1 - Math.log(Math.tan(latR) + 1 / Math.cos(latR)) / Math.PI) / 2 * n)];
}
/** Every tile of zoom Z that BOUNDS touches, as [x, y]. */
export function tilesIn(bounds, z) {
    const [w, s, e, n] = bounds;
    const [x0, y0] = lngLatToTile(w, n, z), [x1, y1] = lngLatToTile(e, s, z);
    const out = [];
    for (let x = x0; x <= x1; x++)
        for (let y = y0; y <= y1; y++)
            out.push([x, y]);
    return out;
}
/** Whether two extents overlap. */
export const boundsMeet = (a, b) => a[0] < b[2] && b[0] < a[2] && a[1] < b[3] && b[1] < a[3];
// ── bytes ────────────────────────────────────────────────────────────────
const compression = (code) => {
    if (code === 1)
        return "none";
    if (code === 2)
        return "gzip";
    throw new Error(`pmtiles: compression ${code} is not served`);
};
/** The header of an archive, from its first 127 bytes. */
export function readHeader(bytes) {
    const v = new DataView(bytes);
    const magic = new TextDecoder().decode(new Uint8Array(bytes, 0, 7));
    if (magic !== MAGIC)
        throw new Error("pmtiles: not a PMTiles archive");
    if (v.getUint8(7) !== 3)
        throw new Error(`pmtiles: version ${v.getUint8(7)}`);
    if (v.getUint8(99) !== 1)
        throw new Error("pmtiles: vector tiles only");
    const u64 = (o) => Number(v.getBigUint64(o, true));
    const deg = (o) => v.getInt32(o, true) / 1e7;
    return {
        rootOff: u64(8), rootLen: u64(16), metaOff: u64(24), metaLen: u64(32),
        leafOff: u64(40), leafLen: u64(48), dataOff: u64(56), dataLen: u64(64),
        internal: compression(v.getUint8(97)), tiles: compression(v.getUint8(98)),
        minZoom: v.getUint8(100), maxZoom: v.getUint8(101),
        bounds: [deg(102), deg(106), deg(110), deg(114)],
    };
}
const pipe = async (bytes, s) => new Response(new Blob([bytes]).stream().pipeThrough(s)).arrayBuffer();
/** Gunzip BYTES with the engine's own inflater. */
export const gunzip = (bytes) => pipe(bytes, new DecompressionStream("gzip"));
/** Gzip BYTES with the engine's own deflater. */
export const gzip = (bytes) => pipe(bytes, new CompressionStream("gzip"));
/** A directory's bytes (uncompressed) as entries sorted by tile id. */
export function decodeDirectory(bytes) {
    const b = new Uint8Array(bytes);
    let pos = 0;
    const varint = () => {
        let shift = 0, acc = 0;
        for (;;) {
            const byte = b[pos++];
            acc += (byte & 0x7f) * 2 ** shift; // past 2^31 a shift would overflow; multiply does not
            if ((byte & 0x80) === 0)
                return acc;
            shift += 7;
        }
    };
    const n = varint();
    const ids = [], runs = [], lens = [], offs = [];
    let last = 0;
    for (let i = 0; i < n; i++) {
        last += varint();
        ids.push(last);
    }
    for (let i = 0; i < n; i++)
        runs.push(varint());
    for (let i = 0; i < n; i++)
        lens.push(varint());
    for (let i = 0; i < n; i++) {
        const v = varint();
        offs.push(v === 0 && i > 0 ? offs[i - 1] + lens[i - 1] : v - 1);
    }
    return ids.map((id, i) => [id, runs[i], offs[i], lens[i]]);
}
/** ENTRIES (sorted by id) as a directory's bytes, uncompressed — the spec's four columns. */
export function encodeDirectory(entries) {
    const out = [];
    const varint = (n) => {
        while (n >= 0x80) {
            out.push((n % 0x80) | 0x80);
            n = Math.floor(n / 0x80);
        }
        out.push(n);
    };
    varint(entries.length);
    let last = 0;
    for (const e of entries) {
        varint(e[0] - last);
        last = e[0];
    }
    for (const e of entries)
        varint(e[1]);
    for (const e of entries)
        varint(e[3]);
    for (let i = 0; i < entries.length; i++) {
        const e = entries[i], p = entries[i - 1];
        varint(p && e[2] === p[2] + p[3] ? 0 : e[2] + 1);
    }
    return new Uint8Array(out).buffer;
}
/** The entry of DIR holding tile ID — a run that covers it, or the leaf it falls under — or null. */
export function findEntry(dir, id) {
    let lo = 0, hi = dir.length - 1;
    while (lo <= hi) {
        const k = (lo + hi) >> 1, c = id - dir[k][0];
        if (c > 0)
            lo = k + 1;
        else if (c < 0)
            hi = k - 1;
        else
            return dir[k];
    }
    if (hi < 0)
        return null;
    const e = dir[hi];
    return e[1] === 0 || id - e[0] < e[1] ? e : null;
}
// ── sources ──────────────────────────────────────────────────────────────
/** A kept pack: the blob's own bytes. */
export const blobSource = (blob) => (off, len) => blob.slice(off, off + len).arrayBuffer();
/** A gateway archive: one HTTP Range per read (the server answers 206, at most 8 MiB). */
export const rangeSource = (url) => async (off, len) => {
    const r = await fetch(url, { headers: { Range: `bytes=${off}-${off + len - 1}` } });
    if (r.status !== 206)
        throw new Error(`${url}: ${r.status} for a range`);
    const b = await r.arrayBuffer();
    if (b.byteLength !== len)
        throw new Error(`${url}: ${b.byteLength} bytes of ${len}`);
    return b;
};
/** Open the archive SOURCE reads: its header and root directory once. */
export async function openPack(source) {
    const header = readHeader(await source(0, HEADER));
    const inflate = async (bytes, how) => how === "gzip" ? gunzip(bytes) : bytes;
    const root = decodeDirectory(await inflate(await source(header.rootOff, header.rootLen), header.internal));
    const leaves = new Map();
    const leaf = async (off, len) => {
        const hit = leaves.get(off);
        if (hit)
            return hit;
        const dir = decodeDirectory(await inflate(await source(header.leafOff + off, len), header.internal));
        if (leaves.size > 256)
            leaves.clear();
        leaves.set(off, dir);
        return dir;
    };
    const entry = async (z, x, y) => {
        if (z < header.minZoom || z > header.maxZoom)
            return null;
        const id = tileId(z, x, y);
        let dir = root;
        for (let hops = 0; hops <= 3; hops++) {
            const e = findEntry(dir, id);
            if (!e)
                return null;
            if (e[1] > 0)
                return e;
            if (hops === 3)
                return null;
            dir = await leaf(e[2], e[3]);
        }
        return null;
    };
    const stored = async (z, x, y) => {
        const e = await entry(z, x, y);
        return e ? source(header.dataOff + e[2], e[3]) : null;
    };
    return {
        header, entry, stored,
        async tile(z, x, y) { const b = await stored(z, x, y); return b ? inflate(b, header.tiles) : null; },
        async metadata() {
            if (!header.metaLen)
                return {};
            const b = await inflate(await source(header.metaOff, header.metaLen), header.internal);
            try {
                return JSON.parse(new TextDecoder().decode(b));
            }
            catch {
                return {};
            }
        },
    };
}
/** The bytes a need points at, as one key: two sources' offsets never collide. */
export const rangeKey = (d) => `${d.src ?? ""}:${d.offset}/${d.length}`;
/**
 * The tiles of PACK that BOUNDS touches from the pack's min zoom to MAXZOOM,
 * by directory lookup alone: no tile bytes move, so the sum of their lengths
 * is the exact size of the cut. Tiles sharing bytes (a run) are listed each,
 * with the same offset; `bytesOf` counts each distinct range once.
 */
export async function entriesIn(pack, bounds, maxZoom, src) {
    const out = [];
    const top = Math.min(maxZoom, pack.header.maxZoom);
    for (let z = pack.header.minZoom; z <= top; z++)
        for (const [x, y] of tilesIn(bounds, z)) {
            const e = await pack.entry(z, x, y);
            if (e)
                out.push(src === undefined ? { z, x, y, offset: e[2], length: e[3] } : { z, x, y, offset: e[2], length: e[3], src });
        }
    return out;
}
/** The bytes a cut of NEEDS moves: each distinct (offset, length) once. */
export function bytesOf(needs) {
    const seen = new Set();
    let n = 0;
    for (const d of needs) {
        const k = rangeKey(d);
        if (!seen.has(k)) {
            seen.add(k);
            n += d.length;
        }
    }
    return n;
}
/**
 * The read plan for NEEDS: distinct ranges sorted by offset, merged when the
 * gap between two is under GAP, each slice at most LIMIT long. Tiles of one
 * area are neighbours on the Hilbert curve, so a few slices cover a city.
 */
export function slicesFor(needs, limit = 8 * 1024 * 1024, gap = 64 * 1024) {
    const ranges = [...new Map(needs.map(d => [rangeKey(d), d])).values()]
        .sort((a, b) => a.offset - b.offset);
    const out = [];
    for (const r of ranges) {
        const last = out[out.length - 1];
        const end = r.offset + r.length;
        if (last && r.offset - last.end <= gap && end - last.offset <= limit)
            last.end = Math.max(last.end, end);
        else
            out.push({ offset: r.offset, end });
    }
    return out;
}
/**
 * A v3 archive of NEEDS, whose stored bytes BYTES(need) hands back: one
 * gzipped root directory (tiles sharing bytes collapse to a run), the tiles
 * as stored (so the writer never inflates), header bounds = the area, the
 * metadata JSON = META. Readable by openPack and by the Guile reader alike.
 */
export async function writePack(needs, bytes, meta, stored) {
    // each distinct range lands once in the data section, in id order
    const byId = [...needs].sort((a, b) => tileId(a.z, a.x, a.y) - tileId(b.z, b.x, b.y));
    const placed = new Map();
    const parts = [];
    let dataLen = 0;
    const entries = [];
    for (const d of byId) {
        const id = tileId(d.z, d.x, d.y);
        const key = rangeKey(d);
        let at = placed.get(key);
        if (!at) {
            const b = await bytes(d);
            at = { offset: dataLen, length: b.byteLength };
            placed.set(key, at);
            parts.push(b);
            dataLen += b.byteLength;
        }
        const last = entries[entries.length - 1];
        if (last && last[0] + last[1] === id && last[2] === at.offset && last[3] === at.length)
            last[1]++;
        else
            entries.push([id, 1, at.offset, at.length]);
    }
    const root = await gzip(encodeDirectory(entries));
    const metadata = await gzip(new TextEncoder().encode(JSON.stringify({
        name: meta.name, bounds: meta.bounds, maxzoom: meta.maxZoom,
        ...(meta.build ? { "planetiler:osm:osmosisreplicationtime": meta.build } : {}),
    })).buffer);
    const h = new ArrayBuffer(HEADER);
    const v = new DataView(h);
    new Uint8Array(h).set(new TextEncoder().encode(MAGIC), 0);
    v.setUint8(7, 3);
    const rootOff = HEADER, metaOff = rootOff + root.byteLength, leafOff = metaOff + metadata.byteLength, dataOff = leafOff;
    const u64 = (o, n) => v.setBigUint64(o, BigInt(n), true);
    u64(8, rootOff);
    u64(16, root.byteLength);
    u64(24, metaOff);
    u64(32, metadata.byteLength);
    u64(40, leafOff);
    u64(48, 0);
    u64(56, dataOff);
    u64(64, dataLen);
    u64(72, needs.length);
    u64(80, entries.length);
    u64(88, placed.size);
    v.setUint8(96, 1); // clustered
    v.setUint8(97, 2); // directories: gzip
    v.setUint8(98, stored === "gzip" ? 2 : 1); // tiles: as stored
    v.setUint8(99, 1); // vector
    const zs = needs.map(d => d.z);
    v.setUint8(100, zs.length ? Math.min(...zs) : 0);
    v.setUint8(101, zs.length ? Math.max(...zs) : meta.maxZoom);
    const deg = (o, d) => v.setInt32(o, Math.round(d * 1e7), true);
    deg(102, meta.bounds[0]);
    deg(106, meta.bounds[1]);
    deg(110, meta.bounds[2]);
    deg(114, meta.bounds[3]);
    v.setUint8(118, Math.min(meta.maxZoom, 12));
    deg(119, (meta.bounds[0] + meta.bounds[2]) / 2);
    deg(123, (meta.bounds[1] + meta.bounds[3]) / 2);
    return new Blob([h, root, metadata, ...parts]);
}
