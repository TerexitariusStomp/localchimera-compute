/// tests/ux/reconnect-live-ux.mjs — a severed gateway connection comes back on its own.
///
/// The spine's refs die with the CapTP connection (a `<-` on one throws in
/// the vat); on-sever drops them and reports, the page schedules a backoff
/// reconnect, the enliven re-seats whoever can sign. Here the socket is
/// closed from outside after a seat; the dial must report the disconnect,
/// reconnect, and be seated again — with a handler answering afterwards.
///
/// Run via:  make test-reconnect-live-ux
import { harness, launch, newPage, sleep, summarize } from './ux-harness.mjs';
import { tickCard, savePasscode } from './probe-lib.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';
const h = harness();
const browser = await launch();
const page = await newPage(browser, h);
const dotIn = () => page.evaluate(() => (document.querySelector('#idrow .who .dot')?.className || '').replace('dot', '').trim());
const waitDot = async (cls, ms) => { const dl = Date.now() + ms; let d = ''; while (Date.now() < dl) { d = await dotIn(); if (d === cls) return d; await sleep(300); } return d; };
const chipText = () => page.evaluate(() => document.querySelector('#idrow .who')?.textContent ?? '');

try {
  await page.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 60000 });
  const dl = Date.now() + 90000;
  while (Date.now() < dl && !/create your identity/i.test(await chipText())) await sleep(1000);
  h.rec('dial connects to the gateway', /create your identity/i.test(await chipText()));
  await page.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor()); await sleep(600);
  await page.waitForSelector('.idc', { timeout: 15000 });
  await tickCard(page, 'consent', 'age');
  await page.click('.idc .ob-next:has-text("create my identity")');
  await page.waitForSelector('.idc[data-view="reveal"] input[name="username"]', { timeout: 120000 }).catch(() => {});
  await savePasscode(page);
  h.rec('seated', (await waitDot('live', 90000)) === 'live');

  const before = h.logs.length;
  await page.evaluate(async () => (await import('/day-boot.js')).probe.closeWs());
  const dl2 = Date.now() + 20000; let sawDisc = false;
  while (Date.now() < dl2) { if (h.logs.slice(before).some(l => /status: error:gateway disconnected/.test(l))) { sawDisc = true; break; } await sleep(300); }
  h.rec('the spine reports the disconnect (on-sever)', sawDisc);
  h.rec('…and the vat is still alive (no Scheme quit)', !h.logs.slice(before).some(l => /SchemeQuit|Uncaught exception/.test(l)));
  const dl3 = Date.now() + 60000; let reconnected = false;
  while (Date.now() < dl3) { if (h.logs.slice(before).some(l => /reconnect → ok/.test(l)) && h.logs.slice(before).filter(l => /status: connected/.test(l)).length) { reconnected = true; break; } await sleep(500); }
  h.rec('the page reconnects with backoff', reconnected);
  h.rec('the seat is taken again', (await waitDot('live', 60000)) === 'live');
  const r = await page.evaluate(async () => { const { HANDLERS } = await import('/app/core.js'); return HANDLERS.devices ? String(await HANDLERS.devices()) : '(no handler)'; });
  h.rec('a handler answers on the new connection', r.startsWith('['), r.slice(0, 40));
  h.rec('no page errors during the flow', h.errs.length === 0, h.errs.slice(0, 2).join(' | '));
} catch (e) {
  h.info('exception: ' + (e?.stack ?? String(e)));
  h.rec('test ran to completion', false);
} finally { await browser.close(); }
summarize(h, ['dial connects to the gateway']);
