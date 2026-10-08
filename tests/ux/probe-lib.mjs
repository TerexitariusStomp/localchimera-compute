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

/** Create an identity through the consent gate. Records one gate on H
 *  (`"<who>: identity created"` when WHO is given). Returns the minted AID
 *  ("" on failure, with the form text + console tail logged for diagnosis). */
export async function createIdentity(page, h, who = '') {
  await page.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
  await sleep(600);
  // the consent gate: creation stays inert until the terms box is ticked
  await page.evaluate(() => {
    const box = document.querySelector('#idform input[type="checkbox"]');
    if (box && !box.checked) box.click();
  });
  await sleep(300);
  await page.click('#idform button.go:has-text("create your identity")');
  await page.waitForSelector('#idform input[name="username"]', { timeout: 120000 })
    .catch(() => {});
  const aid = await page.evaluate(() =>
    document.querySelector('#idform input[name="username"]')?.value ?? '');
  h.rec(`${who ? who + ': ' : ''}identity created`,
        /^E[A-Za-z0-9_-]{43}$/.test(aid), aid || '(none)');
  if (!aid) {
    h.info('idform text: ' + JSON.stringify(
      (await page.evaluate(() =>
        document.querySelector('#idform')?.textContent ?? '(no form)')).slice(0, 300)));
    h.info('console tail: ' + JSON.stringify(h.logs.slice(-15)));
  }
  return aid;
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
