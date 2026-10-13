/// tests/ux/room-join-live-ux.mjs — a person joins a room through a REAL gateway.
///
/// room-ux stubs the spine and walkie-ux drives the media layer directly, so
/// neither runs the join itself: the spine's boot (every import its wasm
/// declares is provided), the gateway's `ice-servers` door answering when a
/// room is joined, the list reaching the page before any peer connection, and
/// the join running through the vat without a Goblins exception. Nothing stubbed
/// but the camera and microphone (Chromium's fake devices).
///
/// Run: make test-room-join-live-ux
///      bash tests/ux/ux-full.sh tests/ux/room-join-live-ux.mjs
import { harness, launch, newPage, sleep, summarize, FAKE_MEDIA_ARGS } from './ux-harness.mjs';
import { tickCard } from './probe-lib.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';
const h = harness();
const browser = await launch(FAKE_MEDIA_ARGS);
const page = await newPage(browser, h);

// what the page's console says while we act, by step
let step = 'boot';
const trouble = [];
page.on('console', m => {
  const t = m.text();
  if (/Goblins exception|Scheme error|arity-violation|boot failed|spine failed|LinkError/.test(t))
    trouble.push(`[${step}] ${t.replace(/\n/g, ' ⏎ ').slice(0, 300)}`);
});
const chip = () => page.evaluate(() => document.querySelector('#idrow .who')?.textContent ?? '');
const iceNow = () => page.evaluate(async () => {
  const r = (await import('/day-boot.js')).walkieRTC; const pc = r.newPc();
  const x = pc.getConfiguration().iceServers.map(s => [].concat(s.urls).join()); r.closePc(pc); return x;
});

try {
  await page.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 60000 });
  let c = '';
  for (let i = 0; i < 90 && !/create your identity/i.test(c); i++) { c = await chip(); await sleep(1000); }
  h.rec('the page connects to the gateway', /create your identity/i.test(c), c);

  step = 'signup';
  await page.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor()); await sleep(600);
  await page.waitForSelector('.idc', { timeout: 15000 });
  await tickCard(page, 'consent', 'age');
  await page.click('.idc .ob-next:has-text("create my identity")');
  await page.waitForSelector('.idc[data-view="reveal"] input[name="username"]', { timeout: 120000 }).catch(() => {});
  await sleep(4000);
  h.rec('a first citizen is signed in', !/create your identity/i.test(await chip()), await chip());

  await page.evaluate(async () => {
    window.__w = []; (await import('/app/bus.js')).on('walkie', s => window.__w.push(s));
  });
  h.rec('before a join the page holds no ICE servers', (await iceNow()).length === 0);

  step = 'join';
  const reply = await page.evaluate(async () =>
    (await (await import('/app/core.js')).HANDLERS.walkie('joinvideo', 'meeting/earth/ice-probe')));
  h.rec('the join is accepted', reply === 'ok', String(reply));
  let said = [];
  for (let i = 0; i < 40 && !said.some(s => /^joined/.test(s)); i++) { said = await page.evaluate(() => window.__w); await sleep(500); }
  h.rec('the spine reports the room joined', said.some(s => /^joined/.test(s)), JSON.stringify(said));
  await sleep(1500);   // a handler that fails does so a turn later
  h.rec('after the join the page holds the gateway\'s ICE servers', (await iceNow()).length >= 1,
        JSON.stringify(await iceNow()));
  h.rec('the join ran without a Goblins exception or a boot failure', trouble.length === 0, trouble.slice(0, 2).join(' | '));

  step = 'leave';
  await page.evaluate(async () => (await import('/app/core.js')).HANDLERS.walkie('leave', ''));
  await sleep(800);
  h.rec('leaving runs clean too', trouble.length === 0, trouble.slice(0, 2).join(' | '));
} catch (e) { h.rec('fatal', false, e.message); }
finally { await browser.close(); }

summarize(h, [
  'the page connects to the gateway',
  'a first citizen is signed in',
  'the join is accepted',
  'the spine reports the room joined',
  'after the join the page holds the gateway\'s ICE servers',
  'the join ran without a Goblins exception or a boot failure',
]);
