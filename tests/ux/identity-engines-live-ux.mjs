/// tests/ux/identity-engines-live-ux.mjs — an identity on Gecko and on WebKit.
///
/// The identity suites drive chromium. A person signs up on whatever their
/// phone carries: WebKit on every iPhone, Gecko on Firefox. This walks the
/// same account through both engines against one live gateway:
///
///   firefox  creates the identity, stays signed in across a reload
///   webkit   signs in as that identity with AID + passcode, stays signed in
///
/// and says, for each engine, what it can hold (WebCrypto Ed25519, a
/// non-extractable key in IndexedDB) so a missing capability reads as a named
/// fact about the engine.
///
/// Run via:  make test-identity-engines-live-ux
///           UX_MANIFEST=deploy/manifests/browser-engines-manifest.scm \
///             bash tests/ux/ux-full.sh tests/ux/identity-engines-live-ux.mjs

import { harness, sleep, summarize } from './ux-harness.mjs';
import { launchFirefox, launchWebKit } from './ux-engines.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';
const ONLY = (process.env.ENGINES || 'firefox,webkit').split(',');
const h = harness();

const waitFor = async (pred, ms = 30000, step = 500) => {
  const dl = Date.now() + ms;
  while (Date.now() < dl) { try { if (await pred()) return true; } catch {} await sleep(step); }
  return false;
};
const q = JSON.stringify;

function probes(page) {
  const chip = () => page.evaluate(`() => document.querySelector('#idrow .who')?.textContent ?? ''`);
  const dot = () => page.evaluate(`() => (document.querySelector('#idrow .who .dot')?.className || '').replace('dot', '').trim()`);
  const waitDot = async (cls, ms = 60000) => { let d = ''; await waitFor(async () => (d = await dot()) === cls, ms); return d; };
  const ls = (k) => page.evaluate(`() => localStorage.getItem(${q(k)})`);
  const call = (name) => page.evaluate(`async () => {
    const { HANDLERS } = await import('/app/core.js');
    return HANDLERS[${q(name)}] ? String(await HANDLERS[${q(name)}]()) : '(no handler)'; }`);
  const tick = () => page.evaluate(`() => { document.querySelectorAll('#idform input[type="checkbox"]').forEach(b => { if (!b.checked) b.click(); }); return true; }`);
  const tap = (sel, text) => page.evaluate(`() => {
    const el = [...document.querySelectorAll(${q(sel)})].find(e => ${text ? `e.textContent.includes(${q(text)})` : 'true'});
    if (el) el.click(); return !!el; }`);
  const caps = () => page.evaluate(`async () => {
    const out = { secure: window.isSecureContext, subtle: !!(crypto && crypto.subtle), ed25519: false, idbKey: false, webauthn: !!window.PublicKeyCredential };
    try {
      const kp = await crypto.subtle.generateKey({ name: 'Ed25519' }, false, ['sign', 'verify']);
      out.ed25519 = true;
      out.idbKey = await new Promise(res => {
        const r = indexedDB.open('caps-probe', 1);
        r.onupgradeneeded = () => r.result.createObjectStore('k');
        r.onerror = () => res(false);
        r.onsuccess = () => { try {
          const t = r.result.transaction('k', 'readwrite'); t.objectStore('k').put(kp.privateKey, 'p');
          t.oncomplete = () => res(true); t.onerror = t.onabort = () => res(false);
        } catch { res(false); } };
      });
    } catch (e) { out.why = String(e); }
    return out; }`);
  return { chip, dot, waitDot, ls, call, tick, tap, caps };
}

async function boot(page, p) {
  await page.goto(`${BASE}/app.html`);
  await page.waitForSelector('#idrow', { timeout: 90000 });
}

let aid = '', bran = '';

async function leg(name, launch, act) {
  if (!ONLY.includes(name)) return;
  let b;
  try {
    b = await launch();
    await b.page.setViewport(1280, 800);
    const p = probes(b.page);
    await boot(b.page, p);
    const c = await p.caps();
    h.info(`${name}: ${q(c)}`);
    h.rec(`${name}: the page is a secure context with WebCrypto`, c.secure && c.subtle, q(c));
    const anon = await waitFor(async () => /create your identity/i.test(await p.chip()), 120000);
    h.rec(`${name}: the dial boots and reaches the gateway`, anon, await p.chip());
    if (anon) await act(b.page, p, c);
    const errs = b.page.errors.filter(e => !/404|favicon|reload-token|sw\.js/.test(e));
    h.rec(`${name}: no page errors`, errs.length === 0, errs.slice(0, 3).join(' | '));
  } catch (e) {
    h.info(`${name}: ${e?.stack ?? e}`);
    h.rec(`${name}: leg ran to completion`, false, String(e).slice(0, 120));
  } finally {
    if (b) await b.close().catch(() => {});
  }
}

/** After a seat: the reload. With a device key the seat returns on its own;
 *  on an engine that cannot hold one, the passcode is asked and seats it. */
async function reloadLeg(name, page, p, c) {
  const enrolled = await waitFor(async () => !!(await p.ls('pn.device.wire')), 20000);
  h.rec(`${name}: the device key is authorized${c.ed25519 ? '' : ' (engine has no WebCrypto Ed25519)'}`,
        enrolled === !!(c.ed25519 && c.idbKey), `enrolled=${enrolled}`);
  await boot(page, p);
  if (enrolled) {
    h.rec(`${name}: a reload stays signed in with no passcode`, (await p.waitDot('live', 90000)) === 'live', await p.dot());
    h.rec(`${name}: …as a device session`, (await p.call('tier')) === 'device');
  } else {
    h.rec(`${name}: a reload asks for the passcode`, (await p.waitDot('idle', 60000)) === 'idle', await p.dot());
    await page.evaluate(`async () => { (await import('/app/tabs/social/id.js')).openIdentityDoor(); return true; }`); await sleep(600);
    await page.evaluate(`() => { document.querySelector('#idform input[name="password"]').value = ${q(bran)}; return true; }`);
    await p.tick();
    await page.evaluate(`() => { document.querySelector('#idform form').requestSubmit(); return true; }`);
    h.rec(`${name}: …and the passcode seats it`, (await p.waitDot('live', 90000)) === 'live', await p.dot());
  }
}

await leg('firefox', () => launchFirefox(), async (page, p, c) => {
  await page.evaluate(`async () => { (await import('/app/tabs/social/id.js')).openIdentityDoor(); return true; }`); await sleep(600);
  await p.tick();
  await p.tap('#idform button.go', 'create your identity');
  await page.waitForSelector('#idform input[name="username"]', { timeout: 120000 });
  aid = await page.evaluate(`() => document.querySelector('#idform input[name="username"]').value`);
  bran = await page.evaluate(`() => document.querySelector('#idform input[name="password"]').value`);
  h.rec('firefox: identity created', /^E[A-Za-z0-9_-]{43}$/.test(aid) && bran.length >= 21, aid);
  await p.tick();
  await page.evaluate(`() => { document.querySelector('#idform form').requestSubmit(); return true; }`);
  h.rec('firefox: seated', (await p.waitDot('live', 90000)) === 'live', await p.dot());
  await reloadLeg('firefox', page, p, c);
});

await leg('webkit', () => launchWebKit(undefined, { direct: true }), async (page, p, c) => {
  if (!aid) { h.rec('webkit: an identity to sign in as', false, 'the firefox leg made none'); return; }
  await page.evaluate(`async () => { (await import('/app/tabs/social/id.js')).openIdentityDoor(); return true; }`); await sleep(600);
  await p.tap('#idform .gen2', 'I already have an identity'); await sleep(500);
  await page.evaluate(`() => {
    document.querySelector('#idform form input[name="username"]').value = ${q(aid)};
    document.querySelector('#idform form input[name="password"]').value = ${q(bran)};
    return true; }`);
  await p.tick();
  await page.evaluate(`() => { document.querySelector('#idform form').requestSubmit(); return true; }`);
  h.rec('webkit: AID + passcode from another engine seats the identity', (await p.waitDot('live', 90000)) === 'live', await p.dot());
  h.rec('webkit: …as the same AID', ((await p.ls('pn.id.hint')) || '').startsWith(aid + '|'));
  await reloadLeg('webkit', page, p, c);
});

summarize(h);
