/// tests/ux/settings-ux.mjs — the calendar RAIL and the SETTINGS room.
///
/// Two surfaces, one property: neither is decoration. The rail's mini-month moves
/// the whole dial; its calendar checkboxes are real filters that every reader of
/// the day obeys at once (dial's ribbons, the week grid, the map, the panel); and
/// settings ADOPTS the dial's own view inputs rather than mirroring them, so there
/// is one source of truth for a setting rather than two that can drift.
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
const openSettingsRoom = async (page) => {
  await page.evaluate(() => document.querySelector('#idrow .who').click());
  await sleep(250);
  await page.evaluate(() => [...document.querySelectorAll('#acct .acct-row')].find(r => r.querySelector('.acct-l')?.textContent === 'settings').click());
};
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
await page.setViewportSize({ width: 1280, height: 950 });
const errs = [];
page.on('pageerror', e => errs.push(String(e)));

const rail = () => page.evaluate(() => ({
  days: document.querySelectorAll('#calrail .cr-day').length,
  today: document.querySelector('#calrail .cr-day.today')?.textContent || null,
  viewed: document.querySelector('#calrail .cr-day.on')?.textContent || null,
  busy: [...document.querySelectorAll('#calrail .cr-day.busy')].map(e => e.textContent),
  firstCol: document.querySelector('#calrail .cr-wd')?.textContent || null,
  clocks: [...document.querySelectorAll('#calrail .cr-clock')].map(e => e.textContent.trim()),
  cals: [...document.querySelectorAll('#calrail .cr-cal')].map(e => e.textContent.trim()),
  month: document.querySelector('#calrail .cr-mname')?.textContent || null,
}));
const gridTitles = () => page.evaluate(() =>
  [...document.querySelectorAll('.calev .calev-t')].map(e => e.textContent));
const uncheckCal = name => page.evaluate(n => {
  const row = [...document.querySelectorAll('#calrail .cr-cal')].find(r => r.textContent.includes(n));
  row.querySelector('input').click();
}, name);
const navTo = title => page.evaluate(t => {
  const a = [...document.querySelectorAll('.set-navi')].find(x => x.textContent === t);
  if (a) a.click();
}, title);

try {
  await page.goto(`${BASE}/app.html?face=cal`, { waitUntil: 'domcontentloaded' });
  await sleep(2200);

  // ── the rail ────────────────────────────────────────────────────────────
  let r = await rail();
  h.rec('app.html loads without page errors', errs.length === 0, errs.slice(0, 2).join(' | '));
  h.rec('the mini-month draws whole weeks', r.days > 0 && r.days % 7 === 0, `${r.days} cells`);
  h.rec('today is ringed and the viewed day filled', !!r.today && !!r.viewed, `${r.today}/${r.viewed}`);
  h.rec('a day carrying events is dotted', r.busy.length > 0, r.busy.join(','));
  h.rec('the world clock shows a zone and its hour', r.clocks.length > 0 && /\d\d:\d\d/.test(r.clocks[0]),
        r.clocks.join(' | '));
  h.rec('the real sources are listed as calendars',
        ['social-plan', 'proposals', 'my events', 'open shifts', 'availability', 'schedule', 'my needs', 'what happened']
          .every(n => r.cals.some(c => c.includes(n))), r.cals.join(' | '));

  // people search: typed ONE KEYSTROKE AT A TIME, because that is the way it
  // breaks — a redraw that rebuilds or re-parents the field takes the focus with
  // it, and the first character typed becomes the last.
  await page.click('#calrail .cr-sin');
  const typed = [];
  for (const ch of 'priya') {
    await page.keyboard.type(ch);
    await sleep(120);
    typed.push(await page.evaluate(() => ({
      v: document.querySelector('#calrail .cr-sin')?.value,
      focused: document.activeElement === document.querySelector('#calrail .cr-sin'),
    })));
  }
  h.rec('the search field keeps focus through every keystroke',
        typed.every(t => t.focused) && typed[typed.length - 1].v === 'priya',
        typed.map(t => `${t.v}/${t.focused}`).join(' '));
  const hits = await page.evaluate(() =>
    [...document.querySelectorAll('#calrail .cr-hit b')].map(e => e.textContent));
  h.rec('…and it finds the contact', hits.some(x => /priya/i.test(x)), hits.join(' | '));
  // the caret keeps its place mid-string, so editing a query is possible at all
  await page.keyboard.press('Home'); await page.keyboard.type('X'); await sleep(200);
  h.rec('…and the caret stays where you put it', await page.evaluate(() => {
    const i = document.querySelector('#calrail .cr-sin');
    return i.value === 'Xpriya' && i.selectionStart === 1;
  }));
  // toggling something else in the rail must not steal the field either
  await page.evaluate(() => {
    const r = [...document.querySelectorAll('#calrail .cr-cal')].find(x => x.textContent.includes('availability'));
    r.querySelector('input').click();
  });
  await sleep(400);
  h.rec('…and another rail control redrawing does not steal it',
        await page.evaluate(() => document.activeElement === document.querySelector('#calrail .cr-sin')));
  await page.evaluate(() => {
    const r = [...document.querySelectorAll('#calrail .cr-cal')].find(x => x.textContent.includes('availability'));
    r.querySelector('input').click();
  });
  await page.fill('#calrail .cr-sin', '');
  await sleep(250);

  // ── the calendars are real filters ──────────────────────────────────────
  const all = await gridTitles();
  h.rec('the grid shows the day, its proposals and its open shifts',
        all.includes('harvest shift') && all.includes('bakery shift w/ Sam')
        && all.includes('library shelving'), `${all.length} blocks`);
  await uncheckCal('open shifts'); await sleep(600);
  const noOpen = await gridTitles();
  h.rec('unchecking `open shifts` drops exactly those from the week grid',
        !noOpen.includes('library shelving') && noOpen.includes('harvest shift')
        && noOpen.includes('bakery shift w/ Sam'), `${all.length} → ${noOpen.length}`);
  await uncheckCal('proposals'); await sleep(600);
  const noProps = await gridTitles();
  h.rec('…and unchecking `proposals` drops those too',
        !noProps.includes('bakery shift w/ Sam') && noProps.includes('harvest shift'),
        `${noOpen.length} → ${noProps.length}`);
  h.rec('the panel list obeys the same switch',
        await page.evaluate(() => document.querySelectorAll('#props li').length === 0));
  // and the month's dot follows what is left showing
  await uncheckCal('social-plan'); await uncheckCal('my events'); await sleep(600);
  h.rec('with every event source off, no day is dotted',
        (await rail()).busy.length === 0);
  // put them back
  for (const n of ['social-plan', 'my events', 'proposals', 'open shifts']) { await uncheckCal(n); await sleep(150); }
  await sleep(500);
  h.rec('re-checking restores the grid',
        (await gridTitles()).length === all.length, `${(await gridTitles()).length} vs ${all.length}`);

  // ── the mini-month moves the WHOLE dial ─────────────────────────────────
  const before = await page.evaluate(() => document.getElementById('datelabel')?.textContent);
  await page.evaluate(() => {
    const d = [...document.querySelectorAll('#calrail .cr-day')]
      .find(a => a.textContent === '20' && !a.classList.contains('out'));
    d.click();
  });
  await sleep(800);
  const after = await page.evaluate(() => document.getElementById('datelabel')?.textContent);
  h.rec('clicking a day moves the dial itself (the date row followed)',
        !!after && after !== before, `${before} → ${after}`);
  h.rec('…and the month marks it as the viewed day', (await rail()).viewed === '20');

  // ── settings ────────────────────────────────────────────────────────────
  await openSettingsRoom(page); await sleep(500);
  const open = await page.evaluate(() => ({
    on: document.getElementById('setface')?.classList.contains('on'),
    tookStage: document.getElementById('main')?.hasAttribute('data-settings'),
    groups: [...document.querySelectorAll('.set-navh')].map(e => e.textContent),
    items: [...document.querySelectorAll('.set-navi')].map(e => e.textContent),
    barStays: (document.getElementById('sharebar')?.getBoundingClientRect().height || 0) > 20,
  }));
  h.rec('the header’s ⚙ opens settings over the stage', !!open.on && !!open.tookStage);
  h.rec('it is a two-pane room with grouped sections',
        open.groups.length >= 2 && open.items.length >= 5, open.items.join(' | '));
  h.rec('the share bar stays — it is chrome, not a face', open.barStays);
  // the left pane is the SITE'S panel, not a second nav column of its own
  h.rec('the section list uses the existing side panel',
        await page.evaluate(() => !!document.querySelector('#panel #setSecs.railgrp.on #setnav')
                                  && !document.querySelector('#setface #setnav')));
  h.rec('…and the face’s own rail steps aside while it does',
        await page.evaluate(() => !document.querySelector('#calSecs')?.classList.contains('on')));

  await navTo('dial views'); await sleep(400);
  const adopted = await page.evaluate(() => ({
    one: document.querySelectorAll('#ctl').length,
    inPane: !!document.querySelector('#setpane #ctl'),
    realInput: !!document.querySelector('#setpane #chords'),
  }));
  h.rec('the dial-view box is ADOPTED, not copied — exactly one #ctl, in settings',
        adopted.one === 1 && adopted.inPane && adopted.realInput, JSON.stringify(adopted));

  // a setting that changes a real thing: the week's first column
  await navTo('look and feel'); await sleep(350);
  const firstBefore = (await rail()).firstCol;
  await page.evaluate(() => {
    const sel = [...document.querySelectorAll('#setpane select')]
      .find(s => [...s.options].some(o => o.textContent === 'Sunday'));
    sel.value = '0'; sel.dispatchEvent(new Event('change'));
  });
  await sleep(600);
  const firstAfter = (await rail()).firstCol;
  h.rec('changing the week start moves the month’s first column',
        firstBefore === 'M' && firstAfter === 'S', `${firstBefore} → ${firstAfter}`);

  await page.keyboard.press('Escape'); await sleep(400);
  const closed = await page.evaluate(() => ({
    off: !document.getElementById('setface').classList.contains('on'),
    stage: !document.getElementById('main').hasAttribute('data-settings'),
    railBack: document.getElementById('calSecs').classList.contains('on'),
    navGone: !document.getElementById('setSecs').classList.contains('on'),
    ctlAlive: document.querySelectorAll('#ctl').length === 1,
  }));
  h.rec('Escape leaves settings and the stage comes back', closed.off && closed.stage);
  h.rec('…the face’s rail returns to the panel', closed.railBack && closed.navGone,
        JSON.stringify(closed));
  h.rec('…and the adopted dial-view box survives in the document (never dropped)',
        closed.ctlAlive);

  // ── the spine: one signal, every reader — nothing calls a redraw by hand ──
  // toggle a calendar in SETTINGS, close, and the rail's own checkbox must have
  // followed with nothing telling it to (both read app/calendars.js's signal).
  await openSettingsRoom(page); await sleep(400);
  await navTo('calendars'); await sleep(300);
  await page.evaluate(() => {
    const r = [...document.querySelectorAll('#setpane .set-check')].find(x => x.textContent.includes('my events'));
    r.querySelector('input').click();
  });
  await sleep(500);
  await page.evaluate(() => document.getElementById('setback').click());
  await sleep(500);
  h.rec('a settings toggle reaches the rail through the signal, unbidden',
        await page.evaluate(() => [...document.querySelectorAll('#calrail .cr-cal')]
          .find(r => r.textContent.includes('my events'))?.querySelector('input').checked === false));

  // ── a setting that forgets itself is a lie: the dial views persist too ────
  await openSettingsRoom(page); await sleep(400);
  await navTo('dial views'); await sleep(400);
  await page.evaluate(() => document.querySelector('#setpane #chords').click());
  await sleep(400);
  const stored = await page.evaluate(() => localStorage.getItem('pn.dial.views'));
  await page.reload({ waitUntil: 'domcontentloaded' });
  await sleep(2200);
  h.rec('a dial view survives a reload and is re-applied',
        await page.evaluate(() => document.getElementById('chords')?.checked === true),
        String(stored));
  // the theme, the calendars and the prefs this run touched are all on disk. The
  // world clock is absent on purpose until a zone is EDITED: the default list is
  // just the device's own zone, and writing a default is how a preference file
  // starts lying about having been chosen.
  h.rec('…as do the theme, the calendars and the prefs',
        await page.evaluate(() => ['pn.theme', 'pn.calendars.off', 'pn.prefs']
          .every(k => localStorage.getItem(k) !== null)),
        await page.evaluate(() => ['pn.theme', 'pn.calendars.off', 'pn.prefs',
                                   'pn.world-clocks']
          .map(k => `${k}=${localStorage.getItem(k)}`).join(' ')));
  h.rec('no page errors across the whole flow', errs.length === 0, errs.slice(0, 3).join(' | '));
  await page.screenshot({ path: process.env.SHOT || '/tmp/day-settings.png' });
  h.info(`screenshot: ${process.env.SHOT || '/tmp/day-settings.png'}`);
} catch (e) { h.rec('fatal', false, e.message); }
finally { await browser.close(); closeServer(); }

summarize(h, ['the mini-month draws whole weeks']);
