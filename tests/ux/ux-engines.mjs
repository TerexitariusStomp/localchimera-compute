/// tests/ux/ux-engines.mjs — the guix-native engines, driven over the standards
/// they ship with. Playwright drives chromium (guix's ungoogled-chromium over
/// CDP); the other two engines guix carries speak W3C protocols of their own:
///
///   firefox  → icecat, over WebDriver BiDi (the websocket `--remote-debugging-port`)
///   webkit   → webkitgtk's WebKitWebDriver, over classic WebDriver (HTTP)
///
/// Full parity with the Playwright suites, not just layout: click / type /
/// drag (the W3C Actions array — one shape, BiDi's `input.performActions`
/// and classic WebDriver's `POST /actions` both take it verbatim), HTTP
/// request mocking (an HTTP-only forward proxy, wired in as each engine's own
/// `proxy` capability — no TLS MITM, so only plain-http traffic can be mocked;
/// the dial's own dev server is plain http, which covers what these suites
/// actually talk to), and a screenshot-loop recorder standing in for
/// Playwright's video/trace (assembled to mp4 by guix's `ffmpeg` if present,
/// left as a PNG sequence + a JSONL action log otherwise). No repackaging:
/// every binary here is a guix substitute
/// (`guix shell icecat webkitgtk xvfb-run ffmpeg`).
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import http from 'node:http';

const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const freePort = () => new Promise(r => { const s = net.createServer(); s.listen(0, () => { const p = s.address().port; s.close(() => r(p)); }); });
const tmpdir = () => fs.mkdtempSync('/tmp/ux-engine-');
const waitFor = async (f, ms = 20000) => { const t = Date.now(); for (;;) { try { const v = await f(); if (v) return v; } catch {} if (Date.now() - t > ms) throw new Error('timeout'); await sleep(150); } };

// ── input: one W3C Actions builder shared by both protocols ─────────────────
// BiDi's input.performActions and classic WebDriver's POST /actions take the
// identical `actions: [...]` shape (BiDi was modelled on classic here), so
// click/type/drag are written ONCE against an engine-supplied `perform()`.
const pointerDown = (x, y) => [{ type: 'pointerMove', x, y }, { type: 'pointerDown', button: 0 }, { type: 'pointerUp', button: 0 }];
const keyTap = (ch) => [{ type: 'keyDown', value: ch }, { type: 'keyUp', value: ch }];

/// Attach click/type/fill/drag/press/waitForSelector to a page whose
/// primitives are already goto/evaluate/screenshot. `perform(actions)` sends
/// one W3C Actions array through whichever transport the engine uses.
function mixInput(page, perform) {
  const srcLocate = (sel) => `() => { const el = document.querySelector(${JSON.stringify(sel)}); if (!el) return null;
    el.scrollIntoView({block:'center', inline:'center'}); const r = el.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; }`;
  const locate = async (sel) => {
    const p = await page.evaluate(srcLocate(sel));
    if (!p) throw new Error(`no element matches ${JSON.stringify(sel)}`);
    return p;
  };
  page.waitForSelector = (sel, { timeout = 15000 } = {}) =>
    waitFor(() => page.evaluate(`() => !!document.querySelector(${JSON.stringify(sel)})`), timeout);
  /// waitForFunction(fnSource, { timeout }) — poll an in-page predicate until
  /// truthy. fnSource is a function-source STRING (not a closure — same rule
  /// as evaluate()'s fn, since it crosses to the browser as text either way).
  page.waitForFunction = (fnSource, { timeout = 15000 } = {}) => waitFor(() => page.evaluate(fnSource), timeout);
  page.click = async (sel) => { const { x, y } = await locate(sel); await perform([{ type: 'pointer', id: 'mouse1', parameters: { pointerType: 'mouse' }, actions: pointerDown(x, y) }]); await sleep(60); };
  page.press = async (key) => { await perform([{ type: 'key', id: 'kbd1', actions: keyTap(key) }]); };
  // one performActions call per character: simple, correct, and these suites
  // type short strings — a form field, a search box — not paragraphs.
  page.type = async (text) => { for (const ch of text) { await page.press(ch); await sleep(15); } };
  page.fill = async (sel, text) => {
    await page.click(sel);
    await page.evaluate(`() => { const el = document.querySelector(${JSON.stringify(sel)}); if (el) el.value = ''; }`);
    await page.type(text);
    await page.evaluate(`() => { document.querySelector(${JSON.stringify(sel)})?.dispatchEvent(new Event('change', {bubbles:true})); }`);
  };
  page.drag = async (fromSel, toSel, { steps = 8 } = {}) => {
    const a = await locate(fromSel), b = await locate(toSel);
    const seq = [{ type: 'pointerMove', x: a.x, y: a.y }, { type: 'pointerDown', button: 0 }];
    for (let i = 1; i <= steps; i++) seq.push({ type: 'pointerMove', x: a.x + (b.x - a.x) * i / steps, y: a.y + (b.y - a.y) * i / steps, duration: 20 });
    seq.push({ type: 'pointerUp', button: 0 });
    await perform([{ type: 'pointer', id: 'mouse1', parameters: { pointerType: 'mouse' }, actions: seq }]);
  };
}

// ── network: an HTTP-only forward proxy, wired in as the engine's `proxy`
// capability. No TLS MITM (no CA to install) — a mocked pattern is matched
// against the absolute request URL as the proxy sees it, which is exactly
// what these suites need against their own plain-http dev server. ────────────
export function mockProxy() {
  const rules = []; // { test(url, method), status, headers, body }
  const log = [];
  const srv = http.createServer((req, res) => {
    const url = req.url; // absolute-URI, as an HTTP proxy receives it
    log.push({ t: Date.now(), method: req.method, url });
    const hit = rules.find(r => r.method === undefined || r.method === req.method ? (r.test.test ? r.test.test(url) : r.test(url, req.method)) : false);
    if (hit) {
      req.resume();
      res.writeHead(hit.status ?? 200, hit.headers ?? { 'content-type': 'application/json' });
      res.end(typeof hit.body === 'string' ? hit.body : JSON.stringify(hit.body ?? {}));
      return;
    }
    let target; try { target = new URL(url); } catch { res.writeHead(502); res.end(); return; }
    const upstream = http.request({ hostname: target.hostname, port: target.port || 80, path: target.pathname + target.search, method: req.method, headers: req.headers },
      (up) => { res.writeHead(up.statusCode, up.headers); up.pipe(res); });
    upstream.on('error', () => { try { res.writeHead(502); res.end(); } catch {} });
    req.pipe(upstream);
  });
  return {
    /// mock(urlPattern: RegExp|(url,method)=>bool, response, { method } = {})
    mock(test, response = {}, { method } = {}) { rules.unshift({ test, method, ...response }); },
    clear() { rules.length = 0; },
    get requests() { return log; },
    listen() { return new Promise((res) => srv.listen(0, '127.0.0.1', () => res(srv.address().port))); },
    close() { return new Promise((res) => srv.close(res)); },
  };
}

// ── recording: a screenshot loop standing in for Playwright's video/trace.
// Frames + a JSONL action log land in `dir`; ffmpeg (if guix's package is in
// PATH) assembles frames.mp4, otherwise the PNG sequence is the artifact. ──
export function recorder(page, dir, { fps = 4 } = {}) {
  fs.mkdirSync(dir, { recursive: true });
  const trace = [];
  let n = 0, timer = null;
  const frame = async () => { try { await page.screenshot({ path: `${dir}/frame-${String(n++).padStart(6, '0')}.png` }); } catch {} };
  const note = (entry) => trace.push({ t: Date.now(), ...entry });
  return {
    note,
    async start() { await frame(); timer = setInterval(frame, Math.round(1000 / fps)); },
    async stop() {
      if (timer) clearInterval(timer);
      await frame();
      fs.writeFileSync(`${dir}/trace.jsonl`, trace.map(e => JSON.stringify(e)).join('\n') + '\n');
      const hasFfmpeg = spawnSync('sh', ['-c', 'command -v ffmpeg']).status === 0;
      let video = null;
      if (n > 1 && hasFfmpeg) {
        // h264 refuses an odd width/height (a screenshot's real pixel size,
        // not a chosen one) — pad up to the next even number rather than crop
        const r = spawnSync('ffmpeg', ['-y', '-framerate', String(fps), '-i', `${dir}/frame-%06d.png`,
          '-vf', 'pad=ceil(iw/2)*2:ceil(ih/2)*2', '-pix_fmt', 'yuv420p', `${dir}/frames.mp4`]);
        if (r.status === 0 && fs.existsSync(`${dir}/frames.mp4`)) {
          video = `${dir}/frames.mp4`;
          for (let i = 0; i < n; i++) fs.rmSync(`${dir}/frame-${String(i).padStart(6, '0')}.png`, { force: true });
        } else fs.rmSync(`${dir}/frames.mp4`, { force: true }); // a partial/invalid file from a failed encode
      }
      return { dir, frames: n, video };
    },
  };
}

// ── icecat over BiDi ────────────────────────────────────────────────────────
class Bidi {
  constructor(ws) { this.ws = ws; this.id = 0; this.pending = new Map();
    this.events = [];
    ws.addEventListener('message', (e) => { const m = JSON.parse(e.data);
      if (m.type === 'event') { this.events.push(m); return; }
      const p = this.pending.get(m.id);
      if (!p) return; this.pending.delete(m.id); m.type === 'error' ? p.rej(new Error(`${m.error}: ${m.message}`)) : p.res(m.result); }); }
  send(method, params = {}) { const id = ++this.id; this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((res, rej) => this.pending.set(id, { res, rej })); }
}
export async function launchFirefox(exe = process.env.FIREFOX_PATH || 'icecat', { proxyPort } = {}) {
  const port = await freePort(), profile = tmpdir();
  // icecat ships LibreJS and NoScript, which refuse the dial's modules outright
  // — the floor stays empty and nothing says why. This is a throwaway profile
  // over our own static files: no add-ons, no remote settings, no first-run.
  const prefs = [
    'user_pref("extensions.enabledScopes", 0);',
    'user_pref("extensions.autoDisableScopes", 15);',
    'user_pref("extensions.systemAddon.update.enabled", false);',
    'user_pref("extensions.blocklist.enabled", false);',
    'user_pref("services.settings.server", "data:,");',
    'user_pref("browser.shell.checkDefaultBrowser", false);',
    'user_pref("datareporting.policy.dataSubmissionEnabled", false);',
    'user_pref("layout.css.prefers-color-scheme.content-override", 1);',
  ];
  if (proxyPort) prefs.push(
    'user_pref("network.proxy.type", 1);',
    `user_pref("network.proxy.http", "127.0.0.1"); user_pref("network.proxy.http_port", ${proxyPort});`,
    `user_pref("network.proxy.ssl", "127.0.0.1"); user_pref("network.proxy.ssl_port", ${proxyPort});`,
    'user_pref("network.proxy.allow_hijacking_localhost", true);',
    'user_pref("network.proxy.no_proxies_on", "");',
  );
  fs.writeFileSync(`${profile}/user.js`, prefs.join('\n'));
  const proc = spawn(exe, ['--headless', '--remote-debugging-port', String(port), '--profile', profile, '--no-remote', '--new-instance', 'about:blank'],
                     { stdio: ['ignore', 'ignore', 'ignore'], env: { ...process.env, MOZ_DISABLE_CONTENT_SANDBOX: '1' } });
  const ws = await waitFor(() => new Promise((res, rej) => { const w = new WebSocket(`ws://127.0.0.1:${port}/session`);
    w.addEventListener('open', () => res(w)); w.addEventListener('error', () => rej()); }), 30000);
  const c = new Bidi(ws);
  await c.send('session.new', { capabilities: {} });
  const { contexts } = await c.send('browsingContext.getTree', {});
  const ctx = contexts[0].context;
  // uncaught exceptions and console.error, as Playwright's pageerror would be
  await c.send('session.subscribe', { events: ['log.entryAdded'] });
  const errors = [];
  const drain = () => { for (const ev of c.events.splice(0)) {
    const p = ev.params; if (ev.method !== 'log.entryAdded' || p.level !== 'error') continue;
    errors.push(`${p.type === 'javascript' ? 'uncaught' : 'console'}: ${p.text}`); } };
  const page = {
    async setViewport(width, height) { await c.send('browsingContext.setViewport', { context: ctx, viewport: { width, height } }); },
    async goto(url) { await c.send('browsingContext.navigate', { context: ctx, url, wait: 'complete' }); },
    async evaluate(fn) {
      // wrapped in an async IIFE and awaited so a fn that returns a promise
      // (fetch(...).then(...), any async work) is resolved before stringify —
      // JSON.stringify(<pending Promise>) silently serializes to "{}" otherwise
      const r = await c.send('script.evaluate', { expression: `(async () => JSON.stringify((await (${fn})()) ?? null))()`, target: { context: ctx }, awaitPromise: true, resultOwnership: 'none' });
      if (r.type === 'exception') throw new Error(r.exceptionDetails?.text || 'evaluate failed');
      return JSON.parse(r.result.value);
    },
    async screenshot({ path }) { const r = await c.send('browsingContext.captureScreenshot', { context: ctx }); fs.writeFileSync(path, Buffer.from(r.data, 'base64')); },
    get errors() { drain(); return errors; },
  };
  mixInput(page, (actions) => c.send('input.performActions', { context: ctx, actions }));
  return { page, version: () => 'icecat', async close() { try { ws.close(); } catch {} proc.kill(); fs.rmSync(profile, { recursive: true, force: true }); } };
}

// ── webkitgtk over classic WebDriver ────────────────────────────────────────
/// `direct: true` navigates the window itself to the URL. The default wraps the
/// page in an iframe of the asked viewport (see goto below), and a frame under
/// a data: document is not a secure context — no crypto.subtle — so a suite
/// that signs anything asks for the page at top level and takes the window's
/// own size.
export async function launchWebKit(driver = process.env.WEBKIT_DRIVER || 'WebKitWebDriver', { proxyPort, direct = false } = {}) {
  const port = await freePort();
  // the browser the driver opens: MiniBrowser lives beside the driver in the
  // package's libexec, which is on no PATH — name it outright
  const { execSync } = await import('node:child_process');
  const drv = fs.realpathSync(execSync(`command -v ${driver}`).toString().trim());
  const libexec = `${drv.replace(/\/bin\/WebKitWebDriver$/, '')}/libexec`;
  const binary = process.env.MINIBROWSER_PATH
    || fs.readdirSync(libexec).map(d => `${libexec}/${d}/MiniBrowser`).find(f => fs.existsSync(f));
  if (!binary) throw new Error(`no MiniBrowser under ${libexec}`);
  // MiniBrowser needs a display; xvfb-run gives it one and the run stays headless
  // the web-process sandbox (bubblewrap) needs unprivileged user namespaces,
  // which a CI container or a hardened host withholds; a test runner over
  // its own static files has nothing for it to protect
  const proc = spawn('xvfb-run', ['-a', '-s', '-screen 0 2560x1600x24', driver, `--port=${port}`],
                     { stdio: ['ignore', 'ignore', 'ignore'], env: { ...process.env, WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS: '1' } });
  const base = `http://127.0.0.1:${port}`;
  // classic WebDriver commands on one session are not safe to interleave —
  // the error-shim poller's own evaluate() calls, running on a timer, would
  // otherwise race goto()'s frame-switch + navigate + evaluate sequence and
  // wedge the session. Every command queues onto the same promise chain.
  let queue = Promise.resolve();
  const call = (method, path, body) => {
    const run = () => fetch(base + path, { method, headers: { 'content-type': 'application/json' }, body: body && JSON.stringify(body) })
      .then(r => r.json()).then(j => { if (j.value?.error) throw new Error(`${j.value.error}: ${j.value.message}`); return j.value; });
    const p = queue.then(run, run);
    queue = p.catch(() => {});
    return p;
  };
  await waitFor(() => fetch(base + '/status').then(r => r.ok), 30000);
  const proxy = proxyPort ? { proxy: { proxyType: 'manual', httpProxy: `127.0.0.1:${proxyPort}`, sslProxy: `127.0.0.1:${proxyPort}`, noProxy: [] } } : {};
  const s = await call('POST', '/session', { capabilities: { alwaysMatch: { browserName: 'MiniBrowser', 'webkitgtk:browserOptions': { binary, args: ['--automation'] }, ...proxy } } });
  const sid = s.sessionId, S = `/session/${sid}`;
  // evaluate() runs every script through /execute/async (below) so a promise
  // an evaluated fn returns resolves before JSON.stringify sees it; give that
  // budget room past the default (often ~0-30s depending on the driver).
  await call('POST', `${S}/timeouts`, { script: 30000 });
  // The viewport is an IFRAME of exactly the asked size inside a window
  // that is merely big enough: MiniBrowser's own toolbar puts a floor under
  // the window's width (≈340px) that a phone is narrower than, and a frame
  // is its own viewport for innerWidth, media queries and dvh alike.
  // Scripts run inside the frame (switchToFrame), so the probe sees the page,
  // and — since actions dispatch to the session's current browsing context —
  // click/drag coordinates land in the frame too, consistent with evaluate().
  let vw = 0, vh = 0;
  // classic WebDriver has no console/exception feed of its own (unlike
  // chromium's native pageerror and Firefox BiDi's log.entryAdded), and
  // WebKitWebDriver here implements neither the logging-extension endpoints
  // (/log/types, /log) nor lets an automation-injected window.onerror /
  // console.error monkeypatch see the page's own realm — confirmed by a
  // direct probe: a real thrown error runs (a DOM marker set right before it
  // proves that), but the injected handler never sees it, on its own
  // isolated execution context. So this shim is a KNOWN GAP, not a fix — it
  // stays wired up (harmless, and might still catch what a test's own
  // evaluate() calls log) but `page.errors` on webkit today cannot be
  // trusted to reveal an uncaught page exception the way it reliably does on
  // chromium and firefox. A webkit suite needs its own assertions to catch a
  // broken page; it cannot lean on "no page errors" the way the other two
  // engines let it.
  const errors = [];
  const installErrorShim = () => page.evaluate(() => {
    window.__uxErrors = window.__uxErrors || [];
    window.addEventListener('error', (e) => window.__uxErrors.push('uncaught: ' + ((e.error && e.error.stack) || e.message)), true);
    window.addEventListener('unhandledrejection', (e) => window.__uxErrors.push('unhandledrejection: ' + ((e.reason && e.reason.stack) || e.reason)));
    const origErr = console.error.bind(console);
    console.error = (...args) => { window.__uxErrors.push('console: ' + args.map(String).join(' ')); origErr(...args); };
  });
  const errPoll = setInterval(async () => {
    try { errors.push(...(await page.evaluate(() => { const e = window.__uxErrors || []; window.__uxErrors = []; return e; }))); } catch {}
  }, 400);
  const page = {
    async setViewport(width, height) {
      vw = width; vh = height;
      await call('POST', `${S}/window/rect`, { width: Math.max(width + 40, 480), height: Math.max(height + 120, 400) });
    },
    async goto(url) {
      if (direct) {
        await call('POST', `${S}/frame`, { id: null });
        await call('POST', `${S}/url`, { url });
        await waitFor(() => page.evaluate(() => document.readyState !== 'loading'), 30000);
        await installErrorShim();
        return;
      }
      const wrap = `<!doctype html><body style="margin:0;background:#888"><iframe id="vp" style="display:block;border:0" width="${vw}" height="${vh}" src="${url.replace(/"/g, '&quot;')}"></iframe>`;
      await call('POST', `${S}/frame`, { id: null });
      await call('POST', `${S}/url`, { url: 'data:text/html;charset=utf-8,' + encodeURIComponent(wrap) });
      await call('POST', `${S}/frame`, { id: 0 });
      await waitFor(() => page.evaluate(() => document.readyState === 'complete' && innerWidth > 0), 30000);
      const [iw, ih] = await page.evaluate(() => [innerWidth, innerHeight]);
      if (iw !== vw || ih !== vh) throw new Error(`viewport ${vw}×${vh} not reachable (got ${iw}×${ih})`);
      await installErrorShim();
    },
    async evaluate(fn) {
      // classic WebDriver's /execute/sync cannot await a returned promise, so
      // an async fn (fetch(...), etc.) is run through /execute/async instead:
      // resolve the fn's result through Promise.resolve (a no-op for a plain
      // value) and hand the JSON string to the injected completion callback.
      const script = `var cb = arguments[arguments.length - 1];
        Promise.resolve((${fn})()).then(function(v){ cb(JSON.stringify(v === undefined ? null : v)); }, function(e){ cb(JSON.stringify({__evalError: String(e)})); });`;
      const v = await call('POST', `${S}/execute/async`, { script, args: [] });
      const parsed = JSON.parse(v);
      if (parsed && typeof parsed === 'object' && '__evalError' in parsed) throw new Error(parsed.__evalError);
      return parsed;
    },
    async screenshot({ path }) { fs.writeFileSync(path, Buffer.from(await call('GET', `${S}/screenshot`), 'base64')); },
    get errors() { return errors; },
  };
  mixInput(page, (actions) => call('POST', `${S}/actions`, { actions }));
  return { page, version: () => 'webkitgtk', async close() { clearInterval(errPoll); try { await call('DELETE', S); } catch {} proc.kill(); } };
}
