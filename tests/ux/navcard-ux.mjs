/// tests/ux/navcard-ux.mjs — the turn-by-turn card is navigation chrome: it
/// states its own palette, so every theme shows it in the same legible colours,
/// and over the map it floats at the TOP, above the bar and sheet that own the
/// bottom edge.
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();
const h = harness();
const browser = await launch();
const page = await browser.newPage();
const errs = [];
page.on('pageerror', e => errs.push(String(e)));
await page.setViewportSize({ width: 1400, height: 900 });

const lum = ([r, g, b]) => {
  const f = v => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; };
  return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
};
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
const chan = s => (s.match(/[\d.]+/g) || []).slice(0, 3).map(Number);

const look = () => page.evaluate(() => {
  const nc = document.getElementById('navcard');
  nc.style.display = 'block'; nc.classList.add('overmap');
  const cs = getComputedStyle(nc);
  const pick = s => getComputedStyle(nc.querySelector(s)).color;
  return { bg: cs.backgroundColor, fg: cs.color, meta: pick('.meta'),
           top: cs.top, bottom: cs.bottom, z: +cs.zIndex,
           bar: +getComputedStyle(document.getElementById('sharebar')).zIndex };
});

const seen = {};
for (const theme of ['day', 'night', 'sepia', 'ink']) {
  try {
    await page.goto(`${BASE}/app.html?face=map&theme=${theme}`, { waitUntil: 'domcontentloaded' });
    await sleep(1500);
    const s = seen[theme] = await look();
    const bg = chan(s.bg);
    h.rec(`${theme}: card text reads on its surface (≥ 7:1)`, ratio(chan(s.fg), bg) >= 7, `${s.fg} on ${s.bg}`);
    h.rec(`${theme}: the secondary line reads too (≥ 4.5:1)`, ratio(chan(s.meta), bg) >= 4.5, `${s.meta} on ${s.bg}`);
    h.rec(`${theme}: over the map the card rides at the top, above the bar`,
          s.top !== 'auto' && s.bottom === 'auto' && s.z > s.bar, `top ${s.top} bottom ${s.bottom} z ${s.z} vs bar ${s.bar}`);
  } catch (e) { h.rec(`${theme}: fatal`, false, e.message); }
}
h.rec('the card keeps ONE palette in every theme',
      new Set(Object.values(seen).map(s => `${s.bg}|${s.fg}|${s.meta}`)).size === 1,
      JSON.stringify(seen));
h.rec('no page errors', errs.length === 0, errs.slice(0, 2).join(' | '));
await browser.close(); closeServer();
summarize(h);
