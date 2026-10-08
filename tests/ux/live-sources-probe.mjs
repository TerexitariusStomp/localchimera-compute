/// tests/ux/live-sources-probe.mjs — one-off LIVE probe (not a suite): against
/// a running gateway, walk the real user journey (connect → create identity →
/// auto-dial the first commune) and report which of the calendar's eight
/// sources the WIRE actually fills — evs/props/open/sched/lived from the
/// snapshot, needs/avail/mine from the browser's own stores.
///
/// Run via:  make probe-live-sources   (needs `make dev` running)
///             guix shell -m deploy/manifests/browser-test-manifest.scm -- \
///             sh tests/ux/ux-run.sh tests/ux/live-sources-probe.mjs
import { harness, launch, newPage, sleep, summarize } from './ux-harness.mjs';
import { connectDial, createIdentity, dialScope } from './probe-lib.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';

const h = harness();
const browser = await launch();
const page = await newPage(browser, h);

const sources = () => page.evaluate(async () => {
  const { evs, proposals, eligible, sched, lived } = await import('./app/events.js');
  const sc = await import('./app/scope.js');
  const roster = (sc.scopesSig?.() ?? []).map(s => `${s.id}:${s.name}`);
  const scope = `${sc.scopeSig?.() ?? ''} of [${roster.join(', ')}]`;
  return {
    evs: evs.length, props: proposals.length, open: eligible.length,
    sched: sched.length, lived: lived.length,
    schedSample: sched.slice(0, 3).map(e => `${e.action ?? 'work'} ${e.label ?? ''} d${e.doy}@${e.t0}`),
    // a refined (sub-day) schedule carries clock moments: material rows keep
    // `when` verbatim, and any row off the 9:00 date-only fallback proves it
    clocked: sched.some(e => /T\d\d:\d\d/.test(String(e.when ?? '')) || (e.t0 != null && e.t0 !== 9)),
    livedSample: lived.slice(0, 3).map(e => `${e.label} d${e.doy}`),   // the label IS the what (action rides its own field)
    evsSample: evs.slice(0, 3).map(e => e.label),
    scope,
  };
});

try {
  const chip = await connectDial(page, BASE);
  h.rec('dial connects to the gateway', /create your identity|sign in/i.test(chip), chip);

  const demoBefore = await sources();
  h.info('anonymous (demo) sources: ' + JSON.stringify(demoBefore));

  await createIdentity(page, h);

  // signed in: dial the Berlin commune — the live-seeded ecoregional scope
  // with a real farm and recipes — the way the crumb switcher would
  let s = demoBefore;
  const dialed = await dialScope(page, /berlin/);
  h.rec('the Berlin commune answers the dial', dialed === 'ok', String(dialed));
  await sleep(4000);   // its snapshot (recipes, locations) replaces the day
  const solved = await page.evaluate(async () => {
    const sc = await import('./app/scope.js');
    const id = sc.scopeSig?.();
    const r = await window.__seam.handlers.solve('{}').catch(e => 'threw:' + e);
    if (id) await window.__seam.handlers.setScope(id).catch(() => {});
    return { id, solve: String(r).slice(0, 120) };
  });
  h.info('solve: ' + JSON.stringify(solved));

  // An empty commune solves to an empty schedule — honest, but nothing to
  // verify. Give it real demand through the SAME door the share face uses:
  // declare a need for something the scope's recipe library can make, then
  // solve again and re-dial so the refreshed snapshot lands.
  const demand = await page.evaluate(async () => {
    const { RECIPE_BY_ID, recipeOutSpec } = await import('./app/recipe-graph.js');
    const sc = await import('./app/scope.js');
    const rs = Object.values(RECIPE_BY_ID);
    const shapes = rs.map(r => ({ id: r.id, produces: r.produces,
      steps: (r.steps || []).map(st => ({ h: st.hours, out: (st.out || []).map(f => f.spec) })) }));
    // prefer the recipe with the MOST work in it — a need filled from stock
    // schedules nothing, so pick the one the solve must labour for
    const workOf = r => Math.max(0, ...(r.steps || []).map(st => +(st.hours || 0)));
    const withWork = rs.filter(r => workOf(r) > 0)
      .sort((a, b) => workOf(b) - workOf(a))[0];
    const spec = (withWork && recipeOutSpec(withWork)) || rs.map(recipeOutSpec).find(Boolean);
    window.__probeShapes = shapes;
    if (!spec) return { spec: null, recipes: rs.map(r => r.id) };
    const avail = await window.__seam.handlers
      .setAvailability('[{"start":"08:00","end":"18:00"}]')
      .catch(e => 'threw:' + e);
    // declare WHERE the share face would: at one of the scope's real places
    const locs = (window.__seam.data?.snapshot?.locations || []).map(L => L.id);
    const at = locs.find(l => /venue/.test(l)) || locs[0] || '';
    // more than any standing stock, so the solve must PRODUCE — a need met
    // from the granary alone schedules nobody and shows nothing
    const declared = await window.__seam.handlers
      .declareNeed(spec, '1000', 'each', at, '', '', '', '', '', '', '', '')
      .catch(e => 'threw:' + e);
    const solved2 = await window.__seam.handlers.solve('{}').catch(e => 'threw:' + e);
    await window.__seam.handlers.setScope(sc.scopeSig?.() ?? '').catch(() => {});
    return { spec, at, avail: String(avail).slice(0, 40), declared: String(declared).slice(0, 60),
             solve: String(solved2).slice(0, 200), shapes: shapes.slice(0, 6) };
  });
  h.info('demand: ' + JSON.stringify(demand));

  const dl = Date.now() + 90000;
  while (Date.now() < dl) {
    s = await sources();
    if (s.sched > 0) break;
    await sleep(2000);
  }
  h.info('signed-in sources: ' + JSON.stringify(s));
  h.rec('a commune is dialed (scope chip shows one)',
        !/no commune/i.test(s.scope), s.scope.slice(0, 60));
  h.rec('the plan arrives from the wire (evs replaced, not the demo day)',
        !s.evsSample.some(t => /bakery shift w\/ Sam/.test(t ?? '')),
        JSON.stringify(s.evsSample));
  h.rec('the schedule fills from the snapshot (wire-only source)',
        s.sched > 0, `${s.sched} rows: ${JSON.stringify(s.schedSample)}`);
  h.rec('the schedule is CLOCKED (sub-day refinement from the availability window)',
        s.clocked, JSON.stringify(s.schedSample));

  // ── the confirmation mile: LIVED ─────────────────────────────────────────
  // Record one material schedule row through the SAME door the calendar's
  // "✓ it happened" uses (recordFlow naming the row by its own id), and one
  // work event through the captain's-log door — the
  // lived layer must answer on the wire (snapshot `events` → the `lived`
  // calendar source).
  const recorded = await page.evaluate(async () => {
    const { sched } = await import('./app/events.js');
    const m = sched.find(e => e.spec && e.action && e.action !== 'work');
    const H = window.__seam.handlers;
    const flow = m
      ? await H.recordFlow('', m.action, m.specId || m.spec, String(m.qty || 1),
                           String(m.qty || 1), (m.loc && m.loc.id) || '',
                           String(m.when || ''), m.proc || '',
                           String(m.note || ''), m.rowId || '').catch(e => 'threw:' + e)
      : 'no material row';
    const work = await H.logObserve('work', 'farming', '2', 'hours',
                                    'probe: field work', '')
      .catch(e => 'threw:' + e);
    window.__probeWork = String(work);          // the witness arc reads the event id
    return { flow: String(flow).slice(0, 80), work: String(work).slice(0, 80) };
  });
  h.info('recorded: ' + JSON.stringify(recorded));
  const dlLived = Date.now() + 60000;
  while (Date.now() < dlLived) {
    s = await sources();
    if (s.lived > 0) break;
    await sleep(2000);
  }
  h.rec('the lived layer fills from the wire (recorded events return)',
        s.lived > 0, `${s.lived} rows: ${JSON.stringify(s.livedSample)}`);

  // ── the witness ceremony, from the browser ───────────────────────────────
  // Open a k-of-n co-signing ceremony over the recorded work event — the
  // gateway's witness door answers with the statement SAID peers will sign.
  // (Finalizing needs a second identity; the two-box harness proves that
  // half. The worker's own inbox stays empty by design — logged as info.)
  const witness = await page.evaluate(async () => {
    const H = window.__seam.handlers;
    const evId = (window.__probeWork || '').replace(/^ok:/, '');
    return { open: String(await H.witnessOpen('', evId).catch(e => 'threw:' + e)).slice(0, 80),
             inbox: String(await H.witnessInbox().catch(e => 'threw:' + e)).slice(0, 80) };
  });
  h.rec('a witness ceremony opens over the lived work (statement SAID returned)',
        /^ok:./.test(witness.open), JSON.stringify(witness));

  await page.screenshot({ path: process.env.PROBE_SHOT || '/tmp/day-live-sources.png',
                          fullPage: false });

  // leave the dev state as we found it: the probe's standing need retires,
  // so repeated runs don't pile dead-AID demand into .dev-data
  if (demand && demand.spec) {
    const retired = await page.evaluate(async spec =>
      String(await window.__seam.handlers.retireNeed(spec).catch(e => 'threw:' + e)),
      demand.spec);
    h.info('need retired: ' + retired.slice(0, 60));
  }
} catch (e) {
  h.rec('fatal', false, e.message);
  h.info('console: ' + JSON.stringify(h.logs.slice(-12)));
} finally { await browser.close(); }

summarize(h, ['dial connects to the gateway', 'identity created',
              'a commune is dialed (scope chip shows one)',
              'the schedule fills from the snapshot (wire-only source)',
              'the lived layer fills from the wire (recorded events return)',
              'a witness ceremony opens over the lived work (statement SAID returned)']);
