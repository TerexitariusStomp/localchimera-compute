/// tests/ux/count-ux.mjs — the count control and the capture sheet
/// (ui/app/capture.ts, ui/app/tabs/inventory.ts; docs/observation/capture.md).
///
/// A row of live stock carries a count control; the demo stock, which no count
/// can land on, carries none. The control opens the capture sheet on that
/// stock. The sheet asks for the figure, sends the count through the seam with
/// the resource, the unit and the technique, and says what the count found. A
/// refusal is said in the gateway's words and leaves the typed figure in
/// place, and a status line changing under the figure leaves it in place too.
///
/// Run via: make test-count-ux
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
  return {
    name: n.querySelector('.cap-name')?.textContent.trim() ?? '',
    sub: n.querySelector('.cap-sub')?.textContent.trim() ?? '',
    says: n.querySelector('.cap-says')?.textContent.trim() ?? '',
    figure: n.querySelector('.cap-figure')?.value ?? null,
    unit: n.querySelector('.cap-unit')?.textContent.trim() ?? '',
    go: n.querySelector('.cap-go')?.textContent.trim() ?? '',
    plan: n.querySelector('.cap-plan > summary')?.textContent.trim() ?? '',
    planOpen: n.querySelector('.cap-plan')?.open ?? null,
    flows: [...n.querySelectorAll('.cap-flows li')].map(li => li.textContent.trim()),
    note: n.querySelector('.cap-notebox')?.open ?? null,
  };
});

try {
  await page.goto(`${BASE}/app.html?face=time`, { waitUntil: 'networkidle' });
  await sleep(400);

  const demoControls = await page.evaluate(() => document.querySelectorAll('#inventory .iv-count').length);
  h.rec('the demo stock carries a count control on each of its rows', demoControls >= 12, `${demoControls} found`);

  // a live stock, and a gateway that answers a count: the first reply is a
  // refusal, every later one lands the difference from the 10 kg it holds
  await page.evaluate(async () => {
    window.__seam.data.inventory = {
      specs: [{ id: 'flour', name: 'flour', unit: 'kg' }],
      resources: [{ id: 'ada/flour', 'conforms-to': 'flour', name: 'flour', unit: 'kg',
                    onhand: 10, 'location-name': 'pantry',
                    expected: { low: 7, high: 15, flows: [
                      { id: 'bake', action: 'consume', quantity: -3, when: '2026-09-28T08:00:00Z', proc: 'bake' },
                      { id: 'delivery', action: 'produce', quantity: 5, when: '2026-09-28T09:00:00Z', proc: 'mill' }] } }],
    };
    window.__counts = [];
    Object.defineProperty(window.__seam.handlers, 'countStock', {
      configurable: true, get: () => (...args) => {
        window.__counts.push(args);
        if (window.__counts.length === 1) return Promise.resolve('err:not yours to count');
        const counted = Number(args[1]);
        return Promise.resolve(JSON.stringify({ event: counted === 10 ? '' : 'evt-count-1', record: '',
                                                delta: counted - 10, onhand: counted,
                                                expected: { low: 7, high: 15, flows: [
                                                  { id: 'bake', action: 'consume', quantity: -3, when: '2026-09-28T08:00:00Z', proc: 'bake' },
                                                  { id: 'delivery', action: 'produce', quantity: 5, when: '2026-09-28T09:00:00Z', proc: 'mill' }] } }));
      }, set: () => {},
    });
    const { emit } = await import('./app/bus.js');
    emit('inventory');
  });
  await page.waitForSelector('#inventory .iv-count', { timeout: 10000 });
  h.rec('a row of live stock carries the count control', true);

  await page.evaluate(() => document.querySelector('#inventory .iv-count').click());
  await sleep(200);
  let s = await sheet();
  h.rec('the control opens the capture sheet on that stock', !!s && s.name === 'flour', JSON.stringify(s));
  h.rec('the sheet says where the stock is and what the ledger reads',
        !!s && /pantry/.test(s.sub) && /10 kg/.test(s.sub), s?.sub);
  h.rec('the figure starts empty, in the stock\'s unit', !!s && s.figure === '' && s.unit === 'kg');
  h.rec('the plan\'s range waits under the figure, in one line', !!s && s.plan === 'the plan expects 7–15 kg', s?.plan);
  h.rec('…its flows stay folded until asked for', !!s && s.planOpen === false);
  h.rec('the note stays folded too', !!s && s.note === false);
  await page.click('#capture .cap-plan > summary');
  s = await sheet();
  h.rec('asked, the plan lists the flows behind its range',
        !!s && s.planOpen === true && s.flows.length === 2 && /^3 kg going/.test(s.flows[0]) && /^5 kg arriving/.test(s.flows[1]),
        JSON.stringify(s?.flows));
  await page.click('#capture .cap-plan > summary');

  await page.evaluate(() => document.querySelector('#capture .cap-go').click());
  await sleep(150);
  s = await sheet();
  h.rec('a count with no figure asks for one', !!s && /how much/.test(s.says), s?.says);
  h.rec('…and sends nothing', (await page.evaluate(() => window.__counts.length)) === 0);

  await page.fill('#capture .cap-figure', '8,5');
  await page.click('#capture .cap-notebox > summary');
  await page.fill('#capture .cap-note', 'second shelf');
  await page.evaluate(() => document.querySelector('#capture .cap-go').click());
  await sleep(250);
  s = await sheet();
  h.rec('a refusal is said in the gateway\'s words', !!s && /not yours to count/.test(s.says), s?.says);
  h.rec('…and the typed figure stays in place', !!s && s.figure === '8,5', String(s?.figure));

  await page.evaluate(() => document.querySelector('#capture .cap-go').click());
  await sleep(250);
  s = await sheet();
  const sent = await page.evaluate(() => window.__counts[1]);
  h.rec('the count names the resource', sent?.[0] === 'ada/flour', JSON.stringify(sent));
  h.rec('…the figure as a number, the comma read as a point', sent?.[1] === 8.5, String(sent?.[1]));
  h.rec('…the stock\'s unit and the stated technique', sent?.[2] === 'kg' && sent?.[3] === 'stated');
  h.rec('…and the note', sent?.[8] === 'second shelf', String(sent?.[8]));
  h.rec('the sheet says which way the ledger was off',
        !!s && /1\.5 kg more than is there/.test(s.says), s?.says);
  h.rec('…and what it reads now', !!s && /8\.5 kg/.test(s.says), s?.says);
  h.rec('the plan\'s word on the count replaces its range', !!s && /^inside what the plan expected: 7–15 kg/.test(s.plan), s?.plan);
  h.rec('a landed count closes the figure and offers done',
        !!s && s.figure === null && s.go === 'done', JSON.stringify(s));

  await page.evaluate(() => document.querySelector('#capture .cap-go').click());
  await sleep(150);
  h.rec('done closes the sheet', (await sheet()) === null);

  // a figure far from what is held lands on a second tap, as a row of a photo read does
  await page.evaluate(() => document.querySelector('#inventory .iv-count').click());
  await sleep(200);
  const before = await page.evaluate(() => window.__counts.length);
  await page.fill('#capture .cap-figure', '1');
  await page.evaluate(() => document.querySelector('#capture .cap-go').click());
  await sleep(200);
  s = await sheet();
  h.rec('a figure far from what is held asks twice', !!s && /really 1 kg\? the ledger read 10 kg/.test(s.says) && s.figure === '1'
        && (await page.evaluate(() => window.__counts.length)) === before, s?.says);
  await page.evaluate(() => document.querySelector('#capture .cap-go').click());
  await sleep(300);
  s = await sheet();
  h.rec('…and lands on the second tap', !!s && s.go === 'done' && (await page.evaluate(() => window.__counts.length)) === before + 1, JSON.stringify(s));
  await page.keyboard.press('Escape');
  await sleep(150);

  await page.evaluate(() => document.querySelector('#inventory .iv-count').click());
  await sleep(200);
  await page.keyboard.press('Escape');
  await sleep(150);
  h.rec('Escape closes the sheet', (await sheet()) === null);

  h.rec('no page errors', h.errs.length === 0, h.errs.slice(0, 3).join(' | '));
} catch (e) {
  // what the page itself said is what explains a wait that never ended
  h.rec('fatal', false, [e.message.split('\n')[0], ...h.errs.slice(0, 5)].join(' | '));
}

await browser.close();
closeServer();
summarize(h);
