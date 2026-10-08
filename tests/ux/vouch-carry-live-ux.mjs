/// tests/ux/vouch-carry-live-ux.mjs — a vouch that travels, live.
///
/// Two real gateways (SECOND_GATEWAY=1), each polling the other's static
/// tier for witness asks, sharing nothing else. At commune A: Alice is the
/// founder's first person; Tia asks and Alice vouches her in; Alice speaks
/// a relationship — "Tia, friends" — the signed credential the steward gate
/// reads. Tia's dial carries her identity, her key log, her personhood and
/// the bundle A hands her (Alice's vouch, Alice's personhood and key log,
/// the root's blessing). On a device that only knows commune B she unlocks,
/// joins, and presents the bundle: B's store — which never held any of it —
/// now carries Alice's vouch for Tia. Then Bo asks at A; Alice signs one of
/// two; Tia, recognised at B, sees the ask on B's rail and signs from there;
/// her signature crosses to A beside her bundle, A checks a key it never
/// saw, and Bo is recognised.
///
/// Run via:  make test-vouch-carry-live-ux

import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { harness, launch, newPage, sleep, summarize } from './ux-harness.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';
const BASE2 = process.env.UX_BASE2 || '';
const DATA2 = process.env.PLAYNET_DATA_DIR2 || '';

const h = harness();
const browser = await launch();

const dial = (page, expr) =>
  page.evaluate(`(() => { const H = window.__seam.handlers; return ${expr}; })()`);
const parse = (s, fallback = {}) => { try { return JSON.parse(s); } catch { return fallback; } };
const chipOf = (page) => page.evaluate(() => document.querySelector('#idrow .who')?.textContent ?? '');
const titleOf = (page) => page.evaluate(() => document.querySelector('#idrow .who')?.getAttribute('title') ?? '');
async function waitChip(page, re, ms = 180000) {
  const dl = Date.now() + ms; let c = '';
  while (Date.now() < dl) { c = await chipOf(page); if (re.test(c)) break; await sleep(1000); }
  return c;
}
async function waitDot(page, want, ms = 60000) {
  const dl = Date.now() + ms; let dot = '';
  while (Date.now() < dl) {
    dot = await page.evaluate(() => {
      const d = document.querySelector('#idrow .dot');
      return d ? [...d.classList].filter(c => c !== 'dot').join(' ') : '';
    });
    if (dot === want) break;
    await sleep(500);
  }
  return dot;
}
const tickConsent = (page) => page.evaluate(() => {
  const box = document.querySelector('#idform input[type="checkbox"]');
  if (box && !box.checked) box.click();
});
async function until(fn, ms = 40000, step = 1000) {
  const dl = Date.now() + ms;
  while (Date.now() < dl) { const v = await fn(); if (v) return v; await sleep(step); }
  return await fn();
}

/// A citizen at BASE: real one-tap create. Returns { page, aid, bran }.
async function citizen(label, base = BASE) {
  const ctx = await browser.newContext();
  const page = await newPage(ctx, h);
  await page.goto(`${base}/app.html`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 60000 });
  const chip = await waitChip(page, /create your identity/i);
  h.rec(`${label}: dial connects`, /create your identity/i.test(chip), chip);
  await page.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
  await sleep(600);
  await tickConsent(page);
  await sleep(200);
  await page.click('#idform button.go:has-text("create your identity")');
  await page.waitForSelector('#idform input[name="username"]', { timeout: 120000 }).catch(() => {});
  const creds = await page.evaluate(() => ({
    aid: document.querySelector('#idform input[name="username"]')?.value ?? '',
    bran: document.querySelector('#idform input[name="password"]')?.value ?? '',
  }));
  h.rec(`${label}: identity minted`, /^E[A-Za-z0-9_-]{43}$/.test(creds.aid), creds.aid || '(none)');
  await waitDot(page, 'live', 30000);
  return { page, ...creds };
}
const isPerson = (page) => until(async () => !!parse(await dial(page, `H.fpStatus()`)).person, 20000);
const askRow = (page, cand) => until(async () => {
  const rows = parse(await dial(page, `H.witnessInbox()`), []);
  return (Array.isArray(rows) ? rows : []).find(r => r.kind === 'enroll' && r.worker === cand) || null;
}, 40000);

try {
  h.rec('a second commune is up', !!BASE2 && !!DATA2, `${BASE2} · ${DATA2}`);

  // ── commune A: Alice, Tia, and a vouch ─────────────────────────────────
  const alice = await citizen('Alice at A');
  const tia = await citizen('Tia at A');
  await sleep(1500);
  const genesis = await dial(alice.page, `H.fpGrant(${JSON.stringify(alice.aid)})`);
  h.rec('genesis: Alice is the first person', genesis === 'ok', String(genesis));
  h.rec('Alice holds a live PHC', await isPerson(alice.page));
  h.rec('Tia asks', (await dial(tia.page, `H.fpEnroll()`)) === 'ok');
  const rowT = await askRow(alice.page, tia.aid);
  if (rowT) h.rec('Alice vouches Tia in', (await dial(alice.page, `H.witnessAttest(${JSON.stringify(rowT.said)})`)) === 'ok:finalized');
  h.rec('Tia is recognised at A', await isPerson(tia.page));
  h.rec('Alice speaks a relationship — Tia, friends (a signed credential)',
        (await dial(alice.page, `H.fpVouch(${JSON.stringify(tia.aid)}, "friends")`)) === 'ok');

  // what Tia carries
  const bundle = await until(async () => {
    const b = await dial(tia.page, `H.fpMyVouches()`);
    return (typeof b === 'string' && b.includes('playnet-relationship')) ? b : null;
  }, 20000);
  h.rec('Tia\'s bundle carries Alice\'s vouch, and Alice\'s key log',
        !!bundle && bundle.includes(`"${alice.aid}"`) && bundle.includes('"kels"'),
        bundle ? `${bundle.length} bytes` : '(none)');
  await dial(tia.page, `H.fpMyPhc().then(c => { if (typeof c === "string" && c.startsWith("{")) localStorage.setItem("pn.id.phc", c); return c; })`);
  const carried = await tia.page.evaluate(() => ({
    hint: localStorage.getItem('pn.id.hint') || '',
    kel: localStorage.getItem('pn.id.kel') || '',
    phc: localStorage.getItem('pn.id.phc') || '',
  }));
  h.rec('Tia\'s browser holds her log and personhood to carry',
        carried.kel.includes(`"i":"${tia.aid}"`) && carried.phc.startsWith('{'));

  // ── commune B: Tia arrives with what she carries ───────────────────────
  const ctxB = await browser.newContext();
  const b = await newPage(ctxB, h);
  await b.goto(`${BASE2}/app.html`, { waitUntil: 'domcontentloaded' });
  await b.waitForSelector('#idrow', { timeout: 60000 });
  await waitChip(b, /create your identity/i);
  h.rec('B has never seen Tia', !existsSync(`${DATA2}/oobi-host/${tia.aid.slice(0, 2)}/${tia.aid}.scm`));
  await b.evaluate(([hint, kel, phc, vouches]) => {
    localStorage.setItem('pn.id.hint', hint);
    localStorage.setItem('pn.id.kel', kel);
    localStorage.setItem('pn.id.phc', phc);
    localStorage.setItem('pn.id.vouches', vouches);
  }, [carried.hint, carried.kel, carried.phc, bundle || '']);
  await b.reload({ waitUntil: 'domcontentloaded' });
  await b.waitForSelector('#idrow', { timeout: 60000 });
  await waitDot(b, 'idle', 120000);
  await b.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor()); await sleep(500);
  await b.fill('#idform input[name="password"]', tia.bran);
  await tickConsent(b);
  await b.click('#idform button[type="submit"]');
  const unreg = await waitDot(b, 'warn');
  h.rec('Tia unlocks at B, unregistered — offered to join', unreg === 'warn', `${unreg} · ${await titleOf(b)}`);
  await b.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor()); await sleep(500);
  await tickConsent(b);
  await b.click('#idform button.go:has-text("join as")');
  h.rec('Tia is seated at B', (await waitDot(b, 'live')) === 'live');
  // B learns A's root through the peer poll; the bundle stands the moment
  // it has — so the presentation is retried until it does
  let presented = '';
  await until(async () => {
    presented = String(await dial(b, `H.fpPresentBundle(${JSON.stringify(bundle || '')})`));
    return presented.startsWith('ok:');
  }, 120000, 3000);
  h.rec('the bundle is accepted at B — a root B learned from its peer', presented.startsWith('ok:'), presented);
  h.rec('Tia is a person at B — her carried personhood stands', await isPerson(b));
  const storeHasVouch = await until(async () => {
    const dir = `${DATA2}/acdc`;
    if (!existsSync(dir)) return false;
    const walk = (d) => readdirSync(d, { withFileTypes: true }).flatMap(e =>
      e.isDirectory() ? walk(`${d}/${e.name}`) : [`${d}/${e.name}`]);
    return walk(dir).some(f => { try { const t = readFileSync(f, 'utf8');
      return t.includes('playnet-relationship') && t.includes(alice.aid) && t.includes(tia.aid); } catch { return false; } });
  }, 20000);
  h.rec('B\'s store holds Alice\'s vouch for Tia — a store that never met Alice', storeHasVouch);
  h.rec('B holds Alice\'s key log now', existsSync(`${DATA2}/oobi-host/${alice.aid.slice(0, 2)}/${alice.aid}.scm`));

  // ── Bo asks at A; Tia witnesses from B ──────────────────────────────────
  const bo = await citizen('Bo at A');
  await sleep(1000);
  h.rec('Bo asks at A', (await dial(bo.page, `H.fpEnroll()`)) === 'ok');
  const mine = parse(await dial(bo.page, `H.fpMyCeremony()`));
  h.rec('Bo\'s ask wants two — Alice and Tia are recognised at A', mine.quorum === 2, JSON.stringify(mine));
  const rowBA = await askRow(alice.page, bo.aid);
  if (rowBA) h.rec('Alice signs — one of two', (await dial(alice.page, `H.witnessAttest(${JSON.stringify(rowBA.said)})`)) === 'ok:attested');
  const rowBB = await askRow(b, bo.aid);
  h.rec('the ask reaches Tia\'s rail at B through the peer poll', !!rowBB, rowBB ? rowBB.said.slice(0, 12) : '(none)');
  if (rowBB) {
    const sent = await dial(b, `H.witnessAttest(${JSON.stringify(rowBB.said)})`);
    h.rec('Tia signs from B — her signature leaves beside her bundle', sent === 'ok:sent', String(sent));
  }
  h.rec('Bo is recognised at A — a witness A had never seen, checked by her carried key log',
        await until(async () => !!parse(await dial(bo.page, `H.fpStatus()`)).person, 60000));
  h.rec('no page errors during the flow', h.errs.length === 0, h.errs.slice(0, 2).join(' | '));
} catch (e) {
  h.info('exception: ' + (e?.stack ?? String(e)));
  h.rec('test ran to completion', false);
} finally {
  await browser.close();
}

summarize(h, ['a second commune is up',
              'B\'s store holds Alice\'s vouch for Tia — a store that never met Alice',
              'Bo is recognised at A — a witness A had never seen, checked by her carried key log']);
