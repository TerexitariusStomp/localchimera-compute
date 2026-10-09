// app/map-packs.ts — the map's regions kept on this device.
//
// A pack is one region's PMTiles archive (server: /tiles/osm/{name}.pmtiles),
// downloaded in 8 MiB range slices — each slice kept as it lands, so a
// download stopped by a lost connection or a closed tab resumes at the next
// slice — then assembled into one Blob in IndexedDB. The map reads tiles
// through the `osm://` protocol this module installs on maplibre: a tile a
// kept pack holds is read off the device; any other is fetched from the
// gateway as before. Nothing else in the map changes between online and
// offline, which is the point.
//
// Packs are read by app/pmtiles.ts; the catalogue of what the gateway offers
// is /tiles/osm/regions.json.

import { table, type Schema } from "./idb.js";
import { signal } from "./reactive.js";
import { ensurePersistent } from "./storage-health.js";
import { openPack, type Pack } from "./pmtiles.js";

/** A region as the gateway lists it. */
export interface Region {
  name: string;
  /** west, south, east, north */
  bounds: [number, number, number, number];
  minZoom: number;
  maxZoom: number;
  bytes: number;
}

/** A pack kept on this device. */
export interface KeptPack {
  name: string;
  bytes: number;
  bounds: [number, number, number, number];
  blob: Blob;
}

interface Part { key: string; name: string; index: number; blob: Blob; }

const SLICE = 8 * 1024 * 1024;

const DB: Schema = {
  name: "map-packs", version: 1,
  upgrade(db, from) {
    if (from < 1) {
      db.createObjectStore("packs", { keyPath: "name" });
      db.createObjectStore("parts", { keyPath: "key" });
    }
  },
};
const packs = table<KeptPack>(DB, "packs");
const parts = table<Part>(DB, "parts");

/** The packs this device keeps, by name: name → bytes. Read once, then kept current. */
export const kept = signal<Record<string, number>>({});
/** Downloads in flight: name → bytes landed. */
export const landing = signal<Record<string, number>>({});
/** The last download that failed, and why. */
export const lastTrouble = signal<{ name: string; why: string } | null>(null);

let opened: Map<string, Pack> | null = null;

/** Open every kept pack (once; again after a change). */
async function openAll(): Promise<Map<string, Pack>> {
  if (opened) return opened;
  const m = new Map<string, Pack>();
  let rows: KeptPack[] = [];
  try { rows = await packs.all(); } catch { /* no storage: no packs */ }
  for (const r of rows) {
    try { m.set(r.name, await openPack(r.blob)); } catch { /* a damaged pack is skipped, not fatal */ }
  }
  kept.set(Object.fromEntries(rows.map(r => [r.name, r.bytes])));
  opened = m;
  return m;
}

const reopen = (): Promise<Map<string, Pack>> => { opened = null; return openAll(); };

/** The regions the gateway offers. */
export async function regions(): Promise<Region[]> {
  const r = await fetch("/tiles/osm/regions.json", { cache: "no-cache" });
  if (!r.ok) throw new Error(`regions: ${r.status}`);
  return r.json() as Promise<Region[]>;
}

/**
 * Keep REGION on this device. Slices already landed are not fetched again.
 * Resolves when the pack is assembled and the map can read it.
 */
export async function download(region: Region): Promise<void> {
  const { name, bytes } = region;
  if (landing()[name] !== undefined) return;           // already on its way
  lastTrouble.set(null);
  await ensurePersistent();
  const count = Math.ceil(bytes / SLICE);
  try {
    const have = new Set<number>();
    for (const p of await parts.all()) if (p.name === name) have.add(p.index);
    landing.update(l => ({ ...l, [name]: have.size * SLICE }));
    for (let i = 0; i < count; i++) {
      if (have.has(i)) continue;
      const start = i * SLICE, end = Math.min(bytes, start + SLICE) - 1;
      const r = await fetch(`/tiles/osm/${encodeURIComponent(name)}.pmtiles`,
                            { headers: { Range: `bytes=${start}-${end}` } });
      if (r.status !== 206) throw new Error(`slice ${i}: ${r.status}`);
      const blob = await r.blob();
      if (blob.size !== end - start + 1) throw new Error(`slice ${i}: ${blob.size} bytes of ${end - start + 1}`);
      await parts.put({ key: `${name}/${i}`, name, index: i, blob });
      have.add(i);
      landing.update(l => ({ ...l, [name]: Math.min(bytes, have.size * SLICE) }));
    }
    const all = (await parts.all()).filter(p => p.name === name).sort((a, b) => a.index - b.index);
    const whole = new Blob(all.map(p => p.blob));
    if (whole.size !== bytes) throw new Error(`assembled ${whole.size} bytes of ${bytes}`);
    await packs.put({ name, bytes, bounds: region.bounds, blob: whole });
    for (const p of all) await parts.del(p.key);
    await reopen();
  } catch (e) {
    lastTrouble.set({ name, why: e instanceof Error ? e.message : String(e) });
    throw e;
  } finally {
    landing.update(l => { const { [name]: _, ...rest } = l; return rest; });
  }
}

/** Let REGION go: the pack, and any slices of an unfinished download. */
export async function remove(name: string): Promise<void> {
  await packs.del(name);
  for (const p of await parts.all()) if (p.name === name) await parts.del(p.key);
  await reopen();
}

/** Bytes of unfinished slices held for NAME (what a resume would skip). */
export async function partial(name: string): Promise<number> {
  let n = 0;
  try { for (const p of await parts.all()) if (p.name === name) n += p.blob.size; } catch { /* none */ }
  return n;
}

/**
 * Teach maplibre the `osm://{z}/{x}/{y}` scheme the style's source uses: a
 * kept pack answers first, the gateway otherwise. Call once, before a map is
 * built; a second call is a no-op.
 */
let installed = false;
export function installOsmProtocol(): void {
  if (installed) return;
  installed = true;
  maplibregl.addProtocol("osm", osmTile);
  void openAll();
}

/** The protocol's answer to one tile URL — kept packs first, then the gateway. */
export async function osmTile(req: { url: string }, abort?: AbortController): Promise<{ data: ArrayBuffer }> {
  const m = /^osm:\/\/(\d+)\/(\d+)\/(\d+)$/.exec(req.url);
  if (!m) throw new Error(`osm: not a tile url: ${req.url}`);
  const z = +m[1]!, x = +m[2]!, y = +m[3]!;
  for (const p of (await openAll()).values()) {
    const data = await p.tile(z, x, y);
    if (data) return { data };
  }
  const r = await fetch(`/tiles/osm/${z}/${x}/${y}`, { signal: abort?.signal });
  if (r.status === 404) return { data: new ArrayBuffer(0) };   // no tile here: empty ground, no error
  if (!r.ok) throw new Error(`tile ${z}/${x}/${y}: ${r.status}`);
  return { data: await r.arrayBuffer() };
}
