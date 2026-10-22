/// tests/ux/lend-ux.mjs — a browser tab that IS a compute node.
///
/// The headline e2e: two identities, two pages, one gateway. Alice signs
/// up, seats herself in a commune, offers a compute lane; Bob signs up,
/// submits an enveloped job, and claims it; Alice's page — through the
/// REAL compute-executor.js running in the REAL browser — fetches the
/// envelope, runs it in its Worker sandbox, and countersigns the receipt.
/// The registry marks the claim complete, and the lend face shows it.
///
/// No mocks anywhere in the path: the KERI ceremonies are the gateway's,
/// the doors are the deployed compute doors, the executor is the shipped
/// browser module.
///
/// Run:  PLAYNET_SEED_DEMO=1 bash tests/ux/ux-full.sh tests/ux/lend-ux.mjs
///       make test-lend-ux

import { harness, launch, newPage, sleep, summarize, installSeamHook } from './ux-harness.mjs';
import { signupIdentity, dialScope, offerHours, connectDial, createIdentity, putAway } from './probe-lib.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';

const h = harness();
const browser = await launch();

const until = async (fn, ms = 30000) => {
  const dl = Date.now() + ms;
  let v;
  while (Date.now() < dl) { v = await fn(); if (v) return v; await sleep(500); }
  return v;
};

// call a compute handler through the live session seam — the same call
// the face makes, so a wire-level check and a UI-level check share a path
const H = (page, name, ...args) => page.evaluate(async ({ name, args }) => {
  const fn = window.__seam?.handlers?.[name];
  if (!fn) return 'err:no-handler';
  try { return await fn(...args); } catch (e) { return 'err:' + e.message; }
}, { name, args });

const membersOf = async (page) =>
  page.evaluate(async () => {
    const sc = await import('./app/scope.js');
    return sc.scopesSig?.() ?? [];
  });

try {
  // ── two identities, two pages, one commune ──────────────────────────────
  const alice = await newPage(browser, h);
  const aliceAid = await signupIdentity(alice, h, BASE, 'alice');

  // seat in a commune: dial the seeded demo scope (Bread town) — fall back
  // to any scope in the roster — and offer hours, the membership upsert.
  const scoped = await dialScope(alice, /bread/i).catch(() => 'no-match');
  const scope = scoped === 'no-match' || scoped.startsWith?.('threw')
    ? await dialScope(alice, /./) : scoped;
  h.rec('alice dialed a commune', scope === 'ok', scope);
  if (scope === 'ok') await offerHours(alice);

  const commune = await alice.evaluate(async () => {
    const sc = await import('./app/scope.js');
    return String(sc.scopeSig?.() ?? '');
  });
  h.rec('the commune has an aid', /^[DE][A-Za-z0-9_-]{43}$/.test(commune) || commune.length > 5, commune);

  const bob = await newPage(browser, h);
  const bobAid = await signupIdentity(bob, h, BASE, 'bob');
  let bScope = await dialScope(bob, new RegExp(commune, 'i')).catch(() => 'no-match');
  // the roster can lag a fresh seat; setScope accepts a scope id outright —
  // the same call the dial would have made — so dial by id when the list
  // hasn't caught up
  if (bScope !== 'ok')
    bScope = await bob.evaluate(async (id) =>
      String(await window.__seam.handlers.setScope(id).catch(e => 'threw:' + e)),
      commune).catch(() => 'no-match');
  h.rec('bob dialed the same commune', bScope === 'ok', bScope);
  if (bScope === 'ok') await offerHours(bob);

  // ── the book: alice offers a lane, bob submits a job ────────────────────
  const offerRes = await H(alice, 'computeOffer', commune, 'member', 'inference', 2, 'deterministic', '');
  const offerId = String(offerRes).replace(/^ok:/, '');
  h.rec('alice offers an inference lane',
        typeof offerRes === 'string' && offerRes.startsWith('ok:'),
        JSON.stringify(offerRes));

  const env = { bridgeJobId: 'bj-ux-1', image: 'js:work',
                entrypoint: '(input) => input * 2', inputHash: 'in:ux1',
                caps: [], network: false };
  const jobRes = await H(bob, 'computeSubmit', commune, 'inference', 'member',
                         'deterministic', 'in:ux1',
                         JSON.stringify({ envelope: env, envelopeHash: 'eh:ux1' }));
  const jobId = String(jobRes).replace(/^ok:/, '');
  h.rec('bob submits the enveloped job',
        typeof jobRes === 'string' && jobRes.startsWith('ok:'),
        JSON.stringify(jobRes));

  // alice — the LENDER — claims bob's job under her offer; the door binds
  // the claim's lender side to the caller, so a claim from the borrower is
  // rightly refused
  const offers = await H(alice, 'computeOffers', commune);
  const jobRows = await H(bob, 'computeJobs', commune);
  const claimRes = await H(alice, 'computeClaim', commune, jobId, offerId, '');
  const claimId = String(claimRes).replace(/^ok:/, '');
  h.rec('the claim binds bob\'s job to alice\'s offer',
        typeof claimRes === 'string' && claimRes.startsWith('ok:'),
        JSON.stringify(claimRes));
  // the borrower accepts — the borrower-side door
  await H(bob, 'computeAccept', commune, claimId);

  // ── the node: alice's page runs the envelope for real ───────────────────
  const fetched = await H(alice, 'computeFetchEnvelope', commune, claimId);
  let envBack = fetched;
  try { envBack = typeof fetched === 'string' ? JSON.parse(fetched) : fetched; }
  catch { envBack = { __raw: fetched }; }
  h.rec('alice fetches the envelope her tab will run',
        envBack?.image === 'js:work', JSON.stringify(envBack).slice(0, 120));
  if (envBack?.__raw) h.info('spine trace tail: ' + JSON.stringify(
    h.logs.filter(l => /fetch-env|day-boot/.test(l)).slice(-8)));

  const run = await alice.evaluate(async ({ env }) => {
    const ex = await import('/app/compute-executor.js');
    return ex.runEnvelope(env, 21);
  }, { env: envBack });
  h.rec('the browser executor ran the job', run?.result === 42,
        JSON.stringify(run));

  // countersign: emitReceipt + computeReceipt through the session
  const rcpt = await alice.evaluate(async ({ env, run, lender, claimId }) => {
    const ex = await import('/app/compute-executor.js');
    return ex.emitReceipt({ env, lenderDid: lender, result: run.result,
                            seconds: run.seconds, bridgeJobId: claimId,
                            reproMode: 'deterministic', seed: 0 });
  }, { env: envBack, run, lender: aliceAid, claimId });
  const rcptRes = await H(bob, 'computeReceipt', commune, JSON.stringify(rcpt));
  h.rec('the receipt lands', !String(rcptRes).startsWith('err:'), String(rcptRes).slice(0, 120));

  // ── the book reflects it ────────────────────────────────────────────────
  const claims = await H(bob, 'computeClaims', commune);
  let rows = claims;
  try { rows = typeof claims === 'string' ? JSON.parse(claims) : claims; }
  catch { rows = [{ __raw: claims }]; }
  const ours = (rows || []).find(r => r.id === claimId);
  h.rec('the claim reads complete on the book', ours?.state === 'complete',
        JSON.stringify(ours).slice(0, 160));

  // ── the face shows it ───────────────────────────────────────────────────
  await alice.goto(`${BASE}/app.html?face=lend&_=${Date.now()}`,
                   { waitUntil: 'load' });
  await sleep(6000);
  const face = await alice.evaluate(() =>
    document.getElementById('lendstage')?.textContent ?? '');
  h.rec('the lend face renders the lane and the claim',
        /lend compute|offer|claim/i.test(face), face.slice(0, 120));

  h.rec('no page errors during the flow', h.errs.length === 0,
        h.errs.slice(0, 2).join(' | '));
} catch (e) {
  h.rec('fatal', false, e.message);
} finally {
  await browser.close();
}

summarize(h);
