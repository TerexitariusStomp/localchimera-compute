/// tests/ux/willingness-ux.mjs — browser e2e for the willingness loop.
/// A worked EXAMPLE of the generic ux-harness pattern (see ux-harness.mjs).
/// Run via:  bash tests/ux/ux-full.sh tests/ux/willingness-ux.mjs
/// Args (supplied by the runner): <base-url> <encoded-gateway-sref>

import { harness, launch, newPage, openConnected, scopeOptions, sleep, summarize } from './ux-harness.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';
const SREF = process.argv[3] || '';

const h = harness();
const browser = await launch();
const page = await newPage(browser, h);

try {
  // Gating: the real WASM loads in Chromium, and the OCapN connection to the
  // LIVE gateway succeeds (repl.scm logs "Connected to OCapN gateway").
  const { connected } = await openConnected(page, h, BASE, SREF);
  h.rec('WASM loads (REPL ready)', true);
  h.rec('connects to gateway over OCapN', connected);

  if (connected) {
    // Best-effort downstream — scopes/calendar load lazily on view navigation
    // with seeded data; reported as INFO. The willingness band rendering itself
    // is covered deterministically by tests/playnet/test-calendar-willingness.scm.
    await sleep(2500);
    const scopes = await scopeOptions(page);
    h.info(`scopes loaded: ${scopes.join(',') || '(none — calendar view not navigated)'}`);
    const willing = await page.evaluate(() =>
      (document.body.textContent || '').includes("You'd be helpful here")
      || !!document.querySelector('.cal-intent-willing, .cal-intents-offers, .cal-willing-race'));
    h.info(`willingness band in DOM: ${willing}`
      + (willing ? '' : ' (needs calendar nav + a seeded candidate offer)'));
  }
} catch (e) {
  h.rec('fatal', false, e.message);
} finally {
  await page.screenshot({ path: '/tmp/willingness-ux.png', fullPage: true }).catch(() => {});
  await browser.close();
}

summarize(h, ['WASM loads (REPL ready)', 'connects to gateway over OCapN']);
