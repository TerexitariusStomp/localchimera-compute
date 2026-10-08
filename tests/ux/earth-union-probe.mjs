/// tests/ux/earth-union-probe.mjs — LIVE probe: EARTH IS THE UNION.
///
/// The day is the fold over every membership: each commune's snapshot rides
/// in scope-tagged, the dialed scope facets the union down to its own rows,
/// and earth (scope null) is the union standpoint — everything relevant to
/// you across the federation, on one day. A citizen who holds a skill in
/// TWO communes sees both fields at earth, and exactly one when dialed in.
///
/// Run via:  GATEWAY_SREF_FILE=.dev-data/gateway-sref.txt GATEWAY_PORT=9099 \
///           guix shell -L deploy/guix -m deploy/manifests/browser-test-manifest.scm -- \
///             sh tests/ux/ux-run.sh tests/ux/earth-union-probe.mjs
import { harness, launch, newPage, sleep, summarize } from './ux-harness.mjs';
import { connectDial, createIdentity } from './probe-lib.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';
const h = harness();
const browser = await launch();
const page = await newPage(browser, h);

// the day's row arrays, with the scope tag each row carries
const rows = () => page.evaluate(async () => {
  const { evs, proposals, eligible } = await import('./app/events.js');
  const sc = await import('./app/scope.js');
  const all = [...evs, ...proposals, ...eligible];
  return {
    at: sc.scopeSig?.() ?? null,
    n: all.length,
    scopes: [...new Set(all.map(e => e.scope).filter(Boolean))].sort(),
  };
});

const dial = (sid) => page.evaluate(async (sid) => {
  const sc = await import('./app/scope.js');
  sc.goToScope(sid);
}, sid);

// stand in a commune: declare the skill its work asks for, re-solve so the
// open shifts re-persist with you among the candidates
const enter = (sid, skill) => page.evaluate(async ({ sid, skill }) => {
  const sc = await import('./app/scope.js');
  sc.goToScope(sid);
  await new Promise(r => setTimeout(r, 1200));
  const H = window.__seam.handlers;
  const s = await H.declareSkill(skill).catch(e => 'threw:' + e);
  const v = await H.solve('{}').catch(e => 'threw:' + e);
  return { skill: String(s).slice(0, 20), solve: String(v).slice(0, 20) };
}, { sid, skill });

// stand in a commune the other way: declare a NEED of your own there — your
// own card, whatever the commune's work windows are doing
const needIn = (sid, spec) => page.evaluate(async ({ sid, spec }) => {
  const sc = await import('./app/scope.js');
  sc.goToScope(sid);
  await new Promise(r => setTimeout(r, 1200));
  const H = window.__seam.handlers;
  const r = await H.declareNeed(spec, '2', 'each', '', '', '', '', '', '', '',
                                '', '', '', '').catch(e => 'threw:' + e);
  return String(r).slice(0, 20);
}, { sid, spec });

try {
  await connectDial(page, BASE);
  await createIdentity(page, h);
  await sleep(6000);   // let every membership's snapshot fold in

  // the union is on the wire regardless of anyone's skills: the raw snapshot
  // carries intents from more than one commune
  const raw = await page.evaluate(() => {
    const sn = window.__seam?.data?.snapshot || {};
    return [...new Set((sn.intents || []).map(i => i.scope).filter(Boolean))].sort();
  });
  h.info('wire scopes: ' + JSON.stringify(raw));
  h.rec('the wire snapshot is the union (intents from >1 commune)',
        raw.length >= 2, JSON.stringify(raw));

  // the citizen stands in TWO communes: a skill in SF (an eligible shift),
  // a declared need in Berlin (their own card) — Berlin's festival windows
  // sit in the durable scope's past, so the closed-window guard rightly
  // lays it no open shifts until horizon-starts-now lands
  h.info('sf: ' + JSON.stringify(await enter('E_commune_SF', 'gardening')));
  h.info('berlin need: ' + JSON.stringify(await needIn('E_commune_Berlin', 'salad')));
  await sleep(5000);   // both refolds land, snapshots refresh

  // dialed in, the facet narrows to the one commune
  await dial('E_commune_Berlin'); await sleep(2500);
  const berlin = await rows();
  h.info('dialed berlin: ' + JSON.stringify(berlin));
  h.rec('a dialed commune shows only its own rows (the facet)',
        berlin.n > 0 && berlin.scopes.every(s => s === 'E_commune_Berlin'),
        JSON.stringify(berlin));

  await dial('E_commune_SF'); await sleep(2500);
  const sf = await rows();
  h.info('dialed sf: ' + JSON.stringify(sf));
  h.rec('the other commune facets to itself the same way',
        sf.scopes.every(s => s === 'E_commune_SF'),
        JSON.stringify(sf));

  // earth: the union — both memberships' rows stand together on one day
  await dial(null); await sleep(2500);
  const earth = await rows();
  h.info('earth: ' + JSON.stringify(earth));
  h.rec('earth is the union standpoint (rows from both communes)',
        earth.scopes.includes('E_commune_Berlin')
        && earth.scopes.includes('E_commune_SF')
        && earth.n >= berlin.n && earth.n >= sf.n,
        JSON.stringify(earth));
  await page.screenshot({ path: process.env.PROBE_SHOT || '/tmp/day-earth-union.png' });
} catch (e) {
  h.rec('fatal', false, e.message);
  h.info('console: ' + JSON.stringify(h.logs.slice(-12)));
} finally { await browser.close(); }

summarize(h, ['the wire snapshot is the union (intents from >1 commune)']);
