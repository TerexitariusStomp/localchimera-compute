/// tests/ux/labels-ux.mjs — a store as it is arranged, a label read, a container
/// counted line by line, and the prints (ui/app/capture.ts,
/// ui/app/tabs/inventory.ts; docs/observation/capture.md §6, §10).
///
/// The inventory face reads a container and then what is in it, a step in. A
/// label's code, typed the way it is read aloud, opens the container it names
/// with a line for each thing in it. A line counted from there is a label
/// count, landed at the container's place, and the container's lines are read
/// again on the way back. The prints hold one symbol per thing, and a thing
/// with no code is given one on the way to the printer. A label's link opens
/// the sheet on the code it carries.
///
/// Run via: make test-labels-ux
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
    code: n.querySelector('.cap-code')?.value ?? null,
    figure: n.querySelector('.cap-figure')?.value ?? null,
    back: !!n.querySelector('.cap-back'),
    lines: [...n.querySelectorAll('.cap-lines li')].map(li => ({
      name: li.querySelector('.cap-lname')?.textContent.trim(),
      sub: li.querySelector('.cap-lsub')?.textContent.trim(),
    })),
    tools: [...n.querySelectorAll('.cap-tools .cap-mini')].map(b => b.textContent.trim()),
  };
});
const click = sel => page.evaluate(s => document.querySelector(s)?.click(), sel);
const clickText = (sel, text) => page.evaluate(([s, t]) =>
  [...document.querySelectorAll(s)].find(b => b.textContent.trim() === t)?.click(), [sel, text]);

// a gateway holding one bin on a shelf, jam and milk in it, and rice beside it
const seed = async () => page.evaluate(async () => {
  const bin = { id: 'bin/1', name: 'the jar bin', 'conforms-to': 'spec-bin', unit: 'each', onhand: 1,
                location: 'site/pantry/shelf-1', code: 'A1B2C3', 'contained-in': '' };
  const jam = { id: 'bin/1/jam', name: 'plum jam', 'conforms-to': 'jam', unit: 'each', onhand: 12,
                location: 'site/pantry/shelf-1', code: 'J4M001', 'contained-in': 'bin/1' };
  const milk = { id: 'bin/1/milk', name: 'milk', 'conforms-to': 'milk', unit: 'l', onhand: 6,
                 location: 'site/pantry/shelf-1', code: '', 'contained-in': 'bin/1',
                 expires: '2026-10-05T00:00:00Z', 'expires-kind': 'use-by' };
  const rice = { id: 'pantry/rice', name: 'rice', 'conforms-to': 'rice', unit: 'kg', onhand: 40,
                 location: 'site/pantry', code: '', 'contained-in': '' };
  window.__store = { bin, jam, milk, rice };
  window.__seam.data.inventory = { specs: [], resources: [rice, jam, bin, milk] };
  window.__seam.data.snapshot = {
    ...(window.__seam.data.snapshot || {}),
    locations: [{ id: 'site', name: 'Mill House', containedIn: null },
                { id: 'site/pantry', name: 'Pantry', containedIn: 'site' },
                { id: 'site/pantry/shelf-1', name: 'Shelf 1', containedIn: 'site/pantry' }],
  };
  window.__calls = { read: [], label: [], count: [] };
  const pin = (name, fn) => Object.defineProperty(window.__seam.handlers, name,
    { configurable: true, get: () => fn, set: () => {} });
  pin('readLabel', code => {
    window.__calls.read.push(code);
    if (code !== 'A1B2C3') return Promise.resolve('err:no stock is known by that code');
    return Promise.resolve(JSON.stringify({ resource: bin, contents: [jam, milk] }));
  });
  pin('labelStock', id => {
    window.__calls.label.push(id);
    return Promise.resolve(JSON.stringify({ code: 'N3W' + String(window.__calls.label.length).padStart(3, '0'), id, name: id }));
  });
  pin('countStock', (...args) => {
    window.__calls.count.push(args);
    const was = args[0] === 'bin/1/jam' ? 12 : 6;
    if (args[0] === 'bin/1/jam') jam.onhand = Number(args[1]);
    return Promise.resolve(JSON.stringify({ event: 'evt-1', record: '', delta: Number(args[1]) - was, onhand: Number(args[1]) }));
  });
  const { emit } = await import('./app/bus.js');
  emit('inventory');
});

try {
  await page.goto(`${BASE}/app.html?face=time`, { waitUntil: 'networkidle' });
  await sleep(400);
  await seed();
  await page.waitForSelector('#inventory .iv-count', { timeout: 10000 });

  // ── the store as it is arranged ──
  const rows = await page.evaluate(() => [...document.querySelectorAll('#inventory li')].map(li => ({
    name: li.querySelector('.iv-name')?.textContent.trim(),
    pad: parseFloat(getComputedStyle(li).paddingLeft),
    sub: li.querySelector('.iv-sub')?.textContent.replace(/\s+/g, ' ').trim(),
  })));
  const at = n => rows.findIndex(r => r.name === n);
  h.rec('a container is read before what is in it', at('the jar bin') >= 0 && at('the jar bin') < at('plum jam') && at('the jar bin') < at('milk'),
        rows.map(r => r.name).join(' · '));
  h.rec('what is in it sits a step in', rows[at('plum jam')].pad > rows[at('the jar bin')].pad && rows[at('milk')].pad > rows[at('the jar bin')].pad,
        rows.map(r => `${r.name}:${r.pad}`).join(' '));
  h.rec('a thing in no container sits at the edge', rows[at('rice')].pad === rows[at('the jar bin')].pad);
  h.rec('a place reads as its path through the places it is inside',
        /Mill House › Pantry › Shelf 1/.test(rows[at('the jar bin')].sub), rows[at('the jar bin')].sub);
  h.rec('a thing with a code shows it as it is read aloud', /A1B 2C3/.test(rows[at('the jar bin')].sub));
  h.rec('a lot\'s date says which date it is', /use by 2026-10-05/.test(rows[at('milk')].sub), rows[at('milk')].sub);

  // ── reading a label ──
  await clickText('#invledger .iv-count', 'read a label');
  await sleep(200);
  let s = await sheet();
  h.rec('the face opens the camera, which takes a typed code beside the shutter', !!s && s.name === 'camera' && s.code === '', JSON.stringify(s));

  await page.fill('#capture .cap-code', 'A1B2');
  await click('#capture .cap-find');
  await sleep(150);
  s = await sheet();
  h.rec('a code too short is said to be one, and nothing is asked',
        !!s && /6 characters/.test(s.says) && (await page.evaluate(() => window.__calls.read.length)) === 0, s?.says);

  await page.fill('#capture .cap-code', 'zzz zzz');
  await click('#capture .cap-find');
  await sleep(200);
  s = await sheet();
  h.rec('a code that names nothing is said so, in the gateway\'s words',
        !!s && /no stock is known by that code/.test(s.says) && s.code === 'zzz zzz', s?.says);

  await page.fill('#capture .cap-code', 'aib 2c3');
  await click('#capture .cap-find');
  await sleep(250);
  s = await sheet();
  h.rec('a code typed as it is read aloud, look-alikes and all, is the code asked for',
        (await page.evaluate(() => window.__calls.read.at(-1))) === 'A1B2C3');
  h.rec('the sheet opens on the container the code names', !!s && s.name === 'the jar bin', JSON.stringify(s));
  h.rec('…where it is, its code, and how much it holds',
        !!s && /Mill House › Pantry › Shelf 1/.test(s.sub) && /A1B 2C3/.test(s.sub) && /holds 2/.test(s.sub), s?.sub);
  h.rec('…with a line for each thing in it',
        !!s && s.lines.map(l => l.name).join(',') === 'plum jam,milk', JSON.stringify(s?.lines));
  h.rec('a line says what the ledger reads, and its date',
        !!s && /12 each/.test(s.lines[0].sub) && /6 l · use by 2026-10-05/.test(s.lines[1].sub), JSON.stringify(s?.lines));
  h.rec('the container offers its count and its prints',
        !!s && ['count the container', 'checklist', 'blind checklist', 'labels', 'name card'].every(t => s.tools.includes(t)),
        s?.tools.join(' · '));

  // ── counting a line ──
  await page.evaluate(() => document.querySelector('#capture .cap-lines li .cap-mini').click());
  await sleep(200);
  s = await sheet();
  h.rec('a line opens its count, with the way back', !!s && s.name === 'plum jam' && s.back && s.figure === '', JSON.stringify(s));
  await page.fill('#capture .cap-figure', '10');
  await click('#capture .cap-go');
  await sleep(300);
  const sent = await page.evaluate(() => window.__calls.count[0]);
  h.rec('the count names the thing in the container', sent?.[0] === 'bin/1/jam', JSON.stringify(sent));
  h.rec('…as a label count', sent?.[3] === 'label', String(sent?.[3]));
  h.rec('…landed at the container\'s place', sent?.[4] === 'site/pantry/shelf-1', String(sent?.[4]));
  s = await sheet();
  h.rec('the sheet says what the count found', !!s && /2 each more than is there/.test(s.says), s?.says);
  await click('#capture .cap-go');
  await sleep(250);
  s = await sheet();
  h.rec('done returns to the container', !!s && s.name === 'the jar bin', s?.name);
  h.rec('…whose lines were read again', !!s && /10 each/.test(s.lines[0].sub), JSON.stringify(s?.lines));

  // ── the prints ──
  await page.evaluate(() => { HTMLIFrameElement.prototype.addEventListener = function () {}; });   // hold the printer's sheet shut
  await clickText('#capture .cap-tools .cap-mini', 'checklist');
  await sleep(400);
  let frames = await page.evaluate(() => [...document.querySelectorAll('iframe[aria-hidden]')].map(f => f.srcdoc));
  const list = frames.at(-1) || '';
  h.rec('the checklist is a page headed by the container', /the jar bin/.test(list) && /<!doctype html>/.test(list));
  h.rec('…with a line for each thing, and what the ledger reads', /plum jam/.test(list) && /milk/.test(list) && />10</.test(list));
  h.rec('a thing with no code is given one on the way to the printer',
        (await page.evaluate(() => window.__calls.label.join(','))) === 'bin/1/milk' && /N3W 001/.test(list));

  await clickText('#capture .cap-tools .cap-mini', 'blind checklist');
  await sleep(400);
  frames = await page.evaluate(() => [...document.querySelectorAll('iframe[aria-hidden]')].map(f => f.srcdoc));
  h.rec('the blind checklist leaves what the ledger reads off the page',
        /blind count/.test(frames.at(-1)) && !/>10</.test(frames.at(-1)));

  await clickText('#capture .cap-tools .cap-mini', 'labels');
  await sleep(400);
  frames = await page.evaluate(() => [...document.querySelectorAll('iframe[aria-hidden]')].map(f => f.srcdoc));
  const labels = frames.at(-1) || '';
  h.rec('the label sheet holds one symbol per thing', (labels.match(/<svg /g) || []).length === 3, String((labels.match(/<svg /g) || []).length));
  h.rec('…and says nothing of what the things are', !/jar|jam|milk|Pantry/.test(labels));

  await page.keyboard.press('Escape');
  await sleep(150);
  h.rec('Escape closes the sheet', (await sheet()) === null);

  await clickText('#invledger .iv-count', 'name cards');
  await sleep(500);
  frames = await page.evaluate(() => [...document.querySelectorAll('iframe[aria-hidden]')].map(f => f.srcdoc));
  const cards = frames.at(-1) || '';
  h.rec('the face prints name cards for what is shown', ['rice', 'plum jam', 'the jar bin', 'milk'].every(n => cards.includes(n)));

  // ── a label's link ──
  await page.goto(`${BASE}/app.html?face=time&label=a1b2c3`, { waitUntil: 'networkidle' });
  await sleep(500);
  s = await sheet();
  h.rec('a label\'s link opens the sheet on the code it carries',
        !!s && s.name === 'camera' && s.code === 'A1B 2C3', JSON.stringify(s));

  h.rec('no page errors', h.errs.length === 0, h.errs.slice(0, 3).join(' | '));
} catch (e) {
  // what the page itself said is what explains a wait that never ended
  h.rec('fatal', false, [e.message.split('\n')[0], ...h.errs.slice(0, 5)].join(' | '));
}

await browser.close();
closeServer();
summarize(h);
