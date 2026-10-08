/// tests/ux/hand-ux.mjs — the hand and the scrub (app/hand.js). Covers the
/// segmented hand, walking time by the end node, the wipe that erases the past
/// over one radian, crossing 0/τ into the NEXT rotation (the date header names
/// a real day, not a phase), and the tap that walks straight back to now.
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

/** The hand's own layer, found by the grab node it alone draws. */
const handInfo = () => page.evaluate(() => {
  const g = [...document.querySelectorAll('#dial > g')]
    .find(g => [...g.querySelectorAll('circle')]
      .some(c => c.getAttribute('fill') === 'transparent' && +c.getAttribute('r') > 15));
  if (!g) return null;
  const grip = [...g.querySelectorAll('circle')]
    .find(c => c.getAttribute('fill') === 'transparent');
  const b = grip.getBoundingClientRect();
  return {
    segments: g.querySelectorAll('line').length,
    dotted: [...g.querySelectorAll('line')]
      .filter(l => (l.getAttribute('stroke-dasharray') || '').startsWith('0,')).length,
    gx: b.x + b.width / 2, gy: b.y + b.height / 2,
  };
});

const dateText = () => page.evaluate(() =>
  (document.getElementById('datelabel') || {}).textContent || '');
const resetShown = () => page.evaluate(() => {
  const rb = document.getElementById('datereset');
  return !!rb && rb.style.display !== 'none';
});

let hand = await handInfo();
h.rec('the hand is on the face', !!hand);
h.rec('it is segmented by the bands it crosses', hand.segments > 2,
      `lines=${hand.segments}`);
h.rec('no horizon before scrubbing', hand.dotted === 0, `dotted=${hand.dotted}`);
h.rec('the reset is hidden at home', !(await resetShown()));

const day0 = await dateText();

// ── walk time by the node ──────────────────────────────────────────────────
// the dial centre, so the drag can be aimed at a chosen clock angle
const centre = await page.evaluate(() => {
  const b = document.getElementById('dial').getBoundingClientRect();
  return { x: b.x + b.width / 2, y: b.y + b.height / 2, r: Math.min(b.width, b.height) / 2 };
});
/** Drag the grab node to turn-unit `t` (0..24, 0 at the top, clockwise). */
const walkTo = async (t) => {
  const g = await handInfo();
  const a = Math.PI / 2 - t * (2 * Math.PI / 24);
  await page.mouse.move(g.gx, g.gy);
  await page.mouse.down();
  await page.mouse.move(centre.x + centre.r * 0.75 * Math.cos(a),
                        centre.y - centre.r * 0.75 * Math.sin(a), { steps: 12 });
  await page.mouse.up();
  await sleep(400);
};

await walkTo(18);
hand = await handInfo();
h.rec('scrubbing draws the horizon one radian back', hand.dotted === 1,
      `dotted=${hand.dotted}`);
h.rec('the reset appears once off "now"', await resetShown());

// the past erases: some ribbon behind the hand is drawn part-faded
const faded = await page.evaluate(() => {
  const ops = [...document.querySelectorAll('#dial g.clickable path[stroke]')]
    .map(p => +(p.getAttribute('opacity') ?? 1));
  return ops.filter(o => o > 0.01 && o < 0.99).length;
});
h.rec('the past erases rather than vanishing', faded > 0, `partial=${faded}`);

// ── across 0/τ into the next rotation ──────────────────────────────────────
await walkTo(23);
await walkTo(1);        // crossing forward: 23 → 1
const day1 = await dateText();
h.rec('walking past 0/τ moves to the next turn, not a re-loop',
      day1 !== day0 && day1.length > 0, `${day0}  →  ${day1}`);

// ── the tap home ───────────────────────────────────────────────────────────
hand = await handInfo();
await page.mouse.move(hand.gx, hand.gy);
await page.mouse.down();
await page.mouse.up();
await sleep(500);
h.rec('a tap on the node walks back to now', !(await resetShown()));
h.rec('and the header names today again', (await dateText()) === day0,
      `${await dateText()}  vs  ${day0}`);
hand = await handInfo();
h.rec('the horizon is gone with the scrub', hand.dotted === 0, `dotted=${hand.dotted}`);

h.rec('no page errors during the flow', errs.length === 0, errs.join(' | '));

await browser.close();
closeServer();
summarize(h);
