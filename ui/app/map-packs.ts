// app/map-packs.ts — the map's areas kept on this device.
//
// A pack is one area's PMTiles archive, CUT ON THE DEVICE out of the gateway's
// region archives (server: /tiles/osm/{name}.pmtiles by Range, the list at
// /tiles/osm/regions.json): the region's directory is read by Range, the
// framed tiles are looked up in it, their bytes fetched in a few coalesced
// 8 MiB slices — each kept as it lands, so a download stopped by a lost
// connection or a closed tab resumes at the next slice — and written as one
// small archive into IndexedDB. A whole region ("Berlin") is the same cut with
// the region's own bounds; there is one path.
//
// The map reads tiles through the `osm://` protocol this module installs on
// maplibre: a tile a kept pack holds is read off the device; any other is
// fetched from the gateway. Nothing else in the map changes between online
// and offline, which is the point.

import { table, type Schema } from "./idb.js";
import { signal } from "./reactive.js";
import { ensurePersistent } from "./storage-health.js";
import { openPack, blobSource, rangeSource, entriesIn, bytesOf, slicesFor, writePack, boundsMeet,
         type Pack, type Bounds, type Need } from "./pmtiles.js";

/** A region as the gateway lists it. */
export interface Region {
  name: string;
  bounds: Bounds;
  minZoom: number;
  maxZoom: number;
  bytes: number;
  /** The OpenStreetMap data's date, ISO; null when the archive says none. */
  build: string | null;
}

/** An area to keep: a name, its extent, how deep. */
export interface Area { name: string; bounds: Bounds; maxZoom: number; }

/** A pack kept on this device. */
export interface KeptPack {
  name: string;
  bytes: number;
  bounds: Bounds;
  maxZoom: number;
  /** The build it was cut from — "update" shows when the gateway's is newer. */
  build: string | null;
  /** When it landed, ms since the epoch. */
  keptAt: number;
  blob: Blob;
}

/** One slice of a download, kept as it lands. */
interface Part { key: string; name: string; index: number; offset: number; blob: Blob; }

const DB: Schema = {
  name: "map-packs", version: 2,
  upgrade(db, from) {
    if (from < 1) {
      db.createObjectStore("packs", { keyPath: "name" });
      db.createObjectStore("parts", { keyPath: "key" });
    }
    // v2 cuts areas; the v1 parts (slices of a whole file) mean nothing to it
    if (from === 1) { db.deleteObjectStore("parts"); db.createObjectStore("parts", { keyPath: "key" }); }
  },
};
const packs = table<KeptPack>(DB, "packs");
const parts = table<Part>(DB, "parts");

/** What this device keeps, by name. Read once, then kept current. */
export const kept = signal<Record<string, KeptPack>>({});
/** Downloads in flight: name → bytes landed of bytes wanted. */
export const landing = signal<Record<string, { done: number; total: number }>>({});
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
    try { m.set(r.name, await openPack(blobSource(r.blob))); } catch { /* a damaged pack is skipped, not fatal */ }
  }
  kept.set(Object.fromEntries(rows.map(r => [r.name, r])));
  opened = m;
  return m;
}

const reopen = (): Promise<Map<string, Pack>> => { opened = null; return openAll(); };

// ── the gateway's regions ────────────────────────────────────────────────

let regionList: Promise<Region[]> | null = null;
const regionPacks = new Map<string, Promise<Pack>>();

/** The regions the gateway offers (asked once per page; `again` re-asks). */
export function regions(again = false): Promise<Region[]> {
  if (again || !regionList) {
    regionList = fetch("/tiles/osm/regions.json", { cache: "no-cache" }).then(async r => {
      if (!r.ok) throw new Error(`regions: ${r.status}`);
      return r.json() as Promise<Region[]>;
    });
    regionList.catch(() => { regionList = null; });
  }
  return regionList;
}

const regionUrl = (name: string): string => `/tiles/osm/${encodeURIComponent(name)}.pmtiles`;

/** A region's archive, opened over Range reads; its directories stay in memory for the page. */
function regionPack(r: Region): Promise<Pack> {
  let p = regionPacks.get(r.name);
  if (!p) { p = openPack(rangeSource(regionUrl(r.name))); regionPacks.set(r.name, p); p.catch(() => regionPacks.delete(r.name)); }
  return p;
}

/** What cutting BOUNDS to MAXZOOM would take, region by region: the exact bytes, by directory lookup alone. */
export interface Measure {
  /** Every region the area touches, with what each contributes. */
  regions: { region: Region; needs: Need[]; bytes: number }[];
  bytes: number;
  /** Whether the area reaches outside every region the gateway offers. */
  partly: boolean;
}

export async function measure(bounds: Bounds, maxZoom: number): Promise<Measure> {
  const all = await regions();
  const touching = all.filter(r => boundsMeet(r.bounds, bounds));
  const rows = [];
  for (const region of touching) {
    const needs = await entriesIn(await regionPack(region), bounds, Math.min(maxZoom, region.maxZoom), region.name);
    rows.push({ region, needs, bytes: bytesOf(needs) });
  }
  const covered = touching.some(r => r.bounds[0] <= bounds[0] && r.bounds[1] <= bounds[1]
                                  && r.bounds[2] >= bounds[2] && r.bounds[3] >= bounds[3]);
  return { regions: rows, bytes: rows.reduce((n, r) => n + r.bytes, 0), partly: !covered };
}

// ── keeping an area ──────────────────────────────────────────────────────

/**
 * Keep AREA on this device: cut it out of every region it touches, in
 * resumable slices, and write one archive. Resolves when the map can read it.
 */
export async function keep(area: Area): Promise<void> {
  const { name } = area;
  if (landing()[name]) return;                        // already on its way
  lastTrouble.set(null);
  await ensurePersistent();
  landing.update(l => ({ ...l, [name]: { done: 0, total: 0 } }));
  try {
    const m = await measure(area.bounds, area.maxZoom);
    if (!m.regions.length) throw new Error("outside every region this gateway offers");
    landing.update(l => ({ ...l, [name]: { done: 0, total: m.bytes } }));
    const have = new Map<string, Part>();
    for (const p of await parts.all()) if (p.name === name) have.set(p.key, p);
    const stored = (await regionPack(m.regions[0]!.region)).header.tiles;
    const needs: Need[] = [];
    const landedBy = new Map<string, Part[]>();
    let done = 0;
    for (const row of m.regions) {
      const slices = slicesFor(row.needs);
      const landed: Part[] = [];
      // a need's offset is within the data section; the archive's bytes start at dataOff
      const dataOff = (await regionPack(row.region)).header.dataOff;
      for (let i = 0; i < slices.length; i++) {
        const s = slices[i]!, key = `${name}/${row.region.name}/${i}`;
        let part = have.get(key);
        if (!part) {
          const r = await fetch(regionUrl(row.region.name), { headers: { Range: `bytes=${dataOff + s.offset}-${dataOff + s.end - 1}` } });
          if (r.status !== 206) throw new Error(`${row.region.name}, slice ${i}: ${r.status}`);
          const blob = await r.blob();
          if (blob.size !== s.end - s.offset) throw new Error(`${row.region.name}, slice ${i}: ${blob.size} bytes of ${s.end - s.offset}`);
          part = { key, name, index: i, offset: s.offset, blob };
          await parts.put(part);
        }
        landed.push(part);
        done += part.blob.size;
        landing.update(l => ({ ...l, [name]: { done: Math.min(done, m.bytes), total: m.bytes } }));
      }
      landedBy.set(row.region.name, landed);
      needs.push(...row.needs);
    }
    // a tile's bytes come out of the slice of its region that holds its range
    const bytesOfNeed = (d: Need): Promise<ArrayBuffer> => {
      const p = (landedBy.get(d.src!) ?? []).find(x => d.offset >= x.offset && d.offset + d.length <= x.offset + x.blob.size);
      if (!p) throw new Error(`${d.src}: no slice holds ${d.z}/${d.x}/${d.y}`);
      return p.blob.slice(d.offset - p.offset, d.offset - p.offset + d.length).arrayBuffer();
    };
    const build = m.regions.map(r => r.region.build).filter((b): b is string => !!b).sort().pop() ?? null;
    const blob = await writePack(needs, bytesOfNeed, { name, bounds: area.bounds, maxZoom: area.maxZoom, build }, stored);
    await packs.put({ name, bytes: blob.size, bounds: area.bounds, maxZoom: area.maxZoom, build, keptAt: Date.now(), blob });
    for (const p of await parts.all()) if (p.name === name) await parts.del(p.key);
    await reopen();
  } catch (e) {
    lastTrouble.set({ name, why: e instanceof Error ? e.message : String(e) });
    throw e;
  } finally {
    landing.update(l => { const { [name]: _, ...rest } = l; return rest; });
  }
}

/** Let NAME go: the pack, and any slices of an unfinished download. */
export async function remove(name: string): Promise<void> {
  await packs.del(name);
  for (const p of await parts.all()) if (p.name === name) await parts.del(p.key);
  await reopen();
}

/** Call NAME something else; the map reads it the same. */
export async function rename(name: string, to: string): Promise<void> {
  to = to.trim();
  if (!to || to === name) return;
  const row = await packs.get(name);
  if (!row) return;
  if (await packs.get(to)) throw new Error(`a map called "${to}" is already kept`);
  await packs.put({ ...row, name: to });
  await packs.del(name);
  await reopen();
}

/** Cut NAME again from the gateway's current build, keeping its area. */
export async function update(name: string): Promise<void> {
  const row = kept()[name];
  if (!row) return;
  await remove(name);
  await keep({ name, bounds: row.bounds, maxZoom: row.maxZoom });
}

/** Whether the gateway holds a newer build than PACK was cut from. */
export function staler(pack: KeptPack, rs: Region[]): boolean {
  const newest = rs.filter(r => boundsMeet(r.bounds, pack.bounds)).map(r => r.build).filter((b): b is string => !!b).sort().pop();
  return !!(newest && pack.build && newest > pack.build);
}

/** A name no kept pack carries yet: BASE, then "BASE 2", "BASE 3"… */
export function freeName(base: string): string {
  const taken = kept();
  if (!taken[base]) return base;
  for (let i = 2; ; i++) if (!taken[`${base} ${i}`]) return `${base} ${i}`;
}

/** Bytes of unfinished slices held for NAME (what a resume would skip). */
export async function partial(name: string): Promise<number> {
  let n = 0;
  try { for (const p of await parts.all()) if (p.name === name) n += p.blob.size; } catch { /* none */ }
  return n;
}

// ── the protocol ─────────────────────────────────────────────────────────

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
