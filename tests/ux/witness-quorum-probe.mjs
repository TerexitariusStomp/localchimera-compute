/// tests/ux/witness-quorum-probe.mjs — one-off LIVE probe (not a suite): the
/// witness ceremony to QUORUM, as two real browsers against a running gateway.
/// Citizen A signs up, offers hours, records work and opens the ceremony;
/// citizen B (a second, isolated browser context = its own identity) finds it
/// in the witness inbox and co-signs with the key that never left its vat —
/// at the quorum floor the work credential strengthens to multisig, and the
/// ask leaves every inbox. The whole k-of-n trust floor, browser to browser.
///
/// Run via:  make probe-witness-quorum   (needs `make dev` running)
import { harness, launch, sleep, summarize } from './ux-harness.mjs';
import { signupIdentity, dialScope, offerHours } from './probe-lib.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';

const h = harness();
const browser = await launch();
// two ISOLATED contexts: localStorage is per-context, so each page mints and
// keeps its OWN identity — the two-citizen case one browser cannot fake
const ctxA = await browser.newContext();
const ctxB = await browser.newContext();
const A = await ctxA.newPage();
const B = await ctxB.newPage();
for (const [p, who] of [[A, 'A'], [B, 'B']]) {
  p.on('console', m => { const t = m.text(); if (t) h.logs.push(`${who}: ${t.slice(0, 140)}`); });
  p.on('pageerror', e => h.errs.push(`${who}: ${String(e).slice(0, 120)}`));
}

// dial Berlin and offer hours — offering time is how a browser AID becomes an
// agent of the scope, and only agents are in the roster a ceremony asks
async function joinBerlin(page, who) {
  const dialed = await dialScope(page, /berlin/);
  const avail = await offerHours(page);
  h.rec(`${who}: joined Berlin (dial + hours offered)`,
        dialed === 'ok' && avail === 'ok', `${dialed}/${avail}`);
}

try {
  const aidA = await signupIdentity(A, h, BASE, 'A');
  await signupIdentity(B, h, BASE, 'B');
  await joinBerlin(A, 'A');
  await joinBerlin(B, 'B');   // B is in the roster BEFORE the ceremony opens

  // A records lived work and asks for witnesses
  const opened = await A.evaluate(async () => {
    const H = window.__seam.handlers;
    const work = String(await H.logObserve('work', 'farming', '2', 'hours',
                                           'quorum probe: field work', '')
      .catch(e => 'threw:' + e));
    const evId = work.replace(/^ok:/, '');
    const open = String(await H.witnessOpen('', evId).catch(e => 'threw:' + e));
    return { work, open, said: open.replace(/^ok:/, '') };
  });
  h.rec('A: work recorded and ceremony opened (statement SAID returned)',
        /^ok:E/.test(opened.open), JSON.stringify(opened).slice(0, 140));
  const said = opened.said;

  // B finds the ask in its witness inbox
  let entry = null;
  const dlInbox = Date.now() + 45000;
  while (Date.now() < dlInbox) {
    entry = await B.evaluate(async (said) => {
      const j = await window.__seam.handlers.witnessInbox().catch(e => 'threw:' + e);
      try { return JSON.parse(j).find(r => r.said === said) || null; }
      catch { return null; }
    }, said);
    if (entry) break;
    await sleep(2000);
  }
  h.rec('B: the ask reaches the second citizen\'s inbox (worker excluded, B offered)',
        !!entry && entry.worker === aidA, JSON.stringify(entry));

  // B co-signs from its own vat-held key — quorum floor is 1, so this both
  // attests AND finalizes: the credential strengthens to multisig in place
  const attested = await B.evaluate(async (said) =>
    String(await window.__seam.handlers.witnessAttest(said).catch(e => 'threw:' + e)), said);
  h.rec('B: co-signature verifies and the ceremony FINALIZES at quorum',
        attested === 'ok:finalized', attested);

  // finalize retires the ask — the swept inbox no longer offers it
  const after = await B.evaluate(async (said) => {
    const j = await window.__seam.handlers.witnessInbox().catch(e => 'threw:' + e);
    try { return JSON.parse(j).some(r => r.said === said); } catch { return true; }
  }, said);
  h.rec('B: the finalized ask leaves the inbox', after === false, `still listed: ${after}`);
} catch (e) {
  h.rec('fatal', false, e.message);
  h.info('console: ' + JSON.stringify(h.logs.slice(-12)));
} finally { await browser.close(); }

summarize(h, ['A: identity created', 'B: identity created',
              'A: work recorded and ceremony opened (statement SAID returned)',
              'B: the ask reaches the second citizen\'s inbox (worker excluded, B offered)',
              'B: co-signature verifies and the ceremony FINALIZES at quorum',
              'B: the finalized ask leaves the inbox']);
