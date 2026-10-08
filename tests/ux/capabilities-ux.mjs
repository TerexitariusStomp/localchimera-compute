/// tests/ux/capabilities-ux.mjs — a browser too old for the wasm is told so, and the page carries on
///
/// day-boot.js asks the engine (lib/capabilities.js) before it fetches a six-megabyte
/// wasm it could not compile. The engine here is current, so the test plays an old
/// one: an init script makes WebAssembly.validate refuse the one probe a given case
/// names, which is exactly what an engine without that feature does.
///
/// What the page owes a person on such a browser: a banner that says why, the demo day
/// untouched underneath, no wasm fetched, a banner that goes away when asked and stays
/// away for the same reason, and no banner at all on an engine that has everything.
///
/// Run via: make test-capabilities-ux
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();
const h = harness();
const browser = await launch();

// the engine says no to the probes whose bytes contain `needle`
const refuse = (needle) => `(() => {
  const real = WebAssembly.validate.bind(WebAssembly);
  const needle = ${JSON.stringify(needle)};
  const has = (a) => { outer: for (let i = 0; i + needle.length <= a.length; i++) {
    for (let j = 0; j < needle.length; j++) if (a[i + j] !== needle[j]) continue outer; return true; } return false; };
  WebAssembly.validate = (bytes) => has(new Uint8Array(bytes)) ? false : real(bytes);
})();`;
const TRY_TABLE = [0x1f, 0x40, 0x01, 0x02, 0x00];   // the exception probe's body
const STRUCT = [0x5f, 0x01, 0x7f, 0x00];           // the garbage-collected-data probe's type

async function open(ctx, init) {
  const page = await ctx.newPage();
  const wasmRequests = [];
  page.on('request', (r) => { if (/\.wasm(\?|$)/.test(r.url()) && /day-boot|family/.test(r.url())) wasmRequests.push(r.url()); });
  if (init) await page.addInitScript(init);
  await page.goto(`${BASE}/app.html?face=calendar`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 60000 });
  await sleep(2500);
  return { page, wasmRequests };
}
const notice = (page) => page.evaluate(() => {
  const el = document.getElementById('capNotice');
  return el ? { text: el.textContent, reason: el.dataset.reason, role: el.getAttribute('role') } : null;
});

try {
  // ── an engine without the standard exception encoding ───────────────────
  const ctx = await browser.newContext();
  {
    const { page, wasmRequests } = await open(ctx, refuse(TRY_TABLE));
    const n = await notice(page);
    h.rec('a banner says the browser is too old', n && /too old/.test(n.text), n && n.text.slice(0, 90));
    h.rec('it names the missing feature', n && /exception handling/.test(n.text));
    h.rec('it says the demo day is what shows', n && /demo day/.test(n.text));
    h.rec('it is announced politely, not as an alert', n && n.role === 'status');
    h.rec('it names the reason for the page to remember', n && n.reason === 'missing:exceptions', n && n.reason);
    h.rec('the demo day stands underneath: the identity row is there', await page.$('#idrow') !== null);
    h.rec('no wasm is fetched for a browser that cannot compile it', wasmRequests.length === 0, wasmRequests.join(' '));

    await page.click('#capNotice button');
    h.rec('dismissing removes the banner', (await notice(page)) === null);
    await page.close();

    const again = await open(ctx, refuse(TRY_TABLE));
    h.rec('the same reason does not come back on the next visit', (await notice(again.page)) === null);
    await again.page.close();

    // a browser lacking something else is a different reason, so it is told
    const other = await open(ctx, refuse(STRUCT));
    const o = await notice(other.page);
    h.rec('a different missing feature is a different reason, and shows', o && o.reason === 'missing:gc', o && o.reason);
    await other.page.close();
  }
  await ctx.close();

  // ── an engine that has everything ───────────────────────────────────────
  {
    const fresh = await browser.newContext();
    const { page } = await open(fresh, null);
    const n = await notice(page);
    // the page may still report a boot failure of its own; what it must not report is a missing feature
    h.rec('a complete engine is never told it is too old', !n || !/^missing:/.test(n.reason || ''), n && n.reason);
    await page.close();
    await fresh.close();
  }
} catch (e) { h.rec('fatal', false, e.message); }
finally { await browser.close(); closeServer(); }
summarize(h, []);
