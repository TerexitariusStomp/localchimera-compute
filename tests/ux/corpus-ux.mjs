/// tests/ux/corpus-ux.mjs — the "corpus" face: the federation's shared
/// corpus, searched directly (docs/planning/faces/corpus-guile-native.md §4a).
/// Covers the omnibar's own hand-off (setPendingQuery), the domain select
/// populating from a live gateway reply, and — the one real bug found here,
/// not by review — a slow corpusDomains reply landing WHILE a citizen is
/// mid-typing must never wipe what they've typed.
///
/// Run via: make test-corpus-ux
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
page.on('pageerror', e => h.errs.push(String(e).slice(0, 160)));

try {
  await page.goto(`${BASE}/app.html?face=time`, { waitUntil: 'networkidle' });
  await sleep(600);

  // a slow domains reply — long enough for a human to start typing before
  // it lands, which is exactly the window the bug lived in
  await page.evaluate(() => {
    window.__seam = window.__seam || {};
    window.__seam.handlers = window.__seam.handlers || {};
    window.__seam.handlers.corpusDomains = () => new Promise(res => setTimeout(() =>
      res(JSON.stringify({ domains: ['permaculture', 'forestry'] })), 500));
    window.__seam.handlers.corpusSearch = async (domain, query) => JSON.stringify({
      hits: [{ domain: 'permaculture', text: `a passage about ${query}`, heading: '',
               source: 'test-src', title: 'Test Source', author: '', score: 1 }],
    });
  });

  await page.evaluate(async () => { const { setFace } = await import('./app/faces.js'); setFace('corpus'); });
  await page.waitForSelector('#cp-q', { timeout: 10000 });
  h.rec('the corpus face mounts with a search box', true);

  await sleep(150);   // the face is up; the domains reply is still ~350ms away
  await page.type('#cp-q', 'what fixes nitrogen in soil');
  const midTyping = await page.$eval('#cp-q', el => el.value);
  h.rec('typing works before the domains reply lands',
        midTyping === 'what fixes nitrogen in soil', midTyping);

  await sleep(600);   // let the (slow) domains reply land and its own render fire
  const afterReply = await page.$eval('#cp-q', el => el.value);
  h.rec('the SAME text survives a domains reply landing mid-typing — the real bug, fixed',
        afterReply === midTyping, `before="${midTyping}" after="${afterReply}"`);

  const opts = await page.$$eval('#cp-domain option', els => els.map(o => o.value));
  h.rec('…and the domain select still populates correctly from that same reply',
        opts.includes('permaculture') && opts.includes('forestry'), opts.join(','));

  // run the search that's still sitting in the box
  await page.click('#cp-go');
  await page.waitForSelector('.cp-hit', { timeout: 10000 });
  h.rec('the query that survived the race actually searches correctly',
        await page.$eval('.cp-hit-text', el => /nitrogen/.test(el.textContent)));

  // the omnibar's own door: setPendingQuery, before AND after mount
  await page.evaluate(async () => { const { setFace } = await import('./app/faces.js'); setFace('time'); });
  await sleep(200);
  await page.evaluate(async () => {
    const m = await import('./app/tabs/corpus.js');
    m.setPendingQuery('composting techniques');
  });
  await page.evaluate(async () => { const { setFace } = await import('./app/faces.js'); setFace('corpus'); });
  await sleep(400);
  const pendingRan = await page.$eval('#cp-q', el => el.value);
  h.rec('setPendingQuery called BEFORE mount runs the search the moment the face opens',
        pendingRan === 'composting techniques', pendingRan);
  await page.waitForSelector('.cp-hit', { timeout: 10000 });
  h.rec('…and it actually produced a result, not just filled the box', true);

  // two overlapping searches: an older, slower one must never clobber a
  // newer, faster one's results — the same class of race loadDomains() had
  await page.evaluate(() => {
    window.__seam.handlers.corpusSearch = (domain, query) => new Promise(res => {
      const delay = query === 'first query' ? 500 : 100;
      setTimeout(() => res(JSON.stringify({
        hits: [{ domain: 'permaculture', text: `a passage about ${query}`, heading: '',
                 source: 'test-src', title: 'Test Source', author: '', score: 1 }],
      })), delay);
    });
  });
  await page.evaluate(async () => {
    const m = await import('./app/tabs/corpus.js');
    m.setPendingQuery('first query');
  });
  await sleep(50);
  await page.evaluate(async () => {
    const m = await import('./app/tabs/corpus.js');
    m.setPendingQuery('second query');
  });
  await sleep(700);
  const raceQ = await page.$eval('#cp-q', el => el.value);
  const raceHit = await page.$eval('.cp-hit-text', el => el.textContent);
  h.rec('a slower, older search reply never overwrites a faster, newer one\'s results',
        raceQ === 'second query' && /second query/.test(raceHit),
        `box="${raceQ}" hits="${raceHit}"`);

  h.rec('no page errors', h.errs.length === 0, h.errs.slice(0, 3).join(' | '));
} catch (e) {
  h.rec('fatal', false, e.message);
}

await browser.close();
closeServer();
summarize(h);
