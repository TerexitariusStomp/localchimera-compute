/// tests/ux/keri-signup-ux.mjs — browser e2e for the KERI signup → OOBI replies
/// path: the real repl.wasm creates an identity in headless Chromium (keys
/// derived in-browser from a passcode), ships the icp + OKEA endpoint
/// replies to a LIVE gateway over OCapN, and the REAL /oobi server
/// (server/serve-static.scm, started by ux-full.sh against the gateway's
/// oobi-host dir) must then serve a body carrying the /loc/scheme +
/// /end/role/add endorsements — the exact artifact a KERIA resolver needs
/// to learn this AID's endpoint (IMPLEMENTATION.md divergence #4).
///
/// Run via:  make test-keri-signup-ux
///           bash tests/ux/ux-full.sh tests/ux/keri-signup-ux.mjs
/// Args (supplied by the runner): <base-url> <encoded-gateway-sref>
/// Env: OOBI_URL — base of the serve-static instance (ux-full.sh exports it).

import { harness, launch, newPage, openConnected, present, sleep,
         summarize } from './ux-harness.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';
const SREF = process.argv[3] || '';
const OOBI = process.env.OOBI_URL || 'http://127.0.0.1:8098';

const h = harness();
const browser = await launch();
const page = await newPage(browser, h);

const replLog = () =>
  page.evaluate(() => document.querySelector('#repl-log')?.textContent ?? '');

/** Poll #repl-log until RE matches or TIMEOUT; returns the match or null. */
async function waitLog(re, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const m = (await replLog()).match(re);
    if (m) return m;
    await sleep(1000);
  }
  return null;
}

try {
  const { connected } = await openConnected(page, h, BASE, SREF);
  h.rec('WASM loads (REPL ready)', true);
  h.rec('connects to gateway over OCapN', connected);

  if (connected) {
    // 1. Open the identity dropdown (top-right "Sign in" anchor).
    await page.click('.id-btn-anchor');
    await sleep(800);
    h.rec('identity dropdown opens (create form)',
          await present(page, '#id-name-input'));

    // 2. Fill the create form. The bran never leaves the browser; the
    //    server sees only the signed icp + endorsed replies.
    await page.fill('#id-name-input',  'uxe2e');
    await page.fill('#id-email-input', 'uxe2e@playnet.test');
    await page.fill('#id-bran-input',  'uxe2e-passcode-21chars-xyz');
    await page.click('button.id-btn-primary');

    // 3. The success log lines: AID registration, then the OKEA replies
    //    landing on the gateway (signup-agent verified the endorsements).
    //    The AID is the icp's saidified `i` (E-prefix) — the identifier
    //    resolvers and the gateway key their KEL/location dbs by.
    const reg = await waitLog(/\[keri\] registered AID (E[A-Za-z0-9_-]{43})/, 180000);
    h.rec('AID registered (icp accepted by gateway)', !!reg, reg?.[1] ?? '');
    if (!reg) {
      h.info('repl-log tail: ' + JSON.stringify((await replLog()).slice(-900)));
      h.info('id-error: ' + JSON.stringify(await page.evaluate(() =>
        document.querySelector('.id-error')?.textContent ?? '(none)')));
      h.info('console tail: ' + JSON.stringify(h.logs.slice(-25)));
      h.info('pageerrors: ' + JSON.stringify(h.errs.slice(-8)));
      await page.screenshot({ path: 'tests/ux/screenshots/keri-signup-fail.png' })
        .catch(() => {});
    }
    // 4. THE artifact: the production /oobi route serves KEL + replies.
    //    The replies ship asynchronously after signup, so poll the served
    //    body until they land — that IS the registration proof (the
    //    gateway verified the endorsements before storing them).
    if (reg) {
      const aid = reg[1];
      let res = { ok: false, status: 0 }, body = '';
      const deadline = Date.now() + 120000;
      while (Date.now() < deadline) {
        res = await fetch(`${OOBI}/oobi/${aid}`).catch(() => ({ ok: false, status: 0 }));
        if (res.ok) {
          body = await res.text();
          if (body.includes('"r":"/loc/scheme"')) break;
        }
        await sleep(2000);
      }
      h.rec('/oobi/{aid} serves 200', res.ok, `status ${res.status}`);
      // The icp is self-addressing (i = d = the registered AID), and the
      // replies' -F endorsement names that same AID as the signer.
      h.rec('OOBI body carries the icp (self-addressing E-AID)',
            body.includes(`"i":"${aid}"`));
      h.rec('OOBI body carries /end/role/add reply',
            body.includes('"r":"/end/role/add"'));
      h.rec('OOBI body carries /loc/scheme reply',
            body.includes('"r":"/loc/scheme"'));
      h.rec('OOBI body advertises the reticulum destination',
            body.includes('"scheme":"reticulum"') &&
            body.includes('"url":"reticulum://'));
      h.rec('OOBI body advertises the lxmf mail destination',
            body.includes('"scheme":"lxmf"') &&
            body.includes('"url":"lxmf://'));
      h.rec('replies endorsed with -F TransIdxSigGroups',
            body.includes(`-FAB${aid}`));
      // Advisory: the JSON debug view shows the stored entry shape.
      const dbg = await fetch(`${OOBI}/oobi/${aid}.json`);
      if (dbg.ok) {
        const entry = await dbg.text();
        h.rec('entry stores framed replies (debug view)',
              entry.includes('replies'), '');
      } else {
        h.info('.json debug view unavailable — skipping advisory check');
      }

      // 5. The browser's own ack of the replies round-trip (the lobby
      //    resolved 'ok). The substantive registration is already proven
      //    by the served body above; this confirms the client saw it.
      const replies = await waitLog(/\[keri\] OOBI endpoint replies registered/, 30000);
      h.rec('OOBI endpoint replies registered (endorsements verified)', !!replies);
    }
  }
} catch (e) {
  h.rec('fatal', false, e.message);
} finally {
  await browser.close();
}

summarize(h, ['WASM loads (REPL ready)',
              'connects to gateway over OCapN',
              'identity dropdown opens (create form)',
              'AID registered (icp accepted by gateway)',
              'OOBI endpoint replies registered (endorsements verified)',
              '/oobi/{aid} serves 200',
              'OOBI body carries /loc/scheme reply',
              'OOBI body advertises the reticulum destination',
              'replies endorsed with -F TransIdxSigGroups']);
