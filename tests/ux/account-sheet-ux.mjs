/// tests/ux/account-sheet-ux.mjs — the person button opens ONE account sheet that
/// holds what is yours: identity, profile, keys and devices, the channel,
/// settings, appearance, help, and the notices. The header no longer carries
/// settings, theme, about or the channel as buttons.
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
    h.rec(`${label}: the person button opens the account sheet`, await vis('#acct .acct-card'));
    const rows = await page.$$eval('#acct .acct-row .acct-l, #acct .acct-look .acct-l', ls => ls.map(l => l.textContent));
    for (const want of ['settings', 'help and about', 'appearance', 'keys and devices', 'your profile', 'diet', 'body', 'health', "the commune's channel", 'your data and the notices'])
      h.rec(`${label}: a row for "${want}"`, rows.includes(want), rows.join(' | '));
    h.rec(`${label}: signed out, it offers to create an identity and to sign in`, rows.includes('create your identity') && rows.includes('sign in'));
    const foot = await page.$$eval('#acct .acct-foot a', as => as.map(a => a.textContent + '→' + a.getAttribute('href')));
    h.rec(`${label}: the foot carries Privacy Policy and Terms of Service`, foot.length === 2 && /Privacy/.test(foot[0]) && /Terms/.test(foot[1]), foot.join(' '));
    const fit = await page.evaluate(() => { const c = document.querySelector('#acct .acct-card').getBoundingClientRect(); return c.left >= 0 && c.right <= innerWidth + 1 && c.top >= 0 && c.bottom <= innerHeight + 1; });
    h.rec(`${label}: the sheet fits the window`, fit);
    await page.screenshot({ path: `${shot}/account-${label}.png` });

    // the identity row is a door to the identity sheet
    await page.click('#acct .acct-row:has-text("sign in")'); await sleep(500);
    h.rec(`${label}: "sign in" puts the sheet away and opens the identity sheet`, !(await vis('#acct')) && await vis('#idform'));
    await page.keyboard.press('Escape'); await sleep(300);
    await page.click('#idrow .who'); await sleep(300);
    // a row is a door: settings opens the room, and the sheet goes
    await page.click('#acct .acct-row:has-text("settings")'); await sleep(500);
    h.rec(`${label}: "settings" opens the settings room and puts the sheet away`,
          !(await vis('#acct')) && await page.evaluate(() => document.getElementById('main').hasAttribute('data-settings')));
    await page.keyboard.press('Escape'); await sleep(300);

    // diet is a door to the chip editor, in the settings room
    await page.click('#idrow .who'); await sleep(300);
    await page.evaluate(() => [...document.querySelectorAll('#acct .acct-row')].find(r => r.querySelector('.acct-l')?.textContent === 'diet').click());
    await sleep(500);
    h.rec(`${label}: "diet" opens the diet editor (the chips), in settings`,
          await page.evaluate(() => !!document.querySelector('#setpane .attr .ob-opts') && /diet/i.test(document.querySelector('#setpane .set-h')?.textContent || '')));
    await page.keyboard.press('Escape'); await sleep(300);
    // the inventory sheet no longer carries an Attributes tab
    await page.evaluate(() => document.querySelector('.sharebar-handle').click()); await sleep(400);
    h.rec(`${label}: the inventory sheet has no Attributes tab`, await page.evaluate(() => !document.querySelector('#sharebar .seg-attribute')));
    await page.evaluate(() => document.querySelector('.sharebar-handle').click()); await sleep(300);
    // theme from the sheet
    await page.click('#idrow .who'); await sleep(300);
    await page.click('#acct .acct-theme:has-text("night")'); await sleep(300);
    h.rec(`${label}: appearance changes the theme in place`, await page.evaluate(() => !!document.querySelector('#acct .acct-theme.on') && document.querySelector('#acct .acct-theme.on').textContent === 'night'));
    // esc / scrim close
    await page.keyboard.press('Escape'); await sleep(250);
    h.rec(`${label}: Esc puts it away`, !(await vis('#acct')));
    await page.click('#idrow .who'); await sleep(250);
    await page.mouse.click(5, 5); await sleep(250);
    h.rec(`${label}: the dimmed page puts it away`, !(await vis('#acct')));
    await page.evaluate(() => localStorage.clear());
  } catch (e) { h.rec(`${label}: fatal`, false, e.message); }
}
h.rec('no page errors', errs.length === 0, errs.slice(0, 2).join(' | '));
await browser.close(); closeServer();
summarize(h);
