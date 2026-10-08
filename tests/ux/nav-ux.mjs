/// tests/ux/nav-ux.mjs — the dial's colour-bar + centre navigation:
/// you can always get back to root, and the centre disc is the way up.
///
/// Reproduces the reported bug: after stepping up to a parent via the
/// coloured bar there was no path back to root, and the centre had
/// stopped being a button. Asserts both routes home now exist.
///
/// Run via: make test-nav-ux
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
page.on('pageerror', e => h.errs.push(String(e).slice(0, 120)));

// the set of band names the dial currently shows (focus.children)
const bandNames = () => page.evaluate(async () =>
  ((await import('/app/spectrum.js')).spectrum()?.bands || []).map(b => b.name).sort());
// is the centre an up-button right now? (caret present)
const hasCentreUp = () => page.evaluate(() =>
  [...document.querySelectorAll('#stage text, svg text')]
    .some(t => t.textContent === '⌃'));

try {
  // ?face=time explicitly: the map is the default face now, and the priority
  // bar is the time face's own navigation.
  await page.goto(`${BASE}/app.html?face=time`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#prioritybar .priseg', { timeout: 30000 });
  await sleep(400);

  const rootBands = await bandNames();
  h.rec('root shows its categories', rootBands.length >= 2,
        rootBands.join(','));
  h.rec('at root the centre is not an up-button', !(await hasCentreUp()));

  // Drill in: tap a top-bar (level 0) segment → that category becomes focus.
  await page.click('#prioritybar .priseg[data-level="0"]');
  await sleep(1200);                       // let the zoom settle
  const inBands = await bandNames();
  h.rec('tapping a bar segment drills into it',
        inBands.length > 0 && inBands.join(',') !== rootBands.join(','),
        inBands.join(','));

  // The centre is now the way up.
  h.rec('inside, the centre becomes an up-button', await hasCentreUp());

  // The bug: from here, can we get back to root? Tap the on-path ancestor
  // segment (where we already are) → it takes us all the way out.
  const onpath = await page.$('#prioritybar .pribar.ancestor .priseg.onpath');
  h.rec('an ancestor on-path segment is present', !!onpath);
  if (onpath) {
    await onpath.click();
    await sleep(1200);
    const back = await bandNames();
    h.rec('tapping where you are returns to root',
          back.join(',') === rootBands.join(','), back.join(','));
    h.rec('back at root the centre is passive again', !(await hasCentreUp()));
  }

  // The other route home: drill in again, then tap the centre disc to rise.
  await page.click('#prioritybar .priseg[data-level="0"]');
  await sleep(1200);
  h.rec('drilled in once more', (await bandNames()).join(',') !== rootBands.join(','));
  // click the centre caret/label — rises one level (root, since depth 1)
  const caret = await page.evaluateHandle(() =>
    [...document.querySelectorAll('svg text')].find(t => t.textContent === '⌃'));
  if (caret && (await caret.evaluate(n => !!n))) {
    await caret.asElement().click({ force: true });
    await sleep(1200);
    h.rec('tapping the centre rises to root',
          (await bandNames()).join(',') === rootBands.join(','));
  } else h.rec('tapping the centre rises to root', false, 'no caret');

  // Earth mode's way up: a small in-map back button exists, hidden until
  // the map opens (the full earth-mode click-through needs geo/tiles; the
  // button shares the proven #backchip → exitEarth path).
  const mb = await page.$('#mapback');
  h.rec('in-map back button is present', !!mb);
  if (mb) h.rec('in-map back button hidden outside earth mode',
        await mb.evaluate(el => getComputedStyle(el).display === 'none'));

  h.rec('no page errors', h.errs.length === 0, h.errs.slice(0, 2).join(' | '));
} catch (e) {
  h.rec('fatal', false, e.message);
} finally {
  await browser.close();
  closeServer();
}

summarize(h, ['root shows its categories',
              'tapping a bar segment drills into it',
              'inside, the centre becomes an up-button',
              'tapping where you are returns to root',
              'tapping the centre rises to root',
              'in-map back button is present', 'no page errors']);
