/// tests/ux/probe-lib.mjs — the first-citizen moves the LIVE probes share.
///
/// Both probes (day-live-sources, day-witness-quorum) walk the same opening
/// mile — load the dial, mint an identity through the consent gate, dial the
/// Berlin commune, offer hours — and a second copy of that dance is a second
/// place for the signup flow to drift from what a citizen actually meets.
/// The connect and create halves are separate so a probe can look at the
/// anonymous demo day in between.
import { sleep } from './ux-harness.mjs';

/** Load app.html and wait for the gateway chip. Returns the chip text
 *  (matches /create your identity|sign in/ when the gateway answered). */
export async function connectDial(page, base) {
  await page.goto(`${base}/app.html?face=calendar`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 60000 });
  let chip = '';
  const dl = Date.now() + 90000;
  while (Date.now() < dl) {
    chip = await page.evaluate(() => document.querySelector('#idrow .who')?.textContent ?? '');
    if (/create your identity|sign in/i.test(chip)) break;
    await sleep(1000);
  }
  return chip;
}

/** The identity card, open: the person button's identity page (app/identity-view.ts). */
export async function openIdentityCard(page) {
  await page.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
  await page.waitForSelector('.sheet-view .acct-card .idc', { timeout: 15000 });
  await sleep(300);
}

/** Tick boxes on the card by name (consent, age, vote, saved) — each as a person's tap would. */
export async function tickCard(page, ...names) {
  await page.evaluate((ns) => {
    for (const n of ns) {
      const box = document.querySelector(`.idc input[name="${n}"]`);
      if (box && !box.checked) box.click();
    }
  }, names);
  await sleep(200);
}

/** Create an identity through the card's gates. Records one gate on H
 *  (`"<who>: identity created"` when WHO is given). Returns the minted AID
 *  ("" on failure, with the card's text + console tail logged for diagnosis).
 *  The passcode is put away (saved, the sheet closed) unless KEEP: the
 *  reveal face stays up so the caller can read it (`revealedPasscode`) and
 *  call `savePasscode` itself. */
export async function createIdentity(page, h, who = '', keep = false) {
  await openIdentityCard(page);
  await tickCard(page, 'consent', 'age');
  await page.click('.idc .ob-next:has-text("create my identity")');
  await page.waitForSelector('.idc[data-view="reveal"] input[name="username"]', { timeout: 120000 })
    .catch(() => {});
  const aid = await page.evaluate(() =>
    document.querySelector('.idc[data-view="reveal"] input[name="username"]')?.value ?? '');
  h.rec(`${who ? who + ': ' : ''}identity created`,
        /^E[A-Za-z0-9_-]{43}$/.test(aid), aid || '(none)');
  if (!aid) {
    h.info('identity card text: ' + JSON.stringify(
      (await page.evaluate(() =>
        document.querySelector('.idc')?.textContent ?? '(no card)')).slice(0, 300)));
    h.info('console tail: ' + JSON.stringify(h.logs.slice(-15)));
  }
  if (aid && !keep) await putAway(page);
  return aid;
}

/** Save the passcode on the reveal face and close the sheet. */
export async function putAway(page) {
  await savePasscode(page);
  await page.evaluate(async () => (await import('/app/account.js')).closeAccount());
  await sleep(300);
}

/** The passcode the reveal face is showing ("" when it is not). */
export const revealedPasscode = (page) => page.evaluate(() =>
  document.querySelector('.idc[data-view="reveal"] input[name="password"]')?.value ?? '');

/** Say the passcode is saved and press done: the card lands on its seated face. */
export async function savePasscode(page) {
  await tickCard(page, 'saved');
  await page.click('.idc [type="submit"]:has-text("done")');
  await sleep(500);
}

/** connectDial + createIdentity in one, for probes with no business in
 *  between. Returns the minted AID. */
export async function signupIdentity(page, h, base, who = '') {
  await connectDial(page, base);
  return createIdentity(page, h, who);
}

/** Wait for the scope roster, dial the first scope whose name/id matches RE.
 *  Returns the setScope reply ("ok", "no-match", or "threw:…"). */
export async function dialScope(page, re) {
  const dl = Date.now() + 60000;
  while (Date.now() < dl) {
    const ok = await page.evaluate(async () => {
      const sc = await import('./app/scope.js');
      return (sc.scopesSig?.() ?? []).length > 0;
    });
    if (ok) break;
    await sleep(2000);
  }
  return page.evaluate(async (src) => {
    const sc = await import('./app/scope.js');
    const re = new RegExp(src, 'i');
    const s = (sc.scopesSig?.() ?? []).find(x => re.test(x.name || x.id));
    if (!s) return 'no-match';
    return await window.__seam.handlers.setScope(s.id).catch(e => 'threw:' + e);
  }, re.source);
}

/** Offer 08:00–18:00 availability — the upsert that makes a browser AID an
 *  agent of the dialed scope (and so a member of any ceremony's roster). */
export async function offerHours(page) {
  return page.evaluate(async () =>
    String(await window.__seam.handlers
      .setAvailability('[{"start":"08:00","end":"18:00"}]')
      .catch(e => 'threw:' + e)));
}

/** Re-dial the current scope — the door the dial itself uses to refresh the
 *  snapshot, so a probe's "echo" gates read the WIRE's answer, never the
 *  optimistic flip. */
export async function redial(page) {
  return page.evaluate(async () => {
    const sc = await import('./app/scope.js');
    const id = sc.scopeSig?.();
    if (id) await window.__seam.handlers.setScope(id).catch(() => {});
    return id;
  });
}
