/// tests/ux/deployed-ux.mjs — e2e against the DEPLOYED site, not localhost.
///
/// Asserts the Cloudflare Pages deployment is functionally live: the pages
/// answer, the static assets land, the hoot-compiled wasms instantiate, the
/// dial shell renders its real DOM, and — when browser/entry-points.json
/// names a reachable gateway — the OCapN websocket actually connects.
///
/// DNS: this dev host's resolver cannot answer *.trycloudflare.com (the
/// quick-tunnel zone), so the suite maps the tunnel host through Chromium's
/// --host-resolver-rules. Real user DNS resolves it fine; the flag is a
/// local-test workaround, harmless elsewhere.
///
///   DEPLOYED_BASE=https://chimera-playnet.pages.dev \
///   NODE_PATH=<dir-with-playwright-core>/node_modules \
///   node tests/ux/deployed-ux.mjs

let pw;
for (const mod of ['playwright-core', 'playwright']) {
  if (pw) break;
  try { const m = await import(mod); pw = m.chromium ? m : m.default; } catch {}
}
if (!pw?.chromium) throw new Error("playwright-core not importable — set NODE_PATH");
const { chromium } = pw;

const BASE = (process.env.DEPLOYED_BASE || 'https://chimera-playnet.pages.dev').replace(/\/$/, '');
const TUNNEL_HOST = 'funky-capabilities-achievements-guitar.trycloudflare.com';
const TUNNEL_IP = '104.16.230.132';
const results = [];
const rec = (name, ok, detail = '') => {
  results.push({ name, ok });
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + String(detail).slice(0, 160) : ''}`);
};

const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM_PATH || undefined,
  args: [
    '--no-sandbox',
    `--host-resolver-rules=MAP ${TUNNEL_HOST} ${TUNNEL_IP}`,
  ],
});

try {
  const page = await browser.newPage();
  const responses = new Map();   // url → status
  page.on('response', r => responses.set(r.url(), r.status()));
  const pageErrors = [];
  const consoleLines = [];
  page.on('pageerror', e => pageErrors.push(String(e).slice(0, 160)));
  page.on('console', m => consoleLines.push(`${m.type()}: ${m.text()}`.slice(0, 200)));

  // ── the REPL/index page ──────────────────────────────────────────────
  const resp = await page.goto(`${BASE}/`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  rec('index page serves', resp && resp.status() < 400, `HTTP ${resp?.status()}`);
  rec('index carries the app title', (await page.title()).toLowerCase().includes('playnet'),
      await page.title());

  // give the module scripts a beat, then count what failed to load.
  // EXPECTED_ABSENT: the scope worker wasm and rns mesh glue are optional
  // build products (the page degrades to recorded answers / no mesh id),
  // and *.json endpoints are gateway-served at runtime.
  const EXPECTED_ABSENT = /scope\.wasm|rns_wasm|universal-commune\.json|operator\.json/;
  await page.waitForTimeout(3000);
  const expectedAbsent = [...responses.entries()]
    .filter(([u, s]) => s >= 400 && EXPECTED_ABSENT.test(u));
  const failedAssets = [...responses.entries()]
    .filter(([u, s]) => s >= 400 && !EXPECTED_ABSENT.test(u));
  rec('committed static assets all land (scripts, css, icons)', failedAssets.length === 0,
      failedAssets.map(([u, s]) => `${s} ${u.split('/').pop()}`).join(', ') || 'all <400');
  console.log(`  INFO  expected-absent (optional build products + gateway endpoints): ` +
              `${expectedAbsent.map(([u]) => u.split('/').pop()).join(', ') || 'none'}`);

  // repl.wasm IS deployed now — it must fetch AND instantiate, and the
  // page must not sit on the wasm-error branch.
  const wasmResp = [...responses.entries()].find(([u]) => u.includes('repl.wasm'));
  rec('repl.wasm serves from Pages', wasmResp && wasmResp[1] === 200,
      wasmResp ? `HTTP ${wasmResp[1]}` : 'never fetched');
  const wasmErrorShown = await page.locator('#wasm-error').isVisible().catch(() => false);
  rec('no wasm-error surface on the REPL page', !wasmErrorShown);

  // functional instantiation: repl.js calls Scheme.load_main("repl.wasm")
  // after logging "[gateway] sref:"/"[gateway] ws:". A successful boot then
  // drives the in-page terminal; watch the console for post-load activity.
  await page.waitForTimeout(12000);
  const gwSrefLogged = consoleLines.some(l => l.includes('[gateway] sref:'));
  const wasmRan = consoleLines.some(l =>
    /\[gateway\] ws:|load_main|wasm.*load|hoot|scheme/i.test(l));
  const schemeQuit = pageErrors.some(e => e.includes('SchemeQuitError'));
  rec('repl page reaches the wasm load (gateway log lines)', gwSrefLogged || wasmRan,
      consoleLines.filter(l => /gateway|wasm|scheme|repl/i.test(l)).slice(0, 3).join(' || ') || 'no boot console');
  console.log(`  INFO  repl console: ${consoleLines.slice(-6).join(' || ') || 'quiet'}`);

  // ── gateway connectivity: entry-points → wss → OCapN ─────────────────
  const ep = await page.evaluate(async () => {
    try { const r = await fetch('/entry-points.json'); return r.ok ? await r.json() : null; }
    catch { return null; }
  });
  rec('entry-points.json serves the live sref', !!(ep && ep.sref && ep.directWs),
      ep ? `sref=${(ep.sref || '').slice(0, 60)}…` : 'absent');

  // the real wire check: open the wss the site names, on this page's own
  // WebSocket stack, and confirm the gateway answers the upgrade.
  let wsOpen = false, wsErr = '';
  if (ep?.directWs) {
    const r = await page.evaluate(async (url) => {
      return await new Promise((resolve) => {
        const t = setTimeout(() => resolve({ open: false, err: 'timeout 15s' }), 15000);
        try {
          const w = new WebSocket(url);
          w.onopen = () => { clearTimeout(t); w.close(); resolve({ open: true }); };
          w.onerror = (e) => { clearTimeout(t); resolve({ open: false, err: 'ws error' }); };
        } catch (e) { clearTimeout(t); resolve({ open: false, err: String(e) }); }
      });
    }, ep.directWs);
    wsOpen = r.open; wsErr = r.err || '';
  }
  rec('gateway websocket reachable through the tunnel (ocapn upgrade)', wsOpen, wsErr || 'handshake ok');

  // ── the dial shell (/app) ────────────────────────────────────────────
  const resp2 = await page.goto(`${BASE}/app`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  rec('app page serves', resp2 && resp2.status() < 400, `HTTP ${resp2?.status()}`);

  // day-boot.wasm is fetched inside the spine worker, where page.on does
  // not observe it — probe the URL from the page context instead.
  const dayBootStatus = await page.evaluate(async () => {
    try { const r = await fetch('/day-boot.wasm', { method: 'HEAD' }); return r.status; }
    catch { return -1; }
  });
  rec('day-boot.wasm serves from Pages', dayBootStatus === 200, `HTTP ${dayBootStatus}`);

  // the spine boot takes a while — wasm instantiate + goblins vat + (if the
  // gateway answers) the OCapN handshake. Wait for the shell's real DOM and
  // the worker's own progress: day-boot.js traces "libs ready, loading wasm"
  // then "wasm loaded" once Scheme.load_main resolves.
  try { await page.waitForSelector('#facestrip', { timeout: 45000 }); } catch {}
  // the spine worker boots: fetch+instantiate 7.8MB wasm, stand the goblins
  // vat, then the OCapN handshake over the tunnel — allow real time for it
  try {
    await page.waitForFunction(
      () => true, { timeout: 1000 });
    await page.waitForEvent('console', {
      predicate: m => /wasm loaded|spine failed|spine worker error/.test(m.text()),
      timeout: 90000 });
  } catch {}
  await page.waitForTimeout(3000);

  rec('the shell mounts', await page.locator('#app').count() > 0);
  rec('the face strip renders', await page.locator('#facestrip').count() > 0);
  rec('the lend face is in the strip — the compute-node face deployed',
      await page.locator('#face-lend').count() > 0,
      await page.locator('#face-lend').getAttribute('title').catch(() => ''));
  rec('the date row renders — the day model booted',
      await page.locator('#daterow').count() > 0);

  // spine boot evidence: the trace console logs the gateway handshake when
  // the sref connects. gw: lines come from day-boot's own tracer.
  const gwLines = consoleLines.filter(l => /^.*gw:/.test(l) || l.includes('ws: new('));
  const spineBooted = consoleLines.some(l => l.includes('wasm loaded'));
  const spineFailed = consoleLines.find(l => /spine failed|spine worker error|boot failed/.test(l));
  const loadingWasm = consoleLines.some(l => l.includes('loading wasm'));
  console.log(`  INFO  gw trace: ${gwLines.slice(0, 4).join(' || ') || 'none'}`);
  rec('spine attempted the gateway ws', gwLines.length > 0, `${gwLines.length} gw/ws trace lines`);
  rec('day-boot.wasm instantiated in the spine worker', spineBooted,
      `wasm-loaded-trace=${spineBooted} loading-trace=${loadingWasm}` +
      (spineFailed ? ` FAILDETAIL=${spineFailed.slice(0, 120)}` : ''));

  // the OCapN handshake itself: connect! pushes seam-status! "connecting"
  // then "connected" once the enliven answers. The status sink traces it.
  const statusLines = consoleLines.filter(l => l.includes('status: '));
  const connected = statusLines.some(l => l.includes('status: connected'));
  console.log(`  INFO  status trace: ${statusLines.slice(0, 6).join(' || ') || 'none'}`);
  rec('OCapN handshake completed — seam reported "connected"', connected,
      statusLines.map(l => l.replace(/.*status: /, '')).slice(0, 4).join(', ') || 'no status');

  // app-page asset health
  const appFailed = [...responses.entries()]
    .filter(([u, s]) => s >= 400 && !u.includes('unpkg.com') && !EXPECTED_ABSENT.test(u));
  rec('app-page committed assets land', appFailed.length === 0,
      appFailed.map(([u, s]) => `${s} ${u.split('/').pop()}`).join(', ') || 'all <400');

  // ── honesty footer ───────────────────────────────────────────────────
  const benign = /ResizeObserver|favicon|deprecat|SchemeQuitError/i;
  const realErrors = pageErrors.filter(e => !benign.test(e));
  rec('no uncaught page errors on either page', realErrors.length === 0,
      realErrors.slice(0, 3).join(' | ') || 'clean console');
  if (pageErrors.length !== realErrors.length)
    console.log(`  INFO  filtered benign errors: ${pageErrors.filter(e => benign.test(e)).join(' | ')}`);
} finally {
  await browser.close();
}

const failed = results.filter(r => !r.ok);
console.log(`\n── results: ${results.length - failed.length} passed, ${failed.length} failed ──`);
process.exit(failed.length ? 1 : 0);
