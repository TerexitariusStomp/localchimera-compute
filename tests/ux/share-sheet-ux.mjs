/// tests/ux/share-sheet-ux.mjs — the share bar's expression row stays put at the
/// foot of the app; the inventory and the type picker rise ABOVE it as a
/// bottom sheet over the page (not below it, not by pushing the page up). A
/// grip pulls the sheet to the whole height, or puts it away.
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();
const h = harness();
const browser = await launch();
const page = await browser.newPage();
const errs = [];
page.on('pageerror', e => errs.push(String(e)));
const shot = process.env.SHOT_DIR || '/tmp';

const geo = () => page.evaluate(() => {
  const r = s => { const e = document.querySelector(s); if (!e) return null; const b = e.getBoundingClientRect(); return { top: b.top, bottom: b.bottom, h: b.height }; };
  const vis = s => { const e = document.querySelector(s); return !!e && getComputedStyle(e).display !== 'none' && e.getBoundingClientRect().height > 0; };
  return { vh: innerHeight, bar: r('#sharebar'), row: r('#sharebar .sharebar-row'), sheet: r('#sharebar .share-sheet'),
           sheetOn: vis('#sharebar .share-sheet'), main: r('#main'), full: document.querySelector('#sharebar .share-sheet')?.classList.contains('full'),
           panelIn: document.querySelector('#sharebar .share-panel')?.parentElement?.className,
           top: r('#top') };
});
const tap = async () => { const g = await page.evaluate(() => { const b = document.querySelector('#sharebar .sheet-grab').getBoundingClientRect(); return { x: b.left + b.width / 2, y: b.top + b.height / 2 }; }); await page.mouse.click(g.x, g.y); await sleep(350); };
const drag = async (dy) => {
  const g = await page.evaluate(() => { const b = document.querySelector('#sharebar .sheet-grab').getBoundingClientRect(); return { x: b.left + b.width / 2, y: b.top + b.height / 2 }; });
  await page.mouse.move(g.x, g.y); await page.mouse.down();
  await page.mouse.move(g.x, g.y + dy / 2, { steps: 4 }); await page.mouse.move(g.x, g.y + dy, { steps: 4 });
  await page.mouse.up(); await sleep(350);
};

for (const [label, vp] of [['desktop', { width: 1400, height: 900 }], ['phone', { width: 390, height: 800 }]]) {
  try {
    await page.setViewportSize(vp);
    await page.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
    await sleep(1800);
    let g = await geo();
    h.rec(`${label}: the bar closes the column, sheet away`, !!g.bar && Math.abs(g.bar.bottom - g.vh) < 3 && !g.sheetOn);
    const rowTop0 = g.row.top, mainH0 = g.main.h;

    await page.evaluate(() => document.querySelector('.sharebar-handle').click()); await sleep(500);
    g = await geo();
    h.rec(`${label}: 🎒 raises the inventory ABOVE the row`, g.sheetOn && g.sheet.bottom <= g.row.top + 2, JSON.stringify(g.sheet));
    h.rec(`${label}: the expression row has not moved`, Math.abs(g.row.top - rowTop0) < 2, `${rowTop0} → ${g.row.top}`);
    h.rec(`${label}: the page is not squeezed — #main keeps its height`, Math.abs(g.main.h - mainH0) < 2, `${mainH0} → ${g.main.h}`);
    h.rec(`${label}: the sheet stops short of the header`, g.sheet.top >= g.top.bottom - 1, `${g.sheet.top} vs ${g.top.bottom}`);
    h.rec(`${label}: the cards are inside the sheet`, await page.evaluate(() => !!document.querySelector('#sharebar .share-sheet .share-lists .slot-card')));
    await page.screenshot({ path: `${shot}/share-sheet-${label}-open.png` });

    await drag(-400);
    g = await geo();
    h.rec(`${label}: pulling the grip up takes the sheet to the whole height`, g.full && g.sheet.top < g.vh * 0.3, JSON.stringify(g.sheet));
    h.rec(`${label}: …still under the header, the row still at the foot`, g.sheet.top >= g.top.bottom - 1 && Math.abs(g.row.top - rowTop0) < 2);
    await page.screenshot({ path: `${shot}/share-sheet-${label}-full.png` });

    await drag(300);
    g = await geo();
    h.rec(`${label}: pulling it part-way down settles at the content height`, g.sheetOn && !g.full, JSON.stringify(g));
    await tap();
    g = await geo();
    h.rec(`${label}: a tap on the grip flips to the whole height`, g.full);
    await tap();

    await drag(500);
    g = await geo();
    h.rec(`${label}: pulling it right down puts it away`, !g.sheetOn && !(await page.evaluate(() => document.getElementById('sharebar').classList.contains('sb-open'))));

    // the type picker rises above the row too
    await page.click('#sharebar .share-name'); await sleep(500);
    g = await geo();
    h.rec(`${label}: the type picker rides in the sheet, above the row`, g.sheetOn && /share-sheet/.test(g.panelIn || '') && g.sheet.bottom <= g.row.top + 2, JSON.stringify(g));
    h.rec(`${label}: the row has not moved for the picker either`, Math.abs(g.row.top - rowTop0) < 2);
    await page.screenshot({ path: `${shot}/share-sheet-${label}-type.png` });
    await drag(500);
    g = await geo();
    h.rec(`${label}: the picker goes away with the sheet`, !g.sheetOn);
  } catch (e) { h.rec(`${label}: fatal`, false, e.message); }
}
// over the map face the sheet is still the topmost thing in its own box
try {
  await page.setViewportSize({ width: 1400, height: 900 });
  await page.goto(`${BASE}/app.html?face=map`, { waitUntil: 'domcontentloaded' });
  await sleep(2500);
  await page.evaluate(() => document.querySelector('.sharebar-handle').click()); await sleep(500);
  const top = await page.evaluate(() => {
    const b = document.querySelector('#sharebar .share-sheet').getBoundingClientRect();
    const e = document.elementFromPoint(b.left + b.width / 2, b.top + 40);
    return !!e?.closest('.share-sheet');
  });
  h.rec('map face: the sheet is drawn above the map', top);
} catch (e) { h.rec('map face: fatal', false, e.message); }
h.rec('no page errors', errs.length === 0, errs.slice(0, 2).join(' | '));
await browser.close(); closeServer();
summarize(h);
