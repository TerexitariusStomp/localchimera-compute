/// tests/ux/route-data-ux.mjs — the page's own /route traffic, end to end
/// through a real browser's fetch: the preview's four mode asks go out at once
/// (transit with its clock), alternates are requested and read, an engine that
/// is down reads as no route in every mode, and the app still boots with the
/// journey module standing on the shared reader.
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';
import { stubRoute } from './route-stub.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();
const h = harness();
const browser = await launch();
const page = await browser.newPage();
const errs = [];
page.on('pageerror', e => errs.push(String(e)));
await page.setViewportSize({ width: 1400, height: 900 });

const A = { lat: 37.7749, lng: -122.4194 }, B = { lat: 37.7849, lng: -122.4094 };
const ask = (args) => page.evaluate(async ({ A, B, args }) => {
  const m = await import('/app/route/data.js');
  m.clearRouteCache();
  const out = await m[args.fn](A, B, ...args.rest);
  const sum = r => ({ costing: r.costing, s: r.s, km: +r.km.toFixed(3), mans: r.mans.length,
                      transit: r.mans.filter(x => x.transit).map(x => x.transit.line) });
  return Array.isArray(out) ? out.map(sum)
    : Object.fromEntries(Object.entries(out).map(([k, v]) => [k, v.map(sum)]));
}, { A, B, args });

try {
  const stub = await stubRoute(page);
  await page.goto(`${BASE}/app.html?face=map`, { waitUntil: 'domcontentloaded' });
  await sleep(1500);
  h.rec('the app boots with the journey module on the shared reader', errs.length === 0, errs.slice(0, 2).join(' | '));

  const tabs = await ask({ fn: 'fetchModes', rest: [] });
  h.rec('the preview asks four modes, once each, all at once', stub.calls.length === 4, stub.calls.join('\n'));
  h.rec('transit is asked first, with its clock', /profile=multimodal/.test(stub.calls[0]) && /depart=now/.test(stub.calls[0]), stub.calls[0]);
  h.rec('every tab has a route', Object.values(tabs).every(r => r.length === 1), JSON.stringify(tabs));
  h.rec('the transit route names its line', tabs.multimodal[0].transit.join() === '48');
  h.rec('walk is slower than bike is slower than drive',
        tabs.pedestrian[0].s > tabs.bicycle[0].s && tabs.bicycle[0].s > tabs.auto[0].s);

  stub.calls.length = 0;
  const alts = await ask({ fn: 'fetchRoutes', rest: ['bicycle', { alternates: 2 }] });
  h.rec('alternates are asked for and read', alts.length === 3 && /alternates=2/.test(stub.calls[0]), JSON.stringify(alts.map(r => r.s)));
  h.rec('the alternates are the longer ways', alts[1].s > alts[0].s && alts[2].s > alts[1].s);

  await page.unroute(/\/route\?/);
  const down = await stubRoute(page, { down: true });
  const none = await ask({ fn: 'fetchModes', rest: [] });
  h.rec('an engine that answers nothing reads as no route in every mode',
        Object.keys(none).length === 4 && Object.values(none).every(r => r.length === 0), JSON.stringify(none));
  h.rec('…each mode still asked', down.calls.length === 4);
} catch (e) { h.rec('fatal', false, e.message); }
h.rec('no page errors', errs.length === 0, errs.slice(0, 2).join(' | '));
await browser.close(); closeServer();
summarize(h);
