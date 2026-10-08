/// tests/ux/share-hear-ux.mjs — the bar's mic never leaves the speaker guessing.
///   · held: a pulsing "listening ···" beside the words
///   · a refused microphone says so in the bar
///   · the speech model's first download fills a ring round the mic, then a check
/// (The microphone and the model worker are stubbed: getUserMedia waits or
/// refuses on cue, and the worker reports download progress on a timer.)
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();
const h = harness();
const browser = await launch();
const page = await browser.newPage();
await page.setViewportSize({ width: 1400, height: 900 });
const errs = [];
page.on('pageerror', e => errs.push(String(e)));
await page.addInitScript(() => {
  window.__gum = 'pending';
  Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: {
    getUserMedia: () => window.__gum === 'refuse' ? Promise.reject(new Error('denied')) : new Promise(() => {}) } });
  // a download as the real one goes: the small files land at once, then the
  // encoder and the decoder come down in pieces, then the runtime builds
  window.Worker = class {
    postMessage(m) {
      if (m.type !== 'preload') return;
      const ev = (status, file, loaded, total) => this.onmessage({ data: { progress: { status, file, loaded, total } } });
      ev('done', 'tokenizer.json', 3761754, 3761754); ev('done', 'config.json', 921, 921);
      let i = 0;
      const t = setInterval(() => {
        i++;
        if (i <= 10) ev('progress', 'encoder.onnx', i * 3088233, 30882331);
        else ev('progress', 'decoder.onnx', (i - 10) * 4465068, 44650684);
        if (i === 20) { clearInterval(t); setTimeout(() => this.onmessage({ data: { id: m.id, ok: true } }), 1500); }
      }, 150);
    }
  };
});
const shot = process.env.SHOT_DIR || '/tmp';
const mark = () => page.evaluate(() => {
  const m = document.querySelector('#sharebar .share-hearing');
  const mic = document.getElementById('sbmic');
  return { shown: !!m && getComputedStyle(m).display !== 'none' && m.getBoundingClientRect().width > 0,
           text: m?.textContent || '', noteOn: document.querySelector('#sharebar .share-pill').classList.contains('hearing-note'),
           dots: m ? [...m.querySelectorAll('i')].map(i => getComputedStyle(i).animationName) : [],
           pill: document.querySelector('#sharebar .share-pill').classList.contains('hearing'),
           ring: mic.classList.contains('loading'), note: document.querySelector('.share-modelnote')?.textContent || '', noteLine: !!document.querySelector('.share-modelnote')?.textContent, ready: mic.classList.contains('ready'),
           p: mic.style.getPropertyValue('--p'), title: mic.title };
});
const centre = () => page.evaluate(() => { const b = document.getElementById('sbmic').getBoundingClientRect(); return { x: b.left + b.width / 2, y: b.top + b.height / 2 }; });
try {
  await page.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
  await sleep(1800);
  let m = await mark();
  h.rec('at rest the hearing mark and the ring are hidden', !m.shown && !m.pill && !m.ring, JSON.stringify(m));
  const c = await centre();

  // first hold: the model starts downloading; the ring fills; the dots pulse
  await page.mouse.move(c.x, c.y); await page.mouse.down(); await sleep(250);
  m = await mark();
  h.rec('holding the mic shows "listening" with three pulsing dots',
        m.shown && m.text === 'listening' && m.dots.length === 3 && m.dots.every(a => a === 'share-hear'), JSON.stringify(m));
  await page.screenshot({ path: `${shot}/share-hear.png`, clip: { x: 0, y: 820, width: 1400, height: 80 } });
  // watch the whole download: a steady climb, sized in MB, then "preparing"
  const seen = [];
  for (let i = 0; i < 40; i++) {
    const x = await mark();
    if (x.ring) seen.push(x);
    if (x.ready) break;
    await sleep(100);
  }
  const ps = seen.map(x => Number(x.p));
  h.rec('the first press shows a loading ring on the mic', seen.length > 3 && ps.some(p => p > 0), `${seen.length} samples`);
  h.rec('the ring climbs steadily — never backwards, never in a leap',
        ps.every((p, i) => i === 0 || p >= ps[i - 1]) && ps.every((p, i) => i === 0 || p - ps[i - 1] <= 25), ps.join(','));
  h.rec('it starts low (the small files do not fill it) and does not sit at 99%', ps[0] < 25 && seen.filter(x => Number(x.p) >= 99 && !/preparing/.test(x.note)).length <= 2, ps.join(','));
  h.rec('beside the mic, a line says how much has come, of how many MB', seen.some(x => /speech model · \d+ of 79 MB/.test(x.note)), seen.map(x => x.note).filter(Boolean).slice(-3).join(' | '));
  h.rec('…then, with the bytes in, says it is preparing', seen.some(x => /preparing the speech model/.test(x.note)), seen.map(x => x.note).filter(Boolean).slice(-2).join(' | '));
  await page.screenshot({ path: `${shot}/share-hear-ring.png`, clip: { x: 0, y: 820, width: 700, height: 80 } });
  await page.mouse.up(); await sleep(300);
  m = await mark();
  h.rec('when it completes the ring turns green, and the line goes', !m.ring && m.ready && !m.noteLine, JSON.stringify(m));
  await sleep(2400);
  m = await mark();
  h.rec('…and the check goes away', !m.ready && !m.ring);

  // on a phone the marks float above the bar and never wrap the pill
  await page.setViewportSize({ width: 390, height: 800 });
  await sleep(400);
  const pillH0 = await page.evaluate(() => document.querySelector('#sharebar .share-pill').getBoundingClientRect().height);
  const c2 = await centre();
  await page.mouse.move(c2.x, c2.y); await page.mouse.down(); await sleep(300);
  const ph = await page.evaluate(() => {
    const p = document.querySelector('#sharebar .share-pill').getBoundingClientRect();
    const m = document.querySelector('#sharebar .share-hearing').getBoundingClientRect();
    return { pill: p.height, above: m.bottom <= p.top + 1 || m.bottom <= document.getElementById('sharebar').getBoundingClientRect().top + 1, w: m.width };
  });
  h.rec('phone: the listening mark floats above the bar; the pill does not grow', ph.above && ph.w > 0 && Math.abs(ph.pill - pillH0) < 2, JSON.stringify({ pillH0, ...ph }));
  await page.screenshot({ path: `${shot}/share-hear-phone.png`, clip: { x: 0, y: 640, width: 390, height: 160 } });
  await page.mouse.up(); await sleep(300);
  await page.evaluate(() => { window.__gum = 'refuse'; });
  await page.mouse.move(c2.x, c2.y); await page.mouse.down(); await sleep(500);
  await page.mouse.up();
  const tap = await page.evaluate(() => {
    const p = document.querySelector('#sharebar .share-pill').getBoundingClientRect();
    const m = document.querySelector('#sharebar .share-hearing');
    const mr = m.getBoundingClientRect();
    return { note: m.textContent, pill: p.height, above: mr.bottom <= document.getElementById('sharebar').getBoundingClientRect().top + 1 };
  });
  h.rec('phone: a note (the mic refused) is a bubble above the bar, the pill unchanged', /blocked/.test(tap.note) && tap.above && Math.abs(tap.pill - pillH0) < 2, JSON.stringify({ pillH0, ...tap }));
  await page.setViewportSize({ width: 1400, height: 900 });
  await sleep(400);
  await page.evaluate(() => { window.__gum = 'pending'; });
  // a refused microphone is said in the bar
  await page.evaluate(() => { window.__gum = 'refuse'; });
  await page.mouse.move(c.x, c.y); await page.mouse.down(); await sleep(500);
  m = await mark();
  h.rec('a refused microphone says so in the bar', m.shown && m.noteOn && /blocked/.test(m.text), JSON.stringify(m));
  await page.mouse.up();
  await sleep(5000);
  m = await mark();
  h.rec('…and the note goes after a few seconds', !m.shown && !m.pill, JSON.stringify(m));
} catch (e) { h.rec('fatal', false, e.message); }
h.rec('no page errors', errs.length === 0, errs.slice(0, 2).join(' | '));
await browser.close(); closeServer();
summarize(h);
