/// tests/ux/identity-card-ux.mjs — the identity card (app/identity-view.ts):
/// create, reveal, hold, sign in, in the onboarding checklist's identity row.
/// No gateway — the spine's handlers are stubbed, as signup-ux does.
///
/// The card is ONE element that follows the door and redraws when its FACE
/// changes, never when a field does. The properties below are what that buys:
/// a passcode half-typed survives a status report, an unsaved passcode holds
/// the page, and the same card answers create and sign-in.
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
const errs = [];
page.on('pageerror', e => errs.push(String(e)));

// pin the seam's report to "connected", as signup-ux does: day-boot reports on
// its own schedule and a one-shot report is overwritten
const connect = async () => {
  await page.waitForSelector('#idrow .who', { timeout: 30000 });
  await page.evaluate(() => {
    const real = window.__seam.status;
    if (!window.__seam.__pinned) {
      window.__seam.__pinned = true;
      window.__seam.__realStatus = real;
      window.__seam.status = () => real('connected');
    }
    window.__seam.status('connected');
  });
  await page.waitForFunction(() => (document.querySelector('#idrow .who .dot')?.className || '').includes('idle'),
    { timeout: 15000, polling: 100 });
};
const pinHandler = (name, fn) => page.evaluate(([n, src]) => {
  window.__seam = window.__seam || {};
  window.__seam.handlers = window.__seam.handlers || {};
  const impl = eval(src);
  Object.defineProperty(window.__seam.handlers, n, { get: () => impl, set: () => {}, configurable: true });
}, [name, fn]);
const fresh = async () => {
  await page.goto(`${BASE}/app.html?face=onboard`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 30000 });
  await page.evaluate(() => localStorage.clear());
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#onboardstage .ob-row', { timeout: 30000 });
  await connect();
};
const openRow = async () => {
  await page.evaluate(() => [...document.querySelectorAll('#onboardstage .ob-row')]
    .find(r => r.querySelector('.acct-l')?.textContent === 'your identity').click());
  await sleep(250);
};
const view = () => page.evaluate(() => document.querySelector('#onboardstage .idc')?.dataset.view ?? null);
const tick = (name) => page.evaluate((n) => {
  const b = document.querySelector(`#onboardstage .idc input[name=${n}]`);
  b.checked = true; b.dispatchEvent(new Event('change', { bubbles: true }));
}, name);
const unsaved = () => page.evaluate(async () => (await import('/app/passcode-held.js')).passcodeUnsaved.peek());

try {
  // ── create → reveal → done ──
  await fresh();
  await pinHandler('signup', `((name, email, bran) => {
      window.__signupBran = bran;
      return Promise.resolve('ok:ECreatedAidExample00000000000000000000000|k0stub');
    })`);
  await openRow();
  h.rec('the identity row opens the create face', (await view()) === 'create');
  h.rec('one-tap: no passcode field before create',
    await page.evaluate(() => !document.querySelector('#onboardstage .idc input[type=password]')));

  const create = () => page.evaluate(() => [...document.querySelectorAll('#onboardstage .idc .ob-next')]
    .find(b => /create my identity/i.test(b.textContent)).click());
  await create(); await sleep(250);
  h.rec('create is REFUSED until the terms are ticked, and says so',
    (await view()) === 'create' && /accept the terms/i.test(await page.evaluate(() => document.querySelector('#onboardstage .idc .ob-err').textContent)));
  await tick('consent'); await create(); await sleep(250);
  h.rec('create is REFUSED until the age is confirmed',
    (await view()) === 'create' && /at least/i.test(await page.evaluate(() => document.querySelector('#onboardstage .idc .ob-err').textContent)));
  await tick('age'); await create(); await sleep(500);

  h.rec('create reveals the passcode face', (await view()) === 'reveal');
  const rev = await page.evaluate(() => {
    const c = document.querySelector('#onboardstage .idc');
    const pw = c.querySelector('input[name=password]'), un = c.querySelector('input[name=username]');
    return { pwType: pw?.type, pwReadonly: pw?.readOnly, pw: pw?.value, un: un?.value, unReadonly: un?.readOnly,
             done: c.querySelector('[type=submit]')?.disabled,
             download: [...c.querySelectorAll('button')].some(b => /download recovery file/i.test(b.textContent)),
             nickname: !!c.querySelector('input[name=nickname]') };
  });
  h.rec('the passcode is a masked, read-only new-password field holding the generated key',
    rev.pwType === 'password' && rev.pwReadonly === true && rev.pw === await page.evaluate(() => window.__signupBran));
  h.rec('the identifier is read-only beside it, as the username a manager files it under',
    rev.un === 'ECreatedAidExample00000000000000000000000' && rev.unReadonly === true);
  h.rec('the recovery file and a name are offered', rev.download && rev.nickname);
  h.rec('done is dead until the passcode is saved', rev.done === true);
  h.rec('an unsaved passcode holds the page', await unsaved());

  // a field half-typed survives a status report: the card redraws on a face change, not on a report
  await page.evaluate(() => { document.querySelector('#onboardstage .idc input[name=nickname]').value = 'rosa'; });
  await page.evaluate(() => window.__seam.status('connected'));
  await sleep(400);
  h.rec('a status report leaves a half-typed field alone',
    (await page.evaluate(() => document.querySelector('#onboardstage .idc input[name=nickname]')?.value)) === 'rosa'
    && (await view()) === 'reveal');

  await tick('saved'); await sleep(100);
  h.rec('ticking saved lights done and releases the hold',
    (await page.evaluate(() => document.querySelector('#onboardstage .idc [type=submit]').disabled)) === false && !(await unsaved()));
  await page.evaluate(() => document.querySelector('#onboardstage .idc [type=submit]').click());
  await sleep(500);
  h.rec('done lands on the held face, naming the identity', (await view()) === 'held');
  h.rec('the held face offers sign out, two taps',
    await page.evaluate(() => !!document.querySelector('#onboardstage .idc .ob-out')));

  // ── sign in on a device that holds nothing ──
  await fresh();
  await pinHandler('unlock', `((bran, aid, k0) => {
      window.__unlockArgs = [bran, aid, k0];
      return Promise.resolve('ok:' + (aid || 'EFoundByPasscode000000000000000000000000') + '|k0stub');
    })`);
  await page.evaluate(() => [...document.querySelectorAll('#onboardstage .ob-chip')]
    .find(b => /already have an identity/i.test(b.textContent)).click());
  await sleep(250);
  h.rec('"I already have an identity" opens the sign-in face', (await view()) === 'signin');
  h.rec('sign-in offers a passcode, a recovery file and friends\' pieces',
    await page.evaluate(() => {
      const c = document.querySelector('#onboardstage .idc');
      return !!c.querySelector('input[name=password]') && !!c.querySelector('input[type=file]') && !!c.querySelector('textarea[name=pieces]');
    }));
  const submit = () => page.evaluate(() => {
    const c = document.querySelector('#onboardstage .idc');
    c.querySelector('input[name=username]').value = 'EFounderAidExample0000000000000000000000000';
    c.querySelector('input[name=password]').value = 'test-passcode-twentyone+chars';
    c.querySelector('form [type=submit]').click();
  });
  await submit(); await sleep(250);
  h.rec('sign-in is REFUSED until the terms are accepted',
    (await page.evaluate(() => window.__unlockArgs ?? null)) === null
    && /accept the terms/i.test(await page.evaluate(() => document.querySelector('#onboardstage .idc .ob-err').textContent)));
  await tick('consent');
  await page.evaluate(() => { document.querySelector('#onboardstage .idc input[name=password]').value = 'short'; });
  await page.evaluate(() => document.querySelector('#onboardstage .idc form [type=submit]').click());
  await sleep(200);
  h.rec('a short passcode is refused with its own words',
    /21\+/.test(await page.evaluate(() => document.querySelector('#onboardstage .idc .ob-err').textContent)));
  await submit(); await sleep(500);
  const args = await page.evaluate(() => window.__unlockArgs);
  h.rec('sign-in calls unlock with the supplied identifier and an EMPTY k0',
    Array.isArray(args) && args[1] === 'EFounderAidExample0000000000000000000000000' && args[2] === '');
  h.rec('and the card lands on the held face', (await view()) === 'held');

  h.rec('no page errors', errs.length === 0, errs.join(' | '));
} catch (e) { h.rec('fatal', false, e.message); }
finally { await browser.close(); closeServer(); }
summarize(h, ['create reveals the passcode face', 'no page errors']);
