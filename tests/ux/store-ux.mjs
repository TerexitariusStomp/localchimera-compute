/// tests/ux/store-ux.mjs — the store face: what is held, as it is arranged
/// (ui/app/tabs/store.ts, ui/app/store-view.ts, ui/app/store-data.ts;
/// docs/observation/capture.md §10).
///
/// ?face=store takes the stage. The left is the tree: places outermost first, a
/// container with what is in it a step in, badges on the rows that are due or
/// contested; the filters narrow it. The right is a desk: with nothing chosen,
/// the counts due and the contests open; with a stock chosen, its figure and
/// verbs. Count opens the capture sheet on that stock, counts opens the contest
/// screen, and the counter is told on the stock when a member contests their
/// count. The rail's inventory section opens the face.
///
/// Run via: make test-store-ux
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
page.on('pageerror', e => h.errs.push(String(e).slice(0, 160)));

// the tree in reading order: a card's heading, then its places and stock; depth is how far in a line sits
const tree = () => page.evaluate(() =>
  [...document.querySelectorAll('#storetree .st-place, #storetree .st-stock')].map(li => ({
    kind: li.classList.contains('st-place') ? 'place' : 'stock',
    name: (li.querySelector('.st-pname') || li.querySelector('.st-sname'))?.textContent.trim() ?? '',
    pad: Number(li.dataset.depth),
    badges: [...li.querySelectorAll('.st-glyph')].map(b => b.title),
    on: li.classList.contains('on'),
  })));
const deskText = () => page.evaluate(() => document.getElementById('storedesk')?.textContent.replace(/\s+/g, ' ').trim() ?? '');
const chip = (label) => page.evaluate(l =>
  [...document.querySelectorAll('#storefilters .st-chip')].find(c => c.textContent.includes(l))?.click(), label);
const reads = () => page.evaluate(() => document.querySelector('#storehead .st-tool[title*="photo reads"]')?.title ?? '');
const chips = () => page.evaluate(() => document.getElementById('storefilters')?.textContent.replace(/\s+/g, ' ').trim() ?? '');
const sheet = () => page.evaluate(() => {
  const n = document.querySelector('#capture');
  return !n || n.hidden ? null : { name: n.querySelector('.cap-name')?.textContent.trim() ?? '' };
});

const install = () => page.evaluate(async () => {
  window.__seam.data.snapshot = { locations: [
    { id: 'site', name: 'Mill House', containedIn: null },
    { id: 'pantry', name: 'Pantry', containedIn: 'site' },
    { id: 'shelf', name: 'Shelf 1', containedIn: 'pantry' },
    { id: 'garage', name: 'Garage', containedIn: 'site' },
  ] };
  window.__seam.data.inventory = {
    specs: [{ id: 'jam', name: 'jam', unit: 'each' }, { id: 'rice', name: 'rice', unit: 'kg' }],
    resources: [
      { id: 'bin', name: 'the jar bin', 'conforms-to': 'spec-bin', unit: 'each', onhand: 1, location: 'shelf', code: 'A1B2C3', 'contained-in': '', 'distribution-mode': 'communal' },
      { id: 'jam1', name: 'plum jam', 'conforms-to': 'jam', unit: 'each', onhand: 12, location: 'shelf', code: '', 'contained-in': 'bin', 'expires-kind': 'use-by', expires: '2026-12-01' },
      { id: 'rice1', name: 'rice', 'conforms-to': 'rice', unit: 'kg', onhand: 40, location: 'pantry', code: '', 'contained-in': '',
        expected: { low: 36, high: 42, flows: [{ id: 'cook', action: 'consume', quantity: -4, when: '2026-09-28T08:00:00Z', proc: 'cook' }, { id: 'sack', action: 'produce', quantity: 2, when: '2026-09-28T09:00:00Z', proc: 'mill' }] } },
      { id: 'tent', name: 'tent', 'conforms-to': 'tent', unit: 'each', onhand: 1, location: '', code: '', 'contained-in': '' },
    ],
  };
  window.__calls = { count: [], history: [], contest: 0, between: 0, readings: 0 };
  const pin = (name, fn) => Object.defineProperty(window.__seam.handlers, name, { configurable: true, get: () => fn, set: () => {} });
  pin('countSchedule', () => Promise.resolve(JSON.stringify({ rows: [
    { id: 'rice1', name: 'rice', lines: 1, hours: 0.15, interval: 86400 * 21, class: 'A', regime: 'announced', lastCount: '', due: '2026-09-20T00:00:00Z', overdue: true },
    { id: 'bin', name: 'the jar bin', lines: 3, hours: 0.3, interval: 86400 * 90, class: 'B', regime: 'announced', lastCount: '2026-09-01T00:00:00Z', due: '2026-12-01T00:00:00Z', overdue: false },
  ] })));
  window.__opened = false;
  pin('contests', () => Promise.resolve(JSON.stringify({ rows: [
    { id: 'contest:evt-1', eventId: 'evt-1', kind: 'count', resource: 'jam1', worker: 'me', by: 'EBO', reason: 'never opened the crate', role: 'attach' },
    ...(window.__opened ? [{ id: 'contest:evt-9', eventId: 'evt-9', kind: 'count', resource: 'rice1', worker: 'EOTHER', by: 'me', reason: 'she never weighed it', role: 'vote' }] : []),
  ] })));
  pin('contestWork', (...a) => { window.__opened = true; return Promise.resolve('contest:evt-9'); });
  pin('countHistory', (...a) => { window.__calls.history.push(a); return Promise.resolve(JSON.stringify({ rows: a[0] === 'rice1' ? [
    { id: 'evt-9', at: '2026-10-01T10:00:00Z', delta: -1, unit: 'kg', counter: 'EOTHERCOUNTER', technique: 'count:stated', evidence: '', mine: false }] : [] })); });
  pin('readingsBetween', () => { window.__calls.between++; return Promise.resolve(JSON.stringify({ rows: [] })); });
  pin('scopeReadings', () => { window.__calls.readings++; return Promise.resolve(JSON.stringify({ rows: [], drift: { n: 0, meanAbs: 0, net: 0 }, latest: null })); });
  pin('countStock', (...a) => { window.__calls.count.push(a); return Promise.resolve(JSON.stringify({ event: 'evt-1', record: '', hours: 0, delta: -1, onhand: Number(a[1]) })); });
  pin('allotment', () => Promise.resolve(JSON.stringify({ remaining: 5, perWeek: 21, opens: '2026-10-05T00:00:00Z', sees: true })));
  const { emit } = await import('./app/bus.js');
  emit('inventory');
});

try {
  await page.goto(`${BASE}/app.html?face=store`, { waitUntil: 'networkidle' });
  await sleep(500);
  h.rec('?face=store takes the stage', await page.evaluate(() => document.getElementById('main').getAttribute('data-face')) === 'store');
  // offline the face shows the demo commons (ui/app/demo/store.ts), in the shape the gateway answers
  await page.waitForSelector('#storetree .st-stock', { timeout: 10000 });
  await sleep(300);
  let demo = await tree();
  h.rec('offline, the demo commons fills the tree, its places nested',
        demo.some(n => n.kind === 'place' && n.name === 'neighbourhood commons') && demo.find(n => n.name === 'commons canteen')?.pad > demo.find(n => n.name === 'neighbourhood commons')?.pad && demo.filter(n => n.kind === 'stock').length === 15, JSON.stringify(demo.map(n => n.name)));
  const shelf = demo.findIndex(n => n.name === 'pantry shelf');
  h.rec('…a container with its code is followed by what is in it, a step in',
        shelf > 0 && demo[shelf + 1]?.name === 'dry beans' && demo[shelf + 2]?.name === 'onions & roots' && demo[shelf + 1].pad > demo[shelf].pad, JSON.stringify(demo.slice(shelf, shelf + 3)));
  h.rec('…a lot that perishes today says so, and a count overdue is badged',
        demo.find(n => n.name === 'cooked meals')?.badges.includes('perishes') && demo.find(n => n.name === 'garden greens')?.badges.includes('count due'), JSON.stringify(demo.find(n => n.name === 'garden greens')));
  h.rec('…the counter is told their count is contested',
        demo.find(n => n.name === 'garden greens')?.badges.some(b => /contested/.test(b)), JSON.stringify(demo.find(n => n.name === 'garden greens')));
  const demoChips = await chips();
  h.rec('…the band says what is held, due and contested, and the week\'s reads',
        /15 kinds/.test(demoChips) && /\d+ due/.test(demoChips) && /1 contested/.test(demoChips) && /17 of 21 photo reads left/.test(await reads()), demoChips);
  let demoDesk = await deskText();
  h.rec('…the desk lists the counts due and both contests',
        /counts due/.test(demoDesk) && /lending library/.test(demoDesk) && /the crate was empty at noon/.test(demoDesk) && /the bakery was shut that day/.test(demoDesk) && /vote in the forum/.test(demoDesk), demoDesk);
  await page.click('#storetree .st-stock[data-id="demo:beans"]');
  await sleep(300);
  demoDesk = await deskText();
  h.rec('…a stock chosen shows its place, its counts and what was seen',
        /neighbourhood commons › pantry/.test(demoDesk) && /3 counts found the ledger off by -2\.5 kg/.test(demoDesk) && /seen count:stated -1\.5 → count:label \+0\.5 → count:photo -1\.5/.test(demoDesk), demoDesk);
  await page.click('#storetree .st-stock[data-id="demo:beans"]');

  await install();
  await page.waitForSelector('#storetree .st-stock', { timeout: 10000 });
  await sleep(300);
  let t = await tree();
  h.rec('the tree starts at the outermost place', t[0]?.kind === 'place' && t[0].name === 'Mill House', JSON.stringify(t.map(n => n.name)));
  h.rec('places nest by path, and an empty place is left out',
        t.some(n => n.kind === 'place' && n.name === 'Pantry') && !t.some(n => /Garage/.test(n.name)), JSON.stringify(t.map(n => n.name)));
  const bin = t.findIndex(n => n.name === 'the jar bin');
  h.rec('a container is followed by what is in it, a step in', t[bin + 1]?.name === 'plum jam' && t[bin + 1].pad > t[bin].pad, JSON.stringify(t.slice(bin, bin + 2)));
  h.rec('what names no place gathers at the end', t[t.length - 2]?.name === 'somewhere unstated' && t[t.length - 1].name === 'tent', JSON.stringify(t.slice(-2)));
  h.rec('a count overdue is badged', t.find(n => n.name === 'rice')?.badges.includes('count due'), JSON.stringify(t.find(n => n.name === 'rice')));
  h.rec('a count a member contests is badged on the counter\'s stock', t.find(n => n.name === 'plum jam')?.badges.some(b => /contested/.test(b)));
  h.rec('a use-by lot says it perishes', t.find(n => n.name === 'plum jam')?.badges.includes('perishes'));
  const head = await chips();
  h.rec('the band says what is held, due and contested', /4 kinds/.test(head) && /1 due/.test(head) && /1 contested/.test(head), head);
  h.rec('…and the week\'s reads', /5 of 21 photo reads left/.test(await reads()), await reads());

  // the desk with nothing chosen: what is due, and the contests
  let d = await deskText();
  h.rec('the desk shows the counts due, overdue first',
        /counts due/.test(d) && /overdue \d+ days/.test(d) && d.indexOf('rice') < d.indexOf('the jar bin') && /due in \d+ days/.test(d), d);
  h.rec('…and the contests open, with the way to attach',
        /contests/.test(d) && /never opened the crate/.test(d) && /your count: attach your photograph/.test(d), d);

  // filters
  await chip(' due');
  await sleep(200);
  t = await tree();
  h.rec('due keeps the stock whose count is overdue and the places above it',
        t.filter(n => n.kind === 'stock').map(n => n.name).join() === 'rice' && t.some(n => n.kind === 'place' && /Pantry/.test(n.name)), JSON.stringify(t.map(n => n.name)));
  await chip(' due'); await chip('contested');
  await sleep(200);
  t = await tree();
  h.rec('contested keeps the contested count\'s stock in its container', t.filter(n => n.kind === 'stock').map(n => n.name).join() === 'the jar bin,plum jam', JSON.stringify(t.map(n => n.name)));
  await chip('contested'); await chip('kind');
  await sleep(200);

  // find: the Express bar is the one search, and a name narrows the cards; a card folds to its heading
  h.rec('the store has no search box of its own', await page.evaluate(() => !document.getElementById('storefind')));
  await page.fill('.share-name', 'jam');
  await sleep(250);
  t = await tree();
  h.rec('a word of a name narrows the tree to that stock in its container and place',
        t.filter(n => n.kind === 'stock').map(n => n.name).join() === 'the jar bin,plum jam' && !t.some(n => n.name === 'rice'), JSON.stringify(t.map(n => n.name)));
  h.rec('…and the bar keeps what was typed', (await page.inputValue('.share-name')) === 'jam');
  await page.fill('.share-name', '');
  await sleep(250);
  h.rec('clearing it brings the whole tree back', (await tree()).some(n => n.name === 'rice'));
  await page.click('#storetree .st-card[data-place="site"] > .st-place');
  await sleep(200);
  t = await tree();
  h.rec('a card folds to its heading', t.some(n => n.name === 'Mill House') && !t.some(n => n.name === 'rice'), JSON.stringify(t.map(n => n.name)));
  await page.click('#storetree .st-card[data-place="site"] > .st-place');
  await sleep(200);
  h.rec('…and opens again', (await tree()).some(n => n.name === 'rice'));
  const tools = await page.evaluate(() => ({
    more: [...document.querySelectorAll('#storehead .st-menu button')].map(b => b.textContent.trim()),
    glyphWords: [...document.querySelectorAll('#storetree .st-stock[data-id="rice1"] .st-glyph')].map(g => g.getAttribute('aria-label')),
  }));
  h.rec('labels and name cards wait behind the more menu', tools.more.includes('labels') && tools.more.includes('name cards'), JSON.stringify(tools.more));
  h.rec('a glyph carries its words for a reader who cannot see it', tools.glyphWords.includes('count due'), JSON.stringify(tools.glyphWords));

  // choose a stock
  await page.click('#storetree .st-stock[data-id="jam1"]');
  await sleep(300);
  d = await deskText();
  h.rec('a stock chosen fills the desk with its figure', /plum jam/.test(d) && /12 each/.test(d), d);
  h.rec('…its place, and its date', /Mill House › Pantry › Shelf 1/.test(d) && /use by 2026-12-01/.test(d), d);
  h.rec('the counter is told their count is contested, with the way to attach', /A member says your count of this was not done/.test(d) && /attach your photograph/.test(d), d);
  h.rec('the chosen row is marked', (await tree()).find(n => n.name === 'plum jam')?.on === true);

  await page.click('#storetree .st-stock[data-id="rice1"]');
  await sleep(300);
  d = await deskText();
  const planOpen = await page.evaluate(() => document.querySelector('#storedesk .cap-plan')?.open ?? null);
  h.rec('a stock the plan bears on shows its range in one line, the flows folded', /the plan expects 36–42 kg/.test(d) && planOpen === false, d);
  h.rec('…and one primary act', await page.evaluate(() => document.querySelectorAll('#storedesk .st-primary').length) === 1);
  await page.click('#storetree .st-stock[data-id="jam1"]');
  await sleep(300);

  // verbs
  await page.evaluate(() => [...document.querySelectorAll('#storedesk .st-verbs .st-tool')].find(b => b.textContent.trim() === 'count')?.click());
  await sleep(300);
  let s = await sheet();
  h.rec('count opens the capture sheet on that stock', !!s && /plum jam/.test(s.name), JSON.stringify(s));
  await page.keyboard.press('Escape'); await sleep(200);
  await page.evaluate(() => [...document.querySelectorAll('#storedesk .st-verbs .st-tool')].find(b => b.textContent.trim() === 'history')?.click());
  await sleep(500);
  s = await sheet();
  h.rec('counts opens the contest screen for it', !!s && /the counts of plum jam/.test(s.name), JSON.stringify(s));
  h.rec('…asking for its counts', (await page.evaluate(() => window.__calls.history[0]))?.[0] === 'jam1');
  await page.keyboard.press('Escape'); await sleep(200);

  // a container: its lines, each countable
  await page.click('#storetree .st-stock[data-id="bin"]');
  await sleep(300);
  d = await deskText();
  h.rec('a container shows what is in it', /in it .*plum jam.*12 each/.test(d), d);
  await page.click('#storedesk .st-close');
  await sleep(200);
  h.rec('the desk closes back to the overview', /counts due/.test(await deskText()));

  // a count made from the desk is announced: the spec's readings and history are asked again
  const before = await page.evaluate(() => ({ b: window.__calls.between, r: window.__calls.readings }));
  await page.click('#storetree .st-stock[data-id="rice1"]');
  await sleep(300);
  await page.evaluate(() => [...document.querySelectorAll('#storedesk .st-verbs .st-tool')].find(b => b.textContent.trim() === 'count')?.click());
  await sleep(300);
  await page.fill('#capture .cap-figure', '39');
  await page.evaluate(() => document.querySelector('#capture .cap-go').click());
  await sleep(600);
  const after = await page.evaluate(() => ({ b: window.__calls.between, r: window.__calls.readings }));
  h.rec('a count landed from the desk asks the readings and the history again', after.b > before.b && after.r > before.r, JSON.stringify({ before, after }));
  await page.keyboard.press('Escape'); await sleep(200);
  await page.click('#storedesk .st-close'); await sleep(200);

  // a contest opened from the counts screen shows on the desk without a reload
  await page.click('#storetree .st-stock[data-id="rice1"]');
  await sleep(300);
  await page.evaluate(() => [...document.querySelectorAll('#storedesk .st-verbs .st-tool')].find(b => b.textContent.trim() === 'history')?.click());
  await page.waitForSelector('#capture .cap-hist', { timeout: 10000 });
  await page.evaluate(() => [...document.querySelectorAll('#capture .cap-hist .cap-mini')].find(b => b.textContent.trim() === 'contest')?.click());
  await sleep(200);
  await page.fill('#capture .cap-reason', 'she never weighed it');
  await page.evaluate(() => [...document.querySelectorAll('#capture .cap-hist .cap-mini')].find(b => b.textContent.trim() === 'open the contest')?.click());
  await sleep(600);
  await page.keyboard.press('Escape'); await sleep(200);
  await page.click('#storedesk .st-close'); await sleep(300);
  d = await deskText();
  h.rec('a contest opened from the counts screen is on the desk at once', /rice/.test(d) && /she never weighed it/.test(d) && /vote in the forum/.test(d), d);

  // the schedule's "count it"
  await page.evaluate(() => [...document.querySelectorAll('#storedesk .st-due .st-mini')].find(b => b.textContent.trim() === 'count it')?.click());
  await sleep(300);
  s = await sheet();
  h.rec('a count due is counted from the desk', !!s && /rice/.test(s.name), JSON.stringify(s));
  await page.keyboard.press('Escape'); await sleep(200);

  // the rail's door in
  await page.goto(`${BASE}/app.html?face=time`, { waitUntil: 'networkidle' });
  await sleep(500);
  await page.click('#openstore');
  await sleep(400);
  h.rec('the inventory section opens the store', await page.evaluate(() => document.getElementById('main').getAttribute('data-face')) === 'store');

  // the rail and the face count the same stock the same way
  await page.goto(`${BASE}/app.html?face=time`, { waitUntil: 'networkidle' });
  await sleep(500);
  await install();
  await page.waitForSelector('#inventory li', { timeout: 10000 });
  await sleep(500);
  const rail = await page.evaluate(() => document.getElementById('invledger')?.textContent.replace(/\s+/g, ' ') ?? '');
  h.rec('the rail counts one perishable, as the face does', /1 perishable/.test(rail), rail);
  h.rec('…and one count due', /1 count due/.test(rail), rail);
  await page.click('#openstore');
  await sleep(400);

  // a phone: one column, the page scrolling as one
  await page.setViewportSize({ width: 390, height: 800 });
  await sleep(400);
  const cols = await page.evaluate(() => getComputedStyle(document.querySelector('#storestage .st-cols')).gridTemplateColumns.split(' ').length);
  h.rec('on a phone the tree stacks over the desk', cols === 1, String(cols));
  const over = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  h.rec('…without a horizontal scroll', over <= 1, String(over));

  // photographs kept to be read later are one tap from the face
  const noLink = await page.evaluate(() => ![...document.querySelectorAll('#storehead .st-tool')].some(b => /waiting/.test(b.textContent)));
  await page.evaluate(async () => {
    const { enqueue } = await import('./app/queue.js');
    enqueue({ at: '2026-10-01T09:00:00Z', shots: ['sha256:' + '1'.repeat(64)], place: '', container: '', label: 'the shelf' });
  });
  await sleep(300);
  const link = await page.evaluate(() => [...document.querySelectorAll('#storehead .st-tool')].find(b => /waiting/.test(b.textContent))?.textContent.trim() ?? '');
  h.rec('with nothing waiting the head has no queue link; with a scene waiting it says so', noLink && /1 waiting to be read/.test(link), link);
  await page.evaluate(() => [...document.querySelectorAll('#storehead .st-tool')].find(b => /waiting/.test(b.textContent)).click());
  await sleep(300);
  const q = await sheet();
  h.rec('…and the link opens the queue', !!q && q.name === 'waiting to be read', JSON.stringify(q));
  await page.evaluate(async () => { const { dequeue, listQueued } = await import('./app/queue.js'); listQueued().forEach(e => dequeue(e.id)); });
  await page.keyboard.press('Escape');
  await sleep(200);

  // a seat attached to a gateway whose books are empty reads empty: nothing of the demo commons shows
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.evaluate(async () => {
    window.__seam.data.inventory = { specs: [], resources: [] };
    const { emit } = await import('./app/bus.js');
    emit('status', 'ok:EAID123|k0');
  });
  await sleep(400);
  const bare = await tree();
  h.rec('an attached seat with empty books shows no stock, and none of the demo commons', bare.every(n => n.kind !== 'stock') && !bare.some(n => /commons|demo/.test(n.name)), JSON.stringify(bare.map(n => n.name)));
  h.rec('…and says nothing is held', /nothing is held/.test(await page.evaluate(() => document.getElementById('storetreenote')?.textContent ?? '')));
  const railRows = await page.evaluate(() => [...document.querySelectorAll('#inventory li:not(.iv-empty)')].length);
  h.rec('…the rail agrees', railRows === 0, String(railRows));

  h.rec('no page errors', h.errs.length === 0, h.errs.slice(0, 3).join(' | '));
} catch (e) {
  h.rec('fatal', false, [e.message.split('\n')[0], ...h.errs.slice(0, 5)].join(' | '));
}

await browser.close();
closeServer();
summarize(h);
