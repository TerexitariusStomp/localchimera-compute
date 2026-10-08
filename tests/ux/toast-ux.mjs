/// tests/ux/toast-ux.mjs — TOASTS: the passing remark (browser/app/toast.js).
/// Standalone/demo mode (no gateway): a toast raised from the page's own module
/// lands in #toasts wearing its kind, a repeat wears a count instead of a second
/// card, the stack keeps its newest four, a click / the ✕ / Escape put one away,
/// the clock spends the card by itself, and the pointer banks what is left. The
/// last check is the one that matters most: hint() — what every face calls when
/// the gateway replies — reaches the toast AND the voice line beside the mic.
///
/// Run via: make test-toast-ux
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
page.on('pageerror', e => h.errs.push(String(e).slice(0, 160)));

// the module, in the page: every check below drives the real toast.js the dial
// itself loads, over the real sheet in app.html
const raise = (msg, kind, opts) => page.evaluate(
  ([m, k, o]) => import('./app/toast.js').then(t => { t.toast(m, k, o); }),
  [msg, kind, opts || null]);
// `.out` cards are on their way off screen — the stack is what is staying
const cards = () => page.$$eval('#toasts .toast:not(.out)', els => els.map(el => ({
  kind: [...el.classList].find(c => c.startsWith('toast-')) || 'toast-notice',
  msg: el.querySelector('.toast-msg').textContent,
  count: el.querySelector('.toast-count').textContent,
  role: el.getAttribute('role') || '',
})));

try {
  await page.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
  // the nav strip is up ⇒ the dial's modules ran. `attached`, not visible: a fresh visitor's
  // strip shows only the default tabs (map, calendar, forum), so the clock's button exists
  // here but is hidden until the clock is the face
  await page.waitForSelector('#face-time', { state: 'attached', timeout: 30000 });
  await sleep(600);

  await raise('the plan has your commitment', 'success');
  await sleep(500);            // the entrance transition has landed
  let c = await cards();
  h.rec('a toast lands, wearing its kind and its words',
        c.length === 1 && c[0].kind === 'toast-success'
        && c[0].msg === 'the plan has your commitment');
  h.rec('the card is on screen (the entrance ran)',
        await page.$eval('#toasts .toast', el =>
          el.classList.contains('in') && getComputedStyle(el).opacity === '1'));

  await raise('the plan has your commitment', 'success');
  await sleep(150);
  c = await cards();
  h.rec('the same remark twice is one card wearing ×2',
        c.length === 1 && c[0].count === '×2');

  await raise('the grant did not go through', 'error');
  await sleep(150);
  c = await cards();
  h.rec('an error card reads through as an alert',
        c.length === 2 && c[1].kind === 'toast-error' && c[1].role === 'alert');
  h.rec('each kind paints its own colour (the theme tokens resolve)',
        await page.$$eval('#toasts .toast', els => {
          const bg = els.map(el => getComputedStyle(el).backgroundColor);
          return bg.length === 2 && bg[0] !== bg[1] && bg.every(b => /^rgb/.test(b));
        }));

  // the stack keeps its newest MAX (4)
  for (const n of [1, 2, 3, 4]) await raise(`crowd ${n}`, 'notice');
  await sleep(300);
  c = await cards();
  h.rec('the stack keeps the newest four',
        c.length === 4 && c[3].msg === 'crowd 4' && !c.some(x => x.msg.includes('commitment')));

  // Escape is the site's "put it away" key here too
  await page.keyboard.press('Escape');
  await sleep(500);
  h.rec('Escape clears the stack', (await cards()).length === 0);

  // the ✕ dismisses one card and leaves its neighbour
  await raise('one', 'notice');
  await raise('two', 'notice');
  await sleep(200);
  await page.click('#toasts .toast:first-child .toast-x');
  await sleep(500);
  c = await cards();
  h.rec('the ✕ puts one card away and leaves the other',
        c.length === 1 && c[0].msg === 'two');
  await page.keyboard.press('Escape');
  await sleep(400);

  // the clock: a toast spends its life and leaves on its own
  await raise('a short life', 'notice', { duration: 700 });
  await sleep(200);
  h.rec('a timed toast is on screen while its life runs', (await cards()).length === 1);
  await sleep(1200);
  h.rec('the clock spends it and the card leaves', (await cards()).length === 0);

  // the pointer banks what is left, so a card under it waits for you
  await raise('read me slowly', 'notice', { duration: 900 });
  await sleep(120);
  await page.hover('#toasts .toast');
  await sleep(1500);
  h.rec('the pointer holds a card open past its life', (await cards()).length === 1);
  await page.mouse.move(5, 5);
  await sleep(1400);
  h.rec('moving away spends the rest of it', (await cards()).length === 0);

  // the point of the whole thing: hint() — what every face already calls when
  // the gateway replies — speaks in BOTH places at once. The voice line beside
  // the mic keeps the time face's running commentary; the toast carries the same
  // words to whichever face you are actually on.
  await page.evaluate(() =>
    import('./app/core.js').then(m =>
      m.hint('sharing rides the gateway — sign in first', 'warn')));
  await sleep(300);
  c = await cards();
  h.rec('a gateway reply hints as a toast, wearing the kind the site gave it',
        c.length === 1 && c[0].kind === 'toast-warn'
        && c[0].msg.includes('sign in first'));
  h.rec('the same words stay on the voice line beside the mic',
        await page.$eval('#voicestate', el => el.textContent.includes('sign in first')));
  h.rec('the toasts sit above the faces (they are always readable)',
        await page.$eval('#toasts', el => parseInt(getComputedStyle(el).zIndex, 10) >= 3000));

  await page.screenshot({ path: 'tests/ux/_artifacts/day-toast.png' }).catch(() => {});
  h.rec('the page raised no errors', h.errs.length === 0, h.errs.join(' | '));
} catch (e) {
  h.rec('fatal', false, e.message);
} finally {
  await browser.close();
  closeServer();
}

summarize(h, ['a toast lands, wearing its kind and its words',
              'the card is on screen (the entrance ran)',
              'the same remark twice is one card wearing ×2',
              'an error card reads through as an alert',
              'each kind paints its own colour (the theme tokens resolve)',
              'the stack keeps the newest four',
              'Escape clears the stack',
              'the ✕ puts one card away and leaves the other',
              'the clock spends it and the card leaves',
              'the pointer holds a card open past its life',
              'moving away spends the rest of it',
              'a gateway reply hints as a toast, wearing the kind the site gave it',
              'the same words stay on the voice line beside the mic',
              'the page raised no errors']);
