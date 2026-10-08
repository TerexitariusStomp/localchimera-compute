/// tests/ux/shots-ux.mjs — several shots of one scene, and photographs kept to be
/// read later (ui/app/capture.ts, ui/app/queue.ts, ui/app/photo.ts;
/// docs/observation/capture.md §9).
///
/// The shutter adds a shot to a tray under the viewfinder and the camera stays
/// live; up to four shots are read together, one request, one of the week's reads,
/// and a count that rests on several names the contact sheet of them, one picture.
/// "read later" keeps the tray as a scene waiting to be read: it survives a
/// reload, is read as it was taken, lands its counts with the instant of its
/// first shot, and leaves the queue when its rows are done. A read that cannot go
/// says why and the scene stays.
///
/// Run via: make test-shots-ux
import { harness, launch, summarize, sleep, FAKE_MEDIA_ARGS } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch(FAKE_MEDIA_ARGS);
const page = await browser.newPage();
page.on('pageerror', e => h.errs.push(String(e).slice(0, 160)));

const card = () => page.evaluate(() => {
  const n = document.querySelector('#capture');
  if (!n || n.hidden) return null;
  const off = el => el?.dataset.off === '1' || el?.disabled === true;
  return {
    name: n.querySelector('.cap-name')?.textContent.trim() ?? '',
    says: n.querySelector('.cap-says')?.textContent.trim() ?? '',
    shots: n.querySelectorAll('.cap-tray .cap-shot').length,
    count: n.querySelector('.cap-count')?.textContent.trim() ?? '',
    read: n.querySelector('.cap-read')?.textContent.trim() ?? '',
    later: !!n.querySelector('.cap-later'),
    chip: n.querySelector('.cap-queued')?.textContent.trim() ?? '',
    shutterOff: off(n.querySelector('.cap-shutter')),
    video: !!n.querySelector('.cap-video'),
    stills: n.querySelectorAll('.cap-stills .cap-still').length,
    rows: n.querySelectorAll('.cap-look').length,
    queue: [...n.querySelectorAll('.cap-queue li')].map(li => ({
      line: li.querySelector('.cap-lname')?.textContent.trim() ?? '', sub: li.querySelector('.cap-lsub')?.textContent.trim() ?? '',
      thumb: !!li.querySelector('.cap-qthumb'), readOff: off(li.querySelector('.cap-qread')) })),
    empty: /nothing is waiting/.test(n.textContent),
  };
});

const install = (allot) => page.evaluate(async (a) => {
  localStorage.setItem('pn.id.hint', 'EAID123|Ada|ada@example.org|');
  const { scopeSig } = await import('./app/scope.js');
  scopeSig.set('ECOMMUNE');
  window.__seam.data.inventory = {
    specs: [{ id: 'jam', name: 'jam', unit: 'each' }],
    resources: [{ id: 'bin/1/jam', name: 'plum jam', 'conforms-to': 'jam', unit: 'each', onhand: 12, location: '', code: '' }],
  };
  window.__calls = { see: [], count: [] };
  const pin = (name, fn) => Object.defineProperty(window.__seam.handlers, name, { configurable: true, get: () => fn, set: () => {} });
  window.__allot = a;
  pin('allotment', () => Promise.resolve(typeof window.__allot === 'string' ? window.__allot : JSON.stringify(window.__allot)));
  pin('readingsBetween', () => Promise.resolve(JSON.stringify({ rows: [] })));
  pin('see', (...x) => { window.__calls.see.push(x); return Promise.resolve(JSON.stringify({ rows: [
    { name: 'plum jam', spec: 'jam', qty: 9, unit: 'each', lot: '', expires: '', expiresKind: '' }] })); });
  pin('countStock', (...x) => { window.__calls.count.push(x); return Promise.resolve(JSON.stringify({ event: 'evt-1', record: '', hours: 0, delta: -3, onhand: Number(x[1]) })); });
  const { emit } = await import('./app/bus.js');
  emit('inventory');
}, allot);

const live = () => page.waitForFunction(() => { const v = document.querySelector('#capture .cap-video'); return v && v.readyState >= 2 && v.videoWidth > 0; }, null, { timeout: 10000 });
const shutter = async (n) => {                    // one shot more; waits until the tray says so
  await page.click('#capture .cap-shutter');
  await page.waitForFunction(k => document.querySelectorAll('#capture .cap-tray .cap-shot').length === k, n, { timeout: 10000 });
  await sleep(150);
};
const evidence = (hash) => page.evaluate(async (hs) => {
  const db = await new Promise((ok, no) => { const r = indexedDB.open('playnet-evidence', 1); r.onsuccess = () => ok(r.result); r.onerror = () => no(r.error); });
  const k = await new Promise(ok => { const r = db.transaction('pictures').objectStore('pictures').get(hs); r.onsuccess = () => ok(r.result); });
  db.close();
  if (!k) return null;
  const bmp = await createImageBitmap(k.blob);
  return { type: k.blob.type, w: bmp.width, h: bmp.height };
}, hash);
const queueKept = () => page.evaluate(() => JSON.parse(localStorage.getItem('pn.photo.queue') || '[]'));

try {
  await page.goto(`${BASE}/app.html?face=time`, { waitUntil: 'networkidle' });
  await sleep(400);
  await install({ remaining: 5, perWeek: 21, opens: '2026-10-05T00:00:00Z', sees: true });

  // ── several shots, read together ──
  await page.click('#capbtn');
  await page.waitForSelector('#capture .cap-video', { timeout: 10000 });
  await live();
  let c = await card();
  h.rec('with no shot taken there is nothing to read yet', !!c && c.shots === 0 && c.read === '' && !c.later, JSON.stringify(c));
  await shutter(1); await shutter(2); await shutter(3);
  c = await card();
  h.rec('the shutter adds shots to a tray, and the camera stays live', c.shots === 3 && c.video && c.count === '3 of 4', JSON.stringify(c));
  h.rec('…which can be read together, or kept for later', c.read === 'read 3 photos' && c.later, JSON.stringify(c));
  await page.click('#capture .cap-tray .cap-shot:nth-child(2) .cap-unshot');
  await sleep(200);
  c = await card();
  h.rec('a shot is removed with its ✕', c.shots === 2 && c.count === '2 of 4' && c.read === 'read 2 photos', JSON.stringify(c));
  await shutter(3); await shutter(4);
  c = await card();
  h.rec('four shots are the most one read takes: the shutter stops', c.shots === 4 && c.shutterOff && /most one read takes/.test(c.says), JSON.stringify(c));
  await page.click('#capture .cap-tray .cap-shot:nth-child(4) .cap-unshot');
  await sleep(200);
  await page.click('#capture .cap-read');
  await page.waitForSelector('#capture .cap-look', { timeout: 15000 });
  const see3 = await page.evaluate(() => window.__calls.see[0]);
  h.rec('one read carries every shot, as base64 JPEGs', Array.isArray(see3?.[0]) && see3[0].length === 3 && see3[0].every(b => b.startsWith('/9j/')), String(see3?.[0]?.length));
  await page.evaluate(() => [...document.querySelectorAll('#capture .cap-look .cap-mini')].find(b => /count it/.test(b.textContent)).click());
  await sleep(400);
  const cnt = await page.evaluate(() => window.__calls.count[0]);
  const proof = await evidence(cnt?.[7]);
  h.rec('the count names one picture: the contact sheet of the shots', !!proof && proof.type === 'image/jpeg' && proof.w === 1280 && proof.h === 960, JSON.stringify([cnt?.[7]?.slice(0, 14), proof]));
  h.rec('…and the instant its first shot was taken', /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(cnt?.[5] ?? '') && Math.abs(Date.parse(cnt[5]) - Date.now()) < 120000, String(cnt?.[5]));
  await page.keyboard.press('Escape');
  await sleep(200);

  // ── one shot reads as it always did ──
  await page.click('#capbtn');
  await live();
  await shutter(1);
  await page.click('#capture .cap-read');
  await page.waitForSelector('#capture .cap-look', { timeout: 15000 });
  const see1 = await page.evaluate(() => window.__calls.see[1]);
  h.rec('a single shot is a request of one picture', see1?.[0]?.length === 1, String(see1?.[0]?.length));
  await page.evaluate(() => [...document.querySelectorAll('#capture .cap-look .cap-mini')].find(b => /count it/.test(b.textContent)).click());
  await sleep(400);
  const cnt1 = await page.evaluate(() => window.__calls.count[1]);
  const own = await evidence(cnt1?.[7]);
  h.rec('…and names that picture itself, not a sheet', !!own && own.w === 640 && own.h === 480, JSON.stringify(own));
  await page.keyboard.press('Escape');
  await sleep(200);

  // ── kept to be read later ──
  const readsBefore = await page.evaluate(() => window.__calls.see.length);
  await page.click('#capbtn');
  await live();
  await shutter(1); await shutter(2);
  await page.click('#capture .cap-later');
  await sleep(300);
  c = await card();
  h.rec('read later keeps the tray and the camera stays up for the next scene', c.shots === 0 && c.video && /1 waiting/.test(c.says) && /1 waiting to be read/.test(c.chip), JSON.stringify(c));
  h.rec('…nothing is sent to be read', (await page.evaluate(() => window.__calls.see.length)) === readsBefore);
  let kept = await queueKept();
  h.rec('the scene is kept with what it knew', kept.length === 1 && kept[0].shots.length === 2 && /^\d{4}-/.test(kept[0].at) && kept[0].label, JSON.stringify(kept));
  await page.keyboard.press('Escape');
  await sleep(200);

  // it survives a reload
  await page.reload({ waitUntil: 'networkidle' });
  await sleep(600);
  await install({ remaining: 5, perWeek: 21, opens: '2026-10-05T00:00:00Z', sees: true });
  await page.click('#capbtn');
  await page.waitForSelector('#capture .cap-queued', { timeout: 10000 });
  c = await card();
  h.rec('after a reload the scene is still waiting', /1 waiting to be read/.test(c.chip), c.chip);
  await page.click('#capture .cap-queued');
  await page.waitForSelector('#capture .cap-queue li', { timeout: 10000 });
  await page.waitForSelector('#capture .cap-qthumb', { timeout: 10000 });
  c = await card();
  const thumbLen = await page.evaluate(() => document.querySelector('#capture .cap-qthumb')?.src.length ?? 0);
  h.rec('a thumbnail in the list is small', thumbLen > 0 && thumbLen < 20000, String(thumbLen));
  h.rec('the queue lists it with its photographs, and the week\'s reads', c.name === 'waiting to be read' && c.queue.length === 1 && /2 photos · \d\d:\d\d/.test(c.queue[0].line) && c.queue[0].thumb && !c.queue[0].readOff, JSON.stringify(c.queue));
  await page.click('#capture .cap-qread');
  await page.waitForSelector('#capture .cap-look', { timeout: 15000 });
  const seeQ = await page.evaluate(() => window.__calls.see.at(-1));
  h.rec('reading it sends its pictures as they were kept', seeQ?.[0]?.length === 2, String(seeQ?.[0]?.length));
  await page.evaluate(() => [...document.querySelectorAll('#capture .cap-look .cap-mini')].find(b => /count it/.test(b.textContent)).click());
  await sleep(400);
  const cntQ = await page.evaluate(() => window.__calls.count.at(-1));
  h.rec('its counts land with the instant its first shot was taken', cntQ?.[5] === kept[0].at, `${cntQ?.[5]} vs ${kept[0].at}`);
  kept = await queueKept();
  h.rec('it waits until its rows are done', kept.length === 1);
  await page.click('#capture .cap-go');             // done
  await sleep(400);
  kept = await queueKept();
  c = await card();
  h.rec('done takes it out of the queue, and the queue says so', kept.length === 0 && c?.empty, JSON.stringify([kept.length, c?.empty]));
  await page.keyboard.press('Escape');
  await sleep(200);

  // ── a read that cannot go says why, and the scene stays ──
  await page.click('#capbtn');
  await live();
  await shutter(1);
  await page.click('#capture .cap-later');
  await sleep(300);
  await page.evaluate(() => { window.__allot = { remaining: 0, perWeek: 21, opens: '2026-10-05T00:00:00Z', sees: true }; });
  await page.click('#capture .cap-queued');
  await page.waitForSelector('#capture .cap-queue li', { timeout: 10000 });
  await sleep(300);
  c = await card();
  h.rec('with the week\'s reads spent the read waits, and says when they return', c.queue[0]?.readOff && /spent · new reads 2026-10-05/.test(c.queue[0].sub), JSON.stringify(c.queue));
  await page.keyboard.press('Escape');
  await sleep(150);
  await page.evaluate(() => { window.__allot = 'err:sign in first'; });
  await page.click('#capbtn');
  await page.waitForSelector('#capture .cap-queued', { timeout: 10000 });
  await page.click('#capture .cap-queued');
  await page.waitForSelector('#capture .cap-queue li', { timeout: 10000 });
  await sleep(300);
  c = await card();
  h.rec('signed out it says to sign in, and keeps the scene', c.queue[0]?.readOff && /sign in/.test(c.queue[0].sub) && (await queueKept()).length === 1, JSON.stringify(c.queue));
  await page.click('#capture .cap-qdrop');
  await sleep(300);
  c = await card();
  h.rec('a scene is discarded when asked', c.empty && (await queueKept()).length === 0);

  // ── a picture chosen from the roll carries its own instant ──
  const instants = await page.evaluate(async () => {
    const { keepShot } = await import('./app/photo.js');
    const c = document.createElement('canvas'); c.width = 320; c.height = 240; c.getContext('2d').fillRect(0, 0, 320, 240);
    const blob = await new Promise(ok => c.toBlob(ok, 'image/jpeg', 0.8));
    const past = Date.UTC(2026, 8, 20, 10, 30, 0), future = Date.now() + 5 * 86400000;
    const a = await keepShot(new File([blob], 'old.jpg', { type: 'image/jpeg', lastModified: past }));
    const b = await keepShot(new File([blob], 'odd.jpg', { type: 'image/jpeg', lastModified: future }));
    const f = await keepShot(blob);
    return { a: a.at, b: b.at, f: f.at, now: new Date().toISOString() };
  });
  h.rec('a chosen file keeps its own instant', instants.a === '2026-09-20T10:30:00Z', instants.a);
  h.rec('…never one from the future', Date.parse(instants.b) <= Date.parse(instants.now) + 2000, instants.b);
  h.rec('a frame from the camera is taken now', Math.abs(Date.parse(instants.f) - Date.parse(instants.now)) < 5000, instants.f);

  // ── the tray and the queue fit every screen ──
  await page.evaluate(() => { window.__allot = { remaining: 5, perWeek: 21, opens: '', sees: true }; });
  await page.keyboard.press('Escape');
  await sleep(150);
  await page.click('#capbtn');
  await live();
  await shutter(1); await shutter(2); await shutter(3); await shutter(4);
  for (const [name, vp] of [['desktop', { width: 1280, height: 800 }], ['laptop', { width: 1024, height: 600 }], ['phone', { width: 390, height: 780 }], ['landscape phone', { width: 780, height: 360 }]]) {
    await page.setViewportSize(vp);
    await sleep(300);
    const g = await page.evaluate(() => {
      const cd = document.querySelector('#capture .cap-card'), r = cd.getBoundingClientRect();
      const inside = sel => { const e = document.querySelector(sel)?.getBoundingClientRect(); return !!e && e.left >= r.left - 1 && e.right <= r.right + 1; };
      return { w: innerWidth, h: innerHeight, t: r.top, b: r.bottom, noSideScroll: cd.scrollWidth <= cd.clientWidth + 1,
               tray: inside('.cap-tray'), read: inside('.cap-read'), later: inside('.cap-later'), shutter: inside('.cap-shutter') };
    });
    h.rec(`${name}: a full tray, its buttons and the shutter fit the card`, g.noSideScroll && g.tray && g.read && g.later && g.shutter && g.t >= 0 && g.b <= g.h + 1, JSON.stringify(g));
    if (process.env.SHOT_DIR) await page.screenshot({ path: `${process.env.SHOT_DIR}/shots-${name.replace(' ', '-')}.png` });
  }
  await page.setViewportSize({ width: 1280, height: 800 });
  // ── a device that cannot keep pictures still reads them, and says so when asked to keep them ──
  await page.addInitScript(() => { indexedDB.open = () => { throw new DOMException('refused', 'SecurityError'); }; });
  await page.reload({ waitUntil: 'networkidle' });
  await sleep(600);
  await install({ remaining: 5, perWeek: 21, opens: '', sees: true });
  await page.click('#capbtn');
  await live();
  await shutter(1); await shutter(2);
  await page.click('#capture .cap-read');
  await page.waitForSelector('#capture .cap-look', { timeout: 15000 });
  const noStore = await page.evaluate(() => window.__calls.see.at(-1));
  h.rec('with no store to keep pictures a tray is still read', noStore?.[0]?.length === 2, String(noStore?.[0]?.length));
  await page.keyboard.press('Escape');
  await sleep(200);
  await page.click('#capbtn');
  await live();
  await shutter(1);
  await page.click('#capture .cap-later');
  await sleep(400);
  c = await card();
  h.rec('…and read later says the device cannot keep them, and keeps the tray', /cannot keep pictures/.test(c.says) && c.shots === 1 && (await queueKept()).length === 0, JSON.stringify([c.says, c.shots]));

  h.rec('no page errors', h.errs.length === 0, h.errs.slice(0, 3).join(' | '));
} catch (e) {
  h.rec('fatal', false, String(e).split('\n')[0].slice(0, 300));
} finally {
  await browser.close();
  closeServer();
}

summarize(h);
