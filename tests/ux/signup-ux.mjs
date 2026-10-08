/// tests/ux/signup-ux.mjs — the create-identity chip: simulate a connected
/// gateway, click "create your identity", and assert the create form popover
/// appears with the passcode + create button. No gateway — pure client flow.
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
const openSettingsRoom = async (page) => {
  await page.evaluate(async () => { const a = await import('/app/account.js'); a.closeAccount(); a.openAccount(); });
  await sleep(250);
  await page.evaluate(() => [...document.querySelectorAll('#acct .acct-row')].find(r => r.querySelector('.acct-l')?.textContent === 'settings').click());
};
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
const errs = [];
page.on('pageerror', e => errs.push(String(e)));

// THIS SUITE RUNS AS IF THE GATEWAY WERE CONNECTED. It is about the identity
// UX, not about gateway timing — and day-boot reports on its OWN schedule
// (`connecting` about a second in, then connected or an error), so a one-shot
// `status("connected")` before that lands is simply overwritten and the chip
// falls back to the away state.
//
// So the stub is explicit rather than a sleep long enough to win the race: pin
// the seam's report to "connected" for the duration, and call it once. Every
// later report from the spine arrives as connected, which is the world this
// suite means to describe.
const connect = async () => {
  await page.waitForSelector('#idrow .who', { timeout: 30000 });
  await page.evaluate(() => {
    const real = window.__seam.status;
    if (!window.__seam.__pinned) {
      window.__seam.__pinned = true;
      window.__seam.__realStatus = real;   // for the one block that needs another report
      window.__seam.status = () => real('connected');
    }
    window.__seam.status('connected');
  });
  // Ready = the corner is drawn and idle (a name to sign in as, or the offer
  // to create one). Read the LIGHT, not the words: the chip says a name and
  // nothing else, so "ada" is indistinguishable from any other prose.
  await page.waitForFunction(
    () => (document.querySelector('#idrow .who .dot')?.className || '')
            .includes('idle'),
    { timeout: 15000, polling: 100 });
};

// DAY-BOOT INSTALLS ITS OWN HANDLERS FROM A WASM CALLBACK, whenever the wasm
// happens to finish — so a plain `handlers.signup = stub` is silently
// overwritten if that lands afterwards. It is a race, and it is why this suite
// used to pass once and fail three times in a row on the same code.
//
// defineProperty pins the stub: this suite OWNS these handlers, and day-boot's
// later write goes nowhere instead of winning by arriving second.
const pinHandler = (name, fn) => page.evaluate(([n, src]) => {
  window.__seam = window.__seam || {};
  window.__seam.handlers = window.__seam.handlers || {};
  const impl = eval(src);
  Object.defineProperty(window.__seam.handlers, n,
    { get: () => impl, set: () => {}, configurable: true });
}, [name, fn]);

try {
  await page.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
  await connect();

  const chip = await page.$eval('#idrow .who', el => el.textContent).catch(() => '');
  h.rec('chip shows create-identity', chip.includes('create your identity'));

  // click the chip → the create form popover should appear
  await page.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
  await sleep(300);
  const form = await page.evaluate(() => {
    const f = document.querySelector('#idform');
    if (!f) return { present: false };
    const cs = getComputedStyle(f);
    const r = f.getBoundingClientRect();
    return {
      present: true,
      visible: cs.display !== 'none' && cs.visibility !== 'hidden',
      // the sheet is a fixed popover in the middle of the viewport, and all
      // of it is within the viewport — present + display:block says neither
      onScreen: r.top >= 0 && r.bottom <= innerHeight && r.left >= 0 && r.right <= innerWidth,
      position: cs.position,
      // one-tap flow: NO passcode field before create (it's generated internally
      // and revealed only AFTER create, once the gateway has minted the AID).
      noPassField: !f.querySelector('input.pcode'),
      hasCreate: [...f.querySelectorAll('button')].some(b => /create your identity/i.test(b.textContent)),
    };
  });
  h.rec('create form popover appears', form.present === true);
  h.rec('form is visible', form.visible === true);
  h.rec('form is ON-SCREEN (a fixed sheet, whole within the viewport)',
        form.onScreen === true && form.position === 'fixed');
  h.rec('one-tap: no passcode field shown before create', form.noPassField === true);
  h.rec('form has a create button', form.hasCreate === true);

  await page.screenshot({ path: 'tests/ux/_artifacts/day-signup.png' }).catch(() => {});

  // the sheet (a modal on <body>) must SURVIVE a chip re-render — renderId fires on every
  // personhood standing-check / 45s poll, and used to wipe the open #idform
  // (the "it closes shortly after I click it" bug). The form is still open
  // from above; a re-render must not destroy it.
  await page.evaluate(() => window.__seam?.status && window.__seam.status('connected'));
  await sleep(250);
  const afterRerender = await page.evaluate(() => {
    const f = document.querySelector('#idform');
    return f
      ? { present: true, childCount: f.childElementCount,
          // the CONTENTS must survive, not just the shell — a naive wipe
          // strips #idform's descendants and re-attaches an empty box. The
          // one-tap create form has no input yet; its button must survive.
          hasButton: !!f.querySelector('button') }
      : { present: false };
  });
  h.rec('popover survives a chip re-render — element present',
        afterRerender.present === true);
  h.rec('popover KEEPS ITS CONTENTS after re-render (not an empty shell)',
        afterRerender.childCount > 1 && afterRerender.hasButton);

  // the sheet has three ways out besides the chip: the dimmed page, Esc, and its ✕
  const sheetOpen = () => page.evaluate(() => !!document.querySelector('#idform'));
  const reopen = async () => { if (!(await sheetOpen())) { await page.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor()); await sleep(300); } };
  await page.mouse.click(5, 300); await sleep(200);
  h.rec('tapping the dimmed page closes the sheet', !(await sheetOpen()));
  await reopen();
  await page.keyboard.press('Escape'); await sleep(200);
  h.rec('Esc closes the sheet', !(await sheetOpen()));
  await reopen();
  await page.click('#idform .idclose'); await sleep(200);
  h.rec('the ✕ closes the sheet', !(await sheetOpen()));
  await reopen();

  // ── "sign in with a different identity" (founder key etc.) ──
  // From the create form, the link opens an AID + passcode sub-form that calls
  // unlock(bran, aid, "") — authenticating as the SUPPLIED AID, not a stored one.
  await pinHandler('unlock', `((bran, aid, k0) => {
      window.__unlockArgs = [bran, aid, k0];
      return Promise.resolve('ok:' + aid + '|k0stub');
    })`);
  await page.evaluate(() => {
    // click the "I already have an identity" link in the open create form
    const link = [...document.querySelectorAll('#idform .gen2')]
      .find(e => /already have an identity/i.test(e.textContent));
    link && link.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  });
  await sleep(200);
  const other = await page.evaluate(() => {
    const f = document.querySelector('#idform');
    return { inputs: f ? f.querySelectorAll('input[name="username"], input[name="password"]').length : 0,
             lead: f ? [...f.querySelectorAll('.lead')].map(l => l.textContent).join(' ') : '' };
  });
  h.rec('different-identity form has AID + passcode fields', other.inputs >= 2);
  h.rec('different-identity form is labelled: sign in, recovery file, people you trusted',
        /sign in/i.test(other.lead || '') && /recovery file/i.test(other.lead || '') && /people you trusted/i.test(other.lead || ''));
  h.rec('different-identity form offers a recovery file',
        await page.evaluate(() => !!document.querySelector('#idform input[type="file"]')));


  // fill AID + passcode and submit WITHOUT consenting — the gate must refuse.
  // Signing in is the collection moment the notice is about, so this is a real
  // property and not merely a step on the way to the next assertion.
  const submitLogin = () => page.evaluate(() => {
    document.querySelector('#idform input[name="username"]').value = 'EFounderAidExample0000000000000000000000000';
    document.querySelector('#idform input[name="password"]').value = 'test-passcode-twentyone+chars';
    [...document.querySelectorAll('#idform button')]
      .find(b => /sign in/i.test(b.textContent))
      ?.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  });
  await submitLogin();
  await sleep(250);
  const gated = await page.evaluate(() => ({
    args: window.__unlockArgs || null,
    err: document.querySelector('#idform form .err')?.textContent || '',
  }));
  h.rec('sign-in is REFUSED until the terms are accepted',
        gated.args === null && /accept the terms/i.test(gated.err));

  // tick the consent box, then sign in → unlock(bran, aid, "")
  await page.evaluate(() => {
    const box = document.querySelector('#idform input[type=checkbox]');
    if (box) { box.checked = true; box.dispatchEvent(new Event('change', { bubbles: true })); }
  });
  await submitLogin();
  await sleep(250);
  const args = await page.evaluate(() => window.__unlockArgs);
  h.rec('sign-in calls unlock with the supplied AID and EMPTY k0',
        Array.isArray(args) && args[1] === 'EFounderAidExample0000000000000000000000000' && args[2] === '');

  // ── one-tap create → post-create credential form (password-manager-ready) ──
  // Reload to a fresh idle state (the sign-in above authed the session), then
  // stub signup so create succeeds without a gateway (the ok:<aid>|<k0> shape
  // day-boot sends). Click the single create button; the post-create screen
  // must reveal AID + the generated passcode as a real <form> managers can save.
  await page.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 30000 });
  // The sign-in above stored a localStorage hint that survives reload. Clear it
  // AND RELOAD: what this device remembers is read once into a signal at module
  // load, so a device with no identity is one that LOADED without one — which is
  // exactly what a fresh device is. Then wait out day-boot's own status report.
  await page.evaluate(() => localStorage.clear());
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 30000 });
  await connect();
  await pinHandler('signup', `((name, email, bran) => {
      window.__signupBran = bran;                       // the internally-generated key
      return Promise.resolve('ok:ECreatedAidExample00000000000000000000000|k0stub');
    })`);
  await sleep(300);
  await page.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());                      // open the create form
  await sleep(200);
  await page.evaluate(() => {
    // creating an identity IS the collection moment the notice is about, so the
    // gate is forced on this path — tick it, exactly as a reader must
    const box = document.querySelector('#idform input[type=checkbox]');
    if (box) { box.checked = true; box.dispatchEvent(new Event('change', { bubbles: true })); }
    [...document.querySelectorAll('#idform button')]
      .find(b => /create your identity/i.test(b.textContent))
      ?.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  });
  await sleep(400);
  const created = await page.evaluate(() => {
    const f = document.querySelector('#idform');
    if (!f) return {};
    const user = f.querySelector('input[autocomplete="username"]');
    const pass = f.querySelector('input[autocomplete="new-password"]');
    const done = [...f.querySelectorAll('button[type="submit"]')].pop();
    return {
      isForm: !!f.querySelector('form'),
      // the identifier is the username a password manager keys the entry
      // by, and it is shown whole: with the passcode it is the way back
      aidPresent: !!user && user.value.startsWith('ECreatedAid'),
      aidShown: !!user && user.readOnly === true && user.offsetWidth > 200
                && user.scrollWidth <= user.clientWidth + 1,
      passShown: !!pass && pass.value === window.__signupBran && window.__signupBran.length >= 21,
      hasDownload: [...f.querySelectorAll('button')].some(b => /download recovery/i.test(b.textContent)),
      doneDisabled: !!done && done.disabled === true,
      // creating takes no name, and nothing else ever asks for one — so this
      // sheet does, after the key material and never before it
      nameField: !!f.querySelector('input[autocomplete="nickname"]'),
      nameAfterKey: (() => {
        const ins = [...f.querySelectorAll('input')];
        return ins.findIndex(i => i.autocomplete === 'nickname')
             > ins.findIndex(i => i.autocomplete === 'new-password');
      })(),
    };
  });
  h.rec('post-create is a credential <form> for password managers', created.isForm === true);
  h.rec('post-create keeps the AID for the manager', created.aidPresent === true);
  h.rec('…shown whole beside the passcode, read-only', created.aidShown === true);
  h.rec('post-create reveals the generated passcode (new-password field)', created.passShown === true);
  h.rec('post-create offers the recovery-file download', created.hasDownload === true);
  h.rec('post-create asks what to call you', created.nameField === true);
  h.rec('…and asks it AFTER the passcode, never before it', created.nameAfterKey === true);

  // THE HOLD. The passcode is shown once; dismissing this sheet without it
  // locks the person out of their own identity for good. So until they confirm
  // they have saved it: done is dead, a stray Enter does nothing, and tapping
  // the chip cannot close the sheet.
  h.rec('done is dead until the passcode is confirmed saved', created.doneDisabled === true);
  await page.evaluate(() => {
    document.querySelector('#idform input[autocomplete="nickname"]').value = 'rosa';
    document.querySelector('#idform form')
      .dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
  });
  await sleep(300);
  h.rec('a stray Enter cannot dismiss it either',
        await page.evaluate(() => !!document.querySelector('#idform')));
  await page.evaluate(() => document.querySelector('#idrow .who')
    .dispatchEvent(new MouseEvent('click', { bubbles: true })));
  await sleep(300);
  h.rec('and tapping the chip cannot dismiss it',
        await page.evaluate(() => !!document.querySelector('#idform input[autocomplete="new-password"]')));

  // Confirming releases it. Naming yourself writes the LOCAL hint first — that
  // is what the chip reads, and with no commune in reach it is the only copy
  // there is — then pushes to the commune's profile.
  await pinHandler('profileSet', `((n, e) => { window.__profileSet = [n, e]; return Promise.resolve('ok'); })`);
  await page.evaluate(() => {
    const box = document.querySelector('#idform input[type="checkbox"]');
    box.click();
    document.querySelector('#idform form')
      .dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
  });
  await sleep(400);
  const named = await page.evaluate(() => ({
    sent: window.__profileSet,
    hint: localStorage.getItem('pn.id.hint') || '',
    chip: document.querySelector('#idrow .who')?.textContent || '',
    sheetClosed: !document.querySelector('#idform'),
  }));
  h.rec('confirming saved + done sends the name to the commune', !!named.sent && named.sent[0] === 'rosa');
  h.rec('…writes it to the local hint', /\|rosa\|/.test(named.hint), named.hint);
  h.rec('…and the chip says it', /rosa/.test(named.chip), named.chip);
  h.rec('…and only THEN does the sheet close', named.sheetClosed === true);

  // ── recovery friends ──
  // The passcode cannot be reset, so losing it is answered by people: the
  // settings sheet splits it among trusted contacts on the SAME rows the
  // vouch list uses, and the sign-in sheet reassembles it from their pieces.
  // The vat is stubbed here (the live crypto is proven end-to-end in the
  // Guile suite and the live walkthrough); what THIS pins is the surface:
  // rows from contacts, a threshold said as a sentence, one piece per
  // person, and the recovery door feeding the ordinary unlock.
  // a passcode seat: the session that may split it (a device-key session is asked for the passcode first)
  await pinHandler('tier', `(() => Promise.resolve('root'))`);
  await pinHandler('guardianSplit', `((k, n) => Promise.resolve(JSON.stringify(
      Array.from({length: Number(n)}, (_, i) => 'pnr1.EUnlockedAid00000000000000000000000000000000.tagS.' + (i+1) + '.' + k + '.aGk'))))`);
  await page.evaluate(async () => {
    const { seam: __seam } = await import('/app/seam.js');
    __seam.data.contacts = [
      { alias: 'Ana', aid: 'EAna0', rel: 'friend' },
      { alias: 'Sam', aid: 'ESam0', rel: 'friend' },
      { alias: 'Priya', aid: 'EPriya', rel: 'friend' }];
    document.querySelector('#idform')?.remove();
    window.__seam.__realStatus('ok:EUnlockedAid00000000000000000000000000000000|Dk0');
  });
  await sleep(300);
  // recovery friends live in the settings room (⚙ → keys and devices → if you lose your
  // passcode), beside the device keys — the identity sheet only points there
  await openSettingsRoom(page); await sleep(500);
  await page.evaluate(() => [...document.querySelectorAll('.set-navi')]
    .find(x => x.textContent === 'if you lose your passcode')?.click());
  await sleep(500);
  h.rec('settings offers "if you lose your passcode"',
        await page.evaluate(() => /if you lose your passcode/i.test(
          document.querySelector('#setface')?.innerText || '')));
  await page.evaluate(() => {
    let n = 0;
    for (const r of document.querySelectorAll('#setface .vrow')) {
      const b = r.querySelector('.vbtn');
      if (b && /^trust$/.test(b.textContent)) {
        b.dispatchEvent(new MouseEvent('click', { bubbles: true }));
        if (++n === 3) break;
      }
    }
  });
  await sleep(200);
  h.rec('the threshold is said as a sentence, not asked as a number',
        await page.evaluate(() => [...document.querySelectorAll('#setface .opt')]
          .some(e => /any 2 of these 3 could bring your passcode back/i.test(e.textContent))));
  await page.evaluate(() => {
    Object.defineProperty(navigator, 'clipboard',
      { value: { writeText: () => Promise.resolve() }, configurable: true });
    [...document.querySelectorAll('#setface button.go')]
      .find(b => /make the pieces/i.test(b.textContent))?.click();
  });
  await sleep(400);
  const pieceRows = await page.evaluate(() =>
    [...document.querySelectorAll('#setface .vrow .vbtn')]
      .filter(b => /copy their piece/i.test(b.textContent)).length);
  h.rec('one copyable piece per trusted person', pieceRows === 3);

  // the recovery door: pieces in → the ordinary unlock, same as any door.
  // RELOAD first: a seated chip opens settings, and 'connected' keeps a held
  // identity held — idle-with-a-hint (the state whose sheet offers "use a
  // different identity") is a state a device LOADS into. Pins die with the
  // page, so they are re-pinned after.
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 30000 });
  await connect();
  await pinHandler('guardianRecover', `((json) => {
      window.__recoverAsked = JSON.parse(json);
      return Promise.resolve('ok:EUnlockedAid00000000000000000000000000000000|reassembled-passcode-21ch');
    })`);
  await pinHandler('unlock', `((bran, aid, k0) => {
      window.__recoverUnlock = [bran, aid];
      return Promise.resolve('ok:EUnlockedAid00000000000000000000000000000000|Dk0');
    })`);
  await page.evaluate(async () => (await import('/app/tabs/social/id.js')).openIdentityDoor());
  await sleep(300);
  await page.evaluate(() => {
    [...document.querySelectorAll('#idform .gen2')]
      .find(e => /another way in/i.test(e.textContent))
      ?.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  });
  await sleep(300);
  h.rec('the sign-in sheet offers help from people you trusted',
        await page.evaluate(() => /people you trusted/i.test(
          document.querySelector('#idform')?.innerText || '')));
  await page.evaluate(() => {
    document.querySelector('#idform textarea').value =
      'pnr1.EUnlockedAid00000000000000000000000000000000.1.2.aGk\n' +
      'pnr1.EUnlockedAid00000000000000000000000000000000.2.2.aGl';
    [...document.querySelectorAll('#idform button.go')]
      .find(b => /put my passcode back together/i.test(b.textContent))?.click();
  });
  await sleep(400);
  const rec = await page.evaluate(() => ({
    asked: window.__recoverAsked, unlock: window.__recoverUnlock }));
  h.rec('the pasted pieces reach the vat as lines',
        Array.isArray(rec.asked) && rec.asked.length === 2 && rec.asked[0].startsWith('pnr1.'));
  h.rec('…and the reassembled passcode walks the ordinary unlock door',
        !!rec.unlock && rec.unlock[0] === 'reassembled-passcode-21ch'
        && rec.unlock[1] === 'EUnlockedAid00000000000000000000000000000000');
  await page.screenshot({ path: 'tests/ux/_artifacts/day-signup-created.png' }).catch(() => {});

  // ── the three replies that carry an identity ──
  // The spine reports one of ok:/local:/unregistered: for an unlocked
  // identity; only the first is a seat. The chip must say which, and the
  // unregistered one must open onto the join door (the log in hand takes a
  // seat at a commune that never saw it).
  // Seed the hint and RELOAD: what this device remembers is read into a signal
  // at module load, so "a device that knows ada" is a device that loaded
  // knowing her — same premise as the fresh-device reload above.
  await page.evaluate(() => {
    localStorage.setItem('pn.id.hint', 'EUnlockedAid00000000000000000000000000000000|ada||Dk0');
  });
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 30000 });
  await connect();
  await page.evaluate(() => {
    document.querySelector('#idform')?.remove();
    window.__seam.__realStatus('local:EUnlockedAid00000000000000000000000000000000');
  });
  await sleep(200);
  const local = await page.evaluate(() => ({
    text: document.querySelector('#idrow .who')?.textContent || '',
    dot: (document.querySelector('#idrow .who .dot')?.className || '').replace('dot','').trim(),
    title: document.querySelector('#idrow .who')?.getAttribute('title') || '',
  }));
  // the corner is a dot and a name; the sentence lives in the title and the sheet
  h.rec('local: — unlocked, the commune unreachable',
        local.dot === 'warn' && /ada/.test(local.text) && /unreachable/i.test(local.title),
        `${local.dot} · ${local.text} · ${local.title}`);
  await page.evaluate(() => window.__seam.__realStatus('unregistered:EUnlockedAid00000000000000000000000000000000'));
  await sleep(200);
  const unreg = await page.evaluate(() => ({
    text: document.querySelector('#idrow .who')?.textContent || '',
    dot: (document.querySelector('#idrow .who .dot')?.className || '').replace('dot','').trim(),
    title: document.querySelector('#idrow .who')?.getAttribute('title') || '',
  }));
  h.rec('unregistered: — unlocked, this commune never met you',
        unreg.dot === 'warn' && /ada/.test(unreg.text) && /join/i.test(unreg.title),
        `${unreg.dot} · ${unreg.text} · ${unreg.title}`);
  await page.evaluate(() => {
    let joinArgs = null;
    Object.defineProperty(window.__seam.handlers, 'join',
      { value: (n, e) => { joinArgs = [n, e]; return Promise.resolve('ok:EUnlockedAid00000000000000000000000000000000|Dk0'); },
        writable: false, configurable: true });
    window.__joinArgs = () => joinArgs;
    import('/app/tabs/social/id.js').then(m => m.openIdentityDoor());
  });
  await sleep(300);
  const join = await page.evaluate(() => {
    const f = document.querySelector('#idform');
    return { lead: f?.querySelector('.lead')?.textContent || '',
             btn: [...(f?.querySelectorAll('button.go') || [])].map(b => b.textContent).join('|') };
  });
  h.rec('the unregistered sheet explains and offers to join', /hasn.t met you/i.test(join.lead) && /join as ada/i.test(join.btn));
  await page.evaluate(() => {
    const box = document.querySelector('#idform input[type="checkbox"]');
    if (box && !box.checked) box.click();
    [...document.querySelectorAll('#idform button.go')].find(b => /join as/i.test(b.textContent))?.click();
  });
  await sleep(300);
  const joined = await page.evaluate(() => ({
    args: window.__joinArgs(),
    chip: document.querySelector('#idrow .who')?.textContent || '' }));
  h.rec('join hands the hint\'s name to the gateway and the seat follows',
        !!joined.args && joined.args[0] === 'ada' && joined.chip.trim() === 'ada', joined.chip);

  h.rec('no page errors during the flow', errs.length === 0);
  if (errs.length) console.log('PAGE ERRORS:', errs.slice(0, 3).join(' | '));
} finally {
  await browser.close();
  closeServer();
}

summarize(h, ['chip shows create-identity', 'create form popover appears',
              'form has a create button', 'no page errors during the flow']);
