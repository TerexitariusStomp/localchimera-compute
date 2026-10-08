/// tests/ux/planned-count-ux.mjs — a count the plan asked for, from the calendar
/// to the ledger (ui/app/day/respond.ts, ui/app/capture.ts,
/// ui/app/tabs/inventory.ts; docs/observation/capture.md §4, §10).
///
/// A committed count answers with "count it", and with that in place of the
/// verb that records hours, since the count lands its hours beside its figure.
/// The verb opens the capture sheet on what is to be counted: a container on
/// its lines, a thing holding nothing at its figure. Every count made there
/// names the commitment. A blind count keeps the ledger's figures off the
/// sheet until a figure has landed. The inventory face says how often each
/// target is counted and which are due, and offers the due ones.
///
/// Run via: make test-planned-count-ux
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
    name: t('.cap-name'), sub: t('.cap-sub'), says: t('.cap-says'),
    figure: n.querySelector('.cap-figure')?.value ?? null,
    lines: [...n.querySelectorAll('.cap-lines li')].map(li => ({
      name: li.querySelector('.cap-lname')?.textContent.trim(),
      sub: li.querySelector('.cap-lsub')?.textContent.trim(),
    })),
    tools: [...n.querySelectorAll('.cap-tools .cap-mini')].map(b => b.textContent.trim()),
  };
});
const click = sel => page.evaluate(s => document.querySelector(s)?.click(), sel);

// the verbs a committed event answers with, and one of them run
const verbs = ev => page.evaluate(async e => {
  const { actionsFor } = await import('./app/day/respond.js');
  return actionsFor(e).map(a => a.l);
}, ev);
const run = (ev, label) => page.evaluate(async ([e, l]) => {
  const { actionsFor } = await import('./app/day/respond.js');
  actionsFor(e).find(a => a.l === l)?.f();
}, [ev, label]);

const committed = (proc, id) => ({
  label: 'a count', t0: 9, t1: 9.25, kind: 'work', action: 'work', status: 'committed',
  proc, vfId: id, scope: 'org:commune', effort: 0.25, done: 0,
});

try {
  await page.goto(`${BASE}/app.html?face=time`, { waitUntil: 'networkidle' });
  await sleep(400);

  await page.evaluate(async () => {
    const at = 'site/pantry/shelf-1';
    window.__seam.data.inventory = { specs: [], resources: [
      { id: 'bin/1', name: 'the jar bin', 'conforms-to': 'spec-bin', unit: 'each', onhand: 1, location: at, code: 'A1B2C3' },
      { id: 'bin/1/jam', name: 'plum jam', 'conforms-to': 'jam', unit: 'each', onhand: 12, location: at, 'contained-in': 'bin/1' },
      { id: 'bin/1/box', name: 'a box', 'conforms-to': 'spec-bin', unit: 'each', onhand: 1, location: at, 'contained-in': 'bin/1' },
      { id: 'bin/1/box/lids', name: 'lids', 'conforms-to': 'lid', unit: 'each', onhand: 30, location: at, 'contained-in': 'bin/1/box' },
      { id: 'rice', name: 'rice', 'conforms-to': 'rice', unit: 'kg', onhand: 40, location: 'site/pantry' },
    ] };
    window.__seam.data.snapshot = { ...(window.__seam.data.snapshot || {}), locations: [
      { id: 'site', name: 'Mill House', containedIn: null },
      { id: 'site/pantry', name: 'Pantry', containedIn: 'site' },
      { id: 'site/pantry/shelf-1', name: 'Shelf 1', containedIn: 'site/pantry' },
    ] };
    window.__calls = { count: [], plan: [], schedule: 0 };
    const pin = (name, fn) => Object.defineProperty(window.__seam.handlers, name,
      { configurable: true, get: () => fn, set: () => {} });
    pin('countStock', (...args) => {
      window.__calls.count.push(args);
      return Promise.resolve(JSON.stringify({ event: 'evt-1', record: 'evt-1-record', hours: 0.15,
                                              delta: Number(args[1]) - 12, onhand: Number(args[1]) }));
    });
    pin('countSchedule', () => {
      window.__calls.schedule++;
      return Promise.resolve(JSON.stringify({ rows: [
        { id: 'bin/1', name: 'the jar bin', lines: 4, hours: 0.3, interval: 21 * 86400, class: 'A',
          regime: 'announced', lastCount: '', due: '2026-09-28T00:00:00Z', overdue: true },
        { id: 'rice', name: 'rice', lines: 1, hours: 0.15, interval: 180 * 86400, class: 'B',
          regime: 'announced', lastCount: '2026-09-01T00:00:00Z', due: '2027-03-01T00:00:00Z', overdue: false },
      ] }));
    });
    pin('planCounts', (...args) => {
      window.__calls.plan.push(args);
      return Promise.resolve(JSON.stringify({ laid: [{ proposal: 'p1', target: 'bin/1', counter: 'bob', regime: 'announced', hours: 0.3 }], due: 1 }));
    });
    const { emit } = await import('./app/bus.js');
    emit('inventory');
  });
  await page.waitForSelector('#inventory .iv-count', { timeout: 10000 });
  await sleep(300);

  // ── the calendar's answer ──
  const bake = { ...committed('bake', 'cmt-bake'), label: 'bake' };
  const binCount = committed('count~announced~bin/1', 'cmt-count-bin');
  const riceCount = committed('count~random~rice', 'cmt-count-rice');
  h.rec('committed work answers with the verb that records it',
        (await verbs(bake)).includes('✓ it happened'), (await verbs(bake)).join(' · '));
  const v = await verbs(binCount);
  h.rec('a committed count answers with "count it"', v.includes('◉ count it'), v.join(' · '));
  h.rec('…in place of the verb that records hours', !v.includes('✓ it happened'));
  h.rec('…and can be released like any commitment', v.includes('↩ release'));
  h.rec('a count already recorded answers with no count',
        !(await verbs({ ...binCount, recorded: true })).includes('◉ count it'));

  // ── a container, on its lines ──
  await run(binCount, '◉ count it');
  await sleep(250);
  let s = await sheet();
  h.rec('the verb opens the sheet on the container', !!s && s.name === 'the jar bin', JSON.stringify(s));
  h.rec('…which says the plan asked for the count', !!s && /the plan asked for this count/.test(s.sub), s?.sub);
  h.rec('…with a line for everything inside it, however deep',
        !!s && s.lines.map(l => l.name).sort().join(',') === 'a box,lids,plum jam', JSON.stringify(s?.lines));
  h.rec('an announced count shows what the ledger reads',
        !!s && s.lines.find(l => l.name === 'plum jam')?.sub === '12 each');

  await page.evaluate(() => [...document.querySelectorAll('#capture .cap-lines li')]
    .find(li => li.querySelector('.cap-lname').textContent.trim() === 'plum jam').querySelector('.cap-mini').click());
  await sleep(200);
  await page.fill('#capture .cap-figure', '11');
  await click('#capture .cap-go');
  await sleep(300);
  let sent = await page.evaluate(() => window.__calls.count.at(-1));
  h.rec('a line\'s count names the thing', sent?.[0] === 'bin/1/jam', JSON.stringify(sent));
  h.rec('…and the commitment it fulfils', sent?.[6] === 'cmt-count-bin', String(sent?.[6]));
  h.rec('…at the container\'s place', sent?.[4] === 'site/pantry/shelf-1');
  s = await sheet();
  h.rec('the sheet says what the count found, and the hours it recorded',
        !!s && /1 each more than is there/.test(s.says) && /0\.15 h of counting recorded/.test(s.says), s?.says);
  await page.keyboard.press('Escape');
  await sleep(150);

  // ── a thing holding nothing, counted blind ──
  const rv = await page.evaluate(async e => {
    const { actionsFor } = await import('./app/day/respond.js');
    return actionsFor(e).find(a => a.l === '◉ count it')?.t ?? '';
  }, riceCount);
  h.rec('a blind count says it is one before it is opened', /blind/.test(rv), rv);
  await run(riceCount, '◉ count it');
  await sleep(250);
  s = await sheet();
  h.rec('a thing holding nothing opens at its figure', !!s && s.name === 'rice' && s.figure === '', JSON.stringify(s));
  h.rec('a blind count keeps the ledger\'s figure off the sheet',
        !!s && /blind count/.test(s.sub) && !/40/.test(s.sub), s?.sub);
  await page.fill('#capture .cap-figure', '38');
  await click('#capture .cap-go');
  await sleep(300);
  sent = await page.evaluate(() => window.__calls.count.at(-1));
  h.rec('the blind count names its commitment', sent?.[0] === 'rice' && sent?.[6] === 'cmt-count-rice', JSON.stringify(sent));
  s = await sheet();
  h.rec('once the figure has landed the ledger\'s shows', !!s && /the ledger read 40 kg/.test(s.sub), s?.sub);
  await page.keyboard.press('Escape');
  await sleep(150);

  // a blind container keeps its lines' figures off the sheet too
  await run(committed('count~undisclosed~bin/1', 'cmt-hidden'), '◉ count it');
  await sleep(250);
  s = await sheet();
  h.rec('a blind container shows its lines without their figures',
        !!s && s.lines.every(l => !/\d/.test(l.sub)), JSON.stringify(s?.lines));
  h.rec('…and offers the blind checklist alone',
        !!s && s.tools.includes('blind checklist') && !s.tools.includes('checklist'), s?.tools.join(' · '));
  await page.keyboard.press('Escape');
  await sleep(150);

  // ── a count of something not on hand ──
  await run(committed('count~announced~gone', 'cmt-gone'), '◉ count it');
  await sleep(250);
  h.rec('a count of a stock that is not on hand opens no sheet', (await sheet()) === null);

  // ── the inventory face's schedule ──
  const face = await page.evaluate(() => ({
    ledger: document.querySelector('#invledger')?.textContent.replace(/\s+/g, ' ').trim(),
    rows: [...document.querySelectorAll('#inventory li')].map(li => ({
      name: li.querySelector('.iv-name')?.textContent.trim(),
      sub: li.querySelector('.iv-sub')?.textContent.replace(/\s+/g, ' ').trim(),
    })),
  }));
  const sub = n => face.rows.find(r => r.name === n)?.sub ?? '';
  h.rec('the face says how many counts are due', /1 count due/.test(face.ledger), face.ledger);
  h.rec('a target says how often it is counted, and that it is due',
        /counted every 3 weeks — due/.test(sub('the jar bin')), sub('the jar bin'));
  h.rec('a target not yet due says how often alone',
        /counted every 6 months/.test(sub('rice')) && !/due/.test(sub('rice')), sub('rice'));
  h.rec('a thing inside a target has no line of its own in the schedule', !/counted every/.test(sub('plum jam')));

  await page.evaluate(() => [...document.querySelectorAll('#invledger .iv-count')]
    .find(b => b.textContent.trim() === 'offer the counts').click());
  await sleep(300);
  const plan = await page.evaluate(() => window.__calls.plan[0]);
  h.rec('offering the counts asks for the announced ones whose window is open', plan?.[0] === 'announced' && plan?.length === 3, JSON.stringify(plan));
  const note = await page.evaluate(() => document.querySelector('#invledger .iv-note')?.textContent.trim());
  h.rec('the face says how many were offered', /1 count offered/.test(note || ''), note);

  h.rec('no page errors', h.errs.length === 0, h.errs.slice(0, 3).join(' | '));
} catch (e) {
  // what the page itself said is what explains a wait that never ended
  h.rec('fatal', false, [e.message.split('\n')[0], ...h.errs.slice(0, 5)].join(' | '));
}

await browser.close();
closeServer();
summarize(h);
