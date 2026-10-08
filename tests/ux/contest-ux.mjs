/// tests/ux/contest-ux.mjs — the counts of a stock, a count contested, and the
/// counter's photograph attached to it (ui/app/capture.ts, ui/app/contest.ts,
/// ui/app/tabs/inventory.ts; docs/observation/capture.md §8).
///
/// A live stock row carries a "counts" control. It opens the sheet on the
/// counts of that stock that found the ledger off, each with its day, who
/// counted, which way it found the ledger and whether a photograph came with
/// it. A count by someone else carries "contest"; it asks why, and opens the
/// contest through the door work is contested through. A contested count says
/// so, and the franchise sees the photograph attached to it. The counter whose
/// act is contested attaches the photograph the count names from the device
/// that took it, and only the picture the count names.
///
/// Run via: make test-contest-ux
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
    name: t('.cap-name'), says: t('.cap-says'), picture: n.querySelector('.cap-picture')?.getAttribute('src') ?? null,
    reason: !!n.querySelector('.cap-reason'),
    rows: [...n.querySelectorAll('.cap-hist')].map(li => ({
      name: li.querySelector('.cap-lname')?.textContent.trim() ?? '',
      sub: li.querySelector('.cap-lsub')?.textContent.trim() ?? '',
      verbs: [...li.querySelectorAll('.cap-tools .cap-mini')].map(b => b.textContent.trim()),
    })),
  };
});
const press = (row, label) => page.evaluate(([i, l]) =>
  [...[...document.querySelectorAll('#capture .cap-hist')][i].querySelectorAll('.cap-mini')]
    .find(b => b.textContent.trim() === l)?.click(), [row, label]);

const HASH = 'sha256:' + 'b'.repeat(64);

const install = (role, evidence) => page.evaluate(async ([role, evidence]) => {
  window.__seam.data.inventory = {
    specs: [{ id: 'flour', name: 'flour', unit: 'kg' }],
    resources: [{ id: 'ada/flour', 'conforms-to': 'flour', name: 'flour', unit: 'kg', onhand: 8, location: '', code: '' }],
  };
  window.__calls = { contest: [], attach: [], see: [], history: 0 };
  window.__contested = false;
  const pin = (name, fn) => Object.defineProperty(window.__seam.handlers, name, { configurable: true, get: () => fn, set: () => {} });
  pin('countHistory', () => { window.__calls.history++; return Promise.resolve(JSON.stringify({ rows: [
    { id: 'evt-2', at: '2026-10-01T10:00:00Z', delta: -2.5, unit: 'kg', counter: 'EOTHERCOUNTER123', technique: 'count:photo', evidence, mine: role === 'attach' },
    { id: 'evt-1', at: '2026-09-30T08:00:00Z', delta: 1, unit: 'kg', counter: 'EOTHERCOUNTER123', technique: 'count:stated', evidence: '', mine: false },
  ] })); });
  pin('contests', () => Promise.resolve(JSON.stringify({ rows: window.__contested
    ? [{ id: 'contest:evt-2', eventId: 'evt-2', kind: 'count', resource: 'ada/flour', worker: 'EOTHERCOUNTER123', by: 'EBO', reason: 'never opened the crate', role }] : [] })));
  pin('contestWork', (...a) => { window.__calls.contest.push(a); window.__contested = true; return Promise.resolve('contest:evt-1'); });
  pin('attachEvidence', (...a) => { window.__calls.attach.push(a); return Promise.resolve('ok'); });
  pin('contestEvidence', (b) => { window.__calls.see.push(b); return Promise.resolve('QUJD'); });
  const { emit } = await import('./app/bus.js');
  emit('inventory');
}, [role, evidence]);

const open = async () => {
  await page.waitForSelector('#inventory .iv-count', { timeout: 10000 });
  await page.evaluate(() => [...document.querySelectorAll('#inventory .iv-count')].find(b => b.textContent.trim() === 'counts')?.click());
  await page.waitForSelector('#capture .cap-hist', { timeout: 10000 });
};

try {
  await page.goto(`${BASE}/app.html?face=time`, { waitUntil: 'networkidle' });
  await sleep(400);
  await install('vote', HASH);

  await open();
  let s = await sheet();
  h.rec('the control opens the counts of that stock', !!s && /the counts of flour/.test(s.name), s?.name);
  h.rec('each count says its day and who counted', !!s && s.rows.length === 2 && /2026/.test(s.rows[0].name) && !/2026-10-01/.test(s.rows[0].name) && /EOTHER/.test(s.rows[0].name), JSON.stringify(s?.rows[0]));
  h.rec('…which way it found the ledger off and how', !!s && /2\.5 kg fewer than the ledger read, from a photograph/.test(s.rows[0].sub), s?.rows[0].sub);
  h.rec('…and that a photograph came with it', !!s && /with a photograph/.test(s.rows[0].sub), s?.rows[0].sub);
  h.rec('a count by someone else can be contested', !!s && s.rows[0].verbs.includes('contest'), JSON.stringify(s?.rows[0].verbs));

  await press(0, 'contest');
  await sleep(150);
  s = await sheet();
  h.rec('contesting asks why', !!s && s.reason);
  await page.fill('#capture .cap-reason', 'she never opened the crate');
  await press(0, 'open the contest');
  await sleep(400);
  const c = await page.evaluate(() => window.__calls.contest[0]);
  h.rec('the contest goes through the work door, naming the count and the reason', c?.[1] === 'evt-2' && c?.[2] === 'she never opened the crate', JSON.stringify(c));
  s = await sheet();
  h.rec('the count now says it is contested, with the reason', !!s && /contested: never opened the crate|contested: she never/.test(s.rows[0].sub) || /contested/.test(s?.rows[0].sub ?? ''), s?.rows[0].sub);
  h.rec('…and is no longer contestable', !!s && !s.rows[0].verbs.includes('contest'), JSON.stringify(s?.rows[0].verbs));
  h.rec('a count with no photograph offers none to see', !!s && !s.rows[1].verbs.includes('see the photograph'));
  h.rec('the franchise may see the photograph', !!s && s.rows[0].verbs.includes('see the photograph'), JSON.stringify(s?.rows[0].verbs));
  h.rec('…and has nothing of its own to attach', !!s && !s.rows[0].verbs.includes('attach my photograph'));

  await press(0, 'see the photograph');
  await sleep(300);
  s = await sheet();
  const seen = await page.evaluate(() => window.__calls.see);
  h.rec('the photograph is fetched by the ballot', seen[0] === 'contest:evt-2', JSON.stringify(seen));
  h.rec('…and shown', !!s && s.picture === 'data:image/jpeg;base64,QUJD', String(s?.picture));
  await page.keyboard.press('Escape');
  await sleep(150);

  // the counter's side: their photograph is on this device, and the count names it
  await page.evaluate(async () => {
    const { useMemoryStore } = await import('./app/photo.js');
    useMemoryStore();
  });
  const hash = await page.evaluate(async () => {
    const { keepEvidence } = await import('./app/photo.js');
    return await keepEvidence(new Blob([new Uint8Array([1, 2, 3, 4])], { type: 'image/jpeg' }));
  });
  await install('attach', hash);
  await page.evaluate(async () => { window.__contested = true; const { emit } = await import('./app/bus.js'); emit('inventory'); });
  await page.waitForSelector('#inventory .iv-contested', { timeout: 10000 });
  h.rec('the counter is told on the stock row that their count is contested',
        await page.evaluate(() => /your count is contested/.test(document.querySelector('#inventory .iv-contested')?.textContent ?? '')));
  h.rec('…and a franchise member is told nothing',
        (await page.evaluate(() => document.querySelectorAll('#inventory .iv-contested').length)) === 1);
  await open();
  s = await sheet();
  h.rec('the counter\'s own count is theirs to attach to, not to contest',
        !!s && s.rows[0].verbs.includes('attach my photograph') && !s.rows[0].verbs.includes('contest'), JSON.stringify(s?.rows[0].verbs));
  await press(0, 'attach my photograph');
  await sleep(500);
  const a = await page.evaluate(() => window.__calls.attach[0]);
  h.rec('the picture the count names is attached to its ballot', a?.[0] === 'contest:evt-2' && a?.[1] === hash, JSON.stringify(a?.slice(0, 2)));
  h.rec('…as base64 of the bytes kept on the device', a?.[2] === 'AQIDBA==', String(a?.[2]));
  s = await sheet();
  h.rec('the sheet says it is attached', !!s && /attached/.test(s.says), s?.says);

  h.rec('no page errors', h.errs.length === 0, h.errs.slice(0, 3).join(' | '));
} catch (e) {
  h.rec('fatal', false, [e.message.split('\n')[0], ...h.errs.slice(0, 5)].join(' | '));
}

await browser.close();
closeServer();
summarize(h);
