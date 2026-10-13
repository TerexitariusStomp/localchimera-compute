/// tests/ux/account-pages-ux.mjs — where contact information, away days and
/// recovery are entered: the account sheet's own pages, never the old two-pane
/// settings room.
///
///   • "your profile" holds who you are and how to reach you — not where you
///     are or your skills, which have their own places (the location chip, the
///     drawer's Skills view).
///   • the calendar's away chip opens the health page of the sheet.
///   • the recovery door the passcode section points at opens keys and devices.
///   • nothing but the settings room's own doors (⚙, "all settings") opens the room.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();
const h = harness();
const browser = await launch();
const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
const errs = [];
page.on('pageerror', e => errs.push(String(e)));

const SHEET = '.sheet-view .acct-card';
const open = (id) => page.evaluate(async (p) => { const a = await import('/app/account.js'); a.closeAccount(); a.openAccountPage(p); }, id);
const title = () => page.evaluate(sel => document.querySelector(`${sel} .acct-title`)?.textContent ?? '', SHEET);
const roomOpen = () => page.evaluate(() => document.getElementById('main').hasAttribute('data-settings'));

try {
  await page.goto(`${BASE}/app.html?face=calendar`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow .who', { timeout: 30000 });
  await sleep(1500);

  // ── your profile: who you are, and how to reach you ──
  await open('profile'); await sleep(500);
  const profile = await page.evaluate((sel) => ({
    title: document.querySelector(`${sel} .acct-title`)?.textContent,
    sections: document.querySelectorAll(`${sel} .acct-page .acct-sect`).length,
    reach: !!document.querySelector(`${sel} .reach .reach-add`),
    text: document.querySelector(`${sel} .acct-page`)?.innerText || '',
    skillsEditor: !!document.querySelector(`${sel} .stand, ${sel} .stand-add-in, ${sel} .stand-where`),
  }), SHEET);
  h.rec('your profile opens in the account sheet', profile.title === 'your profile', profile.title);
  h.rec('…with two sections: name and identifier, and how to reach you',
        profile.sections === 2 && /name and identifier/i.test(profile.text) && /how to reach you/i.test(profile.text), `${profile.sections}`);
  h.rec('…where an address, a handle or a number is added', profile.reach);
  h.rec('…and neither where you are nor a skills editor is repeated there',
        !profile.skillsEditor && !/declare what you can do|a skill you can do/i.test(profile.text));
  h.rec('…and the settings room stays shut', !(await roomOpen()));

  // ── the seam: a page of the sheet by id, from code that cannot import the sheet ──
  await page.evaluate(async () => { (await import('/app/account.js')).closeAccount(); });
  await sleep(200);
  await page.evaluate(async () => (await import('/app/tabs/social/id.js')).openAccountPageDoor('keys'));
  await sleep(500);
  h.rec('the recovery door opens keys and devices in the sheet', (await title()) === 'keys and devices', await title());
  h.rec('…not the settings room', !(await roomOpen()));

  // recovery friends are chosen from your contacts: with none yet, the way to them leaves the sheet for the drawer
  await page.evaluate(async () => {
    (await import('/app/seam.js')).seam.data.contacts = [];
    const a = await import('/app/account.js'); a.closeAccount(); a.openAccountPage('keys');
  });
  await sleep(600);
  const toContacts = await page.evaluate(() => {
    const b = [...document.querySelectorAll('.sheet-view .acct-card .vbtn')].find(x => /open contacts/i.test(x.textContent));
    if (b) b.click();
    return !!b;
  });
  await sleep(500);
  h.rec('recovery friends offer the contacts drawer when there is nobody to choose', toContacts);
  h.rec('…and choosing it puts the sheet away for the drawer',
        toContacts && !(await page.evaluate(sel => !!document.querySelector(sel), SHEET)) && !(await roomOpen()));

  // ── the calendar's away chip: the health page ──
  await page.evaluate(async () => { (await import('/app/account.js')).closeAccount(); });
  await page.evaluate(async () => {
    const today = new Date().toISOString().slice(0, 10);
    (await import('/app/profile.js')).setProfile({ away: [{ kind: 'ill', from: today, to: today }] });
    // the chip names the ONE day showing, so it lives in the day view
    (await import('/app/tabs/calendar.js')).setCalView('day');
  });
  await sleep(600);
  const chip = await page.evaluate(() => { const c = document.querySelector('.calaway'); if (c) c.click(); return !!c; });
  await sleep(600);
  h.rec('the calendar shows the away chip for a day declared away', chip === true);
  h.rec('…and it opens the health page of the sheet', chip && (await title()) === 'health', await title());
  h.rec('…which carries the days-away editor',
        await page.evaluate(sel => /days away/i.test(document.querySelector(`${sel} .acct-page`)?.innerText || ''), SHEET));
  h.rec('…and the settings room stays shut', !(await roomOpen()));

  // ── the room's own doors still open it ──
  await page.evaluate(async () => { (await import('/app/account.js')).closeAccount(); });
  await page.click('#idrow .who'); await sleep(400);
  await page.click(`${SHEET} .acct-row:has-text("all settings")`); await sleep(500);
  h.rec('"all settings" is still the way into the settings room', await roomOpen());

  // ── nothing else sends anyone to it ──
  const root = new URL('../../browser/app/', import.meta.url);
  const calls = [];
  const walk = (dir) => { for (const f of readdirSync(dir)) {
    const p = new URL(f + (statSync(new URL(f, dir)).isDirectory() ? '/' : ''), dir);
    if (statSync(p).isDirectory()) walk(p);
    else if (f.endsWith('.js') && /\bopenSettings\(/.test(readFileSync(p, 'utf8'))) calls.push(p.pathname.split('/browser/app/')[1]);
  } };
  walk(root);
  const allowed = ['settings.js', 'account.js', 'main.js'];
  h.rec('only the room, the sheet\'s "all settings" row and the ⚙ button call openSettings',
        calls.every(f => allowed.includes(f)), calls.join(', '));

  h.rec('no page errors', errs.length === 0, errs.join(' | '));
} catch (e) { h.rec('fatal', false, e.message); }
finally { await browser.close(); closeServer(); }
summarize(h, ['your profile opens in the account sheet', 'no page errors']);
