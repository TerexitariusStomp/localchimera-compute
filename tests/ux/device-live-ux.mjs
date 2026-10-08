/// tests/ux/device-live-ux.mjs — a refresh keeps you signed in, the passcode stays cold.
///
/// docs/planning/identity/device-keys.md, end to end against a real gateway: the
/// one-tap create seats a ROOT session (the passcode in hand); that session
/// authorizes this browser's own key (software tier — a non-extractable
/// WebCrypto Ed25519 key in IndexedDB) with a device-authorization credential
/// the gateway records; a reload then signs in on its own under the DEVICE
/// key, with no passcode anywhere; "stop staying signed in here" revokes the
/// authorization at the gateway and forgets the key, after which a reload
/// offers the passcode again.
///
/// Run via:  make test-device-live-ux
///           bash tests/ux/ux-full.sh tests/ux/device-live-ux.mjs

import { existsSync, readFileSync } from 'node:fs';
import { harness, launch, newPage, present, sleep, summarize } from './ux-harness.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';
const DATA = process.env.PLAYNET_DATA_DIR || '.ux-e2e-data';

const h = harness();
const browser = await launch();
const page = await newPage(browser, h);

const chipText = () =>
  page.evaluate(() => document.querySelector('#idrow .who')?.textContent ?? '');
const dotIn = (pg) =>
  pg.evaluate(() => (document.querySelector('#idrow .who .dot')?.className || '')
                      .replace('dot', '').trim());
const waitDotIn = async (pg, cls, ms = 60000) => {
  const dl = Date.now() + ms; let d = '';
  while (Date.now() < dl) { d = await dotIn(pg); if (d === cls) return d; await sleep(500); }
  return d;
};
const tierIn = (pg) => pg.evaluate(async () => {
  const { HANDLERS } = await import('/app/core.js');
  return HANDLERS.tier ? String(await HANDLERS.tier()) : '(no handler)';
});
const devicesFile = (aid) => `${DATA}/devices-${aid.slice(0, 16)}.scm`;
const waitFor = async (pred, ms = 30000) => {
  const dl = Date.now() + ms;
  while (Date.now() < dl) { if (await pred()) return true; await sleep(500); }
  return false;
};

try {
  await page.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 60000 });
  let chip = '';
  const deadline = Date.now() + 90000;
  while (Date.now() < deadline) {
    chip = await chipText();
    if (/create your identity/i.test(chip)) break;
    await sleep(1000);
  }
  const connected = /create your identity/i.test(chip);
  h.rec('dial connects to the gateway', connected, chip);

  if (connected) {
    // ── a root session: the passcode in hand ──
    await page.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
    await sleep(600);
    await page.evaluate(() => {
      const box = document.querySelector('#idform input[type="checkbox"]');
      if (box && !box.checked) box.click();
    });
    await page.click('#idform button.go:has-text("create your identity")');
    await page.waitForSelector('#idform input[name="username"]', { timeout: 120000 }).catch(() => {});
    const aid = await page.evaluate(() =>
      document.querySelector('#idform input[name="username"]')?.value ?? '');
    const bran = await page.evaluate(() =>
      document.querySelector('#idform input[name="password"]')?.value ?? '');
    const meshHashes = () => h.logs.filter(l => /mesh identity bound/.test(l)).map(l => l.slice(-32));
    h.rec('identity created', /^E[A-Za-z0-9_-]{43}$/.test(aid), aid || '(none)');
    await page.evaluate(() => document.querySelector('#idform form')?.requestSubmit());
    h.rec('seated', (await waitDotIn(page, 'live', 90000)) === 'live');
    h.rec('the session is a ROOT session', (await tierIn(page)) === 'root');

    // ── the root authorizes this browser's key, on its own ──
    const enrolled = await waitFor(() =>
      page.evaluate(() => !!localStorage.getItem('pn.device.wire')));
    h.rec('this browser now holds a root-signed device authorization', enrolled);
    if (!enrolled) {
      h.info('tiers: ' + JSON.stringify(await page.evaluate(async () => {
        const { HANDLERS } = await import('/app/core.js');
        return HANDLERS.deviceTiers ? await HANDLERS.deviceTiers() : '(no handler)';
      })));
      h.info('enroll: ' + JSON.stringify(await page.evaluate(async () => {
        const { HANDLERS } = await import('/app/core.js');
        return HANDLERS.enrollDevice ? await HANDLERS.enrollDevice('probe', 'software') : '(no handler)';
      })));
      h.info('console tail: ' + JSON.stringify(h.logs.slice(-12)));
    }
    const wire = await page.evaluate(() => {
      try { return JSON.parse(localStorage.getItem('pn.device.wire') || 'null'); } catch { return null; }
    });
    h.rec('…issued by this AID to a B-prefix device key',
          !!wire && wire.issuer === aid && /^B[A-Za-z0-9_-]{43}$/.test(wire.holder || ''),
          wire ? `${wire.holder?.slice(0, 8)}… ${wire.claims?.tier}` : '(none)');
    h.rec('the gateway recorded it', await waitFor(() => existsSync(devicesFile(aid))));
    h.rec('no passcode is stored anywhere in the browser',
          await page.evaluate(() => {
            const all = Object.keys(localStorage).map(k => localStorage.getItem(k) || '').join('\n');
            return !/passcode|bran/i.test(all) && !localStorage.getItem('pn.device.key')?.includes('seed');
          }));

    // ── the refresh: signed in again, by the device key ──
    // the first visit registers the service worker, which reloads the page
    // once it takes control — let that settle so the probe below is not
    // torn down mid-flight
    const t0 = Date.now();
    page.on('framenavigated', f => { if (f === page.mainFrame()) h.logs.push(`NAV +${Date.now() - t0}ms ${f.url().slice(-30)}`); });
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#idrow', { timeout: 60000 });
    await sleep(6000);
    await page.waitForSelector('#idrow', { timeout: 60000 });
    const back = await waitDotIn(page, 'live', 60000);
    h.rec('after a refresh the dial is signed in with no passcode typed', back === 'live', back);
    if (back !== 'live') {
      h.info('navs+console: ' + JSON.stringify(h.logs.filter(l => !/404/.test(l)).slice(-25)));
      try { h.info('gateway log: ' + readFileSync(`${DATA}/gateway.log`, 'utf8').split('\n').filter(l => /device|auth|lobby\]/.test(l)).slice(-8).join(' || ')); } catch {}
      h.info('unlockDevice reply: ' + JSON.stringify(await page.evaluate(async () => {
        const { HANDLERS } = await import('/app/core.js');
        return HANDLERS.unlockDevice ? await HANDLERS.unlockDevice() : '(no handler)';
      })));
      h.info('device console: ' + JSON.stringify(h.logs.filter(l => !/404/.test(l)).slice(-25)));
      try { h.info('gateway log: ' + readFileSync(`${DATA}/gateway.log`, 'utf8').split('\n').filter(l => /device|auth|lobby\]/.test(l)).slice(-8).join(' || ')); } catch {}
    }
    h.rec('…as a DEVICE session', (await tierIn(page)) === 'device');
    // the persona's mesh identity (anchored in the icp) rides on the device,
    // sealed under its seal key: the device session binds the SAME identity
    // the bind is logged from the spine's thread; give the relay a moment
    await waitFor(() => Promise.resolve(meshHashes().length >= 2), 5000);
    const hashes = meshHashes();
    h.rec('the device session binds the persona\'s mesh identity',
          hashes.length >= 2 && hashes[hashes.length - 1] === hashes[0],
          hashes.map(x => x.slice(0, 8)).join(' → '));
    const listed = await page.evaluate(async () => {
      const { HANDLERS } = await import('/app/core.js');
      try { return JSON.parse(String(await HANDLERS.devices())); } catch { return []; }
    });
    h.rec('the device session lists its own authorization',
          Array.isArray(listed) && listed.length === 1 && listed[0].said === wire?.said && !listed[0].revokedAt,
          JSON.stringify(listed).slice(0, 80));

    // ── the switch: stop staying signed in here ──
    // the switch lives in settings ("keys and devices"); the identity sheet
    // carries one button that opens it
    await page.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
    await sleep(600);
    h.rec('the sheet offers the way to keys and devices', await present(page, '#idform .keysbtn'));
    await page.click('#idform .keysbtn');
    await sleep(800);
    h.rec('settings shows the switch', await present(page, '.devsec'));
    await page.click('.devsec .vbtn:has-text("stop staying signed in")');
    h.rec('one tap only arms the switch',
          await page.evaluate(() => !!localStorage.getItem('pn.device.wire')
                                   && /tap again/.test(document.querySelector('.devsec .vbtn.arm')?.textContent || '')));
    await page.click('.devsec .vbtn.arm');
    const revoked = await waitFor(() =>
      existsSync(devicesFile(aid)) && /revoked-at \. \d+/.test(readFileSync(devicesFile(aid), 'utf8')));
    h.rec('the gateway marks the authorization revoked', revoked);
    h.rec('…and the browser forgot its key',
          await waitFor(() => page.evaluate(() => !localStorage.getItem('pn.device.wire')
                                                 && !localStorage.getItem('pn.device.key'))));
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#idrow', { timeout: 60000 });
    await sleep(4000);
    const afterRevoke = await dotIn(page);
    h.rec('after that a refresh asks for the passcode again', afterRevoke === 'idle', afterRevoke);

    // ── the hardware tier: a passkey with PRF (Chromium's virtual authenticator) ──
    const cdp = await page.context().newCDPSession(page);
    await cdp.send('WebAuthn.enable');
    await cdp.send('WebAuthn.addVirtualAuthenticator', { options: {
      protocol: 'ctap2', transport: 'internal', hasResidentKey: true,
      hasUserVerification: true, isUserVerified: true, hasPrf: true } });
    await page.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
    await sleep(500);
    await page.fill('#idform input[name="password"]', bran);
    await page.evaluate(() => {
      const box = document.querySelector('#idform input[type="checkbox"]');
      if (box && !box.checked) box.click();
    });
    await page.click('#idform button[type="submit"]');
    h.rec('the passcode seats a root session again', (await waitDotIn(page, 'live', 90000)) === 'live');
    await sleep(1500);
    h.rec('having declined once, nothing enrols on its own',
          await page.evaluate(() => !localStorage.getItem('pn.device.wire')));

    // ── a passcode LOGIN (not create) enrols on its own too ──
    await page.evaluate(() => localStorage.removeItem('pn.device.declined'));
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#idrow', { timeout: 60000 });
    await sleep(3000);
    await page.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
    await sleep(500);
    await page.fill('#idform input[name="password"]', bran);
    await page.click('#idform button[type="submit"]');
    h.rec('login with the passcode', (await waitDotIn(page, 'live', 90000)) === 'live');
    h.rec('a passcode LOGIN authorizes the device on its own',
          await waitFor(() => page.evaluate(() => !!localStorage.getItem('pn.device.wire'))));
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#idrow', { timeout: 60000 });
    h.rec('…and the next refresh is signed in', (await waitDotIn(page, 'live', 60000)) === 'live');
    // back to the declined state for the passkey leg
    await page.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
    await sleep(600);
    await page.click('#idform .keysbtn');
    await sleep(800);
    await page.click('.devsec .vbtn:has-text("stop staying signed in")');
    await page.click('.devsec .vbtn.arm');
    await waitFor(() => page.evaluate(() => !localStorage.getItem('pn.device.wire')));
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#idrow', { timeout: 60000 });
    await sleep(3000);
    await page.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
    await sleep(500);
    await page.fill('#idform input[name="password"]', bran);
    await page.click('#idform button[type="submit"]');
    await waitDotIn(page, 'live', 90000);
    await page.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
    await sleep(600);
    await page.click('#idform .keysbtn');
    await sleep(800);
    h.rec('settings offers the passkey tier', await present(page, '.devsec .vbtn:has-text("passkey")'));
    await page.click('.devsec .vbtn:has-text("passkey")');
    const hw = await waitFor(() => page.evaluate(() => {
      try { return JSON.parse(localStorage.getItem('pn.device.key') || 'null')?.tier === 'hardware'; }
      catch { return false; }
    }));
    h.rec('a passkey-held key is enrolled (record carries only credential id + salt)', hw
          && await page.evaluate(() => {
               const r = JSON.parse(localStorage.getItem('pn.device.key'));
               return !!r.credId && !!r.salt && Object.keys(r).sort().join() === 'credId,salt,tier';
             }));
    h.rec('…and the gateway holds a hardware-tier authorization',
          await waitFor(() => /tier \. "hardware"/.test(readFileSync(devicesFile(aid), 'utf8'))));
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#idrow', { timeout: 60000 });
    h.rec('after a refresh the passkey signs in (PRF → key, no passcode)',
          (await waitDotIn(page, 'live', 60000)) === 'live');
    h.rec('…as a DEVICE session', (await tierIn(page)) === 'device');
    await waitFor(() => Promise.resolve(meshHashes().length >= 3), 5000);
    const hashes2 = meshHashes();
    h.rec('…binding the persona\'s mesh identity from the PRF-sealed seed',
          hashes2.length >= 3 && hashes2[hashes2.length - 1] === hashes2[0]);
  } else {
    h.info('console tail: ' + JSON.stringify(h.logs.slice(-15)));
  }
  h.rec('no page errors during the flow', h.errs.length === 0, h.errs.slice(0, 2).join(' | '));
  const gob = h.logs.filter(l => /Goblins exception|Scheme error|SchemeQuit/.test(l));
  h.rec('no vat exceptions during the flow', gob.length === 0, gob.slice(0, 2).join(' | '));
} catch (e) {
  h.info('exception: ' + (e?.stack ?? String(e)));
  h.rec('test ran to completion', false);
} finally {
  await browser.close();
}

summarize(h, ['dial connects to the gateway']);
