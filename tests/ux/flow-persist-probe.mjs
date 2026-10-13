/// tests/ux/flow-persist-probe.mjs — one-off LIVE probe (not a suite):
/// against a running gateway (make dev), walk the signed-in citizen's
/// commitment arc and prove BOTH halves of it:
///
///   reactive  — willing / commit land on the gateway and the REFRESHED
///               snapshot echoes them back (the wire, not the optimistic flip)
///   durable   — a page RELOAD + passcode unlock brings the same state back:
///               willingness, the commitment, availability
///
/// Run via:  GATEWAY_SREF_FILE=.dev-data/gateway-sref.txt GATEWAY_PORT=9099 \
///           guix shell -L deploy/guix -m deploy/manifests/browser-test-manifest.scm -- \
///             sh tests/ux/ux-run.sh tests/ux/flow-persist-probe.mjs
import { harness, launch, newPage, sleep, summarize } from './ux-harness.mjs';
import { connectDial, createIdentity, revealedPasscode, putAway, dialScope, offerHours, redial } from './probe-lib.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';
const h = harness();
const browser = await launch();
const page = await newPage(browser, h);

// One read of everything this probe cares about, all from the browser's own
// modules — the same state the calendar paints from.
const state = () => page.evaluate(async () => {
  const { evs, proposals, eligible, sched, offered } = await import('./app/events.js');
  const sc = await import('./app/scope.js');
  const snap = window.__seam?.data?.snapshot || {};
  const willingIntents = (snap.intents || [])
    .filter(i => (i['willing-workers'] || i.willing || []).length)
    .map(i => ({ id: i.id, spec: i.spec, willing: (i['willing-workers'] || i.willing || []) }));
  return {
    scope: sc.scopeSig?.() ?? '',
    who: (document.querySelector('#idrow .who')?.textContent ?? '').slice(0, 60),
    evs: evs.length, props: proposals.length, open: eligible.length, sched: sched.length,
    demo: evs.slice(0, 8).map(e => e.label).some(t => /bakery shift w\/ Sam/.test(t ?? '')),
    offered: [...offered],
    committed: evs.filter(e => e.mine || /commit/i.test(String(e.status ?? '')))
                  .slice(0, 6).map(e => `${e.label}|${e.vfId ?? e.id ?? ''}`),
    intents: (snap.intents || []).length,
    willingIntents: willingIntents.slice(0, 6),
    propSample: proposals.slice(0, 6).map(p =>
      ({ label: p.label, vfId: p.vfId, spec: p.spec, cell: p.cell, scope: p.scope,
         ...(p.offer ? { offer: true } : {}), ...(p.social ? { social: true } : {}) })),
    openSample: eligible.slice(0, 4).map(p =>
      ({ label: p.label, vfId: p.vfId, spec: p.spec, cell: p.cell, scope: p.scope })),
  };
});

try {
  // ── the opening mile ─────────────────────────────────────────────────────
  const chip = await connectDial(page, BASE);
  h.rec('dial connects to the gateway', /create your identity|sign in/i.test(chip), chip);
  const s0 = await state();
  h.info('anonymous: ' + JSON.stringify({ evs: s0.evs, demo: s0.demo, scope: s0.scope }));

  const aid = await createIdentity(page, h, '', true);
  // the reveal card shows the generated passcode exactly once — keep it for
  // the reload half
  const passcode = await revealedPasscode(page);
  await putAway(page);
  h.rec('passcode revealed (kept for re-unlock)', passcode.length >= 21,
        `${passcode.length} chars`);
  const k0 = await page.evaluate(() =>
    (localStorage.getItem('pn.id.hint') || '').split('|')[3] || '');

  const dialed = await dialScope(page, /./);
  h.rec('a commune answers the dial', dialed === 'ok', String(dialed));
  // the user's own door writes the device memory (pn.scope) — take it too,
  // so the reload half exercises the auto-recall
  await page.evaluate(async () => {
    const sc = await import('./app/scope.js');
    sc.goToScope(sc.scopeSig());
  });
  await sleep(4000);
  h.info('avail: ' + await offerHours(page));

  // ── make the day non-empty: real demand through the share door ───────────
  const demand = await page.evaluate(async () => {
    const { RECIPE_BY_ID, recipeOutSpec } = await import('./app/recipe-graph.js');
    const rs = Object.values(RECIPE_BY_ID);
    const workOf = r => Math.max(0, ...(r.steps || []).map(st => +(st.hours || 0)));
    const withWork = rs.filter(r => workOf(r) > 0).sort((a, b) => workOf(b) - workOf(a))[0];
    const spec = (withWork && recipeOutSpec(withWork)) || rs.map(recipeOutSpec).find(Boolean);
    if (!spec) return { spec: null };
    const locs = (window.__seam.data?.snapshot?.locations || []).map(L => L.id);
    const at = locs.find(l => /venue/.test(l)) || locs[0] || '';
    // modest: more than any standing stock of the OUTPUT (so the solve must
    // produce) but far from the input stock's fragility wall
    const declared = await window.__seam.handlers
      .declareNeed(spec, '24', 'each', at, '', '', '', '', '', '', '', '')
      .catch(e => 'threw:' + e);
    const solved = await window.__seam.handlers.solve('{}').catch(e => 'threw:' + e);
    return { spec, at, declared: String(declared).slice(0, 60), solve: String(solved).slice(0, 120) };
  });
  h.info('demand: ' + JSON.stringify(demand));
  await redial(page); await sleep(4000);

  let s = await state();
  h.info('signed-in: ' + JSON.stringify(s));
  h.rec('the plan arrives from the wire (demo day replaced)', !s.demo,
        `evs=${s.evs} props=${s.props} open=${s.open} sched=${s.sched}`);

  // ── WILLING: the seam call, then the wire's echo ─────────────────────────
  // pick anything with a spec — an open shift first, else a proposal
  const slot = s.openSample.find(p => p.spec) || s.propSample.find(p => p.spec);
  let wid = '';
  if (slot) {
    const r = await page.evaluate(async (slot) => {
      const w = await import('./app/willingness.js');
      const wid = w.widOf(slot);
      const reply = await window.__seam.handlers
        .willing(slot.scope || '', slot.spec, slot.cell || '', true)
        .catch(e => 'threw:' + e);
      return { wid, reply: String(reply) };
    }, slot);
    wid = r.wid;
    h.rec('willing lands on the gateway (seam ok)', /^ok/.test(r.reply),
          `${slot.spec} → ${r.reply}`);
    await redial(page); await sleep(4000);
    s = await state();
    h.rec('willingness echoes back on the WIRE (offered rebuilt from snapshot)',
          s.offered.includes(wid) && s.willingIntents.length > 0,
          JSON.stringify({ offered: s.offered, willingIntents: s.willingIntents }));
  } else {
    h.rec('willing lands on the gateway (seam ok)', false, 'no slot with a spec to offer on');
  }

  // ── the DIRECTED OFFER arc: every solve presents; an offer directed at
  // us rides the snapshot's proposals with offer:true and its work terms.
  // Enter the race the way a citizen would — declare the skill, raise the
  // hand for it — so the materialization suggests US and the presentation's
  // rank directs the offer here rather than at the seeded Baker.
  const entered = await page.evaluate(async () => {
    const sc = await import('./app/scope.js');
    const H = window.__seam.handlers;
    const skill = await H.declareSkill('baking').catch(e => 'threw:' + e);
    const will  = await H.willing(sc.scopeSig() || '', 'baking', 'venue-granary@0', true)
      .catch(e => 'threw:' + e);
    return { skill: String(skill).slice(0, 40), will: String(will).slice(0, 40) };
  });
  h.info('entered the race: ' + JSON.stringify(entered));
  await page.evaluate(async () =>
    String(await window.__seam.handlers.solve('{}').catch(e => 'threw:' + e)));
  await redial(page); await sleep(4000);
  s = await state();
  const offerRow = s.propSample.find(p => p.offer);
  h.info('after presenting solve: ' + JSON.stringify(s.propSample));
  if (offerRow) {
    h.rec('a directed work offer reaches the snapshot (offer:true, spec carried)',
          !!offerRow.spec, JSON.stringify(offerRow));
    const acc = await page.evaluate(async (p) =>
      String(await window.__seam.handlers.acceptWorkOffer(p.scope || '', p.vfId)
        .catch(e => 'threw:' + e)), offerRow);
    h.rec('accept-work-offer lands (the bounded rung promotes)', /^ok/.test(acc), acc);
    await redial(page); await sleep(4000);
    s = await state();
    h.rec('the accepted offer echoes back as a commitment',
          JSON.stringify(s.committed).includes('offer:') ||
          s.props < 1 + (s.propSample.filter(p => p.offer).length),
          JSON.stringify(s.committed));
  } else {
    h.info('no offer directed at this AID (the matcher chose another member — the seeded Baker)');
  }

  // ── COMMIT: accept a proposal, wire echo ─────────────────────────────────
  const prop = process.env.NO_COMMIT ? null :
               (s.propSample.find(p => p.vfId) ||
                (await state()).openSample.find(p => p.vfId));
  let committedId = '';
  if (prop) {
    const reply = await page.evaluate(async (p) =>
      String(await window.__seam.handlers.commit(p.scope || '', p.vfId)
        .catch(e => 'threw:' + e)), prop);
    h.rec('commit lands on the gateway (seam ok)', /^ok/.test(reply),
          `${prop.label} (${prop.vfId}) → ${reply}`);
    const before = s.committed;
    await redial(page); await sleep(4000);
    s = await state();
    // the intent became a commitment: its row is NEW in the committed list,
    // under the commitment's own id — that row is what must survive
    committedId = s.committed.find(c => !before.includes(c)) || '';
    h.rec('the commitment echoes back on the WIRE (new committed row)',
          committedId !== '', JSON.stringify(s.committed));
  } else {
    h.info('no proposal with a vfId to commit — commit half skipped: ' +
           JSON.stringify({ props: s.propSample, open: s.openSample }));
  }

  // ── RELOAD: the durable half ─────────────────────────────────────────────
  const scopeBefore = s.scope, offeredBefore = s.offered;
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 60000 });
  await sleep(6000);
  const hint2 = await page.evaluate(() =>
    (localStorage.getItem('pn.id.hint') || '').split('|')[0]);
  h.rec('after reload the identity hint survives', hint2 === aid, hint2);

  const unlock = await page.evaluate(async ({ passcode, aid, k0 }) =>
    String(await (window.__seam.handlers.unlock
      ? window.__seam.handlers.unlock(passcode, aid, k0)
      : 'err:no-unlock-handler')).slice(0, 60), { passcode, aid, k0 });
  h.rec('unlock with the kept passcode', /^ok/.test(unlock), unlock);

  // NO manual dial: the roster's arrival recalls the remembered commune
  let recalledScope = '';
  for (const dl = Date.now() + 60000; Date.now() < dl;) {
    recalledScope = await page.evaluate(async () =>
      (await import('./app/scope.js')).scopeSig() ?? '');
    if (recalledScope) break;
    await sleep(2000);
  }
  h.rec('the remembered commune re-dials itself after reload',
        recalledScope === scopeBefore, `${scopeBefore} → ${recalledScope}`);
  await sleep(5000); await redial(page); await sleep(4000);

  const s2 = await state();
  h.info('after reload: ' + JSON.stringify(s2));
  h.rec('after reload the plan is the WIRE\'s (not the demo day)', !s2.demo,
        `evs=${s2.evs}`);
  // committing the intent CONSUMES it (need → commitment), so the hand
  // raised on it has nothing left to stand on — the willing gate is the
  // NO_COMMIT run's question
  if (wid && !committedId)
    h.rec('willingness SURVIVES the reload (offered rebuilt from the wire)',
          s2.offered.includes(wid),
          JSON.stringify({ before: offeredBefore, after: s2.offered }));
  if (committedId)
    h.rec('the commitment SURVIVES the reload',
          s2.committed.some(c => c.includes(committedId)) ||
          JSON.stringify(s2).includes(committedId),
          JSON.stringify(s2.committed));
  h.rec('the scope survives (same commune redialable)',
        s2.scope === scopeBefore, `${scopeBefore} → ${s2.scope}`);

  // leave the dev state tidy: retire the probe's standing need
  if (demand && demand.spec) {
    const retired = await page.evaluate(async spec =>
      String(await window.__seam.handlers.retireNeed(spec).catch(e => 'threw:' + e)),
      demand.spec);
    h.info('need retired: ' + retired.slice(0, 60));
    // …and the hands come down: a probe's willingness withdrawn, so the
    // races it joined stand as it found them
    const withdrew = await page.evaluate(async (spec) => {
      const sc = await import('./app/scope.js');
      const H = window.__seam.handlers;
      const a = await H.willing(sc.scopeSig() || '', spec, 'venue-granary@0', false)
        .catch(e => 'threw:' + e);
      const b = await H.willing(sc.scopeSig() || '', 'baking', 'venue-granary@0', false)
        .catch(e => 'threw:' + e);
      return `${a}/${b}`;
    }, demand.spec);
    h.info('willingness withdrawn: ' + withdrew);
  }
  await page.screenshot({ path: process.env.PROBE_SHOT || '/tmp/day-flow-persist.png' });
} catch (e) {
  h.rec('fatal', false, e.message);
  h.info('console: ' + JSON.stringify(h.logs.slice(-15)));
} finally { await browser.close(); }

summarize(h, ['dial connects to the gateway']);
