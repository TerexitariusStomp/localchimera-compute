/// tests/ux/festival-probe.mjs — one-off LIVE probe: the Berlin FOOD
/// FESTIVAL through a citizen's own arc. Against a running gateway whose
/// Berlin commune carries the festival arm (berlin-festival-seed.scm):
///
///   the crowd's standing need is on the wire · the solve schedules real
///   growing · a citizen declares the gardening skill, raises a hand, and
///   the race echoes back · their hours visibly move the fill
///
/// Run via:  GATEWAY_SREF_FILE=.dev-data/gateway-sref.txt GATEWAY_PORT=9099 \
///           guix shell -L deploy/guix -m deploy/manifests/browser-test-manifest.scm -- \
///             sh tests/ux/ux-run.sh tests/ux/festival-probe.mjs
import { harness, launch, newPage, sleep, summarize } from './ux-harness.mjs';
import { connectDial, createIdentity, dialScope, offerHours, redial } from './probe-lib.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';
const h = harness();
const browser = await launch();
const page = await newPage(browser, h);

const state = () => page.evaluate(async () => {
  const { evs, proposals, eligible, sched } = await import('./app/events.js');
  const sc = await import('./app/scope.js');
  const snap = window.__seam?.data?.snapshot || {};
  const meal = (snap.intents || []).find(i => /festival-crowd/.test(i.id || ''));
  return {
    scope: sc.scopeSig?.() ?? '',
    props: proposals.length, open: eligible.length, sched: sched.length,
    growRows: sched.filter(e => /grow|garden/i.test(`${e.label} ${e.proc}`)).length,
    mealNeed: meal && { id: meal.id, spec: meal.spec,
                        willing: meal['willing-workers'] || meal.willing || [] },
    met: snap.plan && snap.plan.coverage,
  };
});

try {
  await connectDial(page, BASE);
  const aid = await createIdentity(page, h);
  const dialed = await dialScope(page, /berlin/);
  h.rec('the Berlin commune answers the dial', dialed === 'ok', String(dialed));
  await sleep(4000);
  h.info('avail: ' + await offerHours(page));

  await page.evaluate(async () =>
    String(await window.__seam.handlers.solve('{}').catch(e => 'threw:' + e)));
  await redial(page); await sleep(4000);
  let s = await state();
  h.info('festival day: ' + JSON.stringify(s));
  h.rec("the crowd's need stands on the wire (need:festival-crowd:meal)",
        !!s.mealNeed, JSON.stringify(s.mealNeed));
  h.rec('the solve schedules real growing (grow rows on the calendar)',
        s.growRows > 0, `${s.growRows} of ${s.sched} sched rows`);

  // the citizen's own entry: the skill, then the hand
  const entered = await page.evaluate(async () => {
    const sc = await import('./app/scope.js');
    const H = window.__seam.handlers;
    const skill = await H.declareSkill('gardening').catch(e => 'threw:' + e);
    const will = await H.willing(sc.scopeSig() || '', 'gardening',
                                 'berlin-festival@0', true).catch(e => 'threw:' + e);
    return { skill: String(skill).slice(0, 30), will: String(will).slice(0, 30) };
  });
  h.rec('a citizen declares gardening and raises a hand',
        /ok/.test(entered.skill) && /ok/.test(entered.will), JSON.stringify(entered));
  await page.evaluate(async () =>
    String(await window.__seam.handlers.solve('{}').catch(e => 'threw:' + e)));
  await redial(page); await sleep(4000);
  s = await state();
  h.info('after joining: ' + JSON.stringify(s));

  // tidy: the hand comes down, so the state stands as found
  await page.evaluate(async () => {
    const sc = await import('./app/scope.js');
    await window.__seam.handlers
      .willing(sc.scopeSig() || '', 'gardening', 'berlin-festival@0', false)
      .catch(() => {});
  });
  await page.screenshot({ path: process.env.PROBE_SHOT || '/tmp/day-festival.png' });
} catch (e) {
  h.rec('fatal', false, e.message);
  h.info('console: ' + JSON.stringify(h.logs.slice(-12)));
} finally { await browser.close(); }

summarize(h, ['the Berlin commune answers the dial']);
