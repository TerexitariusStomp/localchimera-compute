/// tests/ux/ux-harness.mjs — shared helpers for browser (Playwright) e2e tests.
///
/// Write a test as tests/<feature>-ux.mjs:
///
///   import { harness, launch, newPage, openConnected, summarize } from './ux-harness.mjs';
///   const h = harness();
///   const browser = await launch();
///   const page = await newPage(browser, h);
///   try {
///     const { connected } = await openConnected(page, h, process.argv[2], process.argv[3]);
///     h.rec('WASM loads', true);                 // openConnected threw if not
///     h.rec('connects to gateway', connected);
///     if (connected) { /* navigate + assert; h.rec(...) / h.info(...) */ }
///   } catch (e) { h.rec('fatal', false, e.message); }
///   finally { await browser.close(); }
///   summarize(h, ['WASM loads', 'connects to gateway']);   // these gate the exit code
///
/// Run it via:  bash tests/ux/ux-full.sh tests/<feature>-ux.mjs
/// (starts a gateway, serves browser/ with a /ws proxy, runs the test).

let pw;
for (const mod of ['playwright-core', 'playwright']) {
  if (pw) break;
  try { const m = await import(mod); pw = m.chromium ? m : m.default; } catch {}
}
if (!pw?.chromium) throw new Error("could not load playwright-core or playwright");
const { chromium, devices } = pw;

/// The engine under test — every one a guix substrate, nothing vendored:
///   BROWSER=chromium  guix's ungoogled-chromium, Playwright over CDP (default)
///   BROWSER=firefox   guix's icecat, over WebDriver BiDi   (tests/ux/ux-engines.mjs)
///   BROWSER=webkit    guix's webkitgtk, over WebDriver      (tests/ux/ux-engines.mjs)
/// A suite's checks are the same on every engine; what differs is what the
/// engine makes of the CSS. The Playwright-driven suites (clicks, scrolls,
/// pointer drags) run on chromium; the layout matrix runs on all three.
export const ENGINE = (process.env.BROWSER || 'chromium').toLowerCase();
if (!['chromium', 'firefox', 'webkit'].includes(ENGINE)) throw new Error(`BROWSER=${ENGINE}: not one of chromium|firefox|webkit`);
/// Playwright's device descriptors (viewport, DPR, touch, UA) — the emulation
/// matrix tests/ux/responsive-ux.mjs runs the shell across.
export { devices };

export const sleep = (ms) => new Promise(r => setTimeout(r, ms));

/// A test run's result collector. h.rec(name, pass, detail?) records a gated
/// assertion; h.info(msg) logs a non-gating note. h.logs/h.errs capture the
/// page's console + pageerrors for diagnostics.
export function harness() {
  const results = [], logs = [], errs = [];
  return {
    results, logs, errs,
    rec(name, passed, detail = '') {
      results.push({ name, passed: !!passed, detail });
      console.log(`  ${passed ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + String(detail).slice(0, 140) : ''}`);
    },
    info(msg) { console.log(`  INFO  ${msg}`); },
  };
}

/// The probes' handle on the seam. The app hangs nothing off window; the
/// harness imports the seam module into every page it opens and parks it on
/// window.__seam, so a suite can read handlers, data and pushes from
/// page.evaluate. One module instance, so it is the app's own object.
export const SEAM_HOOK = `import('/app/seam.js').then(m => { window.__seam = m.seam; }).catch(() => {});`;
export const installSeamHook = async (page) => {
  await page.addInitScript(SEAM_HOOK);           // every document this page loads
  for (const nav of ['goto', 'reload']) {        // and settled before a navigation returns
    const real = page[nav].bind(page);
    page[nav] = async (...a) => {
      const r = await real(...a);
      try { await page.evaluate(SEAM_HOOK.replace(/;$/, '')); } catch {}
      return r;
    };
  }
};

import { WEBGL_ARGS } from '../../tools/dev/webgl-args.mjs';
/// Chromium flags for a real (software) WebGL context — `launch(WEBGL_ARGS)` for a suite that needs the map.
export { WEBGL_ARGS };

export async function launch(extraArgs = []) {
  if (ENGINE !== 'chromium') throw new Error(`BROWSER=${ENGINE}: this suite drives Playwright pointer/keyboard APIs, which only chromium has here; use launchLayout() for a layout-only suite, or launchEngine() for a full click/type/drag/mock/record suite that runs on all three`);
  const opts = { headless: true, args: ['--no-sandbox', '--disable-gpu', ...extraArgs] };
  if (process.env.CHROMIUM_PATH) opts.executablePath = process.env.CHROMIUM_PATH;
  const browser = await chromium.launch(opts);
  // every page this browser opens carries the seam hook, whichever factory a
  // suite reaches for (browser.newPage() directly, or newPage() below)
  const open = browser.newPage.bind(browser);
  browser.newPage = async (...a) => { const page = await open(...a); await installSeamHook(page); return page; };
  return browser;
}

/// A browser for a LAYOUT suite — goto / evaluate / screenshot against a device
/// descriptor — on whichever engine BROWSER names. Chromium gets Playwright's
/// full emulation (viewport, DPR, touch, UA); icecat and webkitgtk get the
/// viewport, which is what a layout reads, and their own UA.
///
///   const b = await launchLayout();
///   const d = await b.device(devices['iPhone SE']);   // { goto, evaluate, screenshot, errors, close }
export async function launchLayout() {
  if (ENGINE === 'chromium') {
    const browser = await launch();
    return {
      version: () => browser.version(),
      async device(desc) {
        const d = { ...desc }; delete d.defaultBrowserType;
        const ctx = await browser.newContext(d);
        const page = await ctx.newPage();
        await installSeamHook(page);
        const errors = []; page.on('pageerror', e => errors.push(String(e)));
        return { goto: (u) => page.goto(u, { waitUntil: 'networkidle' }),
                 evaluate: (f) => page.evaluate(f),
                 screenshot: (o) => page.screenshot(o), errors, close: () => ctx.close() };
      },
      close: () => browser.close(),
    };
  }
  const { launchFirefox, launchWebKit } = await import('./ux-engines.mjs');
  const b = await (ENGINE === 'firefox' ? launchFirefox() : launchWebKit());
  return {
    version: b.version,
    async device(desc) {
      const { width, height } = desc.viewport;
      await b.page.setViewport(width, height);
      return { async goto(u) { await b.page.goto(u); await sleep(300); },
               evaluate: (f) => b.page.evaluate(f),
               screenshot: (o) => b.page.screenshot(o), errors: b.page.errors, close: async () => {} };
    },
    close: b.close,
  };
}

/// A full interactive session — click / type / fill / drag / network mocking
/// / a video+trace recorder — on WHICHEVER engine BROWSER names. Chromium
/// gets it natively from Playwright; icecat and webkitgtk get the same shape
/// from tests/ux/ux-engines.mjs (W3C Actions for input, an HTTP-only forward
/// proxy for mocking, a screenshot-loop for recording — used on ALL THREE
/// engines here, not just the two without native video, so a recording looks
/// the same regardless of which engine made it).
///
///   const { page, close } = await launchEngine({ viewport: { width: 390, height: 844 }, mock: true });
///   await page.goto(url); await page.click('#face-cal'); await page.fill('#q', 'hi');
///   page.mock(/\/api\/things/, { status: 200, body: { ok: true } });
///   const rec = page.record('tests/ux/_artifacts/rec/foo'); await rec.start(); …; await rec.stop();
///
/// Network mocking is HTTP-only (no TLS MITM/CA) on firefox and webkit — set
/// `mock: true` at launch (a proxy is a launch-time capability, not a
/// per-request one there); chromium's page.route() has no such limit.
export async function launchEngine({ viewport = { width: 1280, height: 800 }, mock = false } = {}) {
  const { mockProxy, recorder } = await import('./ux-engines.mjs');
  if (ENGINE === 'chromium') {
    const browser = await launch();
    const ctx = await browser.newContext({ viewport });
    const page = await ctx.newPage();
    await installSeamHook(page);
    const errors = []; page.on('pageerror', e => errors.push(String(e)));
    const wrapped = {
      goto: (u) => page.goto(u, { waitUntil: 'networkidle' }),
      evaluate: (f) => page.evaluate(f),
      screenshot: (o) => page.screenshot(o),
      click: (sel) => page.click(sel, { timeout: 15000 }),
      type: (text) => page.keyboard.type(text),
      fill: (sel, text) => page.fill(sel, text, { timeout: 15000 }),
      press: (key) => page.keyboard.press(key),
      async drag(fromSel, toSel, { steps = 8 } = {}) {
        // page.dragAndDrop is HTML5 DnD (dragstart/dragover/drop) — wrong for
        // a pointer-driven grip (pointerdown/pointermove/pointerup), which is
        // what the dial's own resize handles use; a real mouse move sequence
        // dispatches both, matching the non-chromium engines' pointer actions.
        const a = await page.locator(fromSel).boundingBox(); const b = await page.locator(toSel).boundingBox();
        const ax = a.x + a.width / 2, ay = a.y + a.height / 2, bx = b.x + b.width / 2, by = b.y + b.height / 2;
        await page.mouse.move(ax, ay); await page.mouse.down();
        for (let i = 1; i <= steps; i++) await page.mouse.move(ax + (bx - ax) * i / steps, ay + (by - ay) * i / steps);
        await page.mouse.up();
      },
      waitForSelector: (sel, o) => page.waitForSelector(sel, o),
      waitForFunction: (fnSource, o) => page.waitForFunction(fnSource, o),
      get errors() { return errors; },
      mock(test, response = {}, { method } = {}) {
        page.route('**/*', (route) => {
          const req = route.request();
          if ((method && req.method() !== method) || !(test.test ? test.test(req.url()) : test(req.url(), req.method())))
            return route.continue();
          route.fulfill({ status: response.status ?? 200, headers: response.headers, body: typeof response.body === 'string' ? response.body : JSON.stringify(response.body ?? {}) });
        });
      },
      record: (dir) => recorder(wrapped, dir),
    };
    return { version: () => browser.version(), page: wrapped, close: () => browser.close() };
  }
  const { launchFirefox, launchWebKit } = await import('./ux-engines.mjs');
  const proxy = mock ? mockProxy() : null;
  const proxyPort = proxy ? await proxy.listen() : undefined;
  const b = await (ENGINE === 'firefox' ? launchFirefox(undefined, { proxyPort }) : launchWebKit(undefined, { proxyPort }));
  await b.page.setViewport(viewport.width, viewport.height);
  b.page.mock = proxy ? proxy.mock.bind(proxy) : () => { throw new Error('launchEngine({mock:true}) was not set'); };
  b.page.record = (dir) => recorder(b.page, dir);
  return { version: b.version, page: b.page, async close() { await b.close(); if (proxy) await proxy.close(); } };
}

/// Chromium flags that make WebRTC testable headlessly: a synthetic camera
/// (a rolling colour pattern) and microphone (a beep), and auto-granted
/// permission so getUserMedia/getDisplayMedia never block on a prompt.
/// Without these getUserMedia rejects and every media test is vacuous.
export const FAKE_MEDIA_ARGS = [
  '--use-fake-device-for-media-stream',
  '--use-fake-ui-for-media-stream',
  '--allow-file-access-from-files',
  '--autoplay-policy=no-user-gesture-required',
  // Chrome replaces host ICE candidates with .local mDNS names by default;
  // resolving those needs multicast DNS, which a headless/container run does
  // not have — so ICE never completes and connectionState sticks at "new".
  '--disable-features=WebRtcHideLocalIpsWithMdns',
];

export async function newPage(browser, h) {
  const page = await browser.newPage();
  await installSeamHook(page);
  if (h) {
    page.on('console', m => { const t = m.text(); if (t) h.logs.push(t.slice(0, 160)); });
    page.on('pageerror', e => h.errs.push(String(e).slice(0, 120)));
  }
  return page;
}

/// Load index.html (optionally with ?gatewaySref=SREF), wait for the WASM REPL,
/// and — when a sref is given — wait for the OCapN connection to the gateway.
/// THROWS if the WASM never loads. Returns { connected }.
export async function openConnected(page, h, base = 'http://localhost:8089', sref = '',
                                    { wasmTimeout = 60_000, connectTimeout = 50_000 } = {}) {
  const url = sref ? `${base}/index.html?gatewaySref=${sref}` : `${base}/index.html`;
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('textarea#expression', { timeout: wasmTimeout });
  await sleep(1000);
  let connected = false;
  if (sref) {
    try {
      await page.waitForFunction(() =>
        (document.getElementById('repl-log')?.textContent || '').includes('Connected to OCapN gateway'),
        { timeout: connectTimeout });
      connected = true;
    } catch {
      if (h) {
        h.info('repl-log tail: ' + JSON.stringify(
          (await page.evaluate(() => (document.getElementById('repl-log')?.textContent || '').slice(-300)))));
        h.info('console: ' + JSON.stringify(h.logs.slice(-8)));
      }
    }
  }
  return { connected };
}

/// Convenience: the scopes the cap exposes (the session scope <select> options).
export async function scopeOptions(page) {
  return page.evaluate(() => {
    const s = document.getElementById('session-scope-select');
    return s ? Array.from(s.options).map(o => o.value).filter(Boolean) : [];
  });
}

/// ── UI drivers: actually navigate + interact, not just connect ───────────────

/// Click a top nav tab by its visible label (e.g. 'calendar', 'inventory').
export async function clickTab(page, label) {
  await page.locator('.tab', { hasText: label }).first().click({ timeout: 8000 });
  await sleep(800);
}

/// Select the first non-empty option of a <select> by id; returns its value (or
/// null if the select/options are absent). Fires the element's change handler.
export async function pickFirstOption(page, id) {
  const val = await page.evaluate((id) => {
    const s = document.getElementById(id);
    if (!s) return null;
    return Array.from(s.options).map(o => o.value).find(Boolean) ?? null;
  }, id);
  if (val != null) { await page.selectOption('#' + id, val); await sleep(700); }
  return val;
}

/// Set a <select> by id to a specific value (fires its change handler).
export async function setSelect(page, id, value) {
  await page.selectOption('#' + id, value);
  await sleep(700);
}

/// Does any element match the CSS selector?
export async function present(page, sel) {
  return (await page.locator(sel).count()) > 0;
}

/// Full body text, for substring assertions.
export async function bodyText(page) {
  return page.evaluate(() => document.body.textContent || '');
}

/// Print the summary and exit. GATING = the result names that determine the
/// exit code (0 iff all of them passed); other recs are reported but advisory.
export function summarize(h, gating = []) {
  const passed = h.results.filter(r => r.passed).length;
  const failed = h.results.length - passed;
  console.log(`\n== ${passed} passed, ${failed} failed ==`);
  const crit = gating.length ? h.results.filter(r => gating.includes(r.name)) : h.results;
  process.exit(crit.length && crit.every(r => r.passed) ? 0 : 1);
}
