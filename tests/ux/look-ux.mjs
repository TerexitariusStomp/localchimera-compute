/// tests/ux/look-ux.mjs — a photograph read into rows, and each row landed
/// (ui/app/capture.ts, ui/app/photo.ts, ui/app/look.ts, ui/app/offer.ts;
/// docs/observation/capture.md §9, §10).
///
/// The camera button in the share bar opens the sheet on a photograph. The
/// sheet says what is left of the week's reads, takes the picture, reads it
/// through the gateway's vision door and shows one row per thing it names. A
/// row that matches a thing held is a count of it (technique photo, the
/// picture's hash as evidence); a row that matches nothing is a first sighting,
/// declared as the person's own, and offered to the commons in one more tap.
/// Each row can be struck, and its figure is typed over. With no vision model
/// the photograph is kept and nothing is sent.
///
/// Run via: make test-look-ux
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
page.on('pageerror', e => h.errs.push(String(e).slice(0, 160)));

const sheet = () => page.evaluate(() => {
  const n = document.querySelector('#capture');
  if (!n || n.hidden) return null;
  const t = sel => n.querySelector(sel)?.textContent.trim() ?? '';
  return {
    name: t('.cap-name'), says: t('.cap-says'), reads: t('.cap-reads'), go: t('.cap-go'),
    rows: [...n.querySelectorAll('.cap-look')].map(li => ({
      cls: li.className,
      name: li.querySelector('.cap-rname')?.value ?? li.querySelector('.cap-lname')?.textContent.trim() ?? '',
      qty: li.querySelector('.cap-qty')?.value ?? null,
      unit: li.querySelector('.cap-runit')?.value ?? null,
      sub: li.querySelector('.cap-lsub')?.textContent.trim() ?? '',
      verbs: [...li.querySelectorAll('.cap-mini')].map(b => b.textContent.trim()),
    })),
  };
});
const miniOf = (row, label) => page.evaluate(([i, l]) =>
  [...document.querySelectorAll('#capture .cap-look')][i]
    ?.querySelectorAll('.cap-mini') && [...[...document.querySelectorAll('#capture .cap-look')][i].querySelectorAll('.cap-mini')]
      .find(b => b.textContent.trim() === l)?.click(), [row, label]);

// a JPEG the page itself draws: a real picture for the camera to hand over
const jpeg = async () => Buffer.from(await page.evaluate(() => {
  const c = document.createElement('canvas'); c.width = 320; c.height = 240;
  const g = c.getContext('2d'); g.fillStyle = '#c33'; g.fillRect(0, 0, 320, 240); g.fillStyle = '#fff'; g.fillRect(40, 40, 100, 100);
  return c.toDataURL('image/jpeg', 0.8).split(',')[1];
}), 'base64');

const install = (allotment) => page.evaluate(async (allot) => {
  localStorage.setItem('pn.id.hint', 'EAID123|Ada|ada@example.org|');
  const { scopeSig } = await import('./app/scope.js');
  scopeSig.set('ECOMMUNE');
  window.__seam.data.inventory = {
    specs: [{ id: 'jam', name: 'jam', unit: 'each' }],
    resources: [{ id: 'bin/1/jam', name: 'plum jam', 'conforms-to': 'jam', unit: 'each', onhand: 12, location: '', code: '' }],
  };
  window.__calls = { see: [], count: [], declare: [], socialize: [], allotment: 0, between: 0 };
  const pin = (name, fn) => Object.defineProperty(window.__seam.handlers, name, { configurable: true, get: () => fn, set: () => {} });
  pin('allotment', () => { window.__calls.allotment++; return Promise.resolve(JSON.stringify(allot)); });
  pin('readingsBetween', () => { window.__calls.between++; return Promise.resolve(JSON.stringify({ rows: [] })); });
  pin('see', (...a) => { window.__calls.see.push(a); return Promise.resolve(JSON.stringify({ rows: [
    { name: 'plum jam', spec: 'jam', qty: 9, unit: 'each', lot: '', expires: '', expiresKind: '' },
    { name: 'desk lamp', spec: 'lamp', qty: 1, unit: 'each', lot: 'L7', expires: '', expiresKind: '' },
  ] })); });
  pin('countStock', (...a) => { window.__calls.count.push(a); return Promise.resolve(JSON.stringify({ event: 'evt-1', record: '', hours: 0, delta: Number(a[1]) - 12, onhand: Number(a[1]) })); });
  pin('declareMeans', (...a) => { window.__calls.declare.push(a); return Promise.resolve('ok'); });
  pin('socialize', (...a) => { window.__calls.socialize.push(a); return Promise.resolve('ok'); });
  const { emit } = await import('./app/bus.js');
  emit('inventory');
}, allotment);

const shoot = async () => {
  const [chooser] = await Promise.all([
    page.waitForEvent('filechooser'),
    page.click('#capture .cap-go'),
  ]);
  await chooser.setFiles({ name: 'shelf.jpg', mimeType: 'image/jpeg', buffer: await jpeg() });
  // the shot waits in the tray; reading it is a tap of its own
  await page.waitForSelector('#capture .cap-read', { timeout: 10000 });
  await page.click('#capture .cap-read');
};

try {
  await page.goto(`${BASE}/app.html?face=time`, { waitUntil: 'networkidle' });
  await sleep(400);
  // a picture kept past its days goes with the next boot
  await page.evaluate(async () => {
    const db = await new Promise((ok, no) => {
      const r = indexedDB.open('playnet-evidence', 1);
      r.onupgradeneeded = () => r.result.createObjectStore('pictures', { keyPath: 'hash' });
      r.onsuccess = () => ok(r.result); r.onerror = () => no(r.error);
    });
    await new Promise(ok => { const t = db.transaction('pictures', 'readwrite'); t.objectStore('pictures').put({ hash: 'sha256:' + '9'.repeat(64), blob: new Blob([new Uint8Array([1])]), at: Date.now() - 200 * 86400000 }); t.oncomplete = ok; });
    db.close();
  });
  await page.reload({ waitUntil: 'networkidle' });
  await sleep(600);
  const stale = await page.evaluate(async () => {
    const db = await new Promise((ok, no) => { const r = indexedDB.open('playnet-evidence', 1); r.onsuccess = () => ok(r.result); r.onerror = () => no(r.error); });
    const all = await new Promise(ok => { const r = db.transaction('pictures').objectStore('pictures').getAll(); r.onsuccess = () => ok(r.result); });
    db.close();
    return all.filter(k => k.hash === 'sha256:' + '9'.repeat(64)).length;
  });
  h.rec('a picture kept past its days is swept at boot', stale === 0, String(stale));
  await install({ remaining: 5, perWeek: 21, opens: '2026-10-05T00:00:00Z', sees: true });

  h.rec('the share bar carries a camera button', await page.evaluate(() => !!document.getElementById('capbtn')));
  await page.click('#capbtn');
  await sleep(300);
  let s = await sheet();
  h.rec('the button opens the camera', !!s && /camera/.test(s.name), s?.name);
  h.rec('the sheet says what is left of the week\'s reads', !!s && /5 of 21 photo reads left/.test(s.reads), s?.reads);

  await shoot();
  await page.waitForSelector('#capture .cap-look', { timeout: 15000 });
  s = await sheet();
  h.rec('the picture is read into one row per thing', !!s && s.rows.length === 2, JSON.stringify(s?.rows.map(r => r.name)));
  h.rec('a row that names a thing held is a count of it',
        !!s && /counts plum jam, the ledger reads 12 each/.test(s.rows[0].sub), s?.rows[0].sub);
  h.rec('a row that names nothing held is a first sighting', !!s && /first sighting/.test(s.rows[1].sub), s?.rows[1].sub);
  h.rec('…carrying the lot its label stated', !!s && /lot L7/.test(s.rows[1].sub), s?.rows[1].sub);
  const see = await page.evaluate(() => window.__calls.see[0]);
  h.rec('one picture crossed, as base64', Array.isArray(see?.[0]) && see[0].length === 1 && /^[A-Za-z0-9+/=]+$/.test(see[0][0]), String(see?.[0]?.[0]).slice(0, 20));
  h.rec('the model was told what the ledger holds', /plum jam/.test(see?.[2] ?? ''), String(see?.[2]).slice(0, 80));

  // the figure is typed over, then the row lands
  const between0 = await page.evaluate(() => window.__calls.between);
  await page.fill('#capture .cap-qty[data-i="0"]', '9');
  await miniOf(0, 'count it');
  await sleep(300);
  h.rec('a count landed from a photo row asks the spec\'s history again', (await page.evaluate(() => window.__calls.between)) > between0, String(between0));
  s = await sheet();
  const c = await page.evaluate(() => window.__calls.count[0]);
  h.rec('a confirmed row is a count of the thing held', c?.[0] === 'bin/1/jam' && c?.[1] === 9 && c?.[2] === 'each', JSON.stringify(c));
  h.rec('…under the photo technique', c?.[3] === 'photo');
  h.rec('…with the picture\'s hash as evidence', /^sha256:[0-9a-f]{64}$/.test(c?.[7] ?? ''), String(c?.[7]));
  h.rec('the row says which way the ledger was off', !!s && /3 each more than is there/.test(s.rows[0].sub), s?.rows[0].sub);

  // a first sighting is declared, then offered
  await miniOf(1, 'declare it');
  await sleep(300);
  s = await sheet();
  const d = await page.evaluate(() => window.__calls.declare[0]);
  h.rec('a first sighting is declared as the person\'s own', d?.[0] === 'lamp' && d?.[1] === 1 && d?.[2] === 'each' && d?.[7] === 'desk lamp', JSON.stringify(d));
  h.rec('…noting that a picture showed it', /seen in a photo/.test(d?.[5] ?? '') && /lot L7/.test(d?.[5] ?? ''), String(d?.[5]));
  h.rec('the row offers it to the commons', !!s && s.rows[1].verbs.includes('offer to the commons'), JSON.stringify(s?.rows[1]));
  await miniOf(1, 'offer to the commons');
  await sleep(150);
  s = await sheet();
  h.rec('the offer asks for how long', !!s && s.rows[1].verbs.includes('a month') && s.rows[1].verbs.includes('open-ended'), JSON.stringify(s?.rows[1].verbs));
  await miniOf(1, 'a month');
  await sleep(300);
  const g = await page.evaluate(() => window.__calls.socialize[0]);
  h.rec('the offer names the commune and the resource', g?.[0] === 'ECOMMUNE' && g?.[7] === 'means:EAID123:lamp', JSON.stringify(g));
  h.rec('…for a month', /^\d{4}-\d{2}-\d{2}$/.test(g?.[3] ?? ''), String(g?.[3]));
  s = await sheet();
  h.rec('the sheet says the person still owns it', !!s && /you still own it/.test(s.says), s?.says);

  await page.evaluate(() => document.querySelector('#capture .cap-go').click());
  await sleep(150);
  h.rec('done closes the sheet', (await sheet()) === null);

  // with no vision model: the photograph is kept, nothing is sent
  await install({ remaining: 0, perWeek: 21, opens: '', sees: false });
  await page.click('#capbtn');
  await sleep(300);
  s = await sheet();
  h.rec('with no model the sheet says so', !!s && /no vision model/.test(s.reads), s?.reads);
  await shoot();
  await sleep(1200);
  s = await sheet();
  h.rec('the photograph is kept and nothing is sent to be read',
        (await page.evaluate(() => window.__calls.see.length)) === 0 && !!s && /kept/.test(s.says), s?.says);
  const kept = await page.evaluate(async () => {
    const { readEvidence } = await import('./app/photo.js');
    const db = await new Promise((ok, no) => { const r = indexedDB.open('playnet-evidence', 1); r.onsuccess = () => ok(r.result); r.onerror = () => no(r.error); });
    const all = await new Promise(ok => { const r = db.transaction('pictures').objectStore('pictures').getAll(); r.onsuccess = () => ok(r.result); });
    return { n: all.length, back: all.length ? !!(await readEvidence(all[0].hash)) : false };
  });
  h.rec('the picture is in the evidence store on the device', kept.n >= 1 && kept.back, JSON.stringify(kept));

  // ── the walk-up count: marks, one tap for what looks right, "we need more", a count of nothing ──
  await page.keyboard.press('Escape'); await sleep(200);
  await page.evaluate(async () => {
    const flows = [{ id: 'bake', action: 'consume', quantity: -3, when: '', proc: 'bake' }];
    window.__seam.data.inventory = {
      specs: [{ id: 'bread', name: 'bread', unit: 'each' }, { id: 'cheese', name: 'cheese', unit: 'kg' }, { id: 'tea', name: 'tea', unit: 'kg' }, { id: 'rice', name: 'rice', unit: 'kg' }],
      resources: [
        { id: 's/shelf', name: 'the shelf', 'conforms-to': 'shelf', unit: 'each', onhand: 1, location: '', code: '' },
        { id: 's/bread', name: 'bread', 'conforms-to': 'bread', unit: 'each', onhand: 18, location: '', code: '', 'contained-in': 's/shelf', expected: { low: 12, high: 15, flows } },
        { id: 's/cheese', name: 'cheese', 'conforms-to': 'cheese', unit: 'kg', onhand: 2, location: '', code: '', 'contained-in': 's/shelf' },
        { id: 's/tea', name: 'tea', 'conforms-to': 'tea', unit: 'kg', onhand: 6, location: '', code: '', 'contained-in': 's/shelf', expected: { low: 4, high: 6, flows } },
        { id: 's/rice', name: 'rice', 'conforms-to': 'rice', unit: 'kg', onhand: 40, location: '', code: '', 'contained-in': 's/shelf' },
      ],
    };
    window.__calls.count = []; window.__calls.need = [];
    const pin = (name, fn) => Object.defineProperty(window.__seam.handlers, name, { configurable: true, get: () => fn, set: () => {} });
    pin('allotment', () => Promise.resolve(JSON.stringify({ remaining: 5, perWeek: 21, opens: '', sees: true })));
    pin('see', () => Promise.resolve(JSON.stringify({ rows: [
      { name: 'cheese', spec: 'cheese', qty: 2, unit: 'kg', lot: '', expires: '', expiresKind: '' },
      { name: 'tea', spec: 'tea', qty: 5, unit: 'kg', lot: '', expires: '', expiresKind: '' },
      { name: 'bread', spec: 'bread', qty: 4, unit: 'each', lot: '', expires: '', expiresKind: '' },
      { name: 'olive oil', spec: 'olive oil', qty: 3, unit: 'each', lot: '', expires: '', expiresKind: '' },
    ] })));
    const held = { 's/bread': 18, 's/cheese': 2, 's/tea': 6, 's/rice': 40 };
    pin('countStock', (...a) => { window.__calls.count.push(a);
      return Promise.resolve(JSON.stringify({ event: 'e', record: 'r', hours: 0, delta: Number(a[1]) - held[a[0]], onhand: Number(a[1]),
        expected: a[0] === 's/bread' ? { low: 12, high: 15, flows } : null })); });
    pin('declareNeed', (...a) => { window.__calls.need.push(a); return Promise.resolve('ok'); });
    const { emit } = await import('./app/bus.js');
    emit('inventory');
  });
  const walk = () => page.evaluate(() => {
    const n = document.querySelector('#capture');
    return {
      chips: [...n.querySelectorAll('.cap-held:not(.cap-absent) .cap-chip')].map(c => c.textContent.trim()),
      absent: [...n.querySelectorAll('.cap-absent .cap-chip')].map(c => c.textContent.trim()),
      all: n.querySelector('.cap-all')?.textContent.trim() ?? '',
      go: n.querySelector('.cap-go')?.textContent.trim() ?? '',
      says: n.querySelector('.cap-says')?.textContent.trim() ?? '',
      rows: [...n.querySelectorAll('.cap-look')].map(li => ({
        name: li.querySelector('.cap-rname')?.value ?? li.querySelector('.cap-lname')?.textContent.trim() ?? '',
        mark: li.querySelector('.cap-mark')?.getAttribute('aria-label') ?? '',
        sub: li.querySelector('.cap-lsub')?.textContent.trim() ?? '',
        done: li.classList.contains('done'),
        verbs: [...li.querySelectorAll('.cap-mini')].map(b => b.textContent.trim()),
      })),
    };
  });
  const tap = (row, re) => page.evaluate(([i, src]) =>
    [...[...document.querySelectorAll('#capture .cap-look')][i].querySelectorAll('.cap-mini')].find(b => new RegExp(src).test(b.textContent))?.click(), [row, re.source]);
  await page.click('#capbtn');
  await sleep(400);
  let w = await walk();
  h.rec('with no place known the camera names nothing as held here', w.chips.length === 0, JSON.stringify(w.chips));
  await page.keyboard.press('Escape'); await sleep(200);
  await page.evaluate(async () => { const { openCapturePhotoOf } = await import('./app/capture.js'); openCapturePhotoOf('s/shelf'); });
  await sleep(400);
  w = await walk();
  h.rec('the camera opens on what is held here, as chips', w.chips.includes('bread') && w.chips.includes('rice'), JSON.stringify(w.chips));
  await shoot();
  await page.waitForSelector('#capture .cap-look', { timeout: 15000 });
  w = await walk();
  h.rec('each row leads with how its figure stands',
        w.rows.map(r => r.mark).join('|') === 'as the ledger reads|inside what the plan expects|under what was to be there|a first sighting', JSON.stringify(w.rows.map(r => r.mark)));
  h.rec('a row says what the plan expects beside the ledger', /the ledger reads 18 each · the plan expects 12–15 each/.test(w.rows[2].sub), w.rows[2].sub);
  h.rec('one button lands what looks right', w.all === 'looks right · count 2', w.all);
  h.rec('a thing held and absent from the picture is offered as a count of nothing', w.absent.join() === 'rice · 0', JSON.stringify(w.absent));
  await page.click('#capture .cap-all');
  await sleep(700);
  w = await walk();
  let counts = await page.evaluate(() => window.__calls.count.map(a => [a[0], a[1], a[3]]));
  h.rec('…the two rows land as photo counts, in order', JSON.stringify(counts) === JSON.stringify([['s/cheese', 2, 'photo'], ['s/tea', 5, 'photo']]), JSON.stringify(counts));
  h.rec('…and the rows under, and the first sighting, wait', w.rows[0].done && w.rows[1].done && !w.rows[2].done && !w.rows[3].done && w.all === '', JSON.stringify(w.rows.map(r => r.done)));
  h.rec('a short row offers "we need more"', w.rows[2].verbs.includes('we need more') && !w.rows[3].verbs.includes('we need more'), JSON.stringify(w.rows[2].verbs));
  await tap(2, /we need more/);
  await sleep(300);
  w = await walk();
  const asked = await page.evaluate(async () => { const { myNeeds } = await import('./app/tabs/social/share.js'); const n = myNeeds().find(x => x.spec === 'bread'); return n ? n.qty : null; });
  h.rec('…which asks for the shortfall against the plan\'s low end', asked === 8 && /asked for 8 each more bread/.test(w.says), `${asked} · ${w.says}`);
  h.rec('…once: the row says it and the button is gone', /asked for 8 each more/.test(w.rows[2].sub) && !w.rows[2].verbs.includes('we need more'), w.rows[2].sub);
  await tap(2, /count it/);
  await sleep(200);
  w = await walk();
  h.rec('a figure far from what is held asks twice', w.rows[2].verbs.some(v => /really 4\? the ledger reads 18/.test(v)) && (await page.evaluate(() => window.__calls.count.length)) === 2, JSON.stringify(w.rows[2].verbs));
  await tap(2, /really 4/);
  await sleep(400);
  w = await walk();
  h.rec('…and lands on the second tap, with the plan\'s word', w.rows[2].done && /14 each more than is there/.test(w.rows[2].sub) && /8 each under what the plan expected: 12–15 each/.test(w.rows[2].sub), w.rows[2].sub);
  await page.click('#capture .cap-absent .cap-chip');
  await sleep(300);
  w = await walk();
  h.rec('a tap on an absent thing adds its count of nothing', w.rows.length === 5 && w.rows[4].name === 'rice' && w.rows[4].mark === 'under what was to be there' && w.absent.length === 0, JSON.stringify(w.rows[4]));
  await page.click('#capture .cap-go');
  await sleep(200);
  w = await walk();
  h.rec('done with rows unsettled asks twice', w.go === 'leave 2 unsettled?', w.go);
  await page.click('#capture .cap-go');
  await sleep(300);
  h.rec('…and the second tap leaves', (await sheet()) === null);

  h.rec('no page errors', h.errs.length === 0, h.errs.slice(0, 3).join(' | '));
} catch (e) {
  h.rec('fatal', false, [e.message.split('\n')[0], ...h.errs.slice(0, 5)].join(' | '));
}

await browser.close();
closeServer();
summarize(h);
