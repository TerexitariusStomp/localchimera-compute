/// tests/ux/respond-ux.mjs — the dial's three-way response on a
/// proposed event: select the proposal, the detail card offers
/// willing / commit / decline; willing without a planner key hints
/// instead of silently doing nothing. Static demo data — no gateway.
///
/// Run via: make test-respond-ux
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';
import path from 'node:path';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
page.on('pageerror', e => h.errs.push(String(e).slice(0, 120)));

try {
  // ?face=time explicitly: the dial lands on the MAP face by default now, and
  // this suite is about the time face's response card — the proposals are built
  // either way, they are simply not on screen until the time face is up.
  await page.goto(`${BASE}/app.html?face=time`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#props li', { timeout: 30000 });
  h.rec('dial loads with demo proposals', true);

  // Select the first pending proposal → the detail card speaks.
  await page.click('#props li');
  await sleep(500);
  h.rec('detail card shows the proposal',
        await page.$eval('#evdetail', el => el.textContent.includes('proposed Intent')));

  // The three-way response row.
  h.rec('card offers willing',  !!(await page.$('#evdetail .r-willing')));
  h.rec('card offers commit',   !!(await page.$('#evdetail .r-commit')));
  h.rec('card offers decline',  !!(await page.$('#evdetail .r-decline')));

  // Willing on a demo work proposal (spec, no gateway) → the local flip is
  // the whole behaviour, exactly as on the OPEN tier's demo slots.
  await page.click('#evdetail .r-willing');
  await sleep(300);
  h.rec('willing flips locally without a gateway (label shows withdraw)',
        await page.$eval('#evdetail .r-willing', el =>
          /withdraw/i.test(el.textContent)));
  await page.click('#evdetail .r-willing');   // ↩ withdraw, leave it as found
  await sleep(200);

  // Commit transitions the proposal into the calendar (demo path).
  await page.click('#evdetail .r-commit');
  await sleep(400);
  h.rec('commit moves it onto the calendar',
        await page.$eval('#evdetail', el =>
          el.textContent.includes('Commitment')));
  // reversibility: a committed item offers RELEASE, which un-commits it back to
  // a proposal you can act on again (no longer a one-way door).
  h.rec('committed item offers release',
        await page.$eval('#evdetail', el => /release/i.test(el.textContent)));
  await page.click('#evdetail .r-decline');   // ↩ release
  await sleep(400);
  h.rec('release reverts it to a proposal (commit offered again)',
        !!(await page.$('#evdetail .r-commit')) &&
        await page.$eval('#evdetail', el => el.textContent.includes('proposed Intent')));
  // Ambient sound. The orb button is retired (CSS: "the strip took its place");
  // ⚙ → look and feel carries the switch, and that row calls ambient.toggle().
  // Drive the same call and read the same answer, ambient.playing().
  const amb = await page.evaluate(async () => {
    const a = await import('/lib/ambient.js');
    const before = a.playing();
    a.toggle(); await new Promise(r => setTimeout(r, 400));
    const on = a.playing();
    a.toggle(); await new Promise(r => setTimeout(r, 300));
    return { before, on, after: a.playing() };
  });
  h.rec('ambient sound starts off', amb.before === false);
  h.rec('toggling starts the bed', amb.on === true);
  h.rec('toggling again stops it', amb.after === false);

  // The music reads the time-view: app/spectrum.ts hands the ambient engine
  // the live need-shares, and readDial turns them into tone partials.
  const dial = await page.evaluate(async () => {
    const st = (await import('/app/spectrum.js')).spectrum();
    return st && Array.isArray(st.bands)
      ? { t: st.t, n: st.bands.length,
          shares: st.bands.reduce((a, b) => a + b.share, 0) }
      : null;
  });
  h.rec('dial exposes the time-view spectrum',
        !!dial && dial.n > 0 && dial.shares > 0.5,
        dial ? `${dial.n} bands @ t=${dial.t?.toFixed?.(1)}` : 'no state');
  // The state carries the pinch period (register) + per-band colour
  // (timbre warmth) — the two new harmonic inputs.
  const tv = await page.evaluate(async () => {
    const st = (await import('/app/spectrum.js')).spectrum();
    return st ? { turnH: st.turnH,
                  cols: (st.bands || []).filter(b => /^#/.test(b.col || '')).length }
              : null;
  });
  h.rec('state carries turn-period + band colours',
        !!tv && tv.turnH > 0 && tv.cols > 0,
        tv ? `turnH=${tv.turnH}, ${tv.cols} coloured bands` : 'no state');

  // ── social invites: a snapshot `proposals` entry (from the planner's
  // proposed-to filter) renders as an invited event; accepting routes to
  // acceptInvite (accept-proposal), not the work commit path.
  await page.evaluate(() => {
    window.__inviteArgs = null;
    window.__seam = window.__seam || {}; window.__seam.handlers = window.__seam.handlers || {};
    window.__seam.handlers.acceptInvite = (scope, pid) => { window.__inviteArgs = [scope, pid]; return Promise.resolve('ok'); };
    window.__seam.ingest({ proposals: [
      { label: 'boardgames', from: 'Ana', vfId: 'prop-soc-1', id: 'prop-soc-1',
        scope: 's', social: true, kind: 'free', sh: 18, sm: 0, eh: 19, em: 0 }] });
  });
  await sleep(300);
  h.rec('a snapshot social invite renders (label + from)',
        await page.evaluate(() => [...document.querySelectorAll('#props li')]
          .some(li => /boardgames/i.test(li.textContent) && /Ana/i.test(li.textContent))));
  // a social invite has no planner key by nature — its card answers with
  // commit/decline alone, no willing button to warn from
  await page.evaluate(() => {
    const li = [...document.querySelectorAll('#props li')].find(l => /boardgames/i.test(l.textContent));
    li && li.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  });
  await sleep(300);
  h.rec('a social invite offers commit but not willing',
        await page.evaluate(() =>
          !document.querySelector('#evdetail .r-willing')
          && !!document.querySelector('#evdetail .r-commit')));
  // accept via the proposal's ✓ button → acceptInvite with the proposal id
  await page.evaluate(() => {
    const li = [...document.querySelectorAll('#props li')].find(l => /boardgames/i.test(l.textContent));
    const yes = li && li.querySelector('.yes');
    yes && yes.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  });
  await sleep(300);
  h.rec('accepting an invite routes to acceptInvite(proposal-id)',
        await page.evaluate(() => Array.isArray(window.__inviteArgs) && window.__inviteArgs[1] === 'prop-soc-1'));

  h.rec('no page errors', h.errs.length === 0,
        h.errs.slice(0, 2).join(' | '));
} catch (e) {
  h.rec('fatal', false, e.message);
} finally {
  await browser.close();
  closeServer();
}

summarize(h, ['dial loads with demo proposals', 'ambient sound starts off',
              'card offers willing', 'card offers commit',
              'card offers decline', 'no page errors']);
