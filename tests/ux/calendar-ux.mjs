/// tests/ux/calendar-ux.mjs — browser e2e that DRIVES the calendar UI.
///
/// Unlike willingness-ux.mjs (which gates on connect + best-effort observes),
/// this navigates the real app against a LIVE gateway and exercises the full
/// session flow as a user would: open the calendar, pick a scope, act as a
/// member, toggle live/expected location sharing, and mark willingness on a
/// need. Gating asserts the UI is actually drivable end to end; the seed-data-
/// dependent bits (a candidate need, scope locations) are reported as advisory.
///
/// Run via:  bash tests/ux/ux-full.sh tests/ux/calendar-ux.mjs
/// Args (supplied by the runner): <base-url> <encoded-gateway-sref>

import { harness, launch, newPage, openConnected, clickTab, pickFirstOption,
         setSelect, present, bodyText, sleep, summarize } from './ux-harness.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';
const SREF = process.argv[3] || '';

const h = harness();
const browser = await launch();
const page = await newPage(browser, h);

try {
  const { connected } = await openConnected(page, h, BASE, SREF);
  h.rec('WASM loads (REPL ready)', true);
  h.rec('connects to gateway over OCapN', connected);

  if (connected) {
    // 1. Navigate to the calendar view (clicks the real nav tab).
    await clickTab(page, 'calendar');
    await sleep(2000);
    h.rec('calendar view renders', await present(page, '#cal-grid-wrap'));

    // 2. Session: pick a scope, then act as a member.
    const scope = await pickFirstOption(page, 'session-scope-select');
    h.rec('scope selectable', scope != null, scope ?? '');
    await sleep(1200);
    const me = await pickFirstOption(page, 'session-acting-as-select');
    h.rec('acting-as selectable', me != null, me ?? '');
    await sleep(1500);

    // 3. Location sharing toggle (off → here → expected → off). The "expected"
    //    mode reveals the per-period place picker when the scope has locations.
    const locOk = await present(page, '#session-location-select');
    h.rec('location toggle present (needs acting-as)', locOk);
    if (locOk) {
      await setSelect(page, 'session-location-select', 'here');
      await setSelect(page, 'session-location-select', 'expected');
      await sleep(800);
      h.rec('expected-trajectory picker renders (advisory: scope locations)',
            await present(page, '.loc-expected'));
      await setSelect(page, 'session-location-select', 'off');
    }

    // 4. Willingness: click "I'm willing" on a need; express → materialize →
    //    refresh should surface the candidate race / a matched suggestion.
    const willingBtns = await page.locator('.cal-intent-willing').count();
    h.info(`willingness toggles visible: ${willingBtns}`);
    if (willingBtns > 0) {
      await page.locator('.cal-intent-willing').first().click();
      await sleep(2800);   // express-willingness → materialize-willing → refresh
      const raced  = await present(page, '.cal-willing-race');
      const txt    = await bodyText(page);
      h.rec('marking willing surfaces a candidate / match',
            raced || txt.includes('Suggested') || (await present(page, '.cal-intent-matched')));
    } else {
      h.info('no open need the acting-as user is a candidate for (seed-dependent)');
    }
  }
} catch (e) {
  h.rec('fatal', false, e.message);
  h.info('console: ' + JSON.stringify(h.logs.slice(-10)));
  h.info('pageerrors: ' + JSON.stringify(h.errs.slice(-6)));
}
finally { await browser.close(); }

// Gate on the drivable structure (navigate + select + toggle); the data-
// dependent willingness/expected bits are recorded but advisory.
summarize(h, ['WASM loads (REPL ready)', 'connects to gateway over OCapN',
              'calendar view renders', 'scope selectable', 'acting-as selectable',
              'location toggle present (needs acting-as)']);
