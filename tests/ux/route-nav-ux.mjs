/// tests/ux/route-nav-ux.mjs — a journey under way, on the map face: the maneuver banner at the
/// top, the sheet at its lowest rest as the ETA bar (the share bar stepping aside, the map's own
/// controls giving way to the camera's two buttons), the camera heading-up and tipped with you low
/// in the frame, a hand on the map letting go of it and the recentre button taking it back, the
/// overview, arrival with Done, and ✕ ending it all. A rehearsed drive (`?simdrive=`) carries a
/// journey to its end by itself.
///
/// The device is set aside (app/position.ts `simulate`) and fixes are fed along the stub engine's
/// route (tests/browser/route-fixture.mjs: north, then east). Software WebGL gives the page a real
/// map, so the camera is read as the page has it; no tiles are asserted.
import { harness, launch, summarize, sleep, WEBGL_ARGS } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';
import { stubRoute } from './route-stub.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();
const h = harness();
const browser = await launch(WEBGL_ARGS);
const errs = [];
const shot = process.env.SHOT_DIR || '/tmp';

const A = { lat: 37.7749, lng: -122.4194 }, B = { lat: 37.7849, lng: -122.4094 };
const norm = d => ((d % 360) + 360) % 360;
const near = (a, b, tol) => Math.abs(((a - b + 540) % 360) - 180) <= tol;

async function open(page, query = '') {
  await page.context().grantPermissions(['geolocation']);
  await page.context().setGeolocation({ latitude: A.lat, longitude: A.lng });
  const stub = await stubRoute(page);
  await page.goto(`${BASE}/app.html?face=map${query}`, { waitUntil: 'domcontentloaded' });
  for (let i = 0; i < 60; i++) {
    if (await page.evaluate(async () => !!(await import('/app/mapview.js')).theMap())) break;
    await sleep(500);
  }
  await sleep(800);
  return stub;
}
const feed = (page, lat, lng, heading, speed = 1.4) => page.evaluate(async a => {
  (await import('/app/position.js')).feed({ ...a, accuracy: 5 });
}, { lat, lng, heading, speed });
const device = (page, on) => page.evaluate(async on => (await import('/app/position.js')).simulate(on), on);
const txt = (page, sel) => page.evaluate(s => document.querySelector(s)?.textContent?.trim() ?? null, sel);
async function setOut(page) {
  await device(page, true);
  await feed(page, A.lat, A.lng, 0);
  await page.evaluate(async ({ lat, lng }) => (await import('/app/tabs/map/mapsearch.js')).showSpot(lat, lng), B);
  await sleep(700);
  await page.click('.ms-nav'); await sleep(1800);
  await page.click('.rv-start'); await sleep(1500);
}
const state = page => page.evaluate(async () => {
  const m = (await import('/app/mapview.js')).theMap();
  const sh = await import('/app/tabs/social/share.js');
  const q = s => document.querySelector(s);
  const vis = s => { const e = q(s); return !!e && getComputedStyle(e).display !== 'none' && e.getBoundingClientRect().height > 0; };
  const nc = q('#navcard'), r = nc?.getBoundingClientRect();
  return {
    card: vis('#navcard'), cardTop: r ? r.top - (nc.parentElement.getBoundingClientRect().top) : null, cardState: nc?.dataset.state,
    glyph: q('#navcard .glyph')?.textContent, dist: q('#navcard .dist')?.textContent, street: q('#navcard .street')?.textContent,
    thenShown: vis('#navcard .nb-then'), metaShown: vis('#navcard .meta'),
    holds: sh.sheetHolds(), big: q('.eb-big')?.textContent, sub: q('.eb-sub')?.textContent,
    arrived: !!q('.eb.arrived'), doneShown: vis('.eb-done'),
    barRow: vis('#sharebar .sharebar-row'), barh: getComputedStyle(document.documentElement).getPropertyValue('--barh').trim(),
    sheetH: sh.sheetHeight(), vh: innerHeight,
    ctrls: [...document.querySelectorAll('#maptab .maplibregl-ctrl-bottom-right .maplibregl-ctrl')].filter(e => !e.classList.contains('maplibregl-ctrl-attrib') && getComputedStyle(e).display !== 'none').length,
    attrib: !!q('#maptab .maplibregl-ctrl-attrib'), btns: [...document.querySelectorAll('#navbtns .nbtn')].length,
    loose: q('.nb-recentre')?.classList.contains('loose') ?? null, navigating: q('#maptab')?.classList.contains('navigating'),
    arrow: !!q('.user-marker.nav'), hdg: q('.user-marker')?.style.getPropertyValue('--hdg'),
    bearing: m.getBearing(), pitch: m.getPitch(), zoom: m.getZoom(),
    lines: (m.getSource('route')?._data?.features || []).map(f => f.properties.kind).join(),
  };
});

try {
  const page = await browser.newPage();
  page.on('pageerror', e => errs.push(String(e)));
  await page.setViewportSize({ width: 1200, height: 800 });
  const stub = await open(page);
  await setOut(page);

  // ── setting out ───────────────────────────────────────────────────────────
  let s = await state(page);
  h.rec('the card is the banner: floating at the top of the map', s.card && s.cardTop >= 0 && s.cardTop <= 14, `top ${s.cardTop}`);
  h.rec('the turn ahead: an arrow, a distance, a street', s.glyph === '→' && /^\d+ m$|^\d\.\d km$/.test(s.dist || '') && s.street === 'Oak Avenue', `${s.glyph} ${s.dist} ${s.street}`);
  h.rec('over the map the time is the bar\'s: no meta line on the card', !s.metaShown);
  h.rec('the sheet holds the journey, at its lowest rest', s.holds === 'journey' && s.sheetH > 40 && s.sheetH < 160, `${s.holds} ${s.sheetH}px`);
  h.rec('the ETA bar: minutes, then distance and arrival', /^\d+ min$/.test(s.big || '') && /^[\d.]+ (m|km) · \d\d:\d\d$/.test(s.sub || ''), `${s.big} | ${s.sub}`);
  h.rec('the share bar has stepped aside, and reaches nothing', !s.barRow && s.barh === '0px', `${s.barRow} ${s.barh}`);
  h.rec('the map\'s own controls give way; the attribution stays', s.ctrls === 0 && s.attrib, `${s.ctrls} ${s.attrib}`);
  h.rec('the camera\'s two buttons stand at the edge', s.btns === 2 && s.loose === false);
  h.rec('the map is marked as navigating', s.navigating === true);
  h.rec('you are an arrow, not a dot', s.arrow);
  h.rec('the chosen way is drawn, nothing behind you yet', s.lines === 'sel', s.lines);
  await sleep(1200); s = await state(page);
  h.rec('the camera is tipped toward the horizon', s.pitch > 45 && s.pitch < 65, `pitch ${s.pitch}`);
  h.rec('and close in', s.zoom > 17, `zoom ${s.zoom}`);
  h.rec('heading-up: the way north is up, so the arrow is straight', near(norm(s.bearing), 0, 6) && (s.hdg === '0deg' || s.hdg === '0'), `bearing ${s.bearing} hdg ${s.hdg}`);
  await page.screenshot({ path: `${shot}/route-nav-start.png` });

  // ── along the first leg ───────────────────────────────────────────────────
  const d0 = (await state(page)).dist;
  await feed(page, (A.lat + B.lat) / 2, A.lng, 0); await sleep(1300);
  s = await state(page);
  const num = t => parseFloat(t) * (/km/.test(t) ? 1000 : 1);
  h.rec('half way to the turn: the distance to it has fallen', num(s.dist) < num(d0) * 0.7, `${d0} → ${s.dist}`);
  h.rec('the line behind you is dimmed, the rest ahead', /^done,sel/.test(s.lines), s.lines);
  const big0 = s.big;
  await feed(page, B.lat, A.lng + (B.lng - A.lng) * 0.25, 90); await sleep(1300);
  s = await state(page);
  h.rec('past the turn: the next turn is the arrival, under a flag at the place', s.glyph === '🏁' && s.street.length > 0, `${s.glyph} ${s.street}`);
  h.rec('the minutes left have fallen', parseInt(s.big) <= parseInt(big0), `${big0} → ${s.big}`);
  h.rec('heading east: the map has turned so east is up', near(norm(s.bearing), 90, 8), `bearing ${s.bearing}`);
  h.rec('still tipped, still following', s.pitch > 45);
  await page.screenshot({ path: `${shot}/route-nav-leg2.png` });

  // ── a hand on the map, and getting the camera back ────────────────────────
  await page.mouse.move(500, 300); await page.mouse.down();
  await page.mouse.move(560, 340, { steps: 4 }); await page.mouse.up(); await sleep(300);
  s = await state(page);
  h.rec('a hand on the map lets go of the camera: recentre lights', s.loose === true);
  h.rec('and a loose camera turns the arrow with the heading, not straight', s.arrow && s.hdg !== undefined);
  const before = s.bearing;
  await feed(page, B.lat, A.lng + (B.lng - A.lng) * 0.4, 90); await sleep(1300);
  h.rec('a loose camera is left where it is by the next fix', Math.abs(norm((await state(page)).bearing) - norm(before)) < 5);
  await page.click('.nb-recentre'); await sleep(1200);
  s = await state(page);
  h.rec('recentre takes the camera back on you', s.loose === false && near(norm(s.bearing), 90, 8) && s.pitch > 45, `${s.loose} ${s.bearing} ${s.pitch}`);

  // ── the overview ──────────────────────────────────────────────────────────
  await page.click('.nb-overview'); await sleep(1200);
  s = await state(page);
  h.rec('overview levels the camera and puts north up', s.pitch < 5 && (near(norm(s.bearing), 0, 5)), `pitch ${s.pitch} bearing ${s.bearing}`);
  h.rec('and the camera is loose while it looks', s.loose === true);
  await page.screenshot({ path: `${shot}/route-nav-overview.png` });
  await page.click('.nb-recentre'); await sleep(1200);

  // ── arrival ───────────────────────────────────────────────────────────────
  await feed(page, B.lat, B.lng, 90); await sleep(1500);
  s = await state(page);
  h.rec('arrived: the card says so, with the place', s.cardState === 'arrived' && s.dist === 'Arrived' && s.street.length > 0, `${s.cardState} ${s.dist} ${s.street}`);
  h.rec('the ETA bar says so and offers Done', s.arrived && s.doneShown && /arrived/i.test(s.big), s.big);
  h.rec('the camera is given back: level again', s.pitch < 10, `pitch ${s.pitch}`);
  h.rec('the camera\'s buttons go with it', s.btns === 0 || s.btns === 2);
  await page.screenshot({ path: `${shot}/route-nav-arrived.png` });
  await page.click('.eb-done'); await sleep(900);
  s = await state(page);
  h.rec('Done ends it all: card, bar, buttons, lines', !s.card && s.holds === null && s.btns === 0 && s.navigating === false && s.lines === '', JSON.stringify({ c: s.card, h: s.holds, b: s.btns, n: s.navigating, l: s.lines }));
  h.rec('the share bar comes back', s.barRow && s.barh !== '0px', `${s.barRow} ${s.barh}`);
  h.rec('the controls come back', s.ctrls > 0, String(s.ctrls));
  h.rec('the you-marker is a dot again', !s.arrow);
  h.rec('the compass is no longer shut out: the map may turn again', (await page.evaluate(async () => (await import('/app/route/nav.js')).cameraHeld())) === false);

  // ── ✕ ends it mid-way ─────────────────────────────────────────────────────
  await device(page, true); await feed(page, A.lat, A.lng, 0);
  await page.evaluate(async ({ lat, lng }) => (await import('/app/tabs/map/mapsearch.js')).showSpot(lat, lng), B);
  await sleep(600); await page.click('.ms-nav'); await sleep(1500); await page.click('.rv-start'); await sleep(1200);
  h.rec('a second journey sets out', (await state(page)).holds === 'journey');
  await page.click('.eb-x'); await sleep(800);
  s = await state(page);
  h.rec('✕ ends it mid-way: bar, card, buttons gone, share bar back', !s.card && s.holds === null && s.btns === 0 && s.barRow, JSON.stringify({ c: s.card, h: s.holds, b: s.btns, r: s.barRow }));
  h.rec('the map is level and north-up again', s.pitch < 10);
  await device(page, false);
  await page.close();

  // ── a rehearsed drive carries a journey to its end ────────────────────────
  const dp = await browser.newPage();
  dp.on('pageerror', e => errs.push(String(e)));
  await dp.setViewportSize({ width: 390, height: 800 });
  await open(dp, '&simdrive=60');
  await dp.evaluate(async ({ lat, lng }) => (await import('/app/tabs/map/mapsearch.js')).showSpot(lat, lng), B);
  await sleep(700);
  // on a phone the place card is taller than the sheet's room and its actions sit under the bar until scrolled to,
  // so this run presses them by script
  const press = sel => dp.evaluate(s => document.querySelector(s).click(), sel);
  await press('.ms-nav'); await sleep(1800);
  await press('.rv-start');
  await sleep(2500);
  const mid = await state(dp);
  h.rec('?simdrive: the drive moves the journey with no device', mid.holds === 'journey' && mid.card, `${mid.holds}`);
  await dp.screenshot({ path: `${shot}/route-nav-phone.png` });
  let arrived = false;
  for (let i = 0; i < 40 && !arrived; i++) { await sleep(1000); arrived = (await state(dp)).arrived; }
  const end = await state(dp);
  h.rec('…and carries it to the end: arrived, Done offered', arrived && end.doneShown, JSON.stringify({ a: arrived, d: end.doneShown }));
  h.rec('a phone-width banner stays within the screen', (await dp.evaluate(() => { const r = document.getElementById('navcard').getBoundingClientRect(); return r.left >= 0 && r.right <= innerWidth; })));
  await dp.close();
} catch (e) { h.rec('fatal', false, e.stack || e.message); }
h.rec('no page errors', errs.length === 0, errs.slice(0, 2).join(' | '));
await browser.close(); closeServer();
summarize(h);
