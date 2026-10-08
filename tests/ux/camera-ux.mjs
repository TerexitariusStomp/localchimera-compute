/// tests/ux/camera-ux.mjs — the photograph screen opens the camera, and takes the
/// picture from it (ui/app/camera.ts, ui/app/capture.ts, ui/app/scan.ts).
///
/// The sheet on a photograph shows what the camera sees and a shutter under it;
/// the shot is the frame on show, read through the gateway's vision door like
/// any picture. "Or choose one you have" is the file chooser, for a picture the
/// person already has. The camera stays open across the card's redraws and is
/// let go the moment a shot is taken or the sheet is left. Where the person keeps
/// the camera to themselves, the screen says so and the shutter reaches the
/// device's own camera app.
///
/// Run via: make test-camera-ux
import { harness, launch, summarize, sleep, FAKE_MEDIA_ARGS } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch(FAKE_MEDIA_ARGS);
const page = await browser.newPage();
// a symbol reader the test feeds: what it is told to see, it sees once
await page.addInitScript(() => {
  window.__seen = [];
  window.BarcodeDetector = class {
    static async getSupportedFormats() { return ['qr_code', 'ean_13', 'code_128']; }
    constructor(o) { this.formats = o?.formats; }
    async detect(v) { (window.__looked ??= new Map()).set(v, Date.now()); return window.__seen.length ? [window.__seen.shift()] : []; }
  };
});
page.on('pageerror', e => h.errs.push(String(e).slice(0, 160)));

const card = () => page.evaluate(() => {
  const n = document.querySelector('#capture');
  if (!n || n.hidden) return null;
  const v = n.querySelector('.cap-video');
  return {
    video: !!v, playing: !!v && v.readyState >= 2 && v.videoWidth > 0,
    live: !!v && !!v.srcObject && v.srcObject.getTracks().some(t => t.readyState === 'live'),
    note: n.querySelector('.cap-cam')?.textContent.trim() ?? '',
    go: n.querySelector('.cap-go')?.textContent.trim() ?? '',
    pick: n.querySelector('.cap-pick')?.textContent.trim() ?? '',
    rows: n.querySelectorAll('.cap-look').length,
  };
});

const screen = () => page.evaluate(() => {
  const n = document.querySelector('#capture');
  if (!n || n.hidden) return null;
  return { name: n.querySelector('.cap-name')?.textContent.trim() ?? '', says: n.querySelector('.cap-says')?.textContent.trim() ?? '',
           figure: !!n.querySelector('.cap-figure'), pairs: [...n.querySelectorAll('.cap-pairs li')].map(li => li.querySelector('.cap-lname')?.textContent.trim()),
           video: !!n.querySelector('.cap-video') };
});
const show = (format, rawValue) => page.evaluate(([f, v]) => { window.__seen.push({ format: f, rawValue: v }); }, [format, rawValue]);

const install = () => page.evaluate(async () => {
  localStorage.setItem('pn.id.hint', 'EAID123|Ada|ada@example.org|');
  const { scopeSig } = await import('./app/scope.js');
  scopeSig.set('ECOMMUNE');
  window.__seam.data.inventory = {
    specs: [{ id: 'jam', name: 'jam', unit: 'each' }],
    resources: [{ id: 'bin/1/jam', name: 'plum jam', 'conforms-to': 'jam', unit: 'each', onhand: 12, location: '', code: '' }],
  };
  window.__calls = { see: [] };
  window.__tracks = [];
  const get = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
  navigator.mediaDevices.getUserMedia = async (c) => { const s = await get(c); window.__tracks.push(...s.getTracks()); return s; };
  const pin = (name, fn) => Object.defineProperty(window.__seam.handlers, name, { configurable: true, get: () => fn, set: () => {} });
  pin('allotment', () => Promise.resolve(JSON.stringify({ remaining: 5, perWeek: 21, opens: '2026-10-05T00:00:00Z', sees: true })));
  pin('readingsBetween', () => Promise.resolve(JSON.stringify({ rows: [] })));
  window.__calls.read = [];
  pin('readLabel', (code) => { window.__calls.read.push(code); return Promise.resolve(JSON.stringify({
    resource: { id: 'bin/1/jam', name: 'plum jam', 'conforms-to': 'jam', unit: 'each', onhand: 12, code: 'A1B2C3' }, contents: [] })); });
  pin('see', (...a) => { window.__calls.see.push(a); return Promise.resolve(JSON.stringify({ rows: [
    { name: 'plum jam', spec: 'jam', qty: 9, unit: 'each', lot: '', expires: '', expiresKind: '' }] })); });
  const { emit } = await import('./app/bus.js');
  emit('inventory');
});

try {
  await page.goto(`${BASE}/app.html?face=time`, { waitUntil: 'networkidle' });
  await sleep(400);
  await install();

  await page.click('#capbtn');
  await page.waitForSelector('#capture .cap-video', { timeout: 10000 });
  await page.waitForFunction(() => { const v = document.querySelector('#capture .cap-video'); return v && v.readyState >= 2 && v.videoWidth > 0; }, null, { timeout: 10000 });
  let c = await card();
  h.rec('the photograph screen shows what the camera sees', !!c && c.video && c.playing && c.live, JSON.stringify(c));
  h.rec('…with a shutter, and a way to use a photo already taken', !!c && c.go === 'take a photograph' && /a photo you have/.test(c.pick), JSON.stringify(c));

  // the camera button sits in the Express pill, beside the microphone
  const inPill = await page.evaluate(() => {
    const b = document.getElementById('capbtn'), m = document.getElementById('sbmic');
    return { inPill: !!b?.closest('.share-pill'), nextToMic: !!m && m.nextElementSibling === b };
  });
  h.rec('the camera button is inside the Express pill, right after the microphone', inPill.inPill && inPill.nextToMic, JSON.stringify(inPill));

  // the card is centered on a desktop and docks to the bottom edge on a phone
  const geo = () => page.evaluate(() => {
    const c = document.querySelector('#capture .cap-card').getBoundingClientRect();
    const v = document.querySelector('#capture .cap-video')?.getBoundingClientRect();
    const sh = document.querySelector('#capture .cap-shutter')?.getBoundingClientRect();
    return { w: innerWidth, h: innerHeight, c: { l: c.left, r: c.right, t: c.top, b: c.bottom, w: c.width },
             v: v && { w: v.width, h: v.height, b: v.bottom }, sh: sh && { cx: sh.left + sh.width / 2, w: sh.width, h: sh.height } };
  });
  for (const [name, vp] of [['desktop', { width: 1280, height: 800 }], ['laptop', { width: 1024, height: 600 }], ['phone', { width: 390, height: 780 }], ['landscape phone', { width: 780, height: 360 }]]) {
    await page.setViewportSize(vp);
    await sleep(300);
    const g = await geo();
    const phone = vp.width <= 640;
    const centredX = Math.abs((g.c.l + g.c.r) / 2 - g.w / 2) < 2;
    h.rec(`${name}: the card is centred across the screen`, centredX, JSON.stringify(g.c));
    h.rec(`${name}: ${phone ? 'the card docks to the bottom edge and spans the width' : 'the card is centred down the screen'}`,
          phone ? g.c.b >= g.h - 1 && g.c.w >= g.w - 1 : Math.abs((g.c.t + g.c.b) / 2 - g.h / 2) < 40 || g.c.t <= 17, JSON.stringify(g.c));
    h.rec(`${name}: the whole card fits the screen`, g.c.t >= 0 && g.c.b <= g.h + 1, JSON.stringify({ t: g.c.t, b: g.c.b, h: g.h }));
    h.rec(`${name}: the viewfinder stays within the card, and the shutter is centred beneath it`,
          !!g.v && g.v.w <= g.c.w && Math.abs(g.sh.cx - g.w / 2) < 3 && g.sh.w >= 56, JSON.stringify({ v: g.v, sh: g.sh }));
    if (process.env.SHOT_DIR) await page.screenshot({ path: `${process.env.SHOT_DIR}/camera-${name.replace(' ', '-')}.png` });
  }
  await page.setViewportSize({ width: 1280, height: 800 });
  await sleep(300);

  // the week's reads arrive and the card redraws: the camera follows onto the new element
  await sleep(500);
  c = await card();
  h.rec('the camera stays open when the card redraws', !!c && c.video && c.live && c.playing, JSON.stringify(c));

  // the card redraws in quick succession (the typed-code box opens and closes): one reader stays, on the video now shown
  for (let i = 0; i < 4; i++) { await page.click('#capture .cap-type'); await sleep(40); }
  await sleep(900);
  const readers = await page.evaluate(() => {
    const now = Date.now();
    const live = [...(window.__looked ?? new Map())].filter(([, t]) => now - t < 600).map(([v]) => v);
    return { n: live.length, shown: live.every(v => v.isConnected) };
  });
  h.rec('however often the card redraws, one reader looks, at the video now shown', readers.n === 1 && readers.shown, JSON.stringify(readers));

  // the shutter takes the frame on show
  await page.click('#capture .cap-go');
  await page.waitForSelector('#capture .cap-read', { timeout: 10000 });
  await page.click('#capture .cap-read');
  await page.waitForSelector('#capture .cap-look', { timeout: 15000 });
  c = await card();
  h.rec('the shot is read into rows', !!c && c.rows === 1, JSON.stringify(c));
  const see = await page.evaluate(() => window.__calls.see[0]);
  h.rec('one picture crossed, a JPEG of the frame', Array.isArray(see?.[0]) && see[0].length === 1 && see[0][0].startsWith('/9j/'), String(see?.[0]?.[0]).slice(0, 12));
  const live = await page.evaluate(() => window.__tracks.filter(t => t.readyState === 'live').length);
  h.rec('the camera is let go once the shot is taken', live === 0 && !c.video, `${live} live`);

  // choosing a picture is the file chooser, with no camera hint
  await page.click('#capture .cap-go');           // done, with a row still open: asked twice
  await sleep(150);
  await page.click('#capture .cap-go');
  await sleep(200);
  await page.click('#capbtn');
  await page.waitForSelector('#capture .cap-pick', { timeout: 10000 });
  const hint = page.evaluate(() => new Promise(ok => {
    const make = document.createElement.bind(document);
    document.createElement = (t, ...r) => { const el = make(t, ...r); if (t === 'input') setTimeout(() => ok(el.hasAttribute('capture')), 0); return el; };
  }));
  const [chooser] = await Promise.all([page.waitForEvent('filechooser'), page.click('#capture .cap-pick')]);
  h.rec('"a photo you have" opens the file chooser', !!chooser);
  h.rec('…without asking for the camera app', (await hint) === false);
  await chooser.setFiles([]);

  // ── symbols: the same camera reads what it is shown ──
  await page.keyboard.press('Escape');
  await sleep(200);
  await page.click('#capbtn');
  await page.waitForSelector('#capture .cap-video', { timeout: 10000 });
  await sleep(500);
  let sc = await screen();
  h.rec('the camera says what it reads', /label or a barcode/.test(sc?.says ?? ''), sc?.says);
  await show('qr_code', 'https://example.org/menu');
  await sleep(700);
  sc = await screen();
  h.rec('a symbol that is neither a label nor a product code is reported and left alone',
        /QR/.test(sc?.says ?? '') && /not a playnet label/.test(sc?.says ?? '') && sc.video, sc?.says);
  await show('qr_code', 'playnet:A1B2C3');
  await show('qr_code', 'playnet:A1B2C3');
  await sleep(900);
  sc = await screen();
  const reads = await page.evaluate(() => window.__calls.read);
  h.rec('a label in view opens its container', sc?.name === 'plum jam' && !sc.video, JSON.stringify(sc));
  h.rec('…asked once, though it stayed in view', reads.length === 1 && reads[0] === 'A1B2C3', JSON.stringify(reads));

  await page.keyboard.press('Escape');
  await page.evaluate(() => { window.__seen.length = 0; });
  await sleep(200);
  await page.click('#capbtn');
  await page.waitForSelector('#capture .cap-video', { timeout: 10000 });
  await sleep(500);
  await show('ean_13', '4006381333931');
  await sleep(700);
  sc = await screen();
  h.rec('a product barcode this device has not met asks which stock it is',
        /EAN-13/.test(sc?.name ?? '') && sc.pairs?.includes('plum jam'), JSON.stringify(sc));
  await page.evaluate(() => [...document.querySelectorAll('#capture .cap-pairs li')].find(li => /plum jam/.test(li.textContent)).querySelector('.cap-mini').click());
  await sleep(300);
  sc = await screen();
  h.rec('saying which stock opens its count', sc?.name === 'plum jam' && sc.figure, JSON.stringify(sc));
  const kept = await page.evaluate(() => JSON.parse(localStorage.getItem('pn.barcodes') || '{}'));
  h.rec('…and the device keeps the pairing', kept['4006381333931'] === 'bin/1/jam', JSON.stringify(kept));

  await page.keyboard.press('Escape');
  await page.evaluate(() => { window.__seen.length = 0; });
  await sleep(200);
  await page.click('#capbtn');
  await page.waitForSelector('#capture .cap-video', { timeout: 10000 });
  await sleep(500);
  await show('ean_13', '4006381333931');
  await sleep(800);
  sc = await screen();
  h.rec('the next scan of that barcode goes straight to the stock\'s count', sc?.name === 'plum jam' && sc.figure && !sc.pairs?.length, JSON.stringify(sc));

  // no model reads pictures here: the photograph taken stays on show, kept, and another can be taken
  await page.keyboard.press('Escape');
  await page.evaluate(() => {
    Object.defineProperty(window.__seam.handlers, 'allotment', { configurable: true, get: () => () => Promise.resolve(JSON.stringify({ remaining: 0, perWeek: 21, opens: '', sees: false })), set: () => {} });
  });
  await sleep(200);
  await page.click('#capbtn');
  await page.waitForSelector('#capture .cap-video', { timeout: 10000 });
  await page.waitForFunction(() => { const v = document.querySelector('#capture .cap-video'); return v && v.readyState >= 2 && v.videoWidth > 0; }, null, { timeout: 10000 });
  await sleep(400);
  await page.click('#capture .cap-go');
  await page.waitForSelector('#capture .cap-read', { timeout: 10000 });
  await page.click('#capture .cap-read');
  await page.waitForSelector('#capture .cap-still', { timeout: 10000 });
  await sleep(300);
  let still1 = await page.evaluate(() => ({
    still: document.querySelector('#capture .cap-still')?.src.startsWith('data:image/jpeg') ?? false,
    video: !!document.querySelector('#capture .cap-video'),
    says: document.querySelector('#capture .cap-says')?.textContent.trim() ?? '',
    go: document.querySelector('#capture .cap-go')?.textContent.trim() ?? '' }));
  h.rec('a picture no model reads stays on show, kept, with no dead viewfinder beside it',
        still1.still && !still1.video && /no vision model/.test(still1.says) && /kept/.test(still1.says), JSON.stringify(still1));
  h.rec('…and offers another', still1.go === 'take another', JSON.stringify(still1));
  await page.click('#capture .cap-go');
  await page.waitForFunction(() => { const v = document.querySelector('#capture .cap-video'); return v && v.readyState >= 2 && v.videoWidth > 0; }, null, { timeout: 10000 });
  still1 = await page.evaluate(() => ({ still: !!document.querySelector('#capture .cap-still'), video: !!document.querySelector('#capture .cap-video') }));
  h.rec('taking another brings the camera back', !still1.still && still1.video, JSON.stringify(still1));

  // a seat taken at a gateway whose books are empty: the model is told nothing of the demo commons
  await page.keyboard.press('Escape');
  await page.evaluate(async () => {
    window.__seam.data.inventory = { specs: [], resources: [] };
    window.__calls.see.length = 0;
    Object.defineProperty(window.__seam.handlers, 'allotment', { configurable: true, get: () => () => Promise.resolve(JSON.stringify({ remaining: 5, perWeek: 21, opens: '', sees: true })), set: () => {} });
    const { emit } = await import('./app/bus.js');
    emit('status', 'ok:EAID123|k0');
  });
  await sleep(300);
  await page.click('#capbtn');
  await page.waitForSelector('#capture .cap-video', { timeout: 10000 });
  await sleep(500);
  await page.click('#capture .cap-go');
  await page.waitForSelector('#capture .cap-read', { timeout: 10000 });
  await page.click('#capture .cap-read');
  await page.waitForSelector('#capture .cap-look', { timeout: 15000 });
  const told = await page.evaluate(() => (window.__calls.see[0] ?? [])[2] ?? '');
  h.rec('with empty books the vision door is told of no stock, and none of the demo commons',
        !/garden greens|sourdough|demo:/.test(told), told.slice(0, 160));

  // leaving the sheet lets the camera go
  await page.evaluate(() => { window.__tracks.length = 0; });
  await page.keyboard.press('Escape');
  await sleep(300);
  const stillLive = await page.evaluate(() => window.__tracks.filter(t => t.readyState === 'live').length);
  h.rec('the camera is let go when the sheet closes', stillLive === 0);
} catch (e) {
  h.rec('fatal', false, String(e).split('\n')[0].slice(0, 300));
} finally {
  await browser.close();
  closeServer();
}

// a camera kept from the page: the screen says so, and the shutter reaches the device's own app
{
  const b2 = await launch(['--use-fake-ui-for-media-stream']);
  const p2 = await b2.newPage();
  const server = await serveBrowser();
  try {
    await p2.goto(`${server.base}/app.html?face=time`, { waitUntil: 'networkidle' });
    await sleep(400);
    await p2.evaluate(async () => {
      localStorage.setItem('pn.id.hint', 'EAID123|Ada|ada@example.org|');
      navigator.mediaDevices.getUserMedia = () => Promise.reject(new DOMException('no', 'NotAllowedError'));
      const { emit } = await import('./app/bus.js');
      emit('inventory');
    });
    await p2.click('#capbtn');
    await p2.waitForSelector('#capture .cap-cam', { timeout: 10000 });
    const t = await p2.evaluate(() => ({ note: document.querySelector('#capture .cap-cam').textContent.trim(), video: !!document.querySelector('#capture .cap-video') }));
    h.rec('a camera kept from the page is said so, and no viewfinder shows', /kept to you/.test(t.note) && !t.video, JSON.stringify(t));
    const hint = p2.evaluate(() => new Promise(ok => {
      const make = document.createElement.bind(document);
      document.createElement = (tag, ...r) => { const el = make(tag, ...r); if (tag === 'input') setTimeout(() => ok(el.getAttribute('capture')), 0); return el; };
    }));
    const [chooser] = await Promise.all([p2.waitForEvent('filechooser'), p2.click('#capture .cap-go')]);
    h.rec('…and the shutter reaches the device\'s camera app', !!chooser && (await hint) === 'environment');
  } catch (e) {
    h.rec('fatal (camera kept)', false, String(e).split('\n')[0].slice(0, 300));
  } finally {
    await b2.close();
    server.close();
  }
}

summarize(h);
