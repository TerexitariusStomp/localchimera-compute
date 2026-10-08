/// tests/ux/passcode-change-live-ux.mjs — the passcode, changed.
///
/// A passcode change is two rotations made as one act (hoot/day-boot.scm
/// change-passcode!): the identity's keys pass from the current passcode's
/// chain to a new passcode's, and the identifier stays what it was. This walks
/// it as a person meets it, in settings → change your passcode, against a real
/// gateway, with each device a context of its own:
///
///   A  creates the identity and changes its passcode — a wrong current
///      passcode is refused, the new one is shown before anything changes
///   B  was signed in beside A: it is signed out, the old passcode tells it
///      the passcode was changed, the new one seats it
///   C  holds nothing: the old passcode alone is told it was replaced, the
///      new one alone finds the identity
///   D  holds nothing: identifier + old passcode is refused, + new is seated
///   then A changes it a second time, and a device that holds nothing signs
///   in with the newest passcode alone
///
/// Run via:  make test-passcode-change-live-ux
///           bash tests/ux/ux-full.sh tests/ux/passcode-change-live-ux.mjs

import { existsSync, readFileSync } from 'node:fs';
import { harness, launch, newPage, sleep, summarize } from './ux-harness.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';
const DATA = process.env.PLAYNET_DATA_DIR || '.ux-e2e-data';

const h = harness();
const browser = await launch();

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
const depthIn = (pg) => pg.evaluate(() => {
  try { return JSON.parse(localStorage.getItem('pn.id.kel')).rotations.length; } catch { return -1; }
});
const hintIn = async (pg) => { const [aid, name, , k0] = ((await ls(pg, 'pn.id.hint')) || '|||').split('|'); return { aid, name, k0 }; };
const liveDevices = async (pg) => {
  try { return JSON.parse(await call(pg, 'devices')).filter(d => !d.revokedAt); } catch { return null; }
};
async function device() { const pg = await newPage(browser, h); return pg; }
async function open(pg) {
  await pg.goto(`${BASE}/app.html?face=map`, { waitUntil: 'domcontentloaded' });
  await pg.waitForSelector('#idrow', { timeout: 60000 });
}
const waitAnonymous = (pg) => waitFor(async () => /create your identity/i.test(await chipText(pg)), 90000);
/** The sign-in sheet on a device that holds nothing: passcode, identifier optional. */
async function signIn(pg, aid, bran) {
  if (!(await pg.evaluate(() => !!document.querySelector('#idform form input[name="username"]:not([readonly])')))) {
    if (!(await pg.evaluate(() => !!document.querySelector('#idform')))) { await pg.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor()); await sleep(500); }
    await pg.click('#idform .gen2:has-text("I already have an identity"), #idform .gen2:has-text("another way in")');
    await sleep(400);
  }
  await pg.fill('#idform form input[name="username"]', aid);
  await pg.fill('#idform form input[name="password"]', bran);
  await tick(pg, '#idform form');
  await pg.click('#idform form button[type="submit"]');
}
/** Settings → change your passcode, as a person walks it. Answers the new passcode, or the refusal. */
async function changePasscode(pg, current) {
  await pg.evaluate(async () => { (await import('/app/settings.js')).openSettings('passcode'); });
  await pg.waitForSelector('#setface input[autocomplete="current-password"]', { timeout: 15000 });
  await pg.fill('#setface input[autocomplete="current-password"]', current);
  await pg.click('#setface button.go:has-text("continue")');
  const shown = await waitFor(() => pg.evaluate(() =>
    !!document.querySelector('#setface input[autocomplete="new-password"]')
    || !!(document.querySelector('#setface .err')?.textContent)), 15000);
  const next = await pg.evaluate(() => document.querySelector('#setface input[autocomplete="new-password"]')?.value || '');
  if (!shown || !next) return { refused: await pg.evaluate(() => document.querySelector('#setface .err')?.textContent || '(nothing)') };
  return { next };
}
async function confirmChange(pg) {
  await tick(pg, '#setface');
  await pg.click('#setface button.go:has-text("change passcode")');
  return waitFor(async () => /passcode changed/i.test(await pg.evaluate(() => document.querySelector('#setface')?.textContent || '')), 120000);
}
const entryFile = (aid) => `${DATA}/oobi-host/${aid.slice(0, 2)}/${aid}.scm`;

try {
  // ── A creates; B signs in beside it ────────────────────────────────────
  const A = await device();
  await open(A);
  const connected = await waitAnonymous(A);
  h.rec('dial connects to the gateway', connected, await chipText(A));
  if (!connected) throw new Error('no gateway');
  await A.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor()); await sleep(600);
  await tick(A);
  await A.click('#idform button.go:has-text("create your identity")');
  await A.waitForSelector('#idform input[name="username"]', { timeout: 120000 });
  const aid = await A.evaluate(() => document.querySelector('#idform input[name="username"]').value);
  const first = await A.evaluate(() => document.querySelector('#idform input[name="password"]').value);
  await tick(A);
  await A.fill('#idform input[name="nickname"]', 'ada');
  await A.evaluate(() => document.querySelector('#idform form').requestSubmit());
  h.rec('A: identity created and seated', /^E[A-Za-z0-9_-]{43}$/.test(aid) && (await waitDot(A, 'live', 90000)) === 'live', aid);
  await waitFor(async () => !!(await ls(A, 'pn.device.wire')));
  const k0Before = (await hintIn(A)).k0;

  const B = await device();
  await open(B); await waitAnonymous(B);
  await signIn(B, '', first);
  h.rec('B: signed in beside A', (await waitDot(B, 'live', 90000)) === 'live');
  await waitFor(async () => !!(await ls(B, 'pn.device.wire')));
  await B.reload({ waitUntil: 'domcontentloaded' });
  await B.waitForSelector('#idrow', { timeout: 60000 });
  h.rec('B: stays signed in on its own key', (await waitDot(B, 'live', 60000)) === 'live');
  h.rec('A: two devices are signed in', (await liveDevices(A))?.length === 2);

  // old pieces, for later: recovery friends hold the FIRST passcode
  const oldPieces = JSON.parse(await call(A, 'guardianSplit', '2', '3'));

  // ── A changes the passcode ─────────────────────────────────────────────
  const wrong = await changePasscode(A, 'not-the-passcode-of-21-chars');
  h.rec('A: a wrong current passcode is refused, and no new one is shown', /wrong passcode/i.test(wrong.refused || ''), JSON.stringify(wrong));
  const step = await changePasscode(A, first);
  const second = step.next || '';
  h.rec('A: the current passcode shows a new one', second.length >= 21 && second !== first, step.refused || '');
  h.rec('A: nothing has changed yet', (await depthIn(A)) === 0 && (await call(A, 'passcodeCheck', first)) === 'ok');
  h.rec('A: the change is dead until the new passcode is confirmed saved',
        await A.evaluate(() => [...document.querySelectorAll('#setface button.go')].find(b => /change passcode/.test(b.textContent))?.disabled === true));
  h.rec('A: the passcode changes', await confirmChange(A));
  h.rec('A: is still seated, as the same identifier',
        (await dotIn(A)) === 'live' && (await hintIn(A)).aid === aid && /ada/.test(await chipText(A)), `${await dotIn(A)} · ${await chipText(A)}`);
  h.rec('A: the log holds the two rotations', (await depthIn(A)) === 2);
  h.rec('A: the new passcode opens it and the old one does not',
        (await call(A, 'passcodeCheck', second)) === 'ok' && /wrong passcode/.test(await call(A, 'passcodeCheck', first)));
  h.rec('A: this device remembers the new first key', !!(await hintIn(A)).k0 && (await hintIn(A)).k0 !== k0Before);
  const stored = await waitFor(() => existsSync(entryFile(aid)) && (readFileSync(entryFile(aid), 'utf8').match(/"t" \. "rot"/g) || []).length === 2, 20000);
  h.rec('the commune holds both rotations', stored);
  h.rec('…the second anchoring the new mesh identity',
        (readFileSync(entryFile(aid), 'utf8').match(/playnet-reticulum-pub/g) || []).length === 2);
  const after = await waitFor(async () => (await liveDevices(A))?.length === 1, 30000);
  h.rec('A: every device was retired and this one authorized afresh',
        after && await waitFor(async () => !!(await ls(A, 'pn.device.wire'))), JSON.stringify(await liveDevices(A))?.slice(0, 100));
  const nameJson = await call(A, 'profileGet');
  h.rec('A: the name the commune holds is unchanged',
        (() => { try { return JSON.parse(nameJson).name === 'ada'; } catch { return false; } })());
  await A.reload({ waitUntil: 'domcontentloaded' });
  await A.waitForSelector('#idrow', { timeout: 60000 });
  h.rec('A: a refresh stays signed in', (await waitDot(A, 'live', 60000)) === 'live', await dotIn(A));

  // ── B: signed out; the old passcode is told; the new one seats ─────────
  await B.reload({ waitUntil: 'domcontentloaded' });
  await B.waitForSelector('#idrow', { timeout: 60000 });
  h.rec('B: is signed out', await waitFor(async () => (await dotIn(B)) === 'idle' && !(await ls(B, 'pn.device.wire')), 45000), await dotIn(B));
  const unlockB = async (bran) => {
    if (!(await B.evaluate(() => !!document.querySelector('#idform input[name="password"]')))) { await B.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor()); await sleep(500); }
    await B.fill('#idform input[name="password"]', bran);
    await tick(B);
    await B.click('#idform button[type="submit"]');
  };
  await unlockB(first);
  h.rec('B: the old passcode is told the passcode was changed',
        await waitFor(async () => /passcode was changed/i.test(await bodyText(B)), 45000) && (await dotIn(B)) !== 'live', await dotIn(B));
  await sleep(1500);
  await unlockB(second);
  h.rec('B: the new passcode seats it', (await waitDot(B, 'live', 90000)) === 'live', await dotIn(B));
  h.rec('B: …holding the log as A does', (await ls(B, 'pn.id.kel')) === (await ls(A, 'pn.id.kel')));
  await B.close();

  // ── C: nothing but a passcode ──────────────────────────────────────────
  const C = await device();
  await open(C); await waitAnonymous(C);
  await signIn(C, '', first);
  h.rec('C: the old passcode alone is told it was replaced',
        await waitFor(async () => /replaced by a newer one/i.test(await bodyText(C)), 45000) && (await dotIn(C)) !== 'live');
  h.rec('C: …and leaves nothing behind', !(await ls(C, 'pn.id.hint')) && !(await ls(C, 'pn.id.kel')));
  await signIn(C, '', second);
  h.rec('C: the new passcode alone finds the identity', (await waitDot(C, 'live', 90000)) === 'live', await dotIn(C));
  h.rec('C: …the same identifier', (await hintIn(C)).aid === aid);
  await sleep(2000);
  h.rec('C: …and says the name', /ada/.test(await chipText(C)), await chipText(C));
  // pieces cut from the old passcode give the old passcode back, which opens nothing
  await C.close();
  const R = await device();
  await open(R); await waitAnonymous(R);
  const rec = await call(R, 'guardianRecover', JSON.stringify([oldPieces[0], oldPieces[1]]));
  h.rec('pieces cut before the change give back the old passcode', rec === `ok:${aid}|${first}`);
  h.rec('…which opens nothing now', /wrong passcode/.test(await call(R, 'unlock', first, aid, '')) && (await dotIn(R)) !== 'live');
  await R.close();

  // ── D: identifier + passcode ───────────────────────────────────────────
  const D = await device();
  await open(D); await waitAnonymous(D);
  await signIn(D, aid, first);
  h.rec('D: identifier + old passcode is refused',
        await waitFor(async () => /wrong passcode/i.test(await bodyText(D)), 45000) && (await dotIn(D)) !== 'live');
  await signIn(D, aid, second);
  h.rec('D: identifier + new passcode is seated', (await waitDot(D, 'live', 90000)) === 'live', await dotIn(D));
  await D.close();

  // ── a second change ────────────────────────────────────────────────────
  const step2 = await changePasscode(A, second);
  const third = step2.next || '';
  h.rec('A: the passcode in force shows a newer one', third.length >= 21 && third !== second, step2.refused || '');
  h.rec('A: the passcode changes again', await confirmChange(A));
  h.rec('A: the log holds four rotations', (await depthIn(A)) === 4);
  h.rec('A: only the newest passcode opens it',
        (await call(A, 'passcodeCheck', third)) === 'ok'
        && /wrong passcode/.test(await call(A, 'passcodeCheck', second))
        && /wrong passcode/.test(await call(A, 'passcodeCheck', first)));
  const E = await device();
  await open(E); await waitAnonymous(E);
  await signIn(E, '', third);
  h.rec('E: the newest passcode alone finds the identity', (await waitDot(E, 'live', 90000)) === 'live' && (await hintIn(E)).aid === aid, await dotIn(E));
  await E.close();

  h.rec('no page errors during the walk', h.errs.length === 0, h.errs.slice(0, 3).join(' | '));
  const gob = h.logs.filter(l => /Goblins exception|Scheme error|SchemeQuit/.test(l));
  h.rec('no vat exceptions during the walk', gob.length === 0, gob.slice(0, 3).join(' | '));
} catch (e) {
  h.info('exception: ' + (e?.stack ?? String(e)));
  h.info('console tail: ' + JSON.stringify(h.logs.slice(-20)));
  h.rec('test ran to completion', false);
} finally {
  await browser.close();
}

summarize(h);
