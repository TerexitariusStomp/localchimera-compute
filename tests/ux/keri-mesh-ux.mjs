/// tests/ux/keri-mesh-ux.mjs — browser e2e WITH a real mesh hop.
///
/// The full mail round trip, no mocks anywhere:
///   1. real repl.wasm creates a persona, authenticates → the browser
///      SIGNS announce packets, the gateway verifies them against the
///      KEL anchor and relays via bridge B (ANNOUNCE_RAW) — both
///      destinations (ocapn + lxmf), and REGISTERs them;
///   2. announce propagates the TCP link to bridge A;
///   3. this test plays "remote sender": composes a REAL LXMF message
///      with rns-wasm (signed + encrypted to the persona's
///      OOBI-anchored pub) and injects it at bridge A (SEND_RAW);
///   4. the packet routes the hop, bridge B surfaces DELIVERY, the
///      gateway's ^mesh-mailbox stores ciphertext;
///   5. the browser reloads, unlocks, re-authenticates → drains the
///      mailbox, decrypts in rns-wasm, and logs the mail.
///
/// Run via: make test-keri-mesh-ux   (tests/ux/ux-mesh.sh boots it all)
import { harness, launch, newPage, openConnected, present, sleep,
         summarize } from './ux-harness.mjs';
import net from 'node:net';
import fs from 'node:fs';

const BASE = process.argv[2] || 'http://localhost:8089';
const SREF = process.argv[3] || '';
const OOBI = process.env.OOBI_URL || 'http://127.0.0.1:8099';
const A_SOCK = process.env.MESH_BRIDGE_A_SOCK;

const h = harness();
const browser = await launch();
// Explicit context: both sessions share it (same localStorage), and
// implicit per-page contexts can't spawn siblings. Service workers
// blocked — the dev sw.js (unstamped cache) intercepts the SECOND
// load and the wasm never boots.
const ctx = await browser.newContext({ serviceWorkers: 'block' });
function wire(p) {
  p.on('console', m => { const t = m.text(); if (t) h.logs.push(t.slice(0, 160)); });
  p.on('pageerror', e => h.errs.push(String(e).slice(0, 120)));
  return p;
}
let page = wire(await ctx.newPage());

const replLog = () =>
  page.evaluate(() => document.querySelector('#repl-log')?.textContent ?? '');
async function waitLog(re, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const m = (await replLog()).match(re);
    if (m) return m;
    await sleep(1000);
  }
  return null;
}

/** One command on a bridge control socket; resolves with the reply line. */
function bridgeCmd(sockPath, line, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const c = net.createConnection(sockPath);
    const t = setTimeout(() => { c.destroy(); reject(new Error('timeout')); }, timeoutMs);
    let buf = '';
    c.on('data', d => {
      buf += d.toString();
      if (buf.includes('\n')) { clearTimeout(t); c.end(); resolve(buf.trim()); }
    });
    c.on('error', e => { clearTimeout(t); reject(e); });
    c.on('connect', () => c.write(line + '\n'));
  });
}

const BRAN = 'mesh-e2e-passcode-21chars';

async function authenticate() {
  // The anchor TOGGLES the dropdown — after signup it is already
  // open (clicking would close it and silently skip the auth). Only
  // toggle when no dropdown content is visible.
  if (!(await present(page, '.id-page'))) {
    await page.click('.id-btn-anchor', { force: true, timeout: 15000 });
    await page.waitForSelector('.id-page', { timeout: 15000 }).catch(() => {});
  }
  // Fresh signup shows the "Save your passcode now" interstitial.
  if (await present(page, '.id-bran-display')) {
    await page.click('text=I have saved it', { force: true });
    await sleep(1200);
  }
  if (await present(page, '#id-bran-input')) {
    // locked → unlock first (key derivation takes a while)
    await page.fill('#id-bran-input', BRAN);
    await page.click('button.id-btn-primary', { force: true });
    await page.waitForSelector('.id-card-auth, .id-card-auth-ok, .id-error',
                               { timeout: 120000 }).catch(() => {});
    if (await present(page, '.id-error')) {
      h.info('unlock error: ' + JSON.stringify(await page.evaluate(() =>
        document.querySelector('.id-error')?.textContent ?? '')));
    }
  }
  // identity card → authenticate button (absent if already authed)
  const btn = await page.$('.id-card-auth button.id-btn');
  if (btn) await btn.click({ force: true });
  else h.info('authenticate(): no auth button; dropdown: ' +
    JSON.stringify(await page.evaluate(() =>
      document.querySelector('.id-page')?.innerHTML?.slice(0, 400) ?? '(none)')));
}

try {
  const { connected } = await openConnected(page, h, BASE, SREF);
  h.rec('WASM loads + gateway connects', connected);

  // ── 1. persona signup ────────────────────────────────────────────────
  await page.click('.id-btn-anchor');
  await sleep(800);
  await page.fill('#id-name-input',  'meshe2e');
  await page.fill('#id-email-input', 'meshe2e@playnet.test');
  await page.fill('#id-bran-input',  BRAN);
  await page.click('button.id-btn-primary');
  const reg = await waitLog(/\[keri\] registered AID (E[A-Za-z0-9_-]{43})/, 180000);
  h.rec('AID registered', !!reg, reg?.[1] ?? '');
  if (!reg) throw new Error('signup failed');
  const aid = reg[1];
  await waitLog(/\[keri\] OOBI endpoint replies registered/, 60000);

  // ── 2. authenticate → browser-signed announces relay via bridge B ────
  await authenticate();
  const authed = await waitLog(/\[keri\] authenticated as/, 60000);
  h.rec('authenticated', !!authed);
  if (!authed) {
    h.info('dropdown html: ' + JSON.stringify(await page.evaluate(() =>
      document.querySelector('.id-dropdown')?.innerHTML?.slice(0, 600) ?? '(no dropdown)')));
    h.info('anchor: ' + JSON.stringify(await page.evaluate(() =>
      document.querySelector('.id-btn-anchor')?.textContent ?? '(none)')));
    h.info('log tail: ' + JSON.stringify((await replLog()).slice(-300)));
  }
  h.rec('ocapn announce relayed over the REAL bridge',
        !!(await waitLog(/\[reticulum\] ocapn announce relayed/, 60000)));
  h.rec('lxmf announce relayed over the REAL bridge',
        !!(await waitLog(/\[reticulum\] lxmf announce relayed/, 30000)));

  // ── 3. compose REAL LXMF mail to the persona's OOBI-anchored pub ─────
  let body = '';
  for (let i = 0; i < 30 && !body.includes('playnet-reticulum-pub'); i++) {
    const r = await fetch(`${OOBI}/oobi/${aid}`).catch(() => null);
    if (r?.ok) body = await r.text();
    if (!body.includes('playnet-reticulum-pub')) await sleep(2000);
  }
  const pubHex = body.match(/"playnet-reticulum-pub":"([0-9a-f]{128})"/)?.[1];
  h.rec('OOBI anchors the persona mesh pub', !!pubHex);
  if (!pubHex) throw new Error('no anchored pub in OOBI');

  const pkg = process.cwd() + '/rns-wasm/pkg';
  const wasm = await import('file://' + pkg + '/rns_wasm.js');
  await wasm.default(fs.readFileSync(pkg + '/rns_wasm_bg.wasm'));
  const seed = new Uint8Array(64); crypto.getRandomValues(seed);
  const sender = wasm.Identity.fromPrivateKey(seed);
  const pub = new Uint8Array(pubHex.match(/.{2}/g).map(b => parseInt(b, 16)));
  const pkt = sender.packLxmfPacket(pub, 'mesh e2e', 'hello across the hop',
                                    Date.now() / 1000);
  const pktHex = Array.from(pkt).map(b => b.toString(16).padStart(2, '0')).join('');

  // Give the announce a moment to finish propagating B → A.
  await sleep(4000);

  // ── 4. inject at bridge A; it must route the TCP hop ─────────────────
  const sendReply = await bridgeCmd(A_SOCK, 'SEND_RAW ' + pktHex);
  h.rec('mail packet injected at bridge A (SEND_RAW)', sendReply === 'OK',
        sendReply);

  // ── 5. fresh session → unlock → authenticate → drain the mail ────────
  await sleep(5000); // route + DELIVERY + mailbox store
  // SAME context — the persona's localStorage identity persists.
  await page.close();
  page = wire(await ctx.newPage());
  let second = { connected: false };
  try {
    second = await openConnected(page, h, BASE, SREF);
  } catch (e) {
    h.info('second load failed: ' + e.message.slice(0, 120));
    h.info('page html: ' + JSON.stringify(
      await page.content().then(c => c.slice(0, 500)).catch(() => '?')));
    h.info('console tail: ' + JSON.stringify(h.logs.slice(-10)));
  }
  h.rec('second session connects', second.connected);
  await authenticate();
  const mail = await waitLog(/\[lxmf\] mail from unknown sender [0-9a-f]+/,
                             90000);
  h.rec('mesh mail drained + decrypted in the browser', !!mail,
        mail?.[0] ?? '');
  if (!mail) {
    h.info('repl-log tail: ' + JSON.stringify((await replLog()).slice(-600)));
  }
  h.rec('no decrypt failure logged',
        !(await replLog()).includes('decrypt failed'));
} catch (e) {
  h.rec('fatal', false, e.message);
} finally {
  await browser.close();
}

summarize(h, ['WASM loads + gateway connects',
              'AID registered',
              'authenticated',
              'ocapn announce relayed over the REAL bridge',
              'lxmf announce relayed over the REAL bridge',
              'OOBI anchors the persona mesh pub',
              'mail packet injected at bridge A (SEND_RAW)',
              'mesh mail drained + decrypted in the browser']);
