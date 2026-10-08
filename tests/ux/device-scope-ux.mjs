/// tests/ux/device-scope-ux.mjs — the scope the page holds with no gateway in reach
/// (ui/app/demo/seat.ts, ui/app/scope-local.ts, ui/app/outbox.ts,
/// browser/scope-worker.js over browser/scope.wasm).
///
/// With no gateway the store face shows the demo neighbourhood. Its doors are
/// asked the same way as with a gateway, and the device's scope answers them:
/// a count lands on real books, the stock on the seam reads it, and the stock's
/// history holds it as the person's own. A count of the demo is no gateway's to
/// take, so nothing waits in the outbox. Where the scope is kept from starting
/// (?scope=recorded) the recording answers the reads and a count is refused.
///
/// Run via: make test-device-scope-ux     (needs browser/scope.wasm)
import { harness, launch, summarize, sleep, installSeamHook } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();
const h = harness();
const browser = await launch();
const page = await browser.newPage();
await installSeamHook(page);
page.on('pageerror', e => h.errs.push(String(e).slice(0, 200)));

const stock = (id) => page.evaluate(i => {
  const inv = window.__seam.data.snapshot?.inventory;
  const r = (inv?.resources || []).find(x => x.id === i);
  return r ? { onhand: Number(r.onhand), demo: !!inv.demo } : null;
}, id);
const door = (name, ...args) => page.evaluate(([n, a]) => window.__seam.handlers[n](...a).then(String), [name, args]);
const waiting = () => page.evaluate(async () => (await (await import('/app/outbox-idb.js')).idbBox().all()).length);

try {
  await page.goto(`${BASE}/app.html?face=store`, { waitUntil: 'networkidle' });
  await page.waitForSelector('#storetree .st-stock', { timeout: 15000 });
  await sleep(300);
  const before = await stock('demo:tea');
  h.rec('with no gateway the demo neighbourhood\'s books stand on the seam', before && before.demo && before.onhand === 9, JSON.stringify(before));

  // a read asked before the scope stands is answered at once, by the recording of the same books
  const t0 = Date.now();
  const history0 = JSON.parse(await door('countHistory', 'demo:greens', 5));
  h.rec('a read does not wait for the scope to stand', Date.now() - t0 < 3000, `${Date.now() - t0} ms`);
  h.rec('…and answers the stock\'s counts', Array.isArray(history0.rows) && history0.rows.length === 2 && history0.rows[0].counted === 72, JSON.stringify(history0).slice(0, 120));
  h.rec('…dated from today, since it stands the neighbourhood today',
        Math.abs(Date.parse(history0.rows[0].at) - (Date.now() - 4 * 86400000)) < 2 * 86400000, history0.rows[0].at);

  // a count needs the ledger: it waits for the scope, which has been starting since the read
  const t1 = Date.now();
  const landed = JSON.parse(await door('countStock', 'demo:tea', 7, 'box', 'stated', 'place:teahouse', '', '', '', ''));
  h.info(`the first count, the scope standing with it, landed in ${Date.now() - t1} ms`);
  h.rec('a count lands on the device\'s books and answers the difference', landed.delta === -2 && landed.onhand === 7, JSON.stringify(landed).slice(0, 120));
  // the books are asked of the scope again and pushed: wait for them
  let after = await stock('demo:tea');
  for (let i = 0; i < 40 && after?.onhand !== 7; i++) { await sleep(250); after = await stock('demo:tea'); }
  h.rec('the stock on the seam reads the count', after && after.onhand === 7, JSON.stringify(after));
  const mine = JSON.parse(await door('countHistory', 'demo:tea', 5)).rows;
  h.rec('the stock\'s history holds it, as the person\'s own', mine.length === 1 && mine[0].counted === 7 && mine[0].mine === true, JSON.stringify(mine).slice(0, 120));
  const refused = await door('countStock', 'demo:tea', 3, 'kg', 'stated', '', '', '', '', '');
  h.rec('a count in another unit is refused in the door\'s words', refused === "err:count in the stock's unit: box", refused);
  h.rec('a count of the demo is no gateway\'s to take: nothing waits', await waiting() === 0);
  const sched = JSON.parse(await door('countSchedule', ''));
  h.rec('the schedule is the scope\'s own', sched.rows.some(r => r.id === 'demo:tea' && r.lastCount), JSON.stringify(sched.rows.find(r => r.id === 'demo:tea') ?? null).slice(0, 120));
  const own = JSON.parse(await door('mySlots'));
  h.rec('the person\'s own needs and offers are the scope\'s', own.needs.length === 3 && own.means.length === 2, `${own.needs.length} needs, ${own.means.length} offers`);
  h.rec('a need declared offline stands among them',
        await door('declareNeed', 'spec-tea', 2, 'box', '', '', 'for the weekend', '', '', '', 'tea', '', '', '', '') === 'ok'
        && JSON.parse(await door('mySlots')).needs.some(n => n.spec === 'spec-tea'));
  const seen = await door('logObserve', 'work', 'spec-bike-repair', 2, 'hours', 'fixed a flat', '');
  h.rec('an observation made offline lands', seen.startsWith('ok:evt-log-'), seen);
  h.rec('the store face still shows the stock', await page.evaluate(() => [...document.querySelectorAll('#storetree .st-sname')].some(n => n.textContent.includes('loose tea'))));

  // the recording, where the scope is kept from starting
  await page.goto(`${BASE}/app.html?face=store&scope=recorded`, { waitUntil: 'networkidle' });
  await page.waitForSelector('#storetree .st-stock', { timeout: 15000 });
  const recorded = JSON.parse(await door('countHistory', 'demo:greens', 5));
  h.rec('where the scope cannot run, the recording answers a read', recorded.rows.length === 2 && recorded.rows[0].counted === 72);
  const noBooks = await door('countStock', 'demo:tea', 7, 'box', 'stated', '', '', '', '', '');
  h.rec('…and a count is refused, with no ledger to land it on', noBooks.startsWith('err:this needs the books'), noBooks);
  h.rec('no page error', h.errs.length === 0, h.errs.join(' | '));
} catch (e) {
  h.rec('the suite ran to its end', false, String(e).slice(0, 200));
}

await browser.close();
closeServer();
summarize(h);
