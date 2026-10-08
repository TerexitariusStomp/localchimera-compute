/// tests/ux/chrome-ux.mjs — the rim and its marks (app/chrome.js). The chrome
/// is where the turn is NAMED, so this walks the scales and reads what the rim
/// says at each: the day as a 24-hour clock, the 3-day turn naming its interior
/// midnights by weekday, and longer turns reading in the period's own symbol.
/// The sun's marks come and go with the window — labelled at the day, drawn
/// bare at the week, stepped aside past a fortnight.
///
/// The chrome's OTHER reading — an angle as a bearing, N/E/S/W with the sun at
/// its true azimuths — needs earth mode, which needs a live map. Headless
/// chromium has no WebGL, so that half is out of this suite's reach.
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

/**
 * The chrome layer, pinned ONCE by what only it draws at the day scale — the
 * bare hour numerals — and then read by position. Re-finding it per scale would
 * not work: at the 3-day turn its labels are weekday names, which is exactly
 * the case under test, so the finder would go looking for the thing it is
 * meant to discover.
 */
const chromeIdx = await page.evaluate(() =>
  [...document.querySelectorAll('#dial > g')].findIndex(g => {
    const t = [...g.querySelectorAll('text')].map(n => n.textContent);
    return t.includes('0') && t.includes('12');
  }));
const marks = () => page.evaluate((i) => {
  const g = document.querySelectorAll('#dial > g')[i];
  return g ? [...g.querySelectorAll('text')].map(n => n.textContent) : [];
}, chromeIdx);

/** Move the dial to a named scale through the scale strip's own control. */
const pickScale = (re) => page.evaluate((src) => {
  const rx = new RegExp(src, 'i');
  const el = [...document.querySelectorAll('#scalestrip *')]
    .find(n => !n.children.length && rx.test(n.textContent.trim()));
  if (el) el.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  return el ? el.textContent.trim() : null;
}, re);

// ── the day is a clock ─────────────────────────────────────────────────────
h.rec('the chrome layer is on the face', chromeIdx >= 0, `layer=${chromeIdx}`);
let m = await marks();
h.rec('the day dial reads in HOURS, not τ fractions',
      ['0', '6', '12', '18'].every(x => m.includes(x)) && !m.some(s => /τ∕/.test(s)),
      m.join(' '));
h.rec('and it names the sun at its hours',
      m.some(s => /☀ rise/.test(s)) && m.some(s => /☀ set/.test(s)), m.join(' '));

// ── the week reads in its own symbol ───────────────────────────────────────
const picked = await pickScale('week');
await sleep(1200);
m = await marks();
h.rec('the week dial reads in the period\'s own symbol', picked && m.includes('0, W'),
      `${picked}: ${m.join(' ')}`);
h.rec('a quarter and a half of the turn are marked',
      m.includes('W∕4') && m.includes('W∕2'), m.join(' '));
h.rec('the week\'s sun marks are drawn but not labelled',
      !m.some(s => /☀/.test(s)), m.join(' '));

// ── the three-day turn names its midnights ─────────────────────────────────
await pickScale('three');
await sleep(1200);
m = await marks();
h.rec('the 3-day turn names its interior midnights by weekday',
      m.filter(s => /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d/.test(s)).length === 3,
      m.join(' '));

// ── beyond a fortnight the sun marks step aside ────────────────────────────
await pickScale('year');
await sleep(1400);
m = await marks();
h.rec('past a fortnight the sun marks step aside', !m.some(s => /☀/.test(s)),
      m.join(' '));
h.rec('the year still names its own quarters', m.includes('Y∕4'), m.join(' '));

h.rec('no page errors during the flow', errs.length === 0, errs.join(' | '));

await browser.close();
closeServer();
summarize(h);
