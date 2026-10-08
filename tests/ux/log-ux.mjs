/// tests/ux/log-ux.mjs — the LOG face: the captain's log. Standalone/demo
/// mode (no gateway): the diary works end-to-end — a typed entry lands under
/// its stardate, the plain alias scan suggests the demo contacts the entry
/// names, a chip tap tags them, entries survive a reload (localStorage), and
/// striking one removes it. The AI pass and the observe path are gateway-only
/// (the orb's rule) and stay quiet here.
///
/// Run via: make test-log-ux
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
page.on('pageerror', e => h.errs.push(String(e).slice(0, 160)));

try {
  await page.goto(`${BASE}/app.html?face=log`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#logface.on', { timeout: 30000 });
  h.rec('?face=log deep link lands on the log face', true);
  h.rec('the composer renders (mic + draft + log it)',
        await page.evaluate(() =>
          !!(document.querySelector('#logmic') && document.querySelector('#logdraft')
             && document.querySelector('#logcommit'))));
  h.rec('the rail carries the log panel',
        await page.$eval('#logSecs', el => el.classList.contains('on')
          && el.textContent.includes("captain's log")));
  h.rec('empty log says so',
        await page.$eval('#logentries', el => el.textContent.includes('No entries yet')));
  h.rec('the footer carries the universal mic, leftmost',
        await page.evaluate(() => {
          const row = document.querySelector('#sharebar .sharebar-row, #sharebar');
          const mic = document.querySelector('#sbmic');
          return !!mic && !!row && row.contains(mic)
                 && mic.parentElement.firstElementChild === mic;
        }));

  // A typed entry: names two demo contacts, so the alias scan has work to do.
  await page.type('#logdraft', 'Helped Ana fix the greenhouse pump, then reviewed the seed order with Priya.');
  await page.click('#logcommit');
  await sleep(400);
  h.rec('logging an entry renders its card',
        await page.$eval('#logentries', el => el.querySelectorAll('.lg-entry').length === 1));
  h.rec('the entry carries a stardate + civil time',
        await page.$eval('.lg-head', el =>
          /stardate \d+\.\d/.test(el.textContent) && /\d{2}:\d{2}/.test(el.textContent)));
  h.rec('the alias scan suggests Ana and Priya',
        await page.evaluate(() => {
          const t = [...document.querySelectorAll('.lg-chip')].map(c => c.textContent.trim());
          return t.includes('Ana') && t.includes('Priya');
        }));
  h.rec('the rail counts the entry',
        await page.$eval('#logpanel', el => /\b1\b/.test(el.textContent)));

  // Tag Ana; the chip flips on and the tally counts a person.
  await page.evaluate(() => {
    [...document.querySelectorAll('.lg-chip')]
      .find(c => c.textContent.trim() === 'Ana')
      ?.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  });
  await sleep(300);
  h.rec('tapping a chip tags the contact',
        await page.evaluate(() =>
          [...document.querySelectorAll('.lg-chip')]
            .some(c => c.classList.contains('on') && c.textContent.includes('Ana'))));
  h.rec('the rail counts the tagged person',
        await page.$eval('#logpanel', el => /1<\/b> people tagged/.test(el.innerHTML)));
  h.rec('a tag opens the invite flow (✉ invite appears)',
        await page.evaluate(() =>
          [...document.querySelectorAll('.lg-inv')].some(x => x.textContent.includes('invite'))));
  h.rec('the entry offers share-to-channel',
        await page.evaluate(() => !!document.querySelector('.lg-share')));
  h.rec('the rail carries the digest section + its button',
        await page.$eval('#logpanel', el =>
          el.textContent.includes('the week, digested')
          && !!el.querySelector('.lg-digest-go')));

  // Standalone (no gateway): the social + digest doors degrade to hints, never throw.
  await page.evaluate(() => {
    document.querySelector('.lg-inv')?.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    document.querySelector('.lg-share')?.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    document.querySelector('.lg-digest-go')?.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  });
  await sleep(300);
  h.rec('offline, the doors hint instead of throwing',
        await page.$eval('#logentries', el => el.querySelectorAll('.lg-entry').length === 1));

  await page.screenshot({ path: 'tests/ux/_artifacts/day-log.png' }).catch(() => {});

  // Local-first: the entry (and its tag) survive a reload.
  await page.goto(`${BASE}/app.html?face=log`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#logface.on', { timeout: 30000 });
  await sleep(400);
  h.rec('entries survive a reload (localStorage)',
        await page.$eval('#logentries', el =>
          el.querySelectorAll('.lg-entry').length === 1
          && el.textContent.includes('greenhouse pump')));
  h.rec('the tag survives with it',
        await page.evaluate(() =>
          [...document.querySelectorAll('.lg-chip')]
            .some(c => c.classList.contains('on') && c.textContent.includes('Ana'))));

  // Strike the entry from the log.
  await page.evaluate(() =>
    document.querySelector('.lg-del')
      ?.dispatchEvent(new MouseEvent('click', { bubbles: true })));
  await sleep(300);
  h.rec('striking an entry removes it',
        await page.$eval('#logentries', el =>
          el.querySelectorAll('.lg-entry').length === 0));

  // Leaving and returning keeps the face wiring sound.
  await page.evaluate(() =>
    document.querySelector('#face-time')
      ?.dispatchEvent(new MouseEvent('click', { bubbles: true })));
  await sleep(200);
  h.rec('leaving the face hides it',
        await page.$eval('#logface', el => !el.classList.contains('on')));
  await page.evaluate(() =>
    document.querySelector('#face-log')
      ?.dispatchEvent(new MouseEvent('click', { bubbles: true })));
  await sleep(200);
  h.rec('the nav strip brings it back',
        await page.$eval('#logface', el => el.classList.contains('on')));
} finally {
  await browser.close();
  closeServer();
}

summarize(h, ['?face=log deep link lands on the log face',
              'the composer renders (mic + draft + log it)',
              'logging an entry renders its card',
              'the entry carries a stardate + civil time',
              'the alias scan suggests Ana and Priya',
              'tapping a chip tags the contact',
              'entries survive a reload (localStorage)',
              'striking an entry removes it',
              'the nav strip brings it back']);
