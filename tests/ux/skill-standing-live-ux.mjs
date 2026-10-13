/// tests/ux/skill-standing-live-ux.mjs — the profile's skills, over a real gateway.
///
/// A citizen creates an identity in the browser, opens the inventory drawer's
/// Skills view, and it answers from the commons (the demo roster steps aside).
/// The identity sheet no longer carries skills.
/// They declare a skill and withdraw it; every step is read back through the
/// door itself (my-skill-standing), and a reload shows the commons kept it.
/// Nothing stubbed.
///
/// What this run cannot show is the witnessed half: a fresh commune has no work
/// events, so every row stands at "your word" — the fold over co-signed work is
/// pinned by tests/doors/test-skill-standing.scm.
///
/// Run via:  make test-skill-standing-live-ux
///           bash tests/ux/ux-full.sh tests/ux/skill-standing-live-ux.mjs

import { harness, launch, newPage, sleep, summarize } from './ux-harness.mjs';
import { openIdentityCard, tickCard, putAway } from './probe-lib.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';
const h = harness();
const browser = await launch();

const dial = (page, expr) =>
  page.evaluate(`(() => { const H = window.__seam.handlers; return ${expr}; })()`);
const parse = (s, fallback) => { try { return JSON.parse(s); } catch { return fallback; } };
// tolerant of a page still booting (after a reload the seam and its handlers
// arrive a beat later): no handler yet reads as "no answer yet"
const standing = async (page) => parse(await page.evaluate(() => {
  const H = window.__seam?.handlers;
  return H?.mySkillStanding ? H.mySkillStanding() : null;
}).catch(() => null), null);
const rowOf = (rows, skill) => (rows || []).find(r => r.skill === skill);

const until = async (fn, ms = 30000) => {
  const dl = Date.now() + ms;
  let v;
  while (Date.now() < dl) { v = await fn(); if (v) return v; await sleep(400); }
  return v;
};

/// The Skills view's own row for SKILL: its level, evidence and bar.
const sheetRow = (page, skill) => page.evaluate((skill) => {
  const row = [...document.querySelectorAll('#sharebar .sk .stand-row')]
    .find(r => r.querySelector('.stand-name')?.textContent === skill);
  if (!row) return null;
  return { level: row.querySelector('.stand-level')?.textContent || '',
           evidence: row.querySelector('.stand-ev-t')?.textContent || '',
           bar: row.querySelector('.stand-bar-reach')?.style.width || '' };
}, skill);

// the drawer's Skills view: open the inventory, light the third segment
const openSkills = async (page) => {
  if (!(await page.evaluate(() => !!document.querySelector('#sharebar .sk')))) {
    if (!(await page.evaluate(() => document.getElementById('sharebar')?.classList.contains('sb-open'))))
      await page.click('#sharebar .sharebar-handle');
    await sleep(400);
    await page.click('#sharebar .share-railrow .seg-skill');
    await sleep(600);
  }
  return until(() => page.evaluate(() => !!document.querySelector('#sharebar .sk')), 15000);
};

try {
  const page = await newPage(browser, h);
  await page.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 60000 });
  const chip = await until(async () => {
    const t = await page.evaluate(() => document.querySelector('#idrow .who')?.textContent ?? '');
    return /create your identity/i.test(t) ? t : '';
  }, 180000);
  h.rec('dial connects to the gateway', !!chip, chip || '(no chip)');

  await openIdentityCard(page);
  await tickCard(page, 'consent', 'age');
  await page.click('.idc .ob-next:has-text("create my identity")');
  await page.waitForSelector('.idc[data-view="reveal"] input[name="username"]', { timeout: 120000 }).catch(() => {});
  const aid = await page.evaluate(() => document.querySelector('.idc[data-view="reveal"] input[name="username"]')?.value ?? '');
  h.rec('identity minted in-browser', /^E[A-Za-z0-9_-]{43}$/.test(aid), aid || '(none)');
  // the passcode gate: the sheet stays until the citizen says they saved it
  await putAway(page);
  await sleep(500);

  // ── the door answers, and the demo steps aside ──
  const first = await until(async () => { const r = await standing(page); return Array.isArray(r) ? r : null; }, 60000);
  h.rec('my-skill-standing answers a JSON array', Array.isArray(first), JSON.stringify(first)?.slice(0, 120));
  h.rec('a new citizen has no demo rows', Array.isArray(first) && !rowOf(first, 'bike repair'),
        (first || []).map(r => r.skill).join(', ') || '(none)');

  h.rec('the drawer carries a Skills view', !!(await openSkills(page)));
  const demoNote = await until(async () =>
    !(await page.evaluate(() => /a demo roster/.test(document.querySelector('#sharebar .sk')?.textContent || ''))), 15000);
  h.rec('the view reads the commons, not the demo', !!demoNote);
  h.rec('the old strip under Offers is gone', await page.evaluate(() => !document.querySelector('.share-skills')));

  // ── declare a skill through the view ──
  await page.fill('#sharebar .sk .ob-add input', 'spec-cook');
  await page.click('#sharebar .sk .ob-add button');
  const held = await until(async () => { const r = rowOf(await standing(page), 'spec-cook'); return r && r.held ? r : null; });
  h.rec('the commons holds spec-cook on the roster', !!held, JSON.stringify(held));
  h.rec('a row is the record alone: no degree, no note, hours at zero',
        !!held && !('degree' in held) && !('note' in held) && Number(held.hours) === 0 && Number(held.competence) === 0,
        JSON.stringify(held));
  const s = await until(() => sheetRow(page, 'spec-cook'));
  h.rec('the view shows it as your word', !!s && /your word/i.test(s.level), JSON.stringify(s));
  h.rec('…with nothing worked under it yet, the bar at zero', !!s && /nothing worked/.test(s.evidence) && s.bar === '0%', JSON.stringify(s));
  const roster = await dial(page, 'H.mySkills()');
  h.rec('the roster read agrees', String(roster).split('\n').includes('spec-cook'), String(roster));

  // SHOT_OUT=<file.png> keeps a picture of the live view (the harness clears its own data dir)
  if (process.env.SHOT_OUT) await page.screenshot({ path: process.env.SHOT_OUT }).catch(() => {});

  // ── declaring again is idempotent ──
  const twice = await dial(page, 'H.declareSkill("spec-cook")');
  h.rec('declaring it again is no error', !/^err:/.test(String(twice)), String(twice));

  // ── the commons kept it: a reload reads the same ──
  await page.reload({ waitUntil: 'domcontentloaded' });
  const again = await until(async () => rowOf(await standing(page), 'spec-cook'), 120000);
  h.rec('after a reload the commons still holds it', !!again && again.held === true, JSON.stringify(again));

  // ── withdrawing the skill takes the roster entry; with no work behind it, the row is gone ──
  await dial(page, 'H.revokeSkill("spec-cook")');
  const gone = await until(async () => { const rows = await standing(page); return Array.isArray(rows) && !rowOf(rows, 'spec-cook') ? rows : null; });
  h.rec('withdrawn, the skill leaves the standing', !!gone, JSON.stringify(gone)?.slice(0, 80));

} catch (e) {
  h.rec('no exception', false, String(e).slice(0, 300));
} finally {
  await browser.close();
}
summarize(h);
