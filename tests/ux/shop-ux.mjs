/// tests/ux/shop-ux.mjs — the "shop" face: socialist shopping over the
/// individually-claimable pool (docs/playnet.typ §Two rails). Covers the
/// live (non-demo) claim path and — the one real bug found here, not by
/// review — a double-click on the claim button before the gateway's reply
/// lands must never fire a second real draw (claim is a real VF transfer,
/// not idempotent like declare-place's deterministic-id upsert).
///
/// Run via: make test-shop-ux
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
page.on('pageerror', e => h.errs.push(String(e).slice(0, 160)));

try {
  await page.goto(`${BASE}/app.html?face=time`, { waitUntil: 'networkidle' });
  await sleep(400);

  // seed a real (non-demo) inventory + credit snapshot and a SLOW mock
  // claim handler — slow enough for a human to double-click before the
  // reply lands, exactly the window the bug lived in
  await page.evaluate(() => {
    window.__seam.data.inventory = {
      specs: [{ id: 'spec-bread', name: 'bread', unit: 'loaf', snlt: 1 }],
      resources: [{ id: 'res-bread-1', 'conforms-to': 'spec-bread', spec: 'spec-bread',
                    'distribution-mode': 'individual-claimable', onhand: 100, name: 'bread', unit: 'loaf' }],
    };
    window.__seam.data.credit = { drawable: 1000, claimed: 0 };
    window.__claimCallCount = 0;
    window.__seam.handlers.claim = (rid, q, where, when, cb) => {
      window.__claimCallCount++;
      setTimeout(() => cb(JSON.stringify({ claimed: q, balance: 1000 - q })), 1500);
    };
  });

  await page.evaluate(async () => { const { setFace } = await import('./app/faces.js'); setFace('shop'); });
  await page.waitForSelector('.shop-card-item', { timeout: 10000 });
  h.rec('the shop face mounts with at least one claimable item', true);

  await page.evaluate(() => document.querySelector('.shop-card-item')?.click());
  await sleep(200);
  await page.waitForSelector('.shop-claim', { timeout: 10000 });
  h.rec('selecting an item shows the claim card', true);

  await page.evaluate(() => {
    const btn = document.querySelector('.shop-claim');
    btn.click();
    btn.click();   // rapid second click BEFORE the 1.5s reply lands
  });
  await sleep(300);
  const midFlightLabel = await page.$eval('.shop-claim', el => el.textContent.trim()).catch(() => '');
  h.rec('the button visibly reads "claiming…" while the draw is in flight',
        /claiming/i.test(midFlightLabel), midFlightLabel);

  await sleep(1800);   // let the slow reply land
  const claimCalls = await page.evaluate(() => window.__claimCallCount);
  h.rec('a double-click before the reply lands fires the real claim handler only ONCE — the real bug, fixed',
        claimCalls === 1, `claim() called ${claimCalls} time(s)`);

  h.rec('no page errors', h.errs.length === 0, h.errs.slice(0, 3).join(' | '));
} catch (e) {
  h.rec('fatal', false, e.message);
}

await browser.close();
closeServer();
summarize(h);
