/// tests/ux/credential-sync-ux.mjs — browser e2e for the encrypted credential
/// backup: the Scheme↔JS seam that unit tests cannot reach.
///
/// The pieces on either side are covered elsewhere — the key derivation in
/// tests/keri/test-bran-derivations.scm (Guile), the cipher in
/// tests/browser/vault-test.mjs (node). What neither can reach is the wiring
/// between them: blob-key → vault-seal → sync-credentials, and back through
/// list-credentials → vault-open → merge. That needs a real browser talking
/// to a real gateway, which is what this does.
///
/// The decisive assertion is the last one. The test knows the passcode, so it
/// re-derives the key with plain WebCrypto HKDF and decrypts the gateway's
/// stored blob ITSELF. That proves three things at once:
///   • the backup is genuinely encrypted at rest (not just wrapped);
///   • the key really is derived from the bran and nothing else — which is
///     the recovery property (bran + AID is sufficient, browser state is not
///     required);
///   • the on-disk envelope is the vault format the browser wrote.
///
/// Run via:  make test-credential-sync-ux
///           bash tests/ux/ux-full.sh tests/ux/credential-sync-ux.mjs

import { readFileSync, existsSync } from 'node:fs';
import { harness, launch, newPage, openConnected, present, sleep,
         summarize } from './ux-harness.mjs';
import { open as vaultOpen } from '../../browser/lib/vault.js';

const BASE = process.argv[2] || 'http://localhost:8089';
const SREF = process.argv[3] || '';
const DATA = process.env.PLAYNET_DATA_DIR || '.ux-e2e-data';
const BRAN = 'uxe2e-credsync-passcode-21chars';

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

/** The gateway's per-AID credential file: <data>/credentials-<aid[0:16]>.scm */
const credFile = aid => `${DATA}/credentials-${aid.slice(0, 16)}.scm`;

async function waitForFile(path, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path)) return readFileSync(path, 'utf8');
    await sleep(1000);
  }
  return null;
}

/** Parse Guile's `#vu8(1 2 3)` external representation into bytes. */
function parseVu8(text) {
  const m = text.match(/#vu8\(([^)]*)\)/);
  if (!m) return null;
  const body = m[1].trim();
  return Uint8Array.from(body ? body.split(/\s+/).map(Number) : []);
}

/**
 * Re-derive the blob key from the passcode alone, mirroring
 * `bran->blob-key` (signify-portable.scm): HKDF-SHA256, RFC 5869 zero salt,
 * info "playnet:blob:v1", 32 bytes. Deliberately reimplemented from the spec
 * rather than imported — if the two ever disagree, that is the finding.
 */
async function branToBlobKey(bran) {
  const ikm = new TextEncoder().encode(bran);
  const key = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256',
      salt: new Uint8Array(32),                       // #f salt → 32 zero bytes
      info: new TextEncoder().encode('playnet:blob:v1') },
    key, 256);
  return new Uint8Array(bits);
}

try {
  const { connected } = await openConnected(page, h, BASE, SREF);
  h.rec('WASM loads (REPL ready)', true);
  h.rec('connects to gateway over OCapN', connected);

  if (connected) {
    // Sign up. Authentication triggers do-keri-fetch-credentials!, which
    // pulls the (absent) server copy and then pushes an encrypted one —
    // the whole seam, on the app's own initiative.
    await page.click('.id-btn-anchor');
    await sleep(800);
    h.rec('identity dropdown opens', await present(page, '#id-name-input'));

    await page.fill('#id-name-input',  'credsync');
    await page.fill('#id-email-input', 'credsync@playnet.test');
    await page.fill('#id-bran-input',  BRAN);
    await page.click('button.id-btn-primary');

    const reg = await waitLog(/\[keri\] registered AID (E[A-Za-z0-9_-]{43})/, 180000);
    h.rec('AID registered', !!reg, reg?.[1] ?? '');

    if (!reg) {
      h.info('repl-log tail: ' + JSON.stringify((await replLog()).slice(-900)));
      h.info('console tail: ' + JSON.stringify(h.logs.slice(-25)));
    } else {
      const aid = reg[1];

      // Signup registers the AID but does NOT open a session — it never
      // calls do-keri-fetch-credentials!. The sync only runs once we
      // authenticate, so drive that explicitly; otherwise there is simply
      // nothing to assert about and the test would pass vacuously.
      // Signup ends on the passcode-reveal gate ("I have saved it") — the
      // one moment the bran is shown. Acknowledge it to reach the identity
      // card underneath.
      const savedBtn = 'button.id-btn-primary:has-text("I have saved it")';
      if (await page.locator(savedBtn).count() > 0) {
        await page.click(savedBtn).catch(() => {});
        await sleep(800);
      }

      const authBtn = 'button.id-btn:has-text("authenticate")';
      // The anchor TOGGLES the dropdown — clicking it blindly closes the
      // panel signup left open. Only click it if the button isn't already
      // on screen.
      if (await page.locator(authBtn).count() === 0) {
        await page.click('.id-btn-anchor').catch(() => {});
        await sleep(800);
      }
      await page.click(authBtn).catch(e => h.info('authenticate click: ' + e.message));
      const auth = await waitLog(/\[keri\] authenticated as/, 120000);
      h.rec('session opened (this is what triggers the sync)', !!auth);
      if (!auth) {
        h.info('repl-log tail: ' + JSON.stringify((await replLog()).slice(-900)));
        h.info('buttons on screen: ' + JSON.stringify(
          await page.evaluate(() =>
            [...document.querySelectorAll('button')]
              .map(b => b.className + '|' + b.textContent.trim()).slice(0, 25))));
      }

      const path = credFile(aid);
      const raw = await waitForFile(path, 120000);
      h.rec('gateway wrote a credential backup', !!raw, path);

      if (raw) {
        // 1. Encrypted at rest — a bytevector, not a readable credential list.
        const blob = parseVu8(raw);
        h.rec('backup is stored as opaque bytes (#vu8), not an s-expression',
              !!blob && blob.length > 12,
              blob ? `${blob.length} bytes` : raw.slice(0, 80));

        // 2. No plaintext leakage. Before this change the file held the
        //    credential alists verbatim — schema strings and all.
        const leaks = ['playnet-', 'said', 'holder', 'issuer', aid]
              .filter(s => raw.includes(s));
        h.rec('no plaintext credential markers on disk', leaks.length === 0,
              leaks.length ? `leaked: ${leaks.join(', ')}` : '');

        // 3. THE assertion: decrypt it with nothing but the passcode.
        if (blob) {
          const key = await branToBlobKey(BRAN);
          const plain = await vaultOpen(key, blob);
          const text = new TextDecoder().decode(plain);
          h.rec('decrypts using ONLY the bran-derived key (recovery property)',
                plain.length > 0, plain.length ? '' : 'GCM tag rejected');
          h.rec('plaintext is the serialised credential list',
                text.trimStart().startsWith('('),
                text.slice(0, 60));

          // 4. A wrong passcode must not open it.
          const wrong = await branToBlobKey(BRAN + 'x');
          const bad = await vaultOpen(wrong, blob);
          h.rec('a different passcode does NOT decrypt it', bad.length === 0);
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

summarize(h, ['connects to gateway over OCapN', 'AID registered']);
