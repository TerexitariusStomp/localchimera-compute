/// tests/ux/signup-live-ux.mjs — the DIAL's signup against a real gateway.
///
/// tests/ux/signup-ux.mjs covers the same chip client-side, with the seam
/// stubbed: it proves the popover renders, anchors, survives a re-render and
/// hands the right arguments to a fake handler. What it cannot show is that
/// those arguments reach a gateway and produce an identity — the stub always
/// says "ok".
///
/// This is the other half. app.html talks to a live gateway over OCapN, the
/// one-tap create mints keys IN THE BROWSER from a generated passcode, ships
/// the signed inception event, and the production /oobi route must then serve
/// that AID's KEL. Nothing is stubbed.
///
/// Note the division of labour the dial uses: app.html owns #idrow, so
/// day-boot.js hands the chip to the dial (window.__seam.status) rather than
/// rendering its own — the identity UI under test is app/tabs/id.js.
///
/// Run via:  make test-signup-live-ux
///           bash tests/ux/ux-full.sh tests/ux/signup-live-ux.mjs

import { existsSync } from 'node:fs';
import { harness, launch, newPage, present, sleep, summarize } from './ux-harness.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';
const SREF = process.argv[3] || '';
const OOBI = process.env.OOBI_URL || 'http://127.0.0.1:8098';
const DATA = process.env.PLAYNET_DATA_DIR || '.ux-e2e-data';

const h = harness();
const browser = await launch();
const page = await newPage(browser, h);

const chipText = () =>
  page.evaluate(() => document.querySelector('#idrow .who')?.textContent ?? '');
// The corner is a dot and a name; state is read from the LIGHT, and from the
// sentence it stands for where two states share a colour.
const dotIn = (pg) =>
  pg.evaluate(() => (document.querySelector('#idrow .who .dot')?.className || '')
                      .replace('dot', '').trim());
const titleIn = (pg) =>
  pg.evaluate(() => document.querySelector('#idrow .who')?.getAttribute('title') || '');
const waitDotIn = async (pg, cls, ms = 60000) => {
  const dl = Date.now() + ms; let d = '';
  while (Date.now() < dl) { d = await dotIn(pg); if (d === cls) return d; await sleep(500); }
  return d;
};

try {
  // NO ?gateway= param. That path hands discoverGateway a bare sref with no
  // websocket URL, and it correctly refuses ("sref has no ws url — staying
  // standalone"). The production path is /entry-points.json, which the test
  // proxy serves and which lets discoverGateway derive the /ws endpoint from
  // the page's own origin — the same thing nginx does.
  await page.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 60000 });
  h.rec('dial loads (day-boot.wasm ready)', true);

  // The chip reports gateway state through the seam. "create your identity"
  // means connected-and-anonymous; "the gateway is away" means we never got
  // there, and every later assertion would be meaningless.
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
    await page.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
    await sleep(600);
    h.rec('create form opens', await present(page, '#idform'));

    // The consent gate first: creation stays inert until the terms box is
    // ticked (legal-notices arc) — the same gate a real first citizen meets.
    await page.evaluate(() => {
      const box = document.querySelector('#idform input[type="checkbox"]');
      if (box && !box.checked) box.click();
    });
    await sleep(200);
    // One tap: the passcode is generated client-side and never leaves the
    // browser; the AID is minted from it and registered with the gateway.
    await page.click('#idform button.go:has-text("create your identity")');

    // The post-create screen is the only place the passcode is ever shown.
    await page.waitForSelector('#idform input[name="username"]', { timeout: 120000 })
      .catch(() => {});
    const creds = await page.evaluate(() => {
      const u = document.querySelector('#idform input[name="username"]');
      const p = document.querySelector('#idform input[name="password"]');
      return { aid: u?.value ?? '', bran: p?.value ?? '' };
    });
    h.rec('identity created — AID revealed', /^E[A-Za-z0-9_-]{43}$/.test(creds.aid),
          creds.aid || '(none)');
    h.rec('passcode revealed once, client-generated', creds.bran.length >= 21);

    if (!creds.aid) {
      h.info('idform text: ' + JSON.stringify(
        (await page.evaluate(() =>
          document.querySelector('#idform')?.textContent ?? '')).slice(0, 400)));
      h.info('console tail: ' + JSON.stringify(h.logs.slice(-15)));
    } else {
      const aid = creds.aid;

      // The gateway must have PERSISTED the inception event, not merely
      // acknowledged it — this is the same artifact keri-signup-ux checks
      // for the repl, reached through the dial instead.
      let served = { ok: false, status: 0 }, body = '';
      const dl = Date.now() + 120000;
      while (Date.now() < dl) {
        served = await fetch(`${OOBI}/oobi/${aid}`).catch(() => ({ ok: false, status: 0 }));
        if (served.ok) { body = await served.text(); if (body.includes('"t":"icp"')) break; }
        await sleep(2000);
      }
      h.rec('gateway serves /oobi/{aid}', served.ok, `status ${served.status}`);
      h.rec('served OOBI carries this AID\'s inception event',
            body.includes('"t":"icp"') && body.includes(aid),
            body.slice(0, 60));
      h.rec('gateway persisted the AID under its oobi-host dir',
            existsSync(`${DATA}/oobi-host/${aid.slice(0, 2)}/${aid}.scm`));

      // The chip must now show the signed-in state, not fall back to
      // "create" — the regression that would leave a user stuck in a loop
      // re-creating identities.
      await sleep(1500);
      const after = await chipText();
      h.rec('chip switches to the signed-in state',
            !/create your identity/i.test(after), after);

      // ── the controller keeps what it wrote ──
      // The inception event this browser signed is its own log from here on:
      // pn.id.kel, ordered JSON, the same value the recovery file
      // carries. No rotations yet.
      const kel = await page.evaluate(() => {
        try { return JSON.parse(localStorage.getItem('pn.id.kel') || 'null'); }
        catch { return null; }
      });
      h.rec('the browser keeps the KEL it wrote',
            !!kel && kel.icp?.i === aid && Array.isArray(kel.rotations) && kel.rotations.length === 0,
            kel ? `icp.i=${String(kel.icp?.i).slice(0, 12)}… rotations=${kel.rotations?.length}` : '(none)');
      const exported = await page.evaluate(async () => {
        const { HANDLERS } = await import('/app/core.js');
        return HANDLERS.kelExport ? await HANDLERS.kelExport() : '';
      });
      h.rec('kelExport hands the same log to the recovery file',
            typeof exported === 'string' && exported.includes(`"i":"${aid}"`));
      const hint = await page.evaluate(() => localStorage.getItem('pn.id.hint') || '');

      // ── no commune reachable: the passcode opens the identity locally ──
      // A fresh context (its own storage) holding this identity's hint + log,
      // with ?gateway= naming an sref that has no ws url — day-boot refuses it
      // and the spine stands alone, which is the shape of "the commune is
      // unreachable". Unlock never asks the gateway: the bran against the
      // log's inception key, rotation depth from the log.
      const off = await newPage(browser, h);
      await off.goto(`${BASE}/app.html?gateway=x`, { waitUntil: 'domcontentloaded' });
      await off.waitForSelector('#idrow', { timeout: 60000 });
      await off.evaluate(([hh, kk]) => {
        localStorage.setItem('pn.id.hint', hh);
        localStorage.setItem('pn.id.kel', kk);
      }, [hint, JSON.stringify(kel)]);
      await off.reload({ waitUntil: 'domcontentloaded' });
      await off.waitForSelector('#idrow', { timeout: 60000 });
      const offChip = () =>
        off.evaluate(() => document.querySelector('#idrow .who')?.textContent ?? '');
      // With no commune the chip offers the act, not the diagnosis: unlocking
      // is entirely local, so someone who has not signed in can DO this. That
      // the commune is unreachable is said once they are in, where it matters.
      const away = await waitDotIn(off, 'idle');
      h.rec('with no commune the chip still offers to sign in',
            away === 'idle' && /sign in/i.test(await titleIn(off)),
            `${away} · ${await titleIn(off)}`);
      await off.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
      await sleep(500);
      h.rec('the away sheet offers the unlock form',
            await off.evaluate(() => !!document.querySelector('#idform input[name="password"]')));
      await off.fill('#idform input[name="password"]', creds.bran);
      await off.evaluate(() => {
        const box = document.querySelector('#idform input[type="checkbox"]');
        if (box && !box.checked) box.click();
      });
      await off.click('#idform button[type="submit"]');
      const unlocked = await waitDotIn(off, 'warn');
      h.rec('the passcode unlocks against the local log with no gateway',
            unlocked === 'warn' && /unreachable/i.test(await titleIn(off)),
            `${unlocked} · ${await titleIn(off)}`);
      // and a wrong passcode is refused by the log, not by a server
      await off.reload({ waitUntil: 'domcontentloaded' });
      await off.waitForSelector('#idrow', { timeout: 60000 });
      await sleep(2500);
      await off.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
      await sleep(500);
      await off.fill('#idform input[name="password"]', 'wrong-passcode-of-21-chars-x');
      await off.click('#idform button[type="submit"]');
      await sleep(2500);
      const toast = await off.evaluate(() => document.body.textContent || '');
      h.rec('a wrong passcode is refused offline', /wrong passcode/i.test(toast));
      await off.close();

      // ── a recovery file on a new device ──
      // Fresh context, connected gateway, nothing stored. The file carries
      // the passcode + the log: kelImport makes the log this device's, the
      // passcode unlocks, the seat follows.
      const fresh = await newPage(browser, h);
      await fresh.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
      await fresh.waitForSelector('#idrow', { timeout: 60000 });
      const freshChip = () =>
        fresh.evaluate(() => document.querySelector('#idrow .who')?.textContent ?? '');
      const dl4 = Date.now() + 60000;
      while (Date.now() < dl4) {
        if (/create your identity/i.test(await freshChip())) break;
        await sleep(500);
      }
      const fileText = JSON.stringify({
        'playnet-identity': 1, note: '', aid, name: '', email: '',
        passcode: creds.bran, kel,
      });
      await fresh.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
      await sleep(400);
      await fresh.click('#idform .gen2:has-text("I already have an identity")');
      await sleep(400);
      h.rec('the other-sign-in sheet offers a recovery file',
            await fresh.evaluate(() => !!document.querySelector('#idform input[type="file"]')));
      await fresh.setInputFiles('#idform input[type="file"]',
        { name: 'playnet-identity.json', mimeType: 'application/json', buffer: Buffer.from(fileText) });
      const seated = await waitDotIn(fresh, 'live', 90000);
      h.rec('a recovery file seats the identity on a new device', seated === 'live', seated);
      h.rec('…and the new device now keeps the log',
            await fresh.evaluate(([a]) => {
              try { return JSON.parse(localStorage.getItem('pn.id.kel') || 'null')?.icp?.i === a; }
              catch { return false; }
            }, [aid]));
      await fresh.close();

      // ── an identity made with no commune reachable ──
      // Same no-ws context shape as above, nothing stored. Create mints the
      // icp and keeps the log with no gateway in the loop; the chip reports
      // it unlocked and unreachable. Then the same origin (same storage)
      // loaded against the live commune: sign in → the commune has never
      // met this AID → join → seated.
      const born = await newPage(browser, h);
      await born.goto(`${BASE}/app.html?gateway=x`, { waitUntil: 'domcontentloaded' });
      await born.waitForSelector('#idrow', { timeout: 60000 });
      const bornChip = () =>
        born.evaluate(() => document.querySelector('#idrow .who')?.textContent ?? '');
      const dl6 = Date.now() + 60000;
      while (Date.now() < dl6) {
        if (/no commune here/i.test(await bornChip())) break;
        await sleep(500);
      }
      await born.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
      await sleep(500);
      h.rec('with no commune and no identity, the sheet offers to create one',
            await born.evaluate(() =>
              [...document.querySelectorAll('#idform button.go')].some(b => /create your identity/i.test(b.textContent))));
      await born.evaluate(() => {
        const box = document.querySelector('#idform input[type="checkbox"]');
        if (box && !box.checked) box.click();
      });
      await born.click('#idform button.go:has-text("create your identity")');
      await born.waitForSelector('#idform input[name="username"]', { timeout: 60000 }).catch(() => {});
      const offCreds = await born.evaluate(() => ({
        aid: document.querySelector('#idform input[name="username"]')?.value ?? '',
        bran: document.querySelector('#idform input[name="password"]')?.value ?? '',
      }));
      h.rec('identity created with no commune — AID minted in the browser',
            /^E[A-Za-z0-9_-]{43}$/.test(offCreds.aid), offCreds.aid || '(none)');
      const offKel = await born.evaluate(() => localStorage.getItem('pn.id.kel') || '');
      h.rec('…and its log is kept', offKel.includes(`"i":"${offCreds.aid}"`));
      await born.evaluate(() => document.querySelector('#idform form')?.requestSubmit());
      await sleep(300);
      h.rec('the chip reports it unlocked, commune unreachable',
            (await dotIn(born)) === 'warn' && /unreachable/i.test(await titleIn(born)),
            `${await dotIn(born)} · ${await titleIn(born)}`);
      h.rec('the commune has never seen it',
            !existsSync(`${DATA}/oobi-host/${offCreds.aid.slice(0, 2)}/${offCreds.aid}.scm`));

      // now the commune: same origin, so the same storage
      await born.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
      await born.waitForSelector('#idrow', { timeout: 60000 });
      const dl7 = Date.now() + 60000;
      while (Date.now() < dl7) {
        if (/sign in/i.test(await bornChip())) break;
        await sleep(500);
      }
      await born.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
      await sleep(500);
      await born.fill('#idform input[name="password"]', offCreds.bran);
      await born.click('#idform button[type="submit"]');
      const unregistered = await waitDotIn(born, 'warn');
      h.rec('at the commune the chip offers to join',
            unregistered === 'warn' && /join/i.test(await titleIn(born)),
            `${unregistered} · ${await titleIn(born)}`);
      await born.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
      await sleep(500);
      await born.evaluate(() => {
        const box = document.querySelector('#idform input[type="checkbox"]');
        if (box && !box.checked) box.click();
      });
      await born.click('#idform button.go:has-text("join as")');
      const seatedBorn = await waitDotIn(born, 'live', 90000);
      h.rec('the identity made offline is seated', seatedBorn === 'live', seatedBorn);
      let landed = false;
      const dl10 = Date.now() + 30000;
      while (Date.now() < dl10) {
        landed = existsSync(`${DATA}/oobi-host/${offCreds.aid.slice(0, 2)}/${offCreds.aid}.scm`);
        if (landed) break;
        await sleep(1000);
      }
      h.rec('…and the commune now holds its KEL', landed);
      await born.close();
    }
  } else {
    h.info('console tail: ' + JSON.stringify(h.logs.slice(-15)));
  }

  h.rec('no page errors during the flow', h.errs.length === 0,
        h.errs.slice(0, 2).join(' | '));
} catch (e) {
  h.info('exception: ' + (e?.stack ?? String(e)));
  h.rec('test ran to completion', false);
} finally {
  await browser.close();
}

summarize(h, ['dial connects to the gateway']);
