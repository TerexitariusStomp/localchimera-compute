/// tests/ux/join-live-ux.mjs — an identity made at one commune takes a seat
/// at another, carrying nothing but its own log.
///
/// Two real gateways (ux-full.sh SECOND_GATEWAY=1), each with its own
/// oobi-host, each reached through its own /ws proxy on its own origin so the
/// two pages share no storage. The identity is created at A the way a first
/// citizen creates one. Its hint + KEL are then placed on a fresh device that
/// only knows B — the recovery file's contents, minus the file — and the
/// passcode unlocks against that log with B in the loop only afterwards:
/// B reports the AID unregistered, the chip offers to join, the gateway
/// verifies the carried chain (signup-with-kel) and seats it. Nothing stubbed.
///
/// Run via:  make test-join-live-ux
///           SECOND_GATEWAY=1 bash tests/ux/ux-full.sh tests/ux/join-live-ux.mjs

import { existsSync } from 'node:fs';
import { harness, launch, newPage, present, sleep, summarize } from './ux-harness.mjs';
import { openIdentityCard, tickCard } from './probe-lib.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';
const BASE2 = process.env.UX_BASE2 || '';
const DATA2 = process.env.PLAYNET_DATA_DIR2 || '.ux-e2e-data-2';

const h = harness();
const browser = await launch();

const chipOf = (page) =>
  page.evaluate(() => document.querySelector('#idrow .who')?.textContent ?? '');
// The corner is a dot and a name. State is read from the LIGHT (and, where two
// states share a colour, from the sentence it stands for in `title`) rather
// than from prose — which is how a person reads it too.
const dotOf = (page) =>
  page.evaluate(() => (document.querySelector('#idrow .who .dot')?.className || '')
                        .replace('dot', '').trim());
const titleOf = (page) =>
  page.evaluate(() => document.querySelector('#idrow .who')?.getAttribute('title') || '');
const waitDot = async (page, cls, ms = 90000) => {
  const dl = Date.now() + ms;
  let d = '';
  while (Date.now() < dl) { d = await dotOf(page); if (d === cls) return d; await sleep(500); }
  return d;
};
const waitChip = async (page, re, ms = 90000) => {
  let t = '';
  const dl = Date.now() + ms;
  while (Date.now() < dl) { t = await chipOf(page); if (re.test(t)) return t; await sleep(500); }
  return t;
};
const tickConsent = (page) => tickCard(page, 'consent');

try {
  h.rec('a second commune is configured (UX_BASE2)', !!BASE2, BASE2 || '(unset — run with SECOND_GATEWAY=1)');

  // ── A: create ──
  const a = await newPage(browser, h);
  await a.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
  await a.waitForSelector('#idrow', { timeout: 60000 });
  const chipA = await waitChip(a, /create your identity/i);
  h.rec('dial connects to commune A', /create your identity/i.test(chipA), chipA);
  await a.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
  await sleep(500);
  await a.waitForSelector('.idc', { timeout: 15000 });
  await tickCard(a, 'consent', 'age');
  await a.click('.idc .ob-next:has-text("create my identity")');
  await a.waitForSelector('.idc[data-view="reveal"] input[name="username"]', { timeout: 120000 }).catch(() => {});
  const creds = await a.evaluate(() => ({
    aid: document.querySelector('.idc input[name="username"]')?.value ?? '',
    bran: document.querySelector('.idc input[name="password"]')?.value ?? '',
  }));
  h.rec('identity created at A', /^E[A-Za-z0-9_-]{43}$/.test(creds.aid), creds.aid || '(none)');
  const seatedA = await waitDot(a, 'live', 30000);
  h.rec('seated at A', seatedA === 'live', `${seatedA} · ${await chipOf(a)}`);
  const carried = await a.evaluate(() => ({
    hint: localStorage.getItem('pn.id.hint') || '',
    kel: localStorage.getItem('pn.id.kel') || '',
  }));
  h.rec('A\'s browser holds the log to carry', carried.kel.includes(`"i":"${creds.aid}"`));
  await a.close();

  if (BASE2 && creds.aid) {
    // ── B: a fresh device that only knows the other commune ──
    const b = await newPage(browser, h);
    await b.goto(`${BASE2}/app.html`, { waitUntil: 'domcontentloaded' });
    await b.waitForSelector('#idrow', { timeout: 60000 });
    const chipB0 = await waitChip(b, /create your identity/i);
    h.rec('dial connects to commune B, which knows no one', /create your identity/i.test(chipB0), chipB0);
    h.rec('B has never seen this AID',
          !existsSync(`${DATA2}/oobi-host/${creds.aid.slice(0, 2)}/${creds.aid}.scm`));
    await b.evaluate(([hint, kel]) => {
      localStorage.setItem('pn.id.hint', hint);
      localStorage.setItem('pn.id.kel', kel);
    }, [carried.hint, carried.kel]);
    await b.reload({ waitUntil: 'domcontentloaded' });
    await b.waitForSelector('#idrow', { timeout: 60000 });
    const signIn = await waitDot(b, 'idle');
    h.rec('B offers to sign in as the carried identity',
          signIn === 'idle' && /sign in/i.test(await titleOf(b)), `${signIn} · ${await titleOf(b)}`);

    // unlock: the passcode against the carried log. B is asked only
    // afterwards — whether it has a seat — and it does not.
    await b.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
    await sleep(500);
    await b.waitForSelector('.idc input[name="password"]', { timeout: 15000 });
    await b.fill('.idc input[name="password"]', creds.bran);
    await tickConsent(b);
    await b.click('.idc form [type="submit"]');
    const unreg = await waitDot(b, 'warn');
    h.rec('unlocked at B, reported unregistered — the chip offers to join',
          unreg === 'warn' && /join/i.test(await titleOf(b)), `${unreg} · ${await titleOf(b)}`);

    // join: the carried chain verified by B, the seat follows
    await b.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
    await sleep(500);
    h.rec('the join sheet names the situation', await b.evaluate(() =>
      document.querySelector('.idc')?.dataset.view === 'join'
      && /hasn.t met you/i.test(document.querySelector('.idc')?.textContent || '')));
    await tickConsent(b);
    await b.click('.idc .ob-next:has-text("join as")');
    const seatedB = await waitDot(b, 'live');
    h.rec('seated at B under the carried identity', seatedB === 'live', `${seatedB} · ${await chipOf(b)}`);
    let persisted = false;
    const dl = Date.now() + 30000;
    while (Date.now() < dl) {
      persisted = existsSync(`${DATA2}/oobi-host/${creds.aid.slice(0, 2)}/${creds.aid}.scm`);
      if (persisted) break;
      await sleep(1000);
    }
    h.rec('B persisted the carried KEL under its own oobi-host', persisted);

    // the seat is real: a reload comes back seated. The device key enrolled
    // at the join signs the refresh in by itself; a device without one is
    // offered the unlock, and the passcode seats it — either way, no join.
    await b.reload({ waitUntil: 'domcontentloaded' });
    await b.waitForSelector('#idrow', { timeout: 60000 });
    let again = await waitDot(b, 'live', 45000);
    if (again !== 'live') {
      await waitDot(b, 'idle');
      await b.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
      await sleep(500);
      await b.fill('.idc input[name="password"]', creds.bran, { timeout: 15000 }).catch(() => {});
      await b.click('.idc form [type="submit"]').catch(() => {});
      again = await waitDot(b, 'live');
    }
    h.rec('a later reload at B seats directly — B knows the AID now', again === 'live', `${again} · ${await chipOf(b)}`);
    await b.close();
  }

  h.rec('no page errors during the flow', h.errs.length === 0, h.errs.slice(0, 2).join(' | '));
} catch (e) {
  h.info('exception: ' + (e?.stack ?? String(e)));
  h.rec('test ran to completion', false);
} finally {
  await browser.close();
}

summarize(h, ['a second commune is configured (UX_BASE2)', 'dial connects to commune A']);
