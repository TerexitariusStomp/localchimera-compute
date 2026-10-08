/// tests/ux/face-dock-ux.mjs — the header is gone. Which face you are on is one
/// round button at the bar's right (its glyph is the live face; it opens a sheet
/// of every face), the scope pill stands with the clock and the pin, and the
/// scope picker rises above the bar.
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();
const h = harness();
const browser = await launch();
const page = await browser.newPage();
const errs = [];
page.on('pageerror', e => errs.push(String(e)));
const shot = process.env.SHOT_DIR || '/tmp';
const vis = sel => page.evaluate(s => { const e = document.querySelector(s); if (!e) return false; const r = e.getBoundingClientRect(); return getComputedStyle(e).display !== 'none' && r.width > 0 && r.height > 0; }, sel);

for (const [label, vp] of [['desktop', { width: 1400, height: 900 }], ['phone', { width: 390, height: 800 }]]) {
  try {
    await page.setViewportSize(vp);
    await page.goto(`${BASE}/app.html?face=map`, { waitUntil: 'domcontentloaded' });
    await sleep(2200);
    h.rec(`${label}: there is no header`, !(await vis('#top')));
    const g = await page.evaluate(() => {
      const bar = document.getElementById('sharebar').getBoundingClientRect();
      const fb = document.getElementById('facebtn')?.getBoundingClientRect();
      const sp = document.querySelector('#sharebar .share-togs .scopepill')?.getBoundingClientRect();
      return { fb: fb && { in: fb.top >= bar.top && fb.bottom <= bar.bottom + 1 && fb.right <= bar.right, w: fb.width },
               sp: sp && { in: sp.top >= bar.top && sp.bottom <= bar.bottom + 1 && sp.right <= bar.right }, glyph: document.getElementById('facebtn')?.textContent,
               barH: bar.height, doc: document.documentElement.scrollWidth - document.documentElement.clientWidth };
    });
    h.rec(`${label}: the face button sits in the bar, showing the live face`, !!g.fb?.in && /🌍|🌎|🌏/.test(g.glyph || ''), JSON.stringify(g));
    h.rec(`${label}: the scope pill stands with the clock and the pin, inside the bar`, !!g.sp?.in, JSON.stringify(g.sp));
    h.rec(`${label}: the bar stays slim and nothing scrolls sideways`, g.barH < 100 && g.doc <= 1, `bar ${g.barH}, overflow ${g.doc}`);

    await page.screenshot({ path: `${shot}/face-dock-${label}-bar.png`, clip: { x: 0, y: vp.height - 150, width: vp.width, height: 150 } });
    await page.click('#facebtn'); await sleep(350);
    h.rec(`${label}: the face button opens the faces sheet`, await vis('#facesheet .acct-card'));
    const rows = await page.$$eval('#facesheet .acct-row .acct-l', ls => ls.map(l => l.textContent));
    h.rec(`${label}: it lists the faces that show, and the way to choose them`, rows.includes('map') && rows.includes('calendar') && rows.includes('choose which faces show'), rows.join(' | '));
    h.rec(`${label}: the live face is marked`, await page.evaluate(() => document.querySelector('#facesheet .acct-row.here .acct-l')?.textContent === 'map'));
    await page.screenshot({ path: `${shot}/face-dock-${label}.png` });
    await page.evaluate(() => [...document.querySelectorAll('#facesheet .acct-row')].find(r => r.querySelector('.acct-l').textContent === 'calendar').click());
    await sleep(600);
    const after = await page.evaluate(() => ({ face: document.getElementById('main').getAttribute('data-face'), glyph: document.getElementById('facebtn').textContent }));
    h.rec(`${label}: choosing "calendar" switches the face and the button follows`, after.face === 'cal' && /📅|🗓|📆/.test(after.glyph), JSON.stringify(after));
    h.rec(`${label}: the sheet goes away on choosing`, !(await vis('#facesheet')));

    // the scope picker rises above its pill
    await page.click('#sharebar .scopepill'); await sleep(400);
    const pick = await page.evaluate(() => { const p = document.querySelector('.scopepick')?.getBoundingClientRect(); const b = document.querySelector('#sharebar .scopepill').getBoundingClientRect(); return p && { above: p.bottom <= b.top + 2, top: p.top >= 0 }; });
    h.rec(`${label}: the scope picker rises above its pill and fits the window`, !!pick && pick.above && pick.top, JSON.stringify(pick));
    await page.keyboard.press('Escape'); await sleep(200);
    h.rec(`${label}: the focus trail is hidden while there is no focus`, !(await vis('#focuscrumb')));
  } catch (e) { h.rec(`${label}: fatal`, false, e.message); }
}
h.rec('no page errors', errs.length === 0, errs.slice(0, 2).join(' | '));
await browser.close(); closeServer();
summarize(h);
