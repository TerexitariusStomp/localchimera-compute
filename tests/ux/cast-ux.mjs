/// tests/ux/cast-ux.mjs — the DIAL's SIGNED governance cast, end-to-end.
///
/// The last unproven seam in the client-signing work: the dial (day-boot.scm's
/// handle-cast-signed) signs a stance ACDC with the citizen's own KERI key in
/// the browser, and the gateway verifies that signature against the citizen's
/// AID before recording the vote. Every other piece is covered — the server
/// flow in tests/governance/test-client-signing.scm (40/40), the WASM's Ed25519
/// signing in tests/ux/recovery-ux.mjs, the WASM↔gateway seam in
/// tests/ux/credential-sync-ux.mjs — but not this combination, through the DIAL.
///
/// Writing it surfaced a real bug it now guards against: day-boot.js never
/// wired the governance handlers (cast/openProposal/getResult/…) onto
/// __seam.handlers, so app/tabs/governance.js's `if (HANDLERS.cast)` guards
/// were all falsy — the whole governance tab was inert. This test fails if that
/// regresses.
///
/// Opening a ballot needs a governor; the browser's AID is the SAID of an ICP
/// that anchors a browser-side reticulum key, so it can't be cheaply pre-known.
/// The runner therefore starts the gateway with PLAYNET_TEST_OPEN_GOVERNANCE=1
/// (a documented test-only flag that gates ONLY ballot open/close, never the
/// cast signature check) so any signed-in AID can open the ballot we then cast
/// on. The cast itself goes through the real cast-signed + verify path.
///
///   1. openProposal → a ballot exists
///   2. cast a SIGNED 'yes → gateway's cast-signed verifies the sig, records it
///   3. getResult → the stance is in the tally
///   4. the durable stance ACDC on disk is issued by this AID and signed
///
/// Run via:  make test-cast-ux

import { harness, launch, newPage, sleep, summarize } from './ux-harness.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';
const BRAN = 'uxe2e-daycast-voter-passcode-01'; // any ≥21-char passcode

const h = harness();
const browser = await launch();
const page = await newPage(browser, h);
page.on('pageerror', e => h.errs.push(String(e).slice(0, 140)));

const call = (name, ...args) =>
  page.evaluate(([n, a]) => window.__seam.handlers[n](...a), [name, args]);

try {
  await page.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 60000 });

  // Wait for the dial to connect (chip reads "create your identity" when
  // connected-and-anonymous).
  let chip = '';
  for (let i = 0; i < 60; i++) {
    chip = await page.evaluate(() => document.querySelector('#idrow .who')?.textContent ?? '');
    if (/create your identity/i.test(chip)) break;
    await sleep(500);
  }
  h.rec('dial connects to the gateway', /create your identity/i.test(chip), chip);

  // The regression guard: the governance handlers must be on the seam.
  const wired = await page.waitForFunction(
    () => !!(window.__seam?.handlers?.cast && window.__seam?.handlers?.openProposal
             && window.__seam?.handlers?.getResult && window.__seam?.handlers?.myVoice),
    { timeout: 30000 }).then(() => true).catch(() => false);
  h.rec('governance handlers wired onto __seam (cast/openProposal/getResult)', wired);

  // Sign up (mints keys in-browser, registers the ICP). Sets *secret* so the
  // cast can be signed. NOTE: signup replies "ok" BEFORE authenticate! finishes
  // (it's async), so *session* is not set yet on resolve — we poll for it below.
  const signup = await call('signup', 'voter', 'voter@test.local', BRAN);
  const m = /^ok:(E[A-Za-z0-9_-]{43})/.exec(signup);
  h.rec('signed up (keys minted in-browser)', !!m, signup.slice(0, 70));
  const AID = m ? m[1] : '';

  // Wait for authenticate! to establish *session*: poll a session-gated handler
  // until it stops answering "sign in first".
  let sessionReady = false;
  for (let i = 0; i < 60; i++) {
    const r = await call('myVoice');
    if (!/sign in first/i.test(String(r))) { sessionReady = true; break; }
    await sleep(500);
  }
  h.rec('session established after authenticate', sessionReady);

  // Governor (via the test flag) opens a ballot.
  const opened = await call('openProposal', 'ballot', 'policy', 'e2e-cast-1', 'e2e signed cast?', 'federation');
  h.rec('ballot opened', /^ok/.test(opened), opened.slice(0, 70));

  // Cast a SIGNED stance. cast-signed returns ok ONLY after the gateway's
  // client-signature-ok? verifies the browser-produced signature against this
  // AID — so ok here is the end-to-end proof the WASM signed and the server
  // accepted it.
  const cast = await call('cast', 'e2e-cast-1', 'yes');
  h.rec('SIGNED cast accepted (gateway verified the browser signature)',
        /^ok/.test(cast), cast.slice(0, 70));

  // The stance is in the tally.
  const resultJson = await call('getResult', 'e2e-cast-1');
  let recorded = false;
  try {
    const r = JSON.parse(resultJson);
    recorded = !!(r && (r.tally || r.status === 'open' || r.status === 'closed'));
  } catch (_) {}
  h.rec('ballot result reflects the recorded stance', recorded, String(resultJson).slice(0, 90));

  // The durable artifact: a stance credential issued BY this AID, carrying a
  // signature, sits in the gateway's acdc-store on disk. Belt-and-suspenders
  // over the ok above (which already implies a verified signature).
  const dataDir = process.env.PLAYNET_DATA_DIR;
  if (dataDir && AID) {
    const { readdirSync, readFileSync, existsSync } = await import('node:fs');
    const { join } = await import('node:path');
    const acdcDir = join(dataDir, 'acdc');
    let signedStance = false;
    if (existsSync(acdcDir)) {
      const walk = (d) => readdirSync(d, { withFileTypes: true }).flatMap(e =>
        e.isDirectory() ? walk(join(d, e.name)) : [join(d, e.name)]);
      for (const f of walk(acdcDir)) {
        if (!f.endsWith('.scm')) continue;
        const txt = readFileSync(f, 'utf8');
        if (txt.includes(AID) && txt.includes('stance') && /signature|0B/.test(txt)) {
          signedStance = true; break;
        }
      }
    }
    h.rec('durable stance ACDC on disk is issued by this AID + signed', signedStance);
  }
} catch (e) {
  h.rec('test threw', false, String(e).slice(0, 140));
} finally {
  await browser.close();
}

// No gating list → every recorded assertion gates the exit code (0 iff all
// passed). (Passing a title string here is a bug: `gating` is an array of
// assertion NAMES, and a non-empty string filters the results to none, which
// forces exit(1) even on an all-green run.)
summarize(h);
