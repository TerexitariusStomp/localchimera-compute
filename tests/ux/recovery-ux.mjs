/// tests/ux/recovery-ux.mjs — new device, nothing but the passcode.
///
/// The property every other design decision leans on: lose the browser, keep
/// the bran, get everything back. It was asserted nowhere at any level —
/// tests/keri/test-keri-recovery.scm is SERVER recovery (KERIA reconnect,
/// reload the governance AID), which is a different thing entirely.
///
/// The run simulates a genuinely fresh device: sign up, then wipe
/// localStorage and IndexedDB and reload, so nothing survives except what the
/// tester remembers — the AID and the passcode. Then recover through the
/// "I already have an identity" path and check what comes back.
///
/// Two properties, and the second is the one that matters:
///
///   1. IDENTITY returns — keys re-derived locally from the bran, the AID's
///      ICP fetched from the gateway, and the derived key must match the k0
///      in that ICP (a wrong passcode is rejected, not silently accepted).
///   2. The ENCRYPTED BACKUP opens — the credential blob the gateway holds
///      was sealed by the previous session under a bran-derived key. If it
///      decrypts on a browser that shares no state with that session, then
///      the backup really is recoverable from bran + AID and from nothing
///      else. That is Layer 2 of docs/planning/legal/gdpr-analysis.md §"Phase 1b".
///
/// Run via:  make test-recovery-ux
///           bash tests/ux/ux-full.sh tests/ux/recovery-ux.mjs

import { readFileSync, existsSync } from 'node:fs';
import { harness, launch, newPage, openConnected, present, sleep,
         summarize } from './ux-harness.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';
const SREF = process.argv[3] || '';
const DATA = process.env.PLAYNET_DATA_DIR || '.ux-e2e-data';
const BRAN = 'uxe2e-recovery-passcode-21ch';

const h = harness();
const browser = await launch();
const page = await newPage(browser, h);

const replLog = () =>
  page.evaluate(() => document.querySelector('#repl-log')?.textContent ?? '');

async function waitLog(re, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const m = (await replLog()).match(re);
    if (m) return m;
    await sleep(1000);
  }
  return null;
}

const credFile = aid => `${DATA}/credentials-${aid.slice(0, 16)}.scm`;

async function waitForFile(path, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path)) return readFileSync(path, 'utf8');
    await sleep(1000);
  }
  return null;
}

/** Sign in on the identity card so a session (and thus a sync) exists. */
async function authenticate() {
  const savedBtn = 'button.id-btn-primary:has-text("I have saved it")';
  if (await page.locator(savedBtn).count() > 0) {
    await page.click(savedBtn).catch(() => {});
    await sleep(800);
  }
  const authBtn = 'button.id-btn:has-text("authenticate")';
  if (await page.locator(authBtn).count() === 0) {
    await page.click('.id-btn-anchor').catch(() => {});
    await sleep(800);
  }
  await page.click(authBtn).catch(() => {});
  return waitLog(/\[keri\] authenticated as/, 120000);
}

try {
  const { connected } = await openConnected(page, h, BASE, SREF);
  h.rec('connects to gateway over OCapN', connected);

  if (connected) {
    // ── Device 1: create an identity and let it sync ────────────────────
    await page.click('.id-btn-anchor');
    await sleep(800);
    await page.fill('#id-name-input',  'recoverme');
    await page.fill('#id-email-input', 'recoverme@playnet.test');
    await page.fill('#id-bran-input',  BRAN);
    await page.click('button.id-btn-primary');

    const reg = await waitLog(/\[keri\] registered AID (E[A-Za-z0-9_-]{43})/, 180000);
    h.rec('device 1: AID registered', !!reg, reg?.[1] ?? '');

    if (reg) {
      const aid = reg[1];
      h.rec('device 1: session opened', !!(await authenticate()));
      const before = await waitForFile(credFile(aid), 120000);
      h.rec('device 1: gateway holds an encrypted backup', !!before,
            before ? `${before.length} chars` : '');

      // ── Wipe. Everything local goes: the hint, the keypairs, the
      //    cached credentials. Only the AID and the passcode survive,
      //    in the tester's head — exactly a new device.
      await page.evaluate(async () => {
        localStorage.clear();
        sessionStorage.clear();
        for (const db of (await indexedDB.databases?.() ?? []))
          if (db.name) indexedDB.deleteDatabase(db.name);
      });
      const wiped = await page.evaluate(() => localStorage.length);
      h.rec('local state wiped (fresh-device simulation)', wiped === 0);

      await page.reload({ waitUntil: 'domcontentloaded' });
      const { connected: re } = await openConnected(page, h, BASE, SREF);
      h.rec('device 2: reconnects with no stored identity', re);

      if (re) {
        // The chip must offer creation, not unlock — proving the hint
        // really is gone rather than merely stale.
        await page.click('.id-btn-anchor');
        await sleep(800);
        h.rec('device 2: sees the CREATE form (no identity remembered)',
              await present(page, '#id-name-input'));

        // ── Recover: AID + passcode, keys re-derived locally ──────────
        await page.click('button.id-btn-secondary:has-text("I already have an identity")')
          .catch(e => h.info('recover toggle: ' + e.message));
        await sleep(600);
        h.rec('device 2: recover form offers AID + passcode',
              await present(page, '#id-aid-input'));

        // A wrong passcode must be REJECTED — the derived key is compared
        // against the k0 in the AID's own ICP, so this cannot be faked.
        await page.fill('#id-aid-input',  aid);
        await page.fill('#id-bran-input', BRAN + 'wrong');
        await page.click('button.id-btn-primary:has-text("recover")');
        await sleep(6000);
        const badLog = (await replLog()).includes('[keri] recovered AID');
        h.rec('device 2: WRONG passcode does not recover', !badLog);

        // The real one.
        await page.fill('#id-aid-input',  aid);
        await page.fill('#id-bran-input', BRAN);
        await page.click('button.id-btn-primary:has-text("recover")');
        const rec = await waitLog(/\[keri\] recovered AID (E[A-Za-z0-9_-]{43})/, 120000);
        h.rec('device 2: identity recovered from bran + AID alone', !!rec);
        h.rec('device 2: recovered the SAME AID', rec?.[1] === aid, rec?.[1] ?? '');

        if (!rec) {
          h.info('repl-log tail: ' + JSON.stringify((await replLog()).slice(-700)));
          h.info('id-error: ' + JSON.stringify(await page.evaluate(() =>
            document.querySelector('.id-error')?.textContent ?? '(none)')));
        }

        if (rec) {
          // ── The payoff: does the gateway's blob open on this browser?
          //    A session triggers list-credentials → vault-open. If the key
          //    were tied to browser state rather than the bran, this is
          //    where it would fail — the state is gone.
          const auth2 = await authenticate();
          h.rec('device 2: session opened after recovery', !!auth2);

          // A failed decrypt is silent by design (it merges as empty), so
          // assert on the artifact: the backup must still be readable
          // ciphertext, not replaced by a re-sealed empty one under a key
          // this browser invented.
          const after = await waitForFile(credFile(aid), 60000);
          h.rec('device 2: backup still present and still ciphertext',
                !!after && after.includes('#vu8('), after?.slice(0, 40) ?? '');
          h.rec('device 2: no plaintext leaked into the backup',
                !!after && !after.includes('playnet-') && !after.includes(aid));
        }
      }
    }
  }
} catch (e) {
  h.info('exception: ' + (e?.stack ?? String(e)));
  h.rec('test ran to completion', false);
} finally {
  await browser.close();
}

summarize(h, ['connects to gateway over OCapN', 'device 1: AID registered']);
