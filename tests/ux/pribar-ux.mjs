/// tests/ux/pribar-ux.mjs — the priority bar (app/pribar.js): the hand,
/// unrolled. Covers the level stack (current + ancestor rows, and the onpath
/// mark), the hold-to-look gesture that lights a segment WITHOUT navigating,
/// and the tap routing in both directions — the top bar descends, an ancestor
/// bar jumps back out.
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
const errs = [];
page.on('pageerror', e => errs.push(String(e)));

await page.goto(`${BASE}/app.html?face=time`, { waitUntil: 'networkidle' });
await sleep(1200);

const rows = () => page.evaluate(() =>
  [...document.querySelectorAll('#prioritybar .pribar')].map(r => ({
    kind: r.className.replace('pribar', '').trim(),
    segs: [...r.querySelectorAll('.priseg')].map(s => s.textContent.trim()),
  })));

let st = await rows();
h.rec('the bar draws one current row at the root', st.length === 1 && st[0].kind === 'current',
      JSON.stringify(st.map(r => r.kind)));
h.rec('the current row names the root\'s children', st[0].segs.filter(Boolean).length > 1,
      st[0].segs.join(' | '));

// hold a segment: it lights, and nothing navigates
const seg = await page.$('#prioritybar .pribar.current .priseg');
const box = await seg.boundingBox();
await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
await page.mouse.down();
await sleep(500);                       // longer than TAP_MS → a hold, not a tap
const hot = await page.evaluate(() => document.querySelectorAll('#prioritybar .priseg.hot').length);
h.rec('holding a segment lights it', hot === 1, `hot=${hot}`);
await page.mouse.up();
await sleep(400);
st = await rows();
h.rec('a hold does not navigate', st.length === 1, `rows=${st.length}`);

// a clean tap on a branch descends: an ancestor row appears
const before = st[0].segs.join('|');
await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
await page.mouse.down();
await page.mouse.up();
await sleep(1400);
st = await rows();
h.rec('a tap descends — an ancestor row appears',
      st.length === 2 && st[1].kind === 'ancestor',
      JSON.stringify(st.map(r => r.kind)));
h.rec('the current row now shows a different level',
      st[0].segs.join('|') !== before, st[0].segs.join(' | '));
const onpath = await page.evaluate(() =>
  document.querySelectorAll('#prioritybar .pribar.ancestor .priseg.onpath').length);
h.rec('the ancestor row marks the child you came through', onpath === 1, `onpath=${onpath}`);

// tap the ancestor row: jump laterally back out
const anc = await page.$('#prioritybar .pribar.ancestor .priseg.onpath');
const abox = await anc.boundingBox();
await page.mouse.move(abox.x + abox.width / 2, abox.y + abox.height / 2);
await page.mouse.down();
await page.mouse.up();
await sleep(1400);
st = await rows();
h.rec('tapping the ancestor jumps back out', st.length === 1, `rows=${st.length}`);

h.rec('no page errors during the flow', errs.length === 0, errs.join(' | '));

await browser.close();
closeServer();
summarize(h);
