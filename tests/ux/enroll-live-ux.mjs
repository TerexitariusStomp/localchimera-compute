/// tests/ux/enroll-live-ux.mjs — being recognised, live.
///
/// The FPP-I2 human loop over a REAL gateway, three isolated browser
/// contexts as three citizens:
///
///   A signs up (keys minted in-browser) and, as the bootstrap founder under
///   PLAYNET_TEST_OPEN_GOVERNANCE, makes the ecosystem's FIRST person — the
///   genesis act, the same thing the founders.txt seed does at boot. B signs
///   up and asks to be recognised: the ask IS an enrollment ceremony, durable,
///   with the ecosystem's quorum clamped to who could sign — one, since A is
///   the only recognised person. B reads their own ask back as "0 of 1". A
///   sees it on the witness rail and vouches — a signature by A's own
///   browser-held key over the statement — and B's Personhood Credential
///   issues carrying A's vouch as an edge. Then C asks: two people are
///   recognised now, so the quorum is the policy's two; A signs, C still
///   reads "1 of 2"; B signs, and C is recognised.
///
/// Everything crosses the wire: signup, the ask, the ceremony read, the
/// inbox, the vouch signatures, the final status reads. Nothing is stubbed.
///
/// Run via:  make test-enroll-live-ux
///           PLAYNET_TEST_OPEN_GOVERNANCE=1 bash tests/ux/ux-full.sh tests/ux/enroll-live-ux.mjs

import { harness, launch, newPage, sleep, summarize } from './ux-harness.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';

const h = harness();
const browser = await launch();

/// One citizen: an isolated context (its own localStorage), signed up
/// through the dial's real one-tap create. Returns { page, aid }.
async function citizen(label) {
  const ctx = await browser.newContext();
  const page = await newPage(ctx, h);
  await page.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 60000 });
  const deadline = Date.now() + 180000;
  let chip = '';
  while (Date.now() < deadline) {
    chip = await page.evaluate(() =>
      document.querySelector('#idrow .who')?.textContent ?? '');
    if (/create your identity/i.test(chip)) break;
    await sleep(1000);
  }
  h.rec(`${label}: dial connects to the gateway`, /create your identity/i.test(chip), chip);
  await page.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
  await sleep(600);
  await page.evaluate(() => {
    const box = document.querySelector('#idform input[type="checkbox"]');
    if (box && !box.checked) box.click();
  });
  await sleep(200);
  await page.click('#idform button.go:has-text("create your identity")');
  await page.waitForSelector('#idform input[name="username"]', { timeout: 120000 })
    .catch(() => {});
  const aid = await page.evaluate(() =>
    document.querySelector('#idform input[name="username"]')?.value ?? '');
  h.rec(`${label}: identity minted in-browser`, /^E[A-Za-z0-9_-]{43}$/.test(aid), aid || '(none)');
  return { page, aid };
}

/// Every dial capability rides window.__seam.handlers — the same seam the
/// faces call (HANDLERS in seam.ts).
const dial = (page, expr) =>
  page.evaluate(`(() => { const H = window.__seam.handlers; return ${expr}; })()`);

const parse = (s, fallback = {}) => { try { return JSON.parse(s); } catch { return fallback; } };

async function isPerson(page) {
  let ok = false;
  for (let i = 0; i < 15 && !ok; i++) {
    ok = !!parse(await dial(page, `H.fpStatus()`)).person;
    if (!ok) await sleep(1000);
  }
  return ok;
}

async function askRow(page, candidate) {
  let row = null;
  for (let i = 0; i < 15 && !row; i++) {
    const rows = parse(await dial(page, `H.witnessInbox()`), []);
    row = (Array.isArray(rows) ? rows : []).find(r => r.kind === 'enroll' && r.worker === candidate) || null;
    if (!row) await sleep(1000);
  }
  return row;
}

try {
  const A = await citizen('citizen A');
  const B = await citizen('citizen B');
  const C = await citizen('citizen C');
  await sleep(2000); // sessions land their gateway registration

  // ── genesis: the founder makes the first person ──────────────────────────
  const before = parse(await dial(A.page, `H.fpStatus()`));
  h.rec('nobody is recognised yet', before.bootstrapped === false, JSON.stringify(before));
  const genesis = await dial(A.page, `H.fpGrant(${JSON.stringify(A.aid)})`);
  h.rec('A (founder) makes the first person — the genesis act', genesis === 'ok', String(genesis));
  h.rec('A holds a live PHC', await isPerson(A.page));
  const again = await dial(A.page, `H.fpGrant(${JSON.stringify(B.aid)})`);
  h.rec('once bootstrapped, the unilateral grant is refused', /^err:/.test(String(again)), String(again));

  // ── B asks: the ask is a ceremony, and B reads it back ───────────────────
  const ask = await dial(B.page, `H.fpEnroll()`);
  h.rec('B asks to be recognised', ask === 'ok', String(ask));
  const mine = parse(await dial(B.page, `H.fpMyCeremony()`));
  h.rec('B reads their own ask: collecting, 0 of 1 (the quorum clamps to the one recognised person)',
        mine.state === 'collecting' && mine.count === 0 && mine.quorum === 1, JSON.stringify(mine));
  const pending = parse(await dial(A.page, `H.fpPending()`), []);
  h.rec('A sees B among those asking, with the ask\'s progress',
        Array.isArray(pending) && pending.some(r => r.candidate === B.aid && r.quorum === 1),
        JSON.stringify(pending).slice(0, 120));

  // ── the ask on the witness rail; A vouches ────────────────────────────────
  const rowB = await askRow(A.page, B.aid);
  h.rec('the ask appears in A\'s witness inbox (kind=enroll, candidate=B), signable',
        !!rowB && rowB.eligible !== false,
        rowB ? `${rowB.said.slice(0, 12)}… ${rowB.count}/${rowB.quorum}` : '(none)');
  const notB = await dial(B.page, `H.witnessInbox()`);
  h.rec('B does not see their own ask to sign',
        !(parse(notB, []) || []).some(r => r.worker === B.aid), String(notB).slice(0, 60));
  if (rowB) {
    const att = await dial(A.page, `H.witnessAttest(${JSON.stringify(rowB.said)})`);
    h.rec('A vouches — signature lands, quorum met, the credential issues',
          att === 'ok:finalized', String(att));
  }
  h.rec('B holds a live PHC — recognised by a witness', await isPerson(B.page));
  const mineAfter = parse(await dial(B.page, `H.fpMyCeremony()`));
  h.rec('B\'s ask reads finalized', mineAfter.state === 'finalized', JSON.stringify(mineAfter));

  // ── C asks: two are recognised, so the quorum is two ─────────────────────
  const askC = await dial(C.page, `H.fpEnroll()`);
  h.rec('C asks to be recognised', askC === 'ok', String(askC));
  const mineC = parse(await dial(C.page, `H.fpMyCeremony()`));
  h.rec('C\'s ask wants two — the policy\'s quorum, now that two could sign',
        mineC.state === 'collecting' && mineC.quorum === 2, JSON.stringify(mineC));
  const rowCA = await askRow(A.page, C.aid);
  if (rowCA) {
    const one = await dial(A.page, `H.witnessAttest(${JSON.stringify(rowCA.said)})`);
    h.rec('A signs — one of two', one === 'ok:attested', String(one));
  }
  const mid = parse(await dial(C.page, `H.fpMyCeremony()`));
  h.rec('C reads 1 of 2, and who signed', mid.count === 1 && (mid.witnesses || []).includes(A.aid),
        JSON.stringify(mid));
  const rowCB = await askRow(B.page, C.aid);
  h.rec('B, recognised by ceremony, may sign too', !!rowCB && rowCB.eligible !== false,
        rowCB ? `${rowCB.count}/${rowCB.quorum}` : '(none)');
  if (rowCB) {
    const two = await dial(B.page, `H.witnessAttest(${JSON.stringify(rowCB.said)})`);
    h.rec('B signs — quorum, the credential issues', two === 'ok:finalized', String(two));
  }
  h.rec('C holds a live PHC — two witnesses, two edges', await isPerson(C.page));

  h.rec('no page errors during the flow', h.errs.length === 0,
        h.errs.slice(0, 2).join(' | '));
} catch (e) {
  h.info('exception: ' + (e?.stack ?? String(e)));
  h.rec('test ran to completion', false);
} finally {
  await browser.close();
}

summarize(h, ['citizen A: dial connects to the gateway',
              'A (founder) makes the first person — the genesis act',
              'B holds a live PHC — recognised by a witness',
              'C holds a live PHC — two witnesses, two edges']);
