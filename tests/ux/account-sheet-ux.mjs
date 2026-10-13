/// tests/ux/account-sheet-ux.mjs — the person button opens ONE account sheet that
/// holds what is yours: identity, profile, keys and devices, the channel,
/// settings, the look of the site, help, and the notices. The header no longer
/// carries settings, theme, about or the channel as buttons.
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
    await page.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
    await sleep(1800);
    h.rec(`${label}: the header shows no ⚙ 📜 ◐ 📻 buttons`,
          !(await vis('#setbtn')) && !(await vis('#scrollbtn')) && !(await vis('#themepick')) && !(await vis('#netbtn')));
    await page.click('#idrow .who'); await sleep(400);
    const SHEET = '.sheet-view .acct-card';
    h.rec(`${label}: the person button opens the account sheet`, await vis(SHEET));
    const rows = await page.$$eval(`${SHEET} .acct-row .acct-l`, ls => ls.map(l => l.textContent));
    for (const want of ['all settings', 'help and about', 'look and feel', 'keys and devices', 'your profile', 'diet', 'body', 'health', "the commune's channel", 'your data and the notices'])
      h.rec(`${label}: a row for "${want}"`, rows.includes(want), rows.join(' | '));
    h.rec(`${label}: signed out, it offers to create an identity and to sign in`, rows.includes('create your identity') && rows.includes('sign in'));
    const foot = await page.$$eval(`${SHEET} .acct-foot a`, as => as.map(a => a.textContent + '→' + a.getAttribute('href')));
    h.rec(`${label}: the foot carries Privacy Policy and Terms of Service`, foot.length >= 2 && foot.some(f => /Privacy/.test(f)) && foot.some(f => /Terms/.test(f)), foot.join(' '));
    const fit = await page.evaluate(sel => { const c = document.querySelector(sel).getBoundingClientRect(); return c.left >= 0 && c.right <= innerWidth + 1 && c.top >= 0; }, SHEET);
    h.rec(`${label}: the sheet fits the window's width`, fit);
    await page.screenshot({ path: `${shot}/account-${label}.png` });

    // "sign in" is a page of the sheet: the same identity card the onboarding checklist shows
    await page.click(`${SHEET} .acct-row:has-text("sign in")`); await sleep(500);
    h.rec(`${label}: "sign in" opens the identity card inside the sheet, on its sign-in face`,
          await vis(SHEET) && await page.evaluate(sel => document.querySelector(`${sel} .idc`)?.dataset.view === 'signin', SHEET));
    h.rec(`${label}: …and no popover of the old kind exists`, !(await page.evaluate(() => !!document.getElementById('idform'))));
    await page.keyboard.press('Escape'); await sleep(300);
    h.rec(`${label}: Esc steps back to the menu`, await vis(SHEET) && !(await vis(`${SHEET} .idc`)));
    // a row is a door: all settings opens the room, and the sheet goes
    await page.click(`${SHEET} .acct-row:has-text("all settings")`); await sleep(500);
    h.rec(`${label}: "all settings" opens the settings room and puts the sheet away`,
          !(await vis(SHEET)) && await page.evaluate(() => document.getElementById('main').hasAttribute('data-settings')));
    await page.keyboard.press('Escape'); await sleep(300);

    // diet is a page of the sheet: a chevron row enters it, and the back arrow leaves it
    await page.click('#idrow .who'); await sleep(300);
    await page.evaluate(sel => [...document.querySelectorAll(`${sel} .acct-row`)].find(r => r.querySelector('.acct-l')?.textContent === 'diet').click(), SHEET);
    await sleep(500);
    h.rec(`${label}: "diet" enters its page, with the chips`,
          await page.evaluate(sel => /diet/i.test(document.querySelector(`${sel} .acct-title`)?.textContent || '') && !!document.querySelector(`${sel} .acct-page .ob-opts`), SHEET));
    await page.click(`${SHEET} .acct-back`); await sleep(300);
    h.rec(`${label}: the back arrow returns to the menu`, await vis(`${SHEET} .acct-mark`));
    // esc / scrim close
    await page.keyboard.press('Escape'); await sleep(250);
    h.rec(`${label}: Esc puts it away`, !(await vis(SHEET)));
    await page.click('#idrow .who'); await sleep(250);
    await page.mouse.click(5, 5); await sleep(250);
    h.rec(`${label}: the dimmed page puts it away`, !(await vis(SHEET)));
    await page.evaluate(() => localStorage.clear());
  } catch (e) { h.rec(`${label}: fatal`, false, e.message); }
}
h.rec('no page errors', errs.length === 0, errs.slice(0, 2).join(' | '));
await browser.close(); closeServer();
summarize(h);
