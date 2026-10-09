/// tests/ux/map-packs-ux.mjs — a map region kept on the device, end to end.
///
/// Against a running dev server whose map directory is the test fixture
/// (`PLAYNET_MAP_DIR=tests/fixtures/map PORT=8092 make serve`, which `make
/// test-map-packs-ux` starts itself): the page lists the gateway's regions,
/// keeps "tiny" (a download in Range slices into IndexedDB), and the osm://
/// protocol then answers a tile OFF THE DEVICE — proven by cutting the route
/// to the gateway's tiles and reading the tile anyway. Letting the pack go
/// sends the same tile back to the gateway. No WebGL is needed: the handler
/// the protocol registers is called directly, as maplibre would call it.
///
/// Run: UX_BASE=http://127.0.0.1:8092 node tests/ux/map-packs-ux.mjs

import { harness, launch, newPage, summarize } from './ux-harness.mjs';

const BASE = process.env.UX_BASE || 'http://127.0.0.1:8092';
const h = harness();
const browser = await launch();
const page = await newPage(browser, h);
const text = (bytes) => new TextDecoder().decode(new Uint8Array(bytes));
try {
  await page.goto(`${BASE}/app.html?face=map`, { waitUntil: 'load' });
  const out = await page.evaluate(async () => {
    const m = await import('/app/map-packs.js');
    const text = (b) => new TextDecoder().decode(new Uint8Array(b));
    const regions = await m.regions();
    const tiny = regions.find(r => r.name === 'tiny');
    if (!tiny) return { regions };
    await m.remove('tiny').catch(() => {});                       // a clean slate
    const before = text((await m.osmTile({ url: 'osm://1/0/1' })).data);
    await m.download(tiny);
    const kept = m.kept();
    const after = text((await m.osmTile({ url: 'osm://1/0/1' })).data);
    const hole = (await m.osmTile({ url: 'osm://1/1/1' })).data.byteLength;
    return { regions, tiny, before, kept, after, hole };
  });
  h.rec('the gateway lists the fixture region', out.tiny && out.tiny.bytes === 275, JSON.stringify(out.regions));
  h.rec('before the download the gateway answers the tile', out.before === '1/0/0', out.before);
  h.rec('the download lands and the pack is kept', out.kept && out.kept.tiny === 275, JSON.stringify(out.kept));
  h.rec('after it the same tile answers', out.after === '1/0/0', out.after);
  h.rec('a hole is empty ground, not an error', out.hole === 0, String(out.hole));

  // cut the gateway's tiles: what is kept still draws
  await page.route('**/tiles/osm/*/*/*', route => route.abort());
  const offline = await page.evaluate(async () => {
    const m = await import('/app/map-packs.js');
    const text = (b) => new TextDecoder().decode(new Uint8Array(b));
    const kept = text((await m.osmTile({ url: 'osm://2/1/1' })).data);
    let unkept;
    try { unkept = (await m.osmTile({ url: 'osm://1/1/0' })).data.byteLength; } catch (e) { unkept = 'refused'; }
    return { kept, unkept };
  });
  h.rec('with the gateway cut, a kept tile reads off the device', offline.kept === '2/1/1', offline.kept);
  h.rec('…and a tile the pack lacks is refused, not invented', offline.unkept === 'refused', String(offline.unkept));
  await page.unroute('**/tiles/osm/*/*/*');

  // a second visit reopens what was kept; letting go returns to the gateway
  await page.goto(`${BASE}/app.html?face=map`, { waitUntil: 'load' });
  const again = await page.evaluate(async () => {
    const m = await import('/app/map-packs.js');
    const text = (b) => new TextDecoder().decode(new Uint8Array(b));
    const reopened = text((await m.osmTile({ url: 'osm://0/0/0' })).data);
    const keptBefore = { ...m.kept() };
    await m.remove('tiny');
    const keptAfter = { ...m.kept() };
    const fromGateway = text((await m.osmTile({ url: 'osm://0/0/0' })).data);
    return { reopened, keptBefore, keptAfter, fromGateway };
  });
  h.rec('a fresh page reopens the kept pack', again.reopened === '0/0/0' && again.keptBefore.tiny === 275, JSON.stringify(again.keptBefore));
  h.rec('letting go forgets it and the gateway answers again', again.keptAfter.tiny === undefined && again.fromGateway === '0/0/0', JSON.stringify(again.keptAfter));

  // the settings block draws the region and its button
  await page.goto(`${BASE}/app.html?face=map`, { waitUntil: 'load' });
  const block = await page.evaluate(async () => {
    const { mapPacksBlock } = await import('/app/map-packs-view.js');
    const { render } = await import('/app/template.js');
    const el = document.createElement('div'); document.body.appendChild(el);
    render(el, mapPacksBlock());
    await new Promise(r => setTimeout(r, 1500));
    render(el, mapPacksBlock());
    return el.textContent;
  });
  h.rec('the offline-maps block names the region and offers to keep it', /Tiny/.test(block) && /keep on this device/.test(block), block.trim().slice(0, 120));
} catch (e) { h.rec('fatal', false, e.message); }
finally { await browser.close(); }
summarize(h, ['the download lands and the pack is kept', 'with the gateway cut, a kept tile reads off the device']);
