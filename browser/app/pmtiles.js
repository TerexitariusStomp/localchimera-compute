// app/pmtiles.ts — a reader for PMTiles v3 archives held on the device.
//
// The browser twin of module/playnet/utils/pmtiles.scm, over a Blob rather
// than a file: the 127-byte header, gzipped or plain directories, the Hilbert
// tile id, a binary search per directory with leaf hops, and a tile's bytes
// as a byte range of the blob. The two readers are checked against the same
// fixture (tests/fixtures/map/tiny.pmtiles; tests/browser/pmtiles-test.mjs).
//
// This module imports nothing and touches no DOM, so node loads it as it is.
const MAGIC = "PMTiles";
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
        rootOff: u64(8), rootLen: u64(16), leafOff: u64(40), leafLen: u64(48),
        dataOff: u64(56), dataLen: u64(64),
        internal: compression(v.getUint8(97)), tiles: compression(v.getUint8(98)),
        minZoom: v.getUint8(100), maxZoom: v.getUint8(101),
        bounds: [deg(102), deg(106), deg(110), deg(114)],
    };
}
/** Gunzip BYTES with the engine's own inflater. */
export async function gunzip(bytes) {
    const s = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"));
    return new Response(s).arrayBuffer();
}
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
/** Open the archive in BLOB: read its header and root directory once. */
export async function openPack(blob) {
    const slice = (off, len) => blob.slice(off, off + len).arrayBuffer();
    const header = readHeader(await slice(0, 127));
    const inflate = async (bytes, how) => how === "gzip" ? gunzip(bytes) : bytes;
    const root = decodeDirectory(await inflate(await slice(header.rootOff, header.rootLen), header.internal));
    const leaves = new Map();
    const leaf = async (off, len) => {
        const hit = leaves.get(off);
        if (hit)
            return hit;
        const dir = decodeDirectory(await inflate(await slice(header.leafOff + off, len), header.internal));
        if (leaves.size > 256)
            leaves.clear();
        leaves.set(off, dir);
        return dir;
    };
    return {
        header,
        async tile(z, x, y) {
            if (z < header.minZoom || z > header.maxZoom)
                return null;
            const id = tileId(z, x, y);
            let dir = root;
            for (let hops = 0; hops <= 3; hops++) {
                const e = findEntry(dir, id);
                if (!e)
                    return null;
                if (e[1] > 0)
                    return inflate(await slice(header.dataOff + e[2], e[3]), header.tiles);
                if (hops === 3)
                    return null;
                dir = await leaf(e[2], e[3]);
            }
            return null;
        },
    };
}
