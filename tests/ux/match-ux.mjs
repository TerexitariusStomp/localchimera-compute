/// tests/ux/match-ux.mjs — the MATCH face (the ring) and the TAXONOMY face
/// (the folksonomy treemap). Standalone/demo mode (no gateway): the ring
/// scores its demo pool with the browser twin of matching/affinity.scm, so
/// every surface the port added is exercised without a server —
///
///   the ring        needs as squares inside, offers as circles outside, one
///                   chord per scored pairing
///   the pool panel  every slot as the share bar's own card (slots/card.js
///                   slotFace), each with its match count
///   hover           the slot's card follows the pointer; the ring names the
///                   focused node and everything it reaches
///   lock            that slot over its ranked matches, with the score, the
///                   term the two met at (both:/via:/same thing) and a chip
///                   per scored dimension
///   search          app/search.js — the map panel's own search — sifts the
///                   pool list and dims the ring to what the list names
///   the floor       raising the match floor drops the weak chords
///
/// Run via: make test-match-ux
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
page.on('pageerror', e => h.errs.push(String(e).slice(0, 160)));

// hover a ring node by the name in its <title>, and report what the tip says
const hoverNode = (name) => page.evaluate(n => {
  const g = [...document.querySelectorAll('#matchring g.mn')]
    .find(x => (x.querySelector('title') || {}).textContent?.includes(n));
  if (!g) return false;
  const r = g.getBoundingClientRect();
  const at = { bubbles: true, clientX: r.x + r.width / 2, clientY: r.y + r.height / 2 };
  g.dispatchEvent(new MouseEvent('mouseenter', at));
  g.dispatchEvent(new MouseEvent('mousemove', at));
  return true;
}, name);
const clickNode = (name) => page.evaluate(n => {
  const g = [...document.querySelectorAll('#matchring g.mn')]
    .find(x => (x.querySelector('title') || {}).textContent?.includes(n));
  if (!g) return false;
  g.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  return true;
}, name);

try {
  await page.goto(`${BASE}/app.html?face=match`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#matchface.on', { timeout: 30000 });
  await page.waitForSelector('#matchring g.mn', { timeout: 30000 });
  h.rec('?face=match deep link lands on the match face', true);

  // ── the ring ─────────────────────────────────────────────────────────────
  const shapes = await page.evaluate(() => {
    const gs = [...document.querySelectorAll('#matchring g.mn')];
    const d = s => s.querySelector('path').getAttribute('d');
    return { total: gs.length,
             squares: gs.filter(g => d(g).startsWith('M-7,-7')).length,
             circles: gs.filter(g => d(g).includes('A8,8')).length };
  });
  h.rec('the demo pool draws every slot (5 needs + 8 offers)', shapes.total === 13);
  h.rec('needs are squares, offers are circles',
        shapes.squares === 5 && shapes.circles === 8);
  const chords0 = await page.$$eval('#matchring g.mchords path', ps => ps.length);
  h.rec('scored pairings draw as chords', chords0 > 0);

  // ── hover: the tooltip is the same card, and the ring names its reach ────
  await hoverNode('bread');
  await sleep(220);
  h.rec('hovering a node floats its slot card',
        await page.$eval('#matchtip', el =>
          el.classList.contains('on') && !!el.querySelector('.slot-card')));
  h.rec('the tip says how many matches it has, and invites the hold',
        await page.$eval('#matchtip', el => /match(es)? · click to hold/.test(el.textContent)));
  h.rec('the ring labels the hovered node and everything it reaches',
        await page.$$eval('#matchring g.mlabels text', ts => ts.length >= 2));

  // ── lock: a held node dims the chords that do not touch it ──────────────
  // (The face once carried a rail panel of slot cards, ranked matches and a search
  // pill; the face is full-bleed now, #panel is hidden on it, and its one own
  // control is the match floor on the stage — so those assertions went with it.)
  await clickNode('bread');
  await sleep(260);
  h.rec('holding dims the chords that do not touch it',
        await page.$$eval('#matchring g.mchords path',
          ps => ps.some(p => +p.getAttribute('opacity') <= 0.1)
             && ps.some(p => +p.getAttribute('opacity') > 0.5)));

  // ── the match floor ──────────────────────────────────────────────────────
  await page.evaluate(() => {
    const r = document.querySelector('#matchfloor input[type=range]');
    r.value = '0.95'; r.dispatchEvent(new Event('input', { bubbles: true }));
  });
  await sleep(250);
  const chords1 = await page.$$eval('#matchring g.mchords path', ps => ps.length);
  h.rec('raising the match floor drops the weaker chords', chords1 < chords0);

  // ── the taxonomy face ────────────────────────────────────────────────────
  // the taxonomy face has no nav button now (the strip carries map, calendar, forum and the
  // tabs a person turns on); it is reached by route, the way the app itself does
  await page.evaluate(async () => { (await import('/app/faces.js')).setFace('taxonomy'); });
  await page.waitForSelector('#taxonomyface.on', { timeout: 10000 });
  await sleep(400);
  h.rec('the taxonomy face draws the spine as a treemap',
        await page.$$eval('#taxonomystage g.tx-cell', cs => cs.length >= 15));
  h.rec('its cells are named from the same spine the wheel draws',
        await page.$eval('#taxonomystage', el => /nourishment/.test(el.textContent)
                                              && /learning/.test(el.textContent)));
  h.rec('the panel walks the breadcrumb from the root',
        await page.$eval('#taxonomypanel', el => /all/.test(el.textContent)
                                              && /terms under/.test(el.textContent)));
  await page.evaluate(() => {
    const c = [...document.querySelectorAll('#taxonomystage g.tx-cell')]
      .find(g => /nourishment/.test(g.textContent));
    c?.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  });
  await sleep(300);
  h.rec('clicking a branch zooms the treemap into it',
        await page.$eval('#taxonomypanel', el => /terms under nourishment/.test(el.textContent)));

  // ── the tree's search: the dial's pill over the terms, a hit zooms ───────
  await page.type('#taxonomypanel .ms-input', 'stud'); await sleep(250);
  h.rec('the taxonomy panel carries the search pill and lists the terms a query names',
        await page.$$eval('#taxonomypanel .tx-hit', hs => hs.length >= 1 && /study/.test(hs[0].textContent)));
  await page.evaluate(() => document.querySelector('#taxonomypanel .tx-hit')?.dispatchEvent(new MouseEvent('click', { bubbles: true })));
  await sleep(300);
  h.rec('picking a hit zooms the treemap to where it lives',
        await page.$eval('#taxonomypanel', el => /terms under learning/.test(el.textContent)));

  // ── the faces come and go through the nav ────────────────────────────────
  await page.evaluate(() =>
    document.querySelector('#face-match')?.dispatchEvent(new MouseEvent('click', { bubbles: true })));
  await sleep(220);
  h.rec('the nav strip brings the ring back',
        await page.evaluate(() =>
          document.querySelector('#matchface').classList.contains('on')
          && !document.querySelector('#taxonomyface').classList.contains('on')));
} finally {
  await browser.close();
  closeServer();
}

summarize(h, ['?face=match deep link lands on the match face',
              'the demo pool draws every slot (5 needs + 8 offers)',
              'needs are squares, offers are circles',
              'hovering a node floats its slot card',
              'the ring labels the hovered node and everything it reaches',
              'raising the match floor drops the weaker chords',
              'the taxonomy face draws the spine as a treemap',
              'clicking a branch zooms the treemap into it',
              'the nav strip brings the ring back']);
