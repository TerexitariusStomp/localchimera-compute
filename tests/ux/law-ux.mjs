/// tests/ux/law-ux.mjs — the law face (app/tabs/law.js): one screen, read by place.
/// One state — an activity, a place, a way — drives the bar, the map and the
/// docket together, so this drives each of the three and checks the other two
/// followed. It asserts what the face promises a reader: the page never
/// scrolls, the program is the program of the PLACE, and nothing on a shelter
/// screen speaks of food. The legal bodies you steward stand on it too: a body
/// declared in a place is a chip at that place, what it holds marks the bill,
/// and its jurisdiction lights under the who-operates lens. The seam is stubbed
/// (window.__seam.handlers), no gateway.
import { readFileSync } from 'node:fs';
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';
const SNAP = JSON.parse(readFileSync(new URL('../../browser/data/snapshots/law-snapshot.json', import.meta.url), 'utf8'));
const { base: BASE, close: closeServer } = await serveBrowser();
const h = harness(); const browser = await launch();
const errs = [];
const open = async (q, w, hgt) => {
  const page = await browser.newPage({ viewport: { width: w, height: hgt } });
  page.on('pageerror', e => errs.push(String(e)));
  await page.goto(`${BASE}/app.html?face=law${q}`, { waitUntil: 'networkidle' });
  await page.waitForSelector('#lawdocket .dk-head h4');
  await sleep(400);
  return page;
};
const docket = page => page.evaluate(() => ({
  title: document.querySelector('#lawdocket .dk-head h4')?.textContent,
  tab: document.querySelector('#lawdocket .dk-tabs a.on')?.textContent,
  demands: [...document.querySelectorAll('#lawdocket details.dk-dem > summary > b')].map(n => n.textContent),
  ways: [...document.querySelectorAll('#lawdocket .dk-way .dk-wn > b')].map(n => n.textContent),
  marks: Object.fromEntries([...document.querySelectorAll('#lawdocket details.dk-ab > summary')]
    .map(n => [n.querySelector('b').textContent, n.querySelector('.st').className.replace('st ', '')])),
  crumb: [...document.querySelectorAll('#lawbar .lw-crumb a')].map(n => n.textContent),
}));
const fits = page => page.evaluate(() => {
  const d = document.documentElement, dk = document.getElementById('lawdocket').getBoundingClientRect();
  return { scrollY: d.scrollHeight - d.clientHeight, scrollX: d.scrollWidth - d.clientWidth,
           docketInView: dk.top >= 0 && dk.bottom <= innerHeight + 1 && dk.width > 200,
           regions: document.querySelectorAll('#dial path[fill]').length };
});
const clickText = (page, sel, text) => page.evaluate(([sel, text]) => {
  const n = [...document.querySelectorAll(sel)].find(x => x.textContent.includes(text));
  if (n) n.click(); return !!n; }, [sel, text]);

for (const [name, w, hgt] of [['laptop 1280×720', 1280, 720], ['phone 390×844', 390, 844]]) {
  const page = await open('', w, hgt);
  const f = await fits(page), d = await docket(page);
  h.rec(`${name}: the page does not scroll and the docket is on screen`,
        f.scrollY <= 0 && f.scrollX <= 0 && f.docketInView, JSON.stringify(f));
  h.rec(`${name}: it opens on the world, on the ways`, d.title === 'World' && /^Ways/.test(d.tab) && d.ways.length > 0,
        JSON.stringify([d.title, d.tab, d.ways.length]));
  await page.close();
}

// the program is a reading of the place
const fr = await open('&place=france&view=program', 1280, 720), frD = await docket(fr);
const de = await open('&place=germany&view=program', 1280, 720), deD = await docket(de);
h.rec('?place=…&view=program lands on that place, on the program',
      frD.title === 'France' && /^Program/.test(frD.tab) && frD.crumb.at(-1) === 'France', JSON.stringify([frD.title, frD.tab, frD.crumb]));
h.rec('two places carry two programs', frD.demands.join('|') !== deD.demands.join('|') && deD.demands.length > 0,
      JSON.stringify([frD.demands, deD.demands]));
h.rec('a structural demand stands differently in two places with different histories',
      frD.marks['Separate church from state'] !== deD.marks['Separate church from state']
        && frD.marks['Separate church from state'] !== 'unread', JSON.stringify([frD.marks, deD.marks]));
h.rec('a demand nobody has read in a place is shown unread there', frD.marks['Retire rent'] === 'unread',
      String(frD.marks['Retire rent']));

// a region inherits what its nation asks, and the crumb walks back up
const ca = await open('&place=us-06&view=program', 1280, 720), caD = await docket(ca);
h.rec('a state shows its own demands, and the crumb names its chain',
      caD.demands.length > 0 && caD.crumb.join('>') === 'World>United States>California', JSON.stringify(caD.crumb));
await clickText(ca, '#lawbar .lw-crumb a', 'United States'); await sleep(250);
h.rec('a crumb moves the place', (await docket(ca)).title === 'United States');

// the activity changes everything at once, and shelter never speaks of food
await clickText(ca, '#lawbar .seg-rail a', 'Sheltering'); await sleep(250);
await clickText(ca, '#lawdocket .dk-tabs a', 'Ways'); await sleep(250);
const sh = await docket(ca);
// the docket and the legend; the bar's activity switch names both activities by design
const text = await ca.evaluate(() => ['lawdocket', 'lawlegend'].map(id => document.getElementById(id).innerText).join(' ').toLowerCase());
h.rec('switching the activity switches the ways', sh.ways.some(x => /spare room/i.test(x)), JSON.stringify(sh.ways));
h.rec('nothing on a shelter screen speaks of food', !/food|cottage|kitchen/.test(text),
      (text.match(/.{0,30}(food|cottage|kitchen).{0,30}/) || [''])[0]);
// picking a way paints it and opens its bill
const before = await ca.evaluate(() => [...document.querySelectorAll('#dial path[fill]')].map(p => p.getAttribute('fill')).join());
await clickText(ca, '#lawdocket .dk-way', 'Community land trust'); await sleep(300);
const after = await ca.evaluate(() => ({
  fills: [...document.querySelectorAll('#dial path[fill]')].map(p => p.getAttribute('fill')).join(),
  bill: document.querySelectorAll('#lawdocket .dk-bill .dk-dem').length }));
h.rec('picking a way repaints the map and opens its bill', after.fills !== before && after.bill > 0, JSON.stringify(after.bill));
// a way says what the law in force means for it: a prohibition is ✗, and a way
// that trips something nobody has read here carries the unread mark and says so
const marks = await ca.evaluate(() => ({
  badges: [...document.querySelectorAll('#lawdocket .dk-way')].map(w => ({
    name: w.querySelector('.dk-wn b').textContent, badge: w.querySelector('.dk-b').textContent,
    unread: !!w.querySelector('.dk-b sup') })),
  bill: (document.querySelector('#lawdocket .dk-bill') || { innerText: '' }).innerText }));
h.rec('a forbidden way is marked ✗', marks.badges.some(b => /occupy/i.test(b.name) && b.badge.includes('✗')), JSON.stringify(marks.badges));
h.rec('a way that trips something unread here carries the mark, and its bill names what is unread',
      marks.badges.some(b => /land trust/i.test(b.name) && b.unread) && /no steward has read here yet/.test(marks.bill),
      marks.bill.slice(-120));
await clickText(ca, '#lawdocket .dk-tabs a', 'Sources'); await sleep(250);
const cites = await ca.evaluate(() => [...document.querySelectorAll('#lawdocket .dk-cite .conf')].map(n => n.textContent));
h.rec('a rule that fired says who read it', cites.length > 0 && cites.some(c => /read by /.test(c)), JSON.stringify(cites.slice(0, 2)));

// each unwon abolition says what to do about it, the move we can make leading its class,
// and a won one says there is nothing left to press
const de2 = await open('&place=germany&view=program', 1280, 720);
const moves = await de2.evaluate(() => [...document.querySelectorAll('#lawdocket .dk-ab > summary .mv')].map(n => n.className.replace('mv ', '')));
h.rec('every unwon abolition with something to press says what to do', moves.length >= 10 && moves.every(m => /^(wither|absorb|transform)$/.test(m)), JSON.stringify(moves));
const classOrder = await de2.evaluate(() => [...document.querySelectorAll('#lawdocket .dk-cls')].map(c =>
  [...c.querySelectorAll('.dk-ab .mv')].map(n => ({ wither: 0, absorb: 1, transform: 2 })[n.className.replace('mv ', '')])));
h.rec('within a class the move we can make now comes first', classOrder.every(r => r.every((x, i) => i === 0 || r[i - 1] <= x)), JSON.stringify(classOrder));
h.rec('no score is shown anywhere in the docket', !/dual power|ripest/.test(await de2.evaluate(() => document.getElementById('lawdocket').innerText)));
const mx = await open('&place=mexico&view=program', 1280, 720);
const won = await mx.evaluate(() => { const d = [...document.querySelectorAll('#lawdocket .dk-ab')].find(n => /church/.test(n.textContent));
  return { status: d.className, mv: !!d.querySelector('summary .mv'), says: /nothing left to press/.test(d.textContent) }; });
h.rec('a won abolition says nothing is left to press', /won/.test(won.status) && !won.mv && won.says, JSON.stringify(won));
await de2.close(); await mx.close();

// a clause is in one of the four cells or it is unmapped, and the face says which
const be = await open('&place=berlin&view=program', 1280, 720);
const cellsOf = () => be.evaluate(() => [...new Set([...document.querySelectorAll('#lawdocket .lw-cell')].map(n => n.className.replace('lw-cell ', '')))]);
// a long program is one line a demand until a row is opened
h.rec('a long program keeps one line a demand', (await be.evaluate(() => document.querySelectorAll('#lawdocket details.dk-dem > summary .lw-cell').length)) === 0);
await be.evaluate(() => document.querySelectorAll('#lawdocket details.dk-dem').forEach(d => { d.open = true; }));
const cells = await cellsOf();
h.rec('a pack\'s own words land in the cells, and what nobody mapped is shown unmapped',
      cells.includes('provide') && cells.includes('unmapped'), JSON.stringify(cells));
// a place inside a region of nations frames that region: its nations are large enough to pick
const big = await be.evaluate(() => { const r = [...document.querySelectorAll('#dial path[fill="#e2c265"]')].map(p => p.getBoundingClientRect());
  return Math.max(0, ...r.map(b => b.width)); });
h.rec('a place in Europe frames Europe', big > 150, String(big));
await be.close();

// the other lens repaints the map and relabels the legend
const lens = await open('&place=us', 1280, 720);
const paint = () => lens.evaluate(() => ({ fills: [...document.querySelectorAll('#dial path[fill]')].map(p => p.getAttribute('fill')).join(),
  legend: document.getElementById('lawlegend').innerText }));
const burden = await paint();
h.rec('there are two lenses, and none of them is a score', await lens.evaluate(() => [...document.querySelectorAll('#lawbar .lw-lens a')].map(n => n.textContent).join() === 'burden,who operates'));
await clickText(lens, '#lawbar .lw-lens a', 'who operates'); await sleep(250);
const who = await paint();
h.rec('the who-operates lens paints where the federation works',
      who.fills !== burden.fills && /member operates/.test(who.legend) && /#9a7fc4/.test(who.fills), who.legend.replace(/\s+/g, ' '));
await lens.close();

// an arc opens the docket on its three legs
const arc = await open('', 1280, 720);
await clickText(arc, '#lawdocket .dk-way', 'Tijuana'); await sleep(300);
const legs = await arc.evaluate(() => ({ title: document.querySelector('#lawdocket .dk-head h4')?.textContent,
  tabs: [...document.querySelectorAll('#lawdocket .dk-tabs a')].map(n => n.textContent.replace(/[\d.]+$/, '').trim()),
  bill: document.querySelectorAll('#lawdocket .dk-dem').length }));
h.rec('an arc reads as export, border and import', /→/.test(legs.title || '') && legs.tabs.join() === 'export,at the border,import' && legs.bill > 0, JSON.stringify(legs));
await clickText(arc, '#lawdocket .dk-tabs a', 'import'); await sleep(250);
const imp = await arc.evaluate(() => document.querySelector('#lawdocket .dk-body .dk-grp')?.textContent);
h.rec('a leg shows its own side of the crossing', /import/.test(imp || ''), String(imp));
await clickText(arc, '#lawdocket .dk-back', 'back'); await sleep(250);
h.rec('back returns to the place', (await docket(arc)).title === 'World');
await arc.close();

// on a phone the legend carries the lens
const ph = await open('&place=us', 390, 844);
const l0 = await ph.evaluate(() => ({ bar: getComputedStyle(document.querySelector('#lawbar .lw-lens')).display,
  lens: document.querySelector('#lawlegend .lg-lens')?.textContent }));
await ph.evaluate(() => document.querySelector('#lawlegend .lg-lens').click()); await sleep(250);
const l1 = await ph.evaluate(() => document.querySelector('#lawlegend .lg-lens')?.textContent);
h.rec('on a phone the legend carries the lens and a tap moves it', l0.bar === 'none' && /burden/.test(l0.lens) && /operates/.test(l1), JSON.stringify([l0, l1]));
await ph.close();

// our bodies on the face: one declared in France ("fr", the code a body declared
// before the snapshot was the list carries), holding one demand of France's bill, missing
const frAB = SNAP.places.france.byActivity[SNAP.defaultActivity];
const frWay = frAB.modes.find(m => m.id === frAB.recommended);
const DEMAND = frWay.bill.obtainEntity[0].name;
const SCOPE = 'EScopeAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const BODY = { id: 'body:abc123', name: 'Le Four Commun', tags: ['body', 'kind:association', 'role:provider', 'jurisdiction:fr'],
               steward: true, jurisdiction: 'fr', ceremony: null,
               holdings: [{ id: 'res:x', spec: DEMAND, kind: 'registration', name: 'the registration', status: 'missing' }],
               exposure: { stance: 'notice', doors: [], holds: [{ demand: DEMAND, status: 'missing' }], owes: [DEMAND], forbidden: [], doubted: [] } };
// the stubbed commune: a scope to read in, and the body handlers
const stubBodies = (page) => page.evaluate(async ({ SCOPE, BODY }) => {
  const { seam } = await import('/app/seam.js');
  const { scopesSig, scopeSig } = await import('/app/scope.js');
  scopesSig.set([{ id: SCOPE, name: 'Testhaven' }]); scopeSig.set(SCOPE); seam.scope = SCOPE;
  window.__bodyCalls = [];
  seam.handlers.bodiesRead = async (s) => { window.__bodyCalls.push(['bodiesRead', s]); return JSON.stringify([BODY]); };
  seam.handlers.bodyRead = async (id) => { window.__bodyCalls.push(['bodyRead', id]); return JSON.stringify({ ...BODY, stewards: [], members: [], crossings: [], findings: [] }); };
}, { SCOPE, BODY });
const bd = await open('&place=france', 1280, 720);
await bd.evaluate(() => document.querySelector('#lawbar .lw-lens a:last-child').click()); await sleep(300);
const purple = () => bd.evaluate(() => [...document.querySelectorAll('#dial path[fill="#9a7fc4"]')].length);
const lit0 = await purple();
h.rec('before the bodies are read, the ways name no body', (await bd.$$eval('#lawdocket .dk-bodies .ob-chip', cs => cs.length)) === 0);
await stubBodies(bd);
await bd.evaluate(async () => { const { readBodies } = await import('/app/bodies.js'); await readBodies(); }); await sleep(400);
const chips = await bd.$$eval('#lawdocket .dk-bodies .ob-chip', cs => cs.map(c => c.textContent));
h.rec('a body declared here is a chip under "our bodies here"', chips.join() === 'Le Four Commun', chips.join('|'));
h.rec('the who-operates lens lights the body\'s jurisdiction too', (await purple()) > lit0, `${lit0} → ${await purple()}`);
await clickText(bd, '#lawdocket .dk-way', frWay.name); await sleep(300);
const held = await bd.evaluate(() => [...document.querySelectorAll('#lawdocket .dk-bill .dk-hold')].map(n => n.textContent.replace(/\s+/g, ' ')));
h.rec('the bill says who holds a demand here, and the holding\'s status', held.length === 1 && /held by Le Four Commun · missing/.test(held[0]), JSON.stringify(held));
h.rec('a demand nobody holds carries no mark', (await bd.evaluate(() => document.querySelectorAll('#lawdocket .dk-bill .dk-dem').length)) > held.length || frWay.bill.obtainEntity.length === 1);
// the chip reads the body whole and opens it on its own face
await bd.evaluate(() => document.querySelector('#lawdocket .dk-bodies .ob-chip').click()); await sleep(500);
const opened = await bd.evaluate(() => ({ face: document.getElementById('main')?.dataset.face, calls: window.__bodyCalls.map(c => c[0]),
  name: document.querySelector('#bodiesface .bd-body .bd-head .reach-kind')?.textContent }));
h.rec('the chip opens the body on the bodies face', opened.face === 'bodies' && opened.calls.includes('bodyRead') && opened.name === 'Le Four Commun', JSON.stringify(opened));
await bd.close();
// entering the law face with a seat taken and no bodies read asks the commune once
const en = await browser.newPage({ viewport: { width: 1280, height: 720 } });
en.on('pageerror', e => errs.push(String(e)));
await en.goto(`${BASE}/app.html`, { waitUntil: 'networkidle' }); await sleep(400);
await stubBodies(en);
await en.evaluate(async () => { const { lawDeepLink } = await import('/app/tabs/law.js'); const { setFace } = await import('/app/faces.js'); lawDeepLink('france'); setFace('law'); });
await en.waitForSelector('#lawdocket .dk-head h4'); await sleep(600);
const entered = await en.evaluate(() => ({ calls: window.__bodyCalls.map(c => c[0]), title: document.querySelector('#lawdocket .dk-head h4')?.textContent,
  chips: [...document.querySelectorAll('#lawdocket .dk-bodies .ob-chip')].map(c => c.textContent) }));
h.rec('entering the law face reads the bodies, and the place shows them', entered.calls.filter(c => c === 'bodiesRead').length === 1 && entered.title === 'France' && entered.chips.length === 1, JSON.stringify(entered));
await en.close();

h.rec('no page errors', errs.length === 0, errs.slice(0, 3).join(' | '));
await browser.close(); closeServer(); summarize(h);
