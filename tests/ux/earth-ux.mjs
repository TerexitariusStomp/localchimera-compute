/// tests/ux/earth-ux.mjs — the reveal (app/earth.js): a leaf need's answer is
/// a WHERE, so tapping one dilates its band to fill the dial, fades the pigment
/// off the planet that was under the bands all along, and falls to where you
/// stand. Then the open leaf is the way back, and the same three stages run in
/// reverse. Covers both journeys through the priority bar, which is the dial's
/// only navigation.
///
/// The MAP that lands at the end of the fall needs WebGL, which headless
/// chromium has not got. So this walks the reveal and the exit — the stages,
/// the mode transitions, the release-on-failure path — and stops at the map's
/// edge.
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

const barRows = () => page.evaluate(() =>
  document.querySelectorAll('#prioritybar .pribar').length);
const activeSeg = () => page.evaluate(() =>
  document.querySelectorAll('#prioritybar .priseg.active').length);

/** Descend to a leaf by tapping the top bar until the level stops changing. */
const tapTop = async () => {
  const seg = await page.$('#prioritybar .pribar.current .priseg');
  const b = await seg.boundingBox();
  await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2);
  await page.mouse.down(); await page.mouse.up();
  await sleep(1400);
};

await tapTop();          // root → a branch
h.rec('descended one level', await barRows() === 2, `rows=${await barRows()}`);
await tapTop();          // branch → a leaf: this is the reveal
await sleep(3500);       // the reveal is ~3s of transitions

const mode = await page.evaluate(() => {
  // the earth marks its open leaf on the bar; the dial does not
  return { rows: document.querySelectorAll('#prioritybar .pribar').length,
           active: document.querySelectorAll('#prioritybar .priseg.active').length,
           back: !!document.querySelector('#backchip'),
           hint: (document.getElementById('hintrow') || {}).textContent || '' };
});
h.rec('tapping a leaf reveals the earth (or releases the dial on failure)',
      mode.active === 1 || /earth data did not load/.test(mode.hint),
      JSON.stringify(mode));

// the open leaf is the way back: tapping it rises out of the earth
const leaf = await page.$('#prioritybar .priseg.active');
const lb = await leaf.boundingBox();
await page.mouse.move(lb.x + lb.width / 2, lb.y + lb.height / 2);
await page.mouse.down(); await page.mouse.up();
await sleep(4000);          // the exit is ~2.5s of transitions, then a settle
h.rec('tapping the open leaf rises back out of the earth',
      (await activeSeg()) === 0, `active=${await activeSeg()}`);
h.rec('and the dial is live again — the level below is back',
      (await barRows()) >= 2, `rows=${await barRows()}`);

h.rec('no page errors during the flow', errs.length === 0, errs.join(' | '));

await browser.close();
closeServer();
summarize(h);
