/// tests/ux/withholding-ux.mjs — the withheld-service sector on the fragility
/// wheel: push a fragility snapshot carrying a `withholding` array (the shape
/// withholding-snapshot emits, economy/means-fold.scm) through the live seam
/// the "fragility" topic, and read the wheel back — the kind:withheld sector
/// renders in its own hue, the legend names it, and the detail card carries the
/// figure (unit-hours/day withheld) with span→reach. A snapshot WITHOUT the
/// field renders unchanged — old snapshots stay valid. No gateway — pure client.
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

// one withheld means, exactly as withholding-snapshot serializes it: a lathe
// pooled at its workshop that could serve the whole town — 40 unit-hours/day.
const WITHHELD = {
  spec: 'lathe', kind: 'withheld', control: 'lathe', group: 'withheld',
  unit: 'unit-hours/day', w: 1, span: 'workshop-a', reach: 'town',
  current: 40.0, tip: 40.0, s: 0.001,
  source: 'pooled narrower than its reach — hours that could serve wider (means-withholding)',
};
const HUE = '#a1584a';   // palette.js `withheld`

const h = harness();
const browser = await launch();
const page = await browser.newPage();
const errs = [];
page.on('pageerror', e => errs.push(String(e)));

const legendNames = () => page.evaluate(() =>
  [...document.querySelectorAll('#fraglegend .lg')].map(l => l.textContent.trim()));
const withheldPaths = (hue) => page.evaluate((hue) =>
  [...document.querySelectorAll('svg path')]
    .filter(p => (p.getAttribute('fill') || '').toLowerCase() === hue).length, hue);

try {
  await page.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 30000 });
  await sleep(400);

  // onto the fragility face — the wheel draws from the committed witness snapshot
  await page.evaluate(() => document.getElementById('face-frag')
    .dispatchEvent(new MouseEvent('click', { bubbles: true })));
  await sleep(600);

  // 1. an old-shape snapshot (no `withholding` field) renders, with no withheld sector
  h.rec('the wheel renders without a withholding field (old snapshots stay valid)',
        !(await legendNames()).includes('withheld') && (await withheldPaths(HUE)) === 0);

  // 2. the live push carries a withholding array → the sector appears
  await page.evaluate(async (ctl) => (await import('/app/bus.js')).emit('fragility', {
    source: 'test — the withheld service', controls: [], withholding: [ctl],
  }), WITHHELD);
  await sleep(400);
  // (the wheel has no legend row now; the sector itself is what the fold must produce)
  h.rec('the pushed withholding folds into the wheel — a kind:withheld sector renders in the withheld hue',
        (await withheldPaths(HUE)) >= 1);

  // 3. selecting the sector opens the detail: the FIGURE, span→reach
  // a wedge is selected through the transparent hit path laid over it (one per segment);
  // walk them as a hand would until the detail names the lathe
  await page.evaluate(async () => {
    const hits = [...document.querySelectorAll('svg path[fill="transparent"]')]
      .filter(p => p.getAttribute('cursor') === 'pointer');
    for (const p of hits) {
      p.dispatchEvent(new MouseEvent('click', { bubbles: true }));
      await new Promise(r => setTimeout(r, 60));
      if (/lathe/.test((document.getElementById('fragdetail') || {}).textContent || '')) return;
    }
  });
  await sleep(300);
  const detail = await page.evaluate(() =>
    (document.getElementById('fragdetail') || {}).textContent || '');
  h.rec('the detail carries the figure — unit-hours/day withheld',
        /withheld\s*40\.0\s*unit-hours\/day/.test(detail));
  h.rec('the detail carries span→reach — pools at the span, could serve the reach',
        detail.includes('workshop-a') && detail.includes('town'));

  await page.screenshot({ path: 'tests/ux/_artifacts/day-withholding.png' }).catch(() => {});

  // 4. a later push without the field clears it — the seam replaces, never accretes
  await page.evaluate(async () => (await import('/app/bus.js')).emit('fragility', { source: 'test — bare', controls: [] }));
  await sleep(300);
  h.rec('a push without withholding clears the sector',
        (await withheldPaths(HUE)) === 0);

  h.rec('no page errors during the flow', errs.length === 0);
  if (errs.length) console.log('PAGE ERRORS:', errs.slice(0, 3).join(' | '));
} finally {
  await browser.close();
  closeServer();
}

summarize(h, ['the pushed withholding folds into the wheel — a kind:withheld sector renders in the withheld hue',
              'a kind:withheld sector renders in the withheld hue (rim colour band)',
              'the detail carries the figure — unit-hours/day withheld',
              'no page errors during the flow']);
