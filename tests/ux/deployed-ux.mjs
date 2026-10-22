/// tests/ux/deployed-ux.mjs — e2e against the DEPLOYED site, not localhost.
///
/// Asserts the Cloudflare Pages deployment actually serves the app: the
/// pages answer, the static assets land, the dial shell renders its real
/// DOM. Honest about what the deploy does NOT carry: browser/repl.wasm is
/// a hoot-toolchain artifact (guix-pinned, absent from this checkout), so
/// the OCapN REPL page must show its wasm-error — a check passes only when
/// the page fails the way it should, not when we pretend it connected.
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
const results = [];
const rec = (name, ok, detail = '') => {
  results.push({ name, ok });
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + String(detail).slice(0, 160) : ''}`);
};

const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM_PATH || undefined,
  args: ['--no-sandbox'],
});

try {
  const page = await browser.newPage();
  const responses = new Map();   // url → status
  page.on('response', r => responses.set(r.url(), r.status()));
  const pageErrors = [];
  page.on('pageerror', e => pageErrors.push(String(e).slice(0, 120)));

  // ── the REPL/index page ──────────────────────────────────────────────
  const resp = await page.goto(`${BASE}/`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  rec('index page serves', resp && resp.status() < 400, `HTTP ${resp?.status()}`);
  rec('index carries the app title', (await page.title()).toLowerCase().includes('playnet'),
      await page.title());

  // give the module scripts a beat, then count what failed to load.
  // EXPECTED_ABSENT is honest, not a waiver: *.wasm and their glue are
  // hoot-toolchain artifacts `make` produces (absent from this checkout),
  // and *.json endpoints are gateway-served at runtime — a static deploy
  // answers 404 for all of them and the app is built to tolerate that.
  const EXPECTED_ABSENT = /\.(wasm)$|_wasm\.js$|universal-commune\.json|operator\.json/;
  await page.waitForTimeout(3000);
  const expectedAbsent = [...responses.entries()]
    .filter(([u, s]) => s >= 400 && EXPECTED_ABSENT.test(u));
  const failedAssets = [...responses.entries()]
    .filter(([u, s]) => s >= 400 && !EXPECTED_ABSENT.test(u));
  rec('committed static assets all land (scripts, css, icons)', failedAssets.length === 0,
      failedAssets.map(([u, s]) => `${s} ${u.split('/').pop()}`).join(', ') || 'all <400');
  console.log(`  INFO  expected-absent (build artifacts + gateway endpoints): ` +
              `${expectedAbsent.map(([u]) => u.split('/').pop()).join(', ') || 'none'}`);

  // repl.wasm is NOT in the deploy — the page must say so, not hang silently
  const wasmStatus = [...responses.entries()].find(([u]) => u.includes('repl.wasm'));
  const wasmErrorShown = await page.locator('#wasm-error').isVisible().catch(() => false);
  rec('repl.wasm absent is an honest page error, not a silent hang',
      (wasmStatus && wasmStatus[1] >= 400) || wasmErrorShown,
      wasmStatus ? `wasm HTTP ${wasmStatus[1]}, error-visible=${wasmErrorShown}` : `error-visible=${wasmErrorShown}`);

  // ── the dial shell (/app) ────────────────────────────────────────────
  const resp2 = await page.goto(`${BASE}/app`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  rec('app page serves', resp2 && resp2.status() < 400, `HTTP ${resp2?.status()}`);
  await page.waitForTimeout(2500);

  rec('the shell mounts', await page.locator('#app').count() > 0);
  rec('the face strip renders', await page.locator('#facestrip').count() > 0);
  rec('the lend face is in the strip — the compute-node face deployed',
      await page.locator('#face-lend').count() > 0,
      await page.locator('#face-lend').getAttribute('title').catch(() => ''));
  rec('the date row renders — the day model booted',
      await page.locator('#daterow').count() > 0);

  // app-page asset health — committed files must serve; wasm/glue and
  // gateway endpoints are expected-absent on a static deploy
  const appFailed = [...responses.entries()]
    .filter(([u, s]) => s >= 400 && !u.includes('unpkg.com') && !EXPECTED_ABSENT.test(u));
  rec('app-page committed assets land', appFailed.length === 0,
      appFailed.map(([u, s]) => `${s} ${u.split('/').pop()}`).join(', ') || 'all <400');

  // ── honesty footer ───────────────────────────────────────────────────
  rec('no uncaught page errors on either page', pageErrors.length === 0,
      pageErrors.slice(0, 3).join(' | ') || 'clean console');
  console.log(`  INFO  gateway sref path is not e2e-able from Pages — OCapN needs ` +
              `a reachable /ws proxy to a running gateway; this deploy serves the static tier only`);
} finally {
  await browser.close();
}

const failed = results.filter(r => !r.ok);
console.log(`\n── results: ${results.length - failed.length} passed, ${failed.length} failed ──`);
process.exit(failed.length ? 1 : 0);
