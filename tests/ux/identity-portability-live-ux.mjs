/// tests/ux/identity-portability-live-ux.mjs — one identity, several devices, a
/// gateway that restarts underneath them.
///
/// signup-live-ux covers the create, the offline unlock and the recovery file;
/// device-live-ux covers the device key on one browser. This walks the roads
/// between devices, each device a browser context with its own storage:
///
///   A  creates the identity, names it, stays signed in
///   B  signs in with AID + passcode alone (a wrong passcode is refused first),
///      gets its own device key, is retired from A
///   C  comes back through recovery friends: one piece is refused, pieces of
///      two splittings are refused, the threshold opens the identity
///   P  holds the passcode and nothing else: the commune finds the log the
///      passcode opens, the device checks it and is seated
///   D  loses half its storage — the key store, then the hint — and the
///      passcode brings it back each time
///   then the gateway is killed and started again on the same data dir:
///   A's seat returns, and a device that never saw the first process (E)
///   signs in with the passcode alone and reads the name A set
///
/// Run via:  make test-identity-portability-live-ux
///           PLAYNET_SCOPES_DURABLE=1 bash tests/ux/ux-full.sh tests/ux/identity-portability-live-ux.mjs

import { existsSync, readFileSync, readlinkSync, openSync, unlinkSync } from 'node:fs';
import { execSync, spawn } from 'node:child_process';
import { harness, launch, newPage, sleep, summarize } from './ux-harness.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';
const DATA = process.env.PLAYNET_DATA_DIR || '.ux-e2e-data';
const SREF_FILE = process.env.GATEWAY_SREF_FILE || `${DATA}/gateway-sref.txt`;
const GW_PORT = process.env.GATEWAY_PORT || '9097';

const h = harness();
const browser = await launch();
let respawned = null;

const waitFor = async (pred, ms = 30000, step = 500) => {
  const dl = Date.now() + ms;
  while (Date.now() < dl) { try { if (await pred()) return true; } catch {} await sleep(step); }
  return false;
};
const chipText = (pg) => pg.evaluate(() => document.querySelector('#idrow .who')?.textContent ?? '');
const dotIn = (pg) => pg.evaluate(() =>
  (document.querySelector('#idrow .who .dot')?.className || '').replace('dot', '').trim());
const waitDot = async (pg, cls, ms = 60000) => {
  const dl = Date.now() + ms; let d = '';
  while (Date.now() < dl) { try { d = await dotIn(pg); } catch { d = ''; } if (d === cls) return d; await sleep(500); }
  return d;
};
const call = (pg, name, ...args) => pg.evaluate(async ([n, a]) => {
  const { HANDLERS } = await import('/app/core.js');
  return HANDLERS[n] ? String(await HANDLERS[n](...a)) : '(no handler)';
}, [name, args]);
const ls = (pg, key) => pg.evaluate(k => localStorage.getItem(k), key);
const bodyText = (pg) => pg.evaluate(() => document.body.textContent || '');
const tick = (pg, scope = '#idform') => pg.evaluate(s => {
  document.querySelectorAll(`${s} input[type="checkbox"]`).forEach(b => { if (!b.checked) b.click(); });
}, scope);

/** A device: its own context, so its own localStorage and IndexedDB. The
 *  entry point is read from the gateway's sref file on every request, as the
 *  production static tier does — a restarted gateway has a new sturdyref. */
async function device(label) {
  const pg = await newPage(browser, h);
  pg.on('console', m => { const t = m.text(); if (t) h.logs.push(`[${label}] ${t.slice(0, 140)}`); });
  await pg.route('**/entry-points.json', route => {
    let sref = '';
    try { sref = readFileSync(SREF_FILE, 'utf8').trim().split('?')[0]; } catch {}
    route.fulfill({ contentType: 'application/json', body: JSON.stringify({ sref, gateway: [] }) });
  });
  return pg;
}
async function open(pg) {
  await pg.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
  await pg.waitForSelector('#idrow', { timeout: 60000 });
}
const waitAnonymous = (pg) => waitFor(async () => /create your identity/i.test(await chipText(pg)), 90000);

/** The sheet's third door: AID + passcode typed on a device that holds nothing. */
async function signInWithAid(pg, aid, bran) {
  if (!(await pg.evaluate(() => !!document.querySelector('#idform')))) { await pg.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor()); await sleep(500); }
  if (!(await pg.evaluate(() => !!document.querySelector('#idform form input[name="username"]:not([readonly])')))) {
    await pg.click('#idform .gen2:has-text("I already have an identity"), #idform .gen2:has-text("another way in")');
    await sleep(400);
  }
  await pg.fill('#idform form input[name="username"]', aid);
  await pg.fill('#idform form input[name="password"]', bran);
  await tick(pg, '#idform form');
  await pg.click('#idform form button[type="submit"]');
}
/** The unlock sheet of a device that remembers the identity. */
async function unlockHere(pg, bran) {
  await pg.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor()); await sleep(500);
  await pg.fill('#idform input[name="password"]', bran);
  await tick(pg);
  await pg.click('#idform button[type="submit"]');
}
const liveDevices = async (pg) => {
  try { return JSON.parse(await call(pg, 'devices')).filter(d => !d.revokedAt); } catch { return null; }
};

try {
  // ── A: create, name, stay signed in ────────────────────────────────────
  const A = await device('A');
  await open(A);
  const connected = await waitAnonymous(A);
  h.rec('dial connects to the gateway', connected, await chipText(A));
  if (!connected) throw new Error('no gateway');

  // on a phone's width: the sheet a newcomer reads the passcode from
  await A.setViewportSize({ width: 390, height: 844 });
  await A.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor()); await sleep(600);
  await tick(A);
  await A.click('#idform button.go:has-text("create your identity")');
  await A.waitForSelector('#idform input[name="username"]', { timeout: 120000 });
  const sheet = await A.evaluate(() => {
    const f = document.querySelector('#idform');
    const inside = el => { const r = el.getBoundingClientRect(), b = f.getBoundingClientRect();
                           return r.width > 0 && r.left >= b.left - 1 && r.right <= b.right + 1; };
    const done = [...f.querySelectorAll('button')].find(b => /^done$/.test(b.textContent.trim()));
    return {
      noSideways: f.scrollWidth <= f.clientWidth + 1,
      fieldsInside: [...f.querySelectorAll('input:not([type="checkbox"]), button')].every(inside),
      done: !!done && inside(done),
      identifier: f.querySelector('input[name="username"]')?.value || '',
      identifierShown: (() => { const u = f.querySelector('input[name="username"]'); const r = u.getBoundingClientRect();
                                return r.width > 200 && getComputedStyle(u).opacity !== '0'; })(),
    };
  });
  h.rec('A: the created sheet fits a phone — nothing runs off its edge',
        sheet.noSideways && sheet.fieldsInside, JSON.stringify(sheet));
  h.rec('A: …with its done button on it', sheet.done);
  h.rec('A: …and the identifier shown beside the passcode', sheet.identifierShown && /^E[A-Za-z0-9_-]{43}$/.test(sheet.identifier));
  await A.setViewportSize({ width: 1280, height: 720 });
  const aid = await A.evaluate(() => document.querySelector('#idform input[name="username"]').value);
  const bran = await A.evaluate(() => document.querySelector('#idform input[name="password"]').value);
  h.rec('A: identity created', /^E[A-Za-z0-9_-]{43}$/.test(aid) && bran.length >= 21, aid);

  // the name typed on the created sheet, at the pace of someone who reads the
  // sheet: straight away, before the seat report has come back
  await A.fill('#idform input[name="nickname"]', 'ada');
  await tick(A);
  await A.evaluate(() => document.querySelector('#idform form').requestSubmit());
  h.rec('A: seated', (await waitDot(A, 'live', 90000)) === 'live');
  h.rec('A: the chip says the name', /ada/.test(await chipText(A)), await chipText(A));
  await sleep(3000);
  const nameAtCommune = async (pg) => { try { return JSON.parse(await call(pg, 'profileGet')).name; } catch (e) { return `(${e.message})`; } };
  const pushed = await nameAtCommune(A);
  h.rec('A: the name typed at creation reaches the commune', pushed === 'ada', JSON.stringify(pushed));
  if (pushed !== 'ada') {
    // keep the walk going on the documented path: a save with a seat
    h.info('saving the name again with the seat held: ' + await call(A, 'profileSet', 'ada', ''));
  }
  h.rec('A: this browser holds a device authorization',
        await waitFor(async () => !!(await ls(A, 'pn.device.wire'))));
  const kelA = await ls(A, 'pn.id.kel');

  // ── B: AID + passcode on a device that holds nothing ───────────────────
  const B = await device('B');
  await open(B);
  h.rec('B: a fresh device is anonymous', await waitAnonymous(B));
  await signInWithAid(B, aid, bran.slice(0, -1) + (bran.endsWith('a') ? 'b' : 'a'));
  const refused = await waitFor(async () => /wrong passcode/i.test(await bodyText(B)), 30000);
  h.rec('B: a wrong passcode is refused', refused && (await dotIn(B)) !== 'live');
  h.rec('B: …and leaves nothing behind',
        !(await ls(B, 'pn.id.hint')) && !(await ls(B, 'pn.id.kel')) && !(await ls(B, 'pn.device.wire')));
  await signInWithAid(B, aid, bran);
  h.rec('B: AID + passcode seats the identity', (await waitDot(B, 'live', 90000)) === 'live');
  h.rec('B: the device now keeps the log, equal to A\'s', (await ls(B, 'pn.id.kel')) === kelA);
  h.rec('B: the commune\'s name for this identity reads back', (await nameAtCommune(B)) === 'ada', JSON.stringify(await nameAtCommune(B)));
  await sleep(2000);
  h.rec('B: the chip says the name the identity carries', /ada/.test(await chipText(B)), await chipText(B));
  h.rec('B: gets a device key of its own',
        await waitFor(async () => !!(await ls(B, 'pn.device.wire'))));
  const saidB = await B.evaluate(() => { try { return JSON.parse(localStorage.getItem('pn.device.wire')).said; } catch { return ''; } });
  const both = await liveDevices(A);
  h.rec('A: sees two devices signed in', Array.isArray(both) && both.length === 2, JSON.stringify(both)?.slice(0, 120));
  await B.reload({ waitUntil: 'domcontentloaded' });
  await B.waitForSelector('#idrow', { timeout: 60000 });
  h.rec('B: a refresh stays signed in without the passcode', (await waitDot(B, 'live', 60000)) === 'live');

  // the identity sheet opened from settings stands above settings
  await A.evaluate(async () => { (await import('/app/settings.js')).openSettings('identity'); });
  await sleep(600);
  await A.evaluate(() => [...document.querySelectorAll('#setface .vbtn, #setface button')].find(b => /open it/.test(b.textContent))?.click());
  await sleep(700);
  h.rec('A: "open it" in settings shows the identity sheet above settings',
        await A.evaluate(() => {
          const f = document.querySelector('#idform'); if (!f) return false;
          const r = f.getBoundingClientRect();
          const top = document.elementFromPoint(r.left + r.width / 2, r.top + 24);
          return !!top && f.contains(top);
        }));
  await A.evaluate(() => document.querySelector('#idform .idclose')?.click());
  await A.evaluate(async () => { (await import('/app/settings.js')).closeSettings(); });
  await sleep(300);

  // splitting the passcode is the passcode's own act: a device session
  // steps up with it, once
  h.rec('B: after the refresh the session is the device key\'s', (await call(B, 'tier')) === 'device');
  h.rec('B: a device session cannot split the passcode', /unlock first/.test(await call(B, 'guardianSplit', '2', '3')));
  const stepUp = await call(B, 'unlock', bran, aid, '');
  h.rec('B: the passcode steps the session up', /^ok:/.test(stepUp) && (await call(B, 'tier')) === 'root', stepUp.slice(0, 20));
  const stepSplit = await call(B, 'guardianSplit', '2', '3');
  h.rec('B: …and then the passcode splits', (() => { try { return JSON.parse(stepSplit).length === 3; } catch { return false; } })());

  // ── A retires B ────────────────────────────────────────────────────────
  h.rec('A: retires B', (await call(A, 'revokeDevice', saidB)) === 'ok');
  await B.reload({ waitUntil: 'domcontentloaded' });
  await B.waitForSelector('#idrow', { timeout: 60000 });
  const out = await waitFor(async () => !(await ls(B, 'pn.device.wire')) && (await dotIn(B)) === 'idle', 45000);
  h.rec('B: a retired device asks for the passcode again', out, `${await dotIn(B)} · ${await chipText(B)}`);
  h.rec('A: is untouched by retiring B', (await dotIn(A)) === 'live' && (await liveDevices(A))?.length === 1);
  await B.close();

  // ── C: recovery friends ────────────────────────────────────────────────
  const split1 = JSON.parse(await call(A, 'guardianSplit', '2', '3'));
  const split2 = JSON.parse(await call(A, 'guardianSplit', '2', '3'));
  h.rec('A: the passcode splits into three pieces', Array.isArray(split1) && split1.length === 3 && split1.every(l => /^pnr1\./.test(l)));
  h.rec('A: no piece contains the passcode', split1.every(l => !l.includes(bran)));
  const C = await device('C');
  await open(C);
  await waitAnonymous(C);
  await C.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor()); await sleep(500);
  await C.click('#idform .gen2:has-text("I already have an identity")'); await sleep(400);
  const tryPieces = async (lines) => {
    await C.fill('#idform textarea', lines.join('\n'));
    await C.click('#idform button.go:has-text("put my passcode back together")');
    await sleep(2500);
    return C.evaluate(() => [...document.querySelectorAll('#idform .err')].map(e => e.textContent).join(' | '));
  };
  const one = await tryPieces([split1[0]]);
  h.rec('C: one piece of two is refused', /1 of the 2/.test(one) && (await dotIn(C)) !== 'live', one);
  const mixed = await tryPieces([split1[0], split2[1]]);
  h.rec('C: pieces of two splittings are refused', /different splittings/.test(mixed) && (await dotIn(C)) !== 'live', mixed);
  await C.fill('#idform textarea', [split1[2], split1[0]].join('\n'));
  await C.click('#idform button.go:has-text("put my passcode back together")');
  h.rec('C: two pieces open the identity on a new device', (await waitDot(C, 'live', 90000)) === 'live');
  h.rec('C: …as the same AID', ((await ls(C, 'pn.id.hint')) || '').startsWith(aid + '|'));
  await C.close();

  // ── P: the passcode and nothing else ───────────────────────────────────
  const P = await device('P');
  await open(P);
  await waitAnonymous(P);
  await signInWithAid(P, '', 'a-passcode-nobody-made-21-chars');
  const noSuch = await waitFor(async () => /holds no identity for that passcode/i.test(await bodyText(P)), 30000);
  h.rec('P: a passcode that opens nothing here is told so', noSuch && (await dotIn(P)) !== 'live');
  h.rec('P: …and leaves nothing behind', !(await ls(P, 'pn.id.hint')) && !(await ls(P, 'pn.id.kel')));
  await signInWithAid(P, '', bran);
  h.rec('P: the passcode alone seats the identity', (await waitDot(P, 'live', 90000)) === 'live', await dotIn(P));
  h.rec('P: …as the same identifier', ((await ls(P, 'pn.id.hint')) || '').startsWith(aid + '|'));
  h.rec('P: …keeping the same log A wrote', (await ls(P, 'pn.id.kel')) === kelA);
  await sleep(2000);
  h.rec('P: …and saying the name', /ada/.test(await chipText(P)), await chipText(P));
  await P.close();

  // ── D: half the storage goes ───────────────────────────────────────────
  const D = await device('D');
  await open(D);
  await waitAnonymous(D);
  await signInWithAid(D, aid, bran);
  h.rec('D: seated', (await waitDot(D, 'live', 90000)) === 'live');
  await waitFor(async () => !!(await ls(D, 'pn.device.wire')));
  const saidOf = (pg) => pg.evaluate(() => { try { return JSON.parse(localStorage.getItem('pn.device.wire')).said; } catch { return ''; } });
  const lostSaid = await saidOf(D);
  // the key store is evicted, the localStorage record of it stays
  await D.evaluate(() => new Promise(res => {
    const r = indexedDB.deleteDatabase('playnet-keys'); r.onsuccess = r.onerror = r.onblocked = () => res(null);
  }));
  await D.reload({ waitUntil: 'domcontentloaded' });
  await D.waitForSelector('#idrow', { timeout: 60000 });
  await sleep(8000);
  const afterEvict = `${await dotIn(D)} · ${await chipText(D)}`;
  h.rec('D: with its key store gone the device offers the passcode', (await dotIn(D)) === 'idle', afterEvict);
  await unlockHere(D, bran);
  h.rec('D: …and the passcode seats it', (await waitDot(D, 'live', 90000)) === 'live', await dotIn(D));
  h.rec('D: …and authorizes a fresh key', await waitFor(async () => !!(await ls(D, 'pn.device.wire'))));
  await D.reload({ waitUntil: 'domcontentloaded' });
  await D.waitForSelector('#idrow', { timeout: 60000 });
  h.rec('D: …and the next refresh is signed in again', (await waitDot(D, 'live', 60000)) === 'live', await dotIn(D));
  const afterOrphan = await liveDevices(D);
  const freshSaid = await saidOf(D);
  h.rec('D: the authorization of the lost key is retired, the fresh one live',
        Array.isArray(afterOrphan) && !!lostSaid && freshSaid !== lostSaid
        && !afterOrphan.some(d => d.said === lostSaid) && afterOrphan.some(d => d.said === freshSaid),
        `${afterOrphan?.length} live`);
  // now the hint and the log go, the key store stays
  await D.evaluate(() => localStorage.clear());
  await D.reload({ waitUntil: 'domcontentloaded' });
  await D.waitForSelector('#idrow', { timeout: 60000 });
  h.rec('D: with its localStorage gone the device is anonymous', await waitAnonymous(D), await chipText(D));
  await signInWithAid(D, aid, bran);
  h.rec('D: …and AID + passcode seats it', (await waitDot(D, 'live', 90000)) === 'live', await dotIn(D));
  await D.close();

  // ── the gateway dies and comes back on the same data dir ───────────────
  const pid = execSync(`ss -ltnpH 'sport = :${GW_PORT}' | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2`).toString().trim();
  const exe = readlinkSync(`/proc/${pid}/exe`);
  const argv = readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0').filter(Boolean);
  const env = Object.fromEntries(readFileSync(`/proc/${pid}/environ`, 'utf8').split('\0').filter(Boolean)
    .map(kv => { const i = kv.indexOf('='); return [kv.slice(0, i), kv.slice(i + 1)]; }));
  const cwd = readlinkSync(`/proc/${pid}/cwd`);
  const srefBefore = readFileSync(SREF_FILE, 'utf8').trim();
  process.kill(Number(pid), 'SIGKILL');
  h.rec('A: reports the commune gone', await waitFor(async () => (await dotIn(A)) !== 'live', 30000), await dotIn(A));
  unlinkSync(SREF_FILE);
  const log = openSync(`${DATA}/gateway.log`, 'a');
  respawned = spawn(exe, argv.slice(1), { cwd, env, detached: true, stdio: ['ignore', log, log] });
  respawned.unref();
  const up = await waitFor(() => existsSync(SREF_FILE), 240000, 2000);
  h.rec('the gateway starts again on the same data', up);
  if (up) {
    h.info(`sturdyref ${readFileSync(SREF_FILE, 'utf8').trim() === srefBefore ? 'unchanged' : 'changed'} across the restart`);
    const backA = await waitDot(A, 'live', 120000);
    h.rec('A: the open page takes its seat again on its own', backA === 'live', `${backA} · ${await chipText(A)}`);
    if (backA !== 'live') {
      await A.reload({ waitUntil: 'domcontentloaded' });
      await A.waitForSelector('#idrow', { timeout: 60000 });
      h.rec('A: …a refresh takes the seat', (await waitDot(A, 'live', 90000)) === 'live', await dotIn(A));
    }
    // the seat report and the session's first answer, told apart: a seat
    // that reports and then cannot answer is a connection that dropped again
    const t0 = Date.now();
    const first = await nameAtCommune(A);
    if (first !== 'ada') {
      h.info(`A: first read after the seat: ${JSON.stringify(first)}`);
      h.info('A: its reports since the restart: ' + JSON.stringify(
        h.logs.filter(l => /^\[A\]/.test(l) && /status|reconnect|sever|gw:/.test(l)).slice(-14)));
    }
    h.rec('A: the seat answers at once', first === 'ada', JSON.stringify(first));
    await waitFor(async () => (await nameAtCommune(A)) === 'ada', 60000);
    h.info(`A: session answering ${Date.now() - t0} ms after the seat report`);
    h.rec('A: the name survived the restart', (await nameAtCommune(A)) === 'ada', JSON.stringify(await nameAtCommune(A)));
    const kept = await liveDevices(A);
    h.rec('A: the device registry survived the restart', Array.isArray(kept) && kept.length >= 1, JSON.stringify(kept)?.slice(0, 120));
    const E = await device('E');
    await open(E);
    h.rec('E: a new device reaches the restarted gateway', await waitAnonymous(E));
    await signInWithAid(E, '', bran);
    h.rec('E: the passcode alone seats the identity after the restart', (await waitDot(E, 'live', 90000)) === 'live', await dotIn(E));
    h.rec('E: …and reads the name A set', (await nameAtCommune(E)) === 'ada', JSON.stringify(await nameAtCommune(E)));

    // ── sign out ─────────────────────────────────────────────────────────
    await waitFor(async () => !!(await ls(E, 'pn.device.wire')));
    await E.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor()); await sleep(600);
    await E.click('#idform .signout'); await sleep(300);
    await E.click('#idform .signout.arm');
    await sleep(3000);
    await E.waitForSelector('#idrow', { timeout: 60000 });
    h.rec('E: signing out leaves the device anonymous', await waitAnonymous(E), await chipText(E));
    h.rec('E: …with no identity material in localStorage',
          await E.evaluate(() => Object.keys(localStorage).filter(k => /^playnet-keri/.test(k)).length === 0),
          await E.evaluate(() => Object.keys(localStorage).filter(k => /^playnet-keri/.test(k)).join(',')));
    h.rec('E: …and no key in the key store',
          await E.evaluate(() => new Promise(res => {
            const r = indexedDB.open('playnet-keys');
            r.onerror = () => res(true);
            r.onsuccess = () => { try {
              const q = r.result.transaction('keypairs').objectStore('keypairs').getAllKeys();
              q.onsuccess = () => res(q.result.length === 0); q.onerror = () => res(false);
            } catch { res(true); } };
          })));
    h.info('what a signed-out browser still keeps: ' + await E.evaluate(() => Object.keys(localStorage).sort().join(', ')));
    await E.close();
  }

  h.rec('no page errors during the walk', h.errs.length === 0, h.errs.slice(0, 3).join(' | '));
  const gob = h.logs.filter(l => /Goblins exception|Scheme error|SchemeQuit/.test(l));
  h.rec('no vat exceptions during the walk', gob.length === 0, gob.slice(0, 3).join(' | '));
} catch (e) {
  h.info('exception: ' + (e?.stack ?? String(e)));
  h.info('console tail: ' + JSON.stringify(h.logs.slice(-20)));
  h.rec('test ran to completion', false);
} finally {
  await browser.close();
  if (respawned) { try { process.kill(-respawned.pid, 'SIGKILL'); } catch {} }
}

// every assertion gates: an identity walk that half-passes is a failure
summarize(h);
