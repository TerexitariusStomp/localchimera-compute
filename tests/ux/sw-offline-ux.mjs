/// tests/ux/sw-offline-ux.mjs — the service worker's three promises, in a real
/// browser: the dial boots with the network gone, a page stays on the build it
/// booted on until it chooses to move, and a deploy leaves other caches alone.
///
/// Every other suite runs WITHOUT the worker (a loopback http origin is
/// live-editing, app/pwa.ts isDev), so nothing else can see these. This one
/// serves a stamped copy of browser/ on `dial.localhost` — loopback to the
/// engine, a secure context, and a production origin to isDev. The tree it
/// serves is a scratch one, re-stamped mid-run to stand for a deploy.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

// a scratch copy of the served tree; the Explorer and the dev symlinks stay behind
const tree = fs.mkdtempSync(path.join(os.tmpdir(), 'sw-offline-'));
const SKIP = new Set(['.dev', 'radicle']);
fs.cpSync('browser', tree, { recursive: true, dereference: true,
                             filter: (src) => !SKIP.has(path.basename(src)) });
const stamp = () => execFileSync('bash', ['tools/emit/sw-stamp.sh', tree], { encoding: 'utf8' }).trim();
const build1 = stamp();
// a sub-app the worker passes through changes: the dial's stamp stands
fs.writeFileSync(path.join(tree, 'boards', 'changed.txt'), 'a boards deploy');
const afterBoards = stamp();
// a server route that looks like a file. It appears after the stamp, as a
// route does, so it is under none of the tree's roots.
fs.mkdirSync(path.join(tree, 'tiles/sat/1/0'), { recursive: true });
fs.copyFileSync('browser/assets/icons/icon-192.png', path.join(tree, 'tiles/sat/1/0/0.png'));
const { base: BASE, close: closeServer } = await serveBrowser({
  root: tree, index: 'app.html', host: 'dial.localhost',
  // the static rule the real server sends, so the worker's revalidating
  // fetches are what keeps a build's cache its own
  headers: (p) => ({ 'cache-control': p === '/sw.js' ? 'no-store' : 'public, max-age=3600' }),
});

const h = harness();
const browser = await launch([`--host-resolver-rules=MAP dial.localhost 127.0.0.1`]);
const ctx = await browser.newContext();
const page = await ctx.newPage();
const errs = []; page.on('pageerror', e => errs.push(String(e)));

const cacheNames = () => page.evaluate(() => caches.keys());
const cached = (name, url) => page.evaluate(async ([n, u]) => !!(await (await caches.open(n)).match(u)), [name, url]);
const booted = () => page.evaluate(async () => {
  const { stage } = await import('/app/stage.js');
  return { face: stage.face, svg: document.querySelectorAll('svg').length > 0 };
});

try {
  // ── first visit ──────────────────────────────────────────────────────────
  await page.goto(`${BASE}/app.html?face=time`, { waitUntil: 'load' });
  // install is all-or-nothing over the page's own files: give it a bound, and
  // say what the worker reported when it does not get there
  const installed = await page.evaluate(() => Promise.race([
    navigator.serviceWorker.ready.then(() => 'ready'),
    new Promise(r => setTimeout(async () => {
      const reg = await navigator.serviceWorker.getRegistration();
      r(`no active worker after 60 s (installing: ${reg?.installing?.state}, waiting: ${!!reg?.waiting})`);
    }, 60000)),
  ]));
  if (installed !== 'ready') throw new Error(installed);
  // a first worker claims the page once it activates; install ends when SHELL is in
  await page.waitForFunction(() => navigator.serviceWorker.controller != null, null, { timeout: 60000 });
  h.rec('a production origin registers the worker', true);
  h.rec('the build has its own cache', (await cacheNames()).includes(`playnet-${build1}`));
  h.rec('a change in a passed-through sub-app leaves the stamp', afterBoards === build1, `${build1} ${afterBoards}`);
  h.rec('what app.html’s tags load is in it, the map libraries too',
        await cached(`playnet-${build1}`, '/vendor/maplibre-gl.js') && await cached(`playnet-${build1}`, '/vendor/deck.gl.js')
        && await cached(`playnet-${build1}`, '/day-boot.js'));
  h.rec('the REPL page’s wasm is left for the REPL page', !(await cached(`playnet-${build1}`, '/repl.wasm')));
  const regions = await page.evaluate(async () => (await fetch('/tiles/osm/regions.json')).ok);
  h.rec('a server route is answered and stays out of the cache',
        regions && !(await cached(`playnet-${build1}`, '/tiles/osm/regions.json')));
  h.rec('the dial’s modules are in it', await cached(`playnet-${build1}`, '/app/main.js')
                                       && await cached(`playnet-${build1}`, '/app/tabs/calendar.js')
                                       && await cached(`playnet-${build1}`, '/spine-worker.js'));

  // one online load under the worker fills in what install leaves lazy (wasm, vendor)
  await page.reload({ waitUntil: 'networkidle' });
  await sleep(1500);
  await page.evaluate(async () => { await (await caches.open('transformers-cache')).put('/model', new Response('weights')); });

  // ── the network goes ─────────────────────────────────────────────────────
  await ctx.setOffline(true);
  errs.length = 0;
  await page.reload({ waitUntil: 'load' });
  await sleep(2500);
  const off = await booted().catch(e => ({ error: String(e) }));
  h.rec('offline, the dial boots', off.svg === true && !off.error, JSON.stringify(off));
  h.rec('offline, no module fails to load',
        !errs.some(e => /import|module|fetch/i.test(e)), errs.slice(0, 2).join(' | '));
  await ctx.setOffline(false);

  // ── a deploy lands while the page is open ────────────────────────────────
  fs.appendFileSync(path.join(tree, 'app/pwa.js'), '\n// a later build\n');
  const build2 = stamp();
  h.rec('a changed tree is a new build', build2 !== build1, `${build1} → ${build2}`);
  await page.evaluate(async () => { await (await navigator.serviceWorker.getRegistration()).update(); });
  // installing the new build fetches its whole shell; poll the registration
  // (waitForFunction takes a promise as a yes, so the wait is spelled out)
  const waitingNow = () => page.evaluate(async () => !!(await navigator.serviceWorker.getRegistration())?.waiting);
  for (let i = 0; i < 240 && !(await waitingNow()); i++) await sleep(500);
  const mid = await cacheNames();
  h.rec('the new build waits; both caches stand',
        mid.includes(`playnet-${build1}`) && mid.includes(`playnet-${build2}`), mid.join(' '));
  await page.waitForSelector('.toast-tap', { timeout: 10000 });
  h.rec('the page says a new version is ready',
        /new version/.test(await page.textContent('.toast-tap .toast-msg')));
  h.rec('and it stands on the identity chip once the card is gone',
        await page.evaluate(() => document.getElementById('idrow')?.classList.contains('wants') === true));
  const stillOld = await page.evaluate(async () => (await (await fetch('/app/pwa.js')).text()).includes('a later build'));
  h.rec('the open page still gets its own build’s modules', stillOld === false);

  // ── the page moves ───────────────────────────────────────────────────────
  await Promise.all([ page.waitForNavigation({ waitUntil: 'load', timeout: 30000 }),
                      page.click('.toast-tap .toast-msg') ]);
  await sleep(1000);
  const after = await cacheNames();
  h.rec('after the tap the page runs the new build',
        await page.evaluate(async () => (await (await fetch('/app/pwa.js')).text()).includes('a later build')));
  h.rec('the previous build’s cache is cleared',
        !after.includes(`playnet-${build1}`) && after.includes(`playnet-${build2}`), after.join(' '));
  h.rec('a cache the worker does not own survives the deploy', after.includes('transformers-cache'), after.join(' '));
} catch (e) { h.rec('fatal', false, e.message); }
finally {
  await browser.close(); closeServer();
  fs.rmSync(tree, { recursive: true, force: true });
}
summarize(h);
