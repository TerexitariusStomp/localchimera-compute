/// tests/ux/map-packs-ux.mjs — a map area kept on the device, end to end.
///
/// Against a running dev server whose map directory is the test fixture
/// (`PLAYNET_MAP_DIR=tests/fixtures/map PORT=8092 make serve`, which `make
/// test-map-packs-ux` starts itself): the page lists the gateway's regions,
/// measures an area (the exact figure, from the directory alone), keeps it
/// (the cut: Range slices into IndexedDB, written as one archive), and the
/// osm:// protocol then answers a tile OFF THE DEVICE — proven by cutting the
/// route to the gateway's tiles and reading the tile anyway. Rename, the
/// whole-region row, letting go. No WebGL is needed: the handler the protocol
/// registers is called directly, as maplibre would call it, and the frame's
/// own pure parts (the foot's sentence) are read off their module.
///
/// Run: UX_BASE=http://127.0.0.1:8092 node tests/ux/map-packs-ux.mjs

import { harness, launch, newPage, summarize } from './ux-harness.mjs';

const BASE = process.env.UX_BASE || 'http://127.0.0.1:8092';
const h = harness();
const browser = await launch();
const page = await newPage(browser, h);
try {
  await page.goto(`${BASE}/app.html?face=map`, { waitUntil: 'load' });
  const out = await page.evaluate(async () => {
    const m = await import('/app/map-packs.js');
    const text = (b) => new TextDecoder().decode(new Uint8Array(b));
    const regions = await m.regions();
    const tiny = regions.find(r => r.name === 'tiny');
    if (!tiny) return { regions };
    for (const n of Object.keys(m.kept())) await m.remove(n).catch(() => {});   // a clean slate
    const before = text((await m.osmTile({ url: 'osm://1/0/1' })).data);
    // the whole world to z1: 0/0/0 and the run 1/0/0+1/0/1 — the figure the directory promises
    const world = [-180, -85, 180, 85];
    const measured = await m.measure(world, 1);
    await m.keep({ name: 'Mitte', bounds: world, maxZoom: 1 });
    const kept = m.kept();
    const after = text((await m.osmTile({ url: 'osm://1/0/1' })).data);
    const hole = (await m.osmTile({ url: 'osm://1/1/1' })).data.byteLength;
    const deeper = text((await m.osmTile({ url: 'osm://2/1/1' })).data);     // past the cut's zoom: the gateway's
    return { regions, tiny, before, measured: { bytes: measured.bytes, regions: measured.regions.length, partly: measured.partly },
             kept: Object.fromEntries(Object.entries(kept).map(([k, p]) => [k, { bytes: p.bytes, build: p.build, maxZoom: p.maxZoom }])),
             after, hole, deeper };
  });
  h.rec('the gateway lists the fixture region with its build', out.tiny && out.tiny.bytes === 351 && out.tiny.build === '2026-10-08T04:00:00Z', JSON.stringify(out.regions));
  h.rec('before the download the gateway answers the tile', out.before === '1/0/0', out.before);
  h.rec('the area is measured off the directory: one region, an exact figure, not fully covered', out.measured && out.measured.regions === 1 && out.measured.bytes > 0 && out.measured.partly === true, JSON.stringify(out.measured));
  h.rec('the cut lands and the pack is kept with its build', out.kept && out.kept.Mitte && out.kept.Mitte.build === '2026-10-08T04:00:00Z' && out.kept.Mitte.maxZoom === 1, JSON.stringify(out.kept));
  h.rec('after it the same tile answers', out.after === '1/0/0', out.after);
  h.rec('a hole is empty ground, not an error', out.hole === 0, String(out.hole));
  h.rec('a tile deeper than the cut still comes from the gateway', out.deeper === '2/1/1', out.deeper);

  // cut the gateway's tiles: what is kept still draws
  await page.route('**/tiles/osm/*/*/*', route => route.abort());
  const offline = await page.evaluate(async () => {
    const m = await import('/app/map-packs.js');
    const text = (b) => new TextDecoder().decode(new Uint8Array(b));
    const kept = text((await m.osmTile({ url: 'osm://0/0/0' })).data);
    let unkept;
    try { unkept = (await m.osmTile({ url: 'osm://2/1/1' })).data.byteLength; } catch (e) { unkept = 'refused'; }
    return { kept, unkept };
  });
  h.rec('with the gateway cut, a kept tile reads off the device', offline.kept === '0/0/0', offline.kept);
  h.rec('…and a tile the pack lacks is refused, not invented', offline.unkept === 'refused', String(offline.unkept));
  await page.unroute('**/tiles/osm/*/*/*');

  // a second visit reopens what was kept; rename; the whole region; letting go returns to the gateway
  await page.goto(`${BASE}/app.html?face=map`, { waitUntil: 'load' });
  const again = await page.evaluate(async () => {
    const m = await import('/app/map-packs.js');
    const text = (b) => new TextDecoder().decode(new Uint8Array(b));
    const reopened = text((await m.osmTile({ url: 'osm://0/0/0' })).data);
    await m.rename('Mitte', 'Home');
    const renamed = Object.keys(m.kept());
    const tiny = (await m.regions()).find(r => r.name === 'tiny');
    await m.keep({ name: m.freeName('Tiny'), bounds: tiny.bounds, maxZoom: tiny.maxZoom });
    const whole = m.kept().Tiny;
    const deep = text((await m.osmTile({ url: 'osm://2/1/1' })).data);
    await m.remove('Home'); await m.remove('Tiny');
    const keptAfter = Object.keys(m.kept());
    const fromGateway = text((await m.osmTile({ url: 'osm://0/0/0' })).data);
    return { reopened, renamed, whole: whole && { bytes: whole.bytes, maxZoom: whole.maxZoom }, deep, keptAfter, fromGateway };
  });
  h.rec('a fresh page reopens the kept pack', again.reopened === '0/0/0', again.reopened);
  h.rec('rename keeps the pack under the new name only', JSON.stringify(again.renamed) === '["Home"]', JSON.stringify(again.renamed));
  h.rec('the whole region is the same cut with its own bounds, to its own depth', again.whole && again.whole.maxZoom === 2 && again.whole.bytes > 0, JSON.stringify(again.whole));
  h.rec('…and its deepest tile reads from it', again.deep === '2/1/1', again.deep);
  h.rec('letting go forgets them and the gateway answers again', again.keptAfter.length === 0 && again.fromGateway === '0/0/0', JSON.stringify(again.keptAfter));

  // the frame's sentence, and the list
  await page.goto(`${BASE}/app.html?face=map`, { waitUntil: 'load' });
  const ui = await page.evaluate(async () => {
    const sel = await import('/app/tabs/map/select-area.js');
    const m = await import('/app/map-packs.js');
    const lines = [sel.sizeLine(null, null), sel.sizeLine({ regions: [], bytes: 0, partly: true }, null),
                   sel.sizeLine(await m.measure([-180, -85, 180, 85], 1), null), sel.sizeLine(null, 'no route')];
    const { mapPacksBlock } = await import('/app/map-packs-view.js');
    const { render } = await import('/app/template.js');
    const el = document.createElement('div'); document.body.appendChild(el);
    render(el, mapPacksBlock());
    await new Promise(r => setTimeout(r, 1500));
    render(el, mapPacksBlock());
    return { lines, block: el.textContent };
  });
  h.rec('the foot says measuring, outside, the figure, or why', /measuring/.test(ui.lines[0]) && /outside every region/.test(ui.lines[1]) && /Download will use up to .* — part of this area/.test(ui.lines[2]) && /out of reach \(no route\)/.test(ui.lines[3]), JSON.stringify(ui.lines));
  h.rec('the Offline maps page lists the region whole and offers to select an area', /the whole of Tiny/.test(ui.block) && /Select your own map/.test(ui.block) && /none yet/.test(ui.block), ui.block.trim().replace(/\s+/g, ' ').slice(0, 160));
} catch (e) { h.rec('fatal', false, e.message); }
finally { await browser.close(); }
summarize(h, ['the cut lands and the pack is kept with its build', 'with the gateway cut, a kept tile reads off the device']);
