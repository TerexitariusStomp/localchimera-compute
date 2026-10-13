/// tests/ux/route-preview-ux.mjs — ↦ directions opens the ways, not a journey:
/// the from/to card at the top of the map, the sheet (owner "route") with a tab
/// and a time for every mode, the chosen route heavy and its alternatives pale
/// with a time each, all framed between card and sheet; ⇅ swaps the ends; a tap
/// on the map leaves the preview up; Start hands the chosen way to the
/// wayfinder without asking the engine again; ✕ returns to the place card.
///
/// /route is answered from the synthetic engine (tests/browser/route-fixture.mjs).
/// Software WebGL (WEBGL_ARGS) gives the page a real map, so the layers, the
/// markers and the camera are read as the page has them; no tiles are asserted.
import { harness, launch, summarize, sleep, WEBGL_ARGS } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';
import { stubRoute } from './route-stub.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();
const h = harness();
const browser = await launch(WEBGL_ARGS);
const errs = [];
const shot = process.env.SHOT_DIR || '/tmp';

const HERE = { latitude: 37.7749, longitude: -122.4194 };
const SPOT = { lat: 37.7849, lng: -122.4094 };

async function open(page, { down = false } = {}) {
  await page.context().grantPermissions(['geolocation']);
  await page.context().setGeolocation(HERE);
  const stub = await stubRoute(page, { down });
  await page.goto(`${BASE}/app.html?face=map`, { waitUntil: 'domcontentloaded' });
  for (let i = 0; i < 60; i++) {
    if (await page.evaluate(async () => !!(await import('/app/mapview.js')).theMap())) break;
    await sleep(500);
  }
  await sleep(800);
  return stub;
}
const spotNav = page => page.evaluate(async ({ lat, lng }) => {
  (await import('/app/tabs/map/mapsearch.js')).showSpot(lat, lng);
}, SPOT);
const txt = (page, sel) => page.evaluate(s => document.querySelector(s)?.textContent?.trim() ?? null, sel);
const state = page => page.evaluate(async () => {
  const m = (await import('/app/mapview.js')).theMap();
  const sh = await import('/app/tabs/social/share.js');
  const src = m.getSource('route');
  const data = src?._data || src?._options?.data || null;
  const card = document.getElementById('routecard');
  const cb = card?.getBoundingClientRect();
  const sheetTop = sh.sheetHeight() ? innerHeight - sh.sheetHeight() : innerHeight;
  const feats = (data?.features || []).map(f => ({ kind: f.properties.kind, n: f.geometry.coordinates.length, c: f.geometry.coordinates }));
  const cont = m.getContainer().getBoundingClientRect();
  const pts = feats.filter(f => f.kind !== 'bearing').flatMap(f => f.c.map(([x, y]) => m.project([x, y])));
  // the map's pixels start at its container's corner; the card and the sheet are in the page's
  const box = pts.length ? { x0: Math.min(...pts.map(p => p.x)) + cont.left, x1: Math.max(...pts.map(p => p.x)) + cont.left,
                             y0: Math.min(...pts.map(p => p.y)) + cont.top, y1: Math.max(...pts.map(p => p.y)) + cont.top } : null;
  const inside = !box || (box.x0 >= cont.left && box.x1 <= cont.right && box.y0 >= (cb ? cb.bottom : 0) - 2 && box.y1 <= sheetTop + 2);
  return { zoom: m.getZoom(), cont: [cont.left, cont.top, cont.width, cont.height].map(Math.round).join(','), holds: sh.sheetHolds(), card: !!card, cardTop: cb && cont ? cb.top - cont.top : null, box: box && JSON.stringify(box, (k, v) => typeof v === 'number' ? Math.round(v) : v), cardBottom: cb?.bottom ?? null,
           feats: feats.map(f => f.kind), inside, layers: ['route-sel', 'route-alt', 'route-bearing'].map(l => !!m.getLayer(l)),
           pills: [...document.querySelectorAll('.rv-pill')].map(e => ({ t: e.textContent, sel: e.classList.contains('sel') })),
           pin: document.querySelectorAll('.rv-pin').length, dot: document.querySelectorAll('.rv-dot').length,
           tabs: [...document.querySelectorAll('.rv-tab')].map(e => ({ id: e.dataset.mode, t: e.querySelector('b').textContent, on: e.classList.contains('on') })),
           from: document.querySelector('.rc-in-from')?.value, to: document.querySelector('.rc-in-to')?.value,
           fromYou: document.querySelector('.rc-in-from')?.classList.contains('you'), sheetTop, vh: innerHeight };
});

try {
  // ── the ways, with the engine up ───────────────────────────────────────────
  const page = await browser.newPage();
  page.on('pageerror', e => errs.push(String(e)));
  await page.setViewportSize({ width: 1200, height: 800 });
  const stub = await open(page);
  h.rec('a real map stands (software WebGL)', await page.evaluate(async () => !!(await import('/app/mapview.js')).theMap()));

  await spotNav(page); await sleep(700);
  h.rec('a dropped spot opens its card, with directions', !!(await page.$('.ms-nav')));
  await page.click('.ms-nav');
  await sleep(1800);
  let s = await state(page);
  h.rec('the sheet holds the route', s.holds === 'route', String(s.holds));
  h.rec('the from/to card floats at the top of the map', s.card && s.cardTop >= 0 && s.cardTop <= 14, `top ${s.cardTop}`);
  h.rec('the origin is you, in blue', s.from === 'Your location' && s.fromYou);
  h.rec('the destination is the spot', !!s.to && s.to.length > 0, s.to);
  h.rec('every mode asked once, transit with its clock', stub.calls.length === 4 &&
        stub.calls.some(c => /profile=multimodal/.test(c) && /depart=now/.test(c)), stub.calls.join(' | '));
  h.rec('four tabs, each with a time', s.tabs.length === 4 && s.tabs.every(t => /^\d+ min$|^\d+ h/.test(t.t)), JSON.stringify(s.tabs));
  h.rec('the tabs read transit, walk, bicycle, drive in order', s.tabs.map(t => t.id).join() === 'multimodal,pedestrian,bicycle,auto');
  h.rec('walk is the tab that opens', s.tabs.find(t => t.on)?.id === 'pedestrian');
  h.rec('the sheet titles the mode', (await txt(page, '.rv-title')) === 'Walk');
  h.rec('the summary reads "N min (x km)"', /^\d+ min \([\d.]+ (km|m)\)$/.test(await txt(page, '.rv-big') || ''), await txt(page, '.rv-big'));
  h.rec('and when you would arrive', /arrive \d\d:\d\d/.test(await txt(page, '.rv-sub') || ''));
  h.rec('three ways drawn: one chosen, two alternatives', s.feats.join() === 'sel,alt,alt', s.feats.join());
  h.rec('the layers are up', s.layers[0] && s.layers[1]);
  h.rec('a time on every way, the chosen one marked', s.pills.length === 3 && s.pills.filter(p => p.sel).length === 1, JSON.stringify(s.pills));
  h.rec('the chosen way is the best one, and says so', /Best route/.test(s.pills.find(p => p.sel)?.t || ''));
  h.rec('the destination has its pin; you have no second dot', s.pin === 1 && s.dot === 0);
  h.rec('the whole of every way is framed between card and sheet', s.inside, `card ${s.cardBottom} sheet ${s.sheetTop} box ${s.box} zoom ${s.zoom} cont ${s.cont}`);
  await page.screenshot({ path: `${shot}/route-preview-walk.png` });

  // ── another mode: a tab, no new asking ─────────────────────────────────────
  const callsBefore = stub.calls.length;
  await page.click('.rv-tab[data-mode="bicycle"]'); await sleep(900);
  s = await state(page);
  h.rec('the bicycle tab is chosen and titled', s.tabs.find(t => t.on)?.id === 'bicycle' && (await txt(page, '.rv-title')) === 'Bicycle');
  h.rec('a tab asks the engine nothing more', stub.calls.length === callsBefore, `${callsBefore} → ${stub.calls.length}`);
  h.rec('the mode is remembered', await page.evaluate(() => localStorage.getItem('pn.map.route.mode')) === 'bicycle');
  await page.click('.rv-tab[data-mode="multimodal"]'); await sleep(900);
  s = await state(page);
  h.rec('transit draws one way — dotted on foot, solid on the ride — and names its line', s.feats.join() === 'walk,sel,walk' && /48/.test(await txt(page, '.rv-sub') || ''), await txt(page, '.rv-sub'));
  await page.screenshot({ path: `${shot}/route-preview-transit.png` });
  await page.click('.rv-tab[data-mode="pedestrian"]'); await sleep(700);

  // ── an alternative, and a tap on the map ───────────────────────────────────
  const alt = (await page.$$('.rv-pill'))[1];
  await alt.click(); await sleep(300);
  s = await state(page);
  h.rec('a time pill chooses its way', s.feats.join() === 'alt,sel,alt' && s.pills[1].sel, JSON.stringify(s.feats));
  h.rec('and the summary follows it', !/Best route/.test(s.pills[1].t));
  await page.mouse.click(40, 300); await sleep(400);
  h.rec('a tap on the map leaves the preview up', (await state(page)).holds === 'route');

  // ── the ends ───────────────────────────────────────────────────────────────
  await page.click('.rc-swap'); await sleep(900);
  s = await state(page);
  h.rec('⇅ swaps the ends: you are the destination now', s.to === 'Your location' && s.from !== 'Your location', `${s.from} → ${s.to}`);
  h.rec('the new origin gets its own dot', s.dot === 1);
  h.rec('a journey sets out from you: Start says so', /from my location/i.test(await txt(page, '.rv-start') || ''));
  h.rec('the swap asked again, every mode', stub.calls.length === callsBefore + 4, `${stub.calls.length}`);
  await page.click('.rc-swap'); await sleep(900);
  s = await state(page);
  h.rec('⇅ again puts you back at the start', s.from === 'Your location' && s.fromYou && s.dot === 0);
  await page.focus('.rc-in-to');
  await page.keyboard.type('zzzz-no-such-place'); await sleep(200);
  h.rec('a name nothing matches offers nothing', await page.evaluate(() => document.querySelector('.rc-hits').hidden));
  await page.focus('.rc-in-from'); await sleep(200);
  h.rec('the origin field offers "Your location"', /Your location/.test(await txt(page, '.rc-hits') || ''));
  await page.keyboard.press('Escape'); await sleep(200);
  h.rec('Esc closes the offers and keeps the preview', (await state(page)).holds === 'route');

  // ── Start ──────────────────────────────────────────────────────────────────
  const before = stub.calls.length;
  await page.click('.rv-start'); await sleep(1500);
  s = await state(page);
  h.rec('Start: the preview is gone — card, pale ways, markers, sheet — and the journey draws its own way', !s.card && s.holds === null && s.feats.join() === 'sel' && s.pin === 0 && s.pills.length === 0, JSON.stringify(s));
  h.rec('Start asks the engine nothing: the chosen way is taken as it is', stub.calls.length === before, `${before} → ${stub.calls.length}`);
  const nc = await page.evaluate(() => { const c = document.getElementById('navcard'); return { show: getComputedStyle(c).display !== 'none', t: c.textContent }; });
  h.rec('the wayfinder is under way, on the mode that was chosen', nc.show && /Head north|Turn right/.test(nc.t) && nc.t.includes('🚶'), nc.t);
  await page.evaluate(async () => (await import('/app/route/nav.js')).endNav());

  // ── ✕ goes back to the place; Esc closes ───────────────────────────────────
  await spotNav(page); await sleep(500);
  await page.click('.ms-nav'); await sleep(1200);
  await page.click('.rv-x'); await sleep(600);
  s = await state(page);
  h.rec('✕ closes the preview and returns to the place card', !s.card && !!(await page.$('.ms-detail')) && s.holds === 'map', s.holds);
  await page.click('.ms-nav'); await sleep(900);
  await page.keyboard.press('Escape'); await sleep(500);
  h.rec('Esc closes the preview', !(await state(page)).card);
  await page.close();

  // ── the engine down ────────────────────────────────────────────────────────
  const dp = await browser.newPage();
  dp.on('pageerror', e => errs.push(String(e)));
  await dp.setViewportSize({ width: 1200, height: 800 });
  await open(dp, { down: true });
  await spotNav(dp); await sleep(600);
  await dp.click('.ms-nav'); await sleep(1800);
  s = await state(dp);
  h.rec('no engine: every tab is a dash', s.tabs.every(t => t.t === '–'), JSON.stringify(s.tabs));
  h.rec('…and says routing is unavailable, as the crow flies', /unavailable/.test(await txt(dp, '.rv-big') || '') && /crow flies/.test(await txt(dp, '.rv-sub') || ''));
  h.rec('…drawn as a bearing, not a route', s.feats.join() === 'bearing' && s.layers[2]);
  h.rec('Go by compass is offered; Start is not', !!(await dp.$('.rv-go')) && !(await dp.$('.rv-start:not(.rv-go)')));
  await dp.screenshot({ path: `${shot}/route-preview-down.png` });
  await dp.click('.rv-go'); await sleep(1200);
  const nd = await dp.evaluate(() => { const c = document.getElementById('navcard'); return { show: getComputedStyle(c).display !== 'none', t: c.textContent }; });
  h.rec('Go by compass sets out on the compass card', nd.show && /crow flies/.test(nd.t), nd.t);
} catch (e) { h.rec('fatal', false, e.stack || e.message); }
h.rec('no page errors', errs.length === 0, errs.slice(0, 2).join(' | '));
await browser.close(); closeServer();
summarize(h);
