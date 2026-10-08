/// tests/ux/availability-ux.mjs — the availability ring: seed an arc, render
/// it near the rim in the day view, select it (its editor opens in the below-dial
/// #evdetail card, not a popover), toggle its recurrence, confirm the planner
/// wire shape, and delete it. No gateway — pure client flow.
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
const errs = [];
page.on('pageerror', e => errs.push(String(e)));

try {
  // seed one availability arc into localStorage BEFORE the page reads it on load.
  // ?face=time explicitly: the dial lands on the MAP face by default now, and
  // the rings only draw in the SETTLED DAY VIEW — off it the geometry is not
  // stable, so an arc dragged there would mean something else by the time you
  // let go. On the map face every redraw wipes the ring, which is correct
  // behaviour and simply not what this suite is about.
  await page.goto(`${BASE}/app.html?face=time`, { waitUntil: 'domcontentloaded' });
  await page.evaluate(() => {
    localStorage.setItem('pn.ring.avail:local', JSON.stringify(
      [{ id: 'seed1', t0: 9, t1: 13, days: ['monday','tuesday','wednesday','thursday','friday','saturday','sunday'] }]));
  });
  await page.goto(`${BASE}/app.html?face=time`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 30000 });
  // capture what the dial pushes to the planner. The wasm spine registers
  // its own setAvailability bridge whenever it finishes loading — a plain
  // assignment loses that race, so the stub pins itself: writes are
  // absorbed, reads always see the capture.
  await page.evaluate(() => {
    window.__availWire = null;
    window.__seam = window.__seam || {}; window.__seam.handlers = window.__seam.handlers || {};
    const stub = (json) => { window.__availWire = json; return Promise.resolve('ok'); };
    Object.defineProperty(window.__seam.handlers, 'setAvailability',
                          { configurable: true, get: () => stub, set: () => {} });
  });
  await sleep(400);   // let the day view settle + drawEvents/drawAvail run

  // 1. the seeded arc renders in the availability ring (gAvail has a path)
  const rendered = await page.evaluate(() => {
    const g = document.querySelector('g'); // not specific; count paths in the avail group
    // gAvail is the group holding a create-ring <circle> + arc <path>(s)
    const paths = [...document.querySelectorAll('svg g path')].filter(p => {
      const s = p.getAttribute('stroke') || '';
      return /9fd0ea|57a8d8/i.test(s);   // light-blue availability strokes
    });
    return { arcs: paths.length };
  });
  h.rec('seeded availability arc renders in the day view', rendered.arcs >= 1);

  // 2. clicking the arc selects it → the recurrence editor appears
  await page.evaluate(() => {
    const arc = [...document.querySelectorAll('svg g path')]
      .find(p => /9fd0ea|57a8d8/i.test(p.getAttribute('stroke') || ''));
    arc && arc.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  });
  await sleep(200);
  const editor = await page.evaluate(() => {
    const ed = document.querySelector('#evdetail');
    const dayDots = ed ? ed.querySelectorAll('span[title]').length : 0;
    return { present: !!ed, hasEditor: dayDots > 0,   // the avail card lives in #evdetail now
             text: ed ? ed.textContent : '', dayDots };
  });
  h.rec('selecting an arc shows the recurrence editor', editor.hasEditor === true);
  h.rec('editor labels the time window', /09:00.*13:00/.test(editor.text));
  h.rec('editor has 7 weekday toggles', editor.dayDots === 7);

  // 3. toggling a weekday off pushes the new availability to the planner
  // the dial's viewed weekday (header "Sat 13 Jun …") → its day name; we drive
  // the recurrence/filter/delete tests relative to it so they're deterministic.
  const WDMAP = { Sun:'sunday',Mon:'monday',Tue:'tuesday',Wed:'wednesday',Thu:'thursday',Fri:'friday',Sat:'saturday' };
  const ORDER = ['monday','tuesday','wednesday','thursday','friday','saturday','sunday'];
  const viewed = await page.evaluate(() => (document.getElementById('datelabel')||{}).textContent || '');
  const viewedDay = WDMAP[(viewed.trim().split(/\s+/)[0]) || 'Mon'] || 'monday';
  const otherDay = ORDER.find(d => d !== viewedDay);

  // 3. toggle a NON-viewed weekday off → pushes the new recurrence to the planner
  await page.evaluate((d) => {
    const dot = document.querySelector(`#evdetail span[title="${d}"]`);
    dot && dot.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  }, otherDay);
  await sleep(900);   // debounced sync (600ms)
  const wire = await page.evaluate(() => window.__availWire);
  let parsed = null; try { parsed = JSON.parse(wire); } catch (_) {}
  h.rec('toggling recurrence pushes to the planner (setAvailability)', !!wire);
  h.rec('wire shape is {start,end,days} with HH:MM times',
        Array.isArray(parsed) && parsed[0] &&
        /^\d\d:\d\d$/.test(parsed[0].start) && /^\d\d:\d\d$/.test(parsed[0].end) &&
        Array.isArray(parsed[0].days));
  // av_sync emits per-weekday entries ({start,end,days:[oneDay]}) so net
  // availability (minus committed events) is exact per day.
  h.rec('the toggled-off weekday is removed from the recurrence',
        Array.isArray(parsed) && parsed.length > 0 &&
        parsed.every(e => !e.days.includes(otherDay)) &&
        parsed.some(e => e.days.includes(viewedDay)));

  // 3b. RECURRENCE FILTER: toggling the VIEWED day off hides the arc on this day
  const arcsNow = () => page.evaluate(() => [...document.querySelectorAll('svg g path')]
    .filter(p => /9fd0ea|57a8d8/i.test(p.getAttribute('stroke') || '')).length);
  await page.evaluate((d) => {
    const dot = document.querySelector(`#evdetail span[title="${d}"]`);
    dot && dot.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  }, viewedDay);
  await sleep(200);
  h.rec('excluding the viewed weekday hides the arc on that day', (await arcsNow()) === 0);
  // toggle it back on → it returns
  await page.evaluate((d) => {
    const dot = document.querySelector(`#evdetail span[title="${d}"]`);
    dot && dot.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  }, viewedDay);
  await sleep(200);
  h.rec('re-including the weekday brings the arc back', (await arcsNow()) === 1);

  await page.screenshot({ path: 'tests/ux/_artifacts/day-availability.png' }).catch(() => {});

  // 4. DELETE PROMPTS this-day vs every-day (arc recurs on >1 day incl. today)
  await page.evaluate(() => {
    const del = [...document.querySelectorAll('#evdetail span')]
      .find(s => /^✕ delete$/.test(s.textContent.trim()));
    del && del.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  });
  await sleep(150);
  const prompt = await page.evaluate(() => {
    const spans = [...document.querySelectorAll('#evdetail span')].map(s => s.textContent.trim());
    return { thisDay: spans.some(t => /^this /i.test(t)), everyDay: spans.some(t => /^every day$/i.test(t)),
             cancel: spans.some(t => /^cancel$/i.test(t)) };
  });
  h.rec('delete asks "this day" vs "every day" (with cancel)',
        prompt.thisDay && prompt.everyDay && prompt.cancel);

  // choose "every day" → the whole arc is removed + cleared from localStorage
  await page.evaluate(() => {
    const all = [...document.querySelectorAll('#evdetail span')].find(s => /^every day$/i.test(s.textContent.trim()));
    all && all.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  });
  await sleep(300);
  const afterDelete = await page.evaluate(() => ({
    arcs: [...document.querySelectorAll('svg g path')]
      .filter(p => /9fd0ea|57a8d8/i.test(p.getAttribute('stroke') || '')).length,
    stored: JSON.parse(localStorage.getItem('pn.ring.avail:local') || '[]').length,
  }));
  h.rec('delete "every day" removes the arc from the ring', afterDelete.arcs === 0);
  h.rec('delete "every day" clears it from localStorage', afterDelete.stored === 0);

  h.rec('no page errors during the flow', errs.length === 0);
  if (errs.length) console.log('PAGE ERRORS:', errs.slice(0, 3).join(' | '));
} finally {
  await browser.close();
  closeServer();
}

summarize(h, ['seeded availability arc renders in the day view',
              'selecting an arc shows the recurrence editor',
              'toggling recurrence pushes to the planner (setAvailability)',
              'no page errors during the flow']);
