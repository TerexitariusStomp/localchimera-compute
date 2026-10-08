/// tests/ux/events-ux.mjs — personal events render as RIBBONS (like any other
/// event); selecting one opens its editor IN THE BELOW-DIAL CARD (#evdetail),
/// not a popover. Covers: ribbon render, click-to-edit, the editor (title ·
/// once/repeats · commit · delete), busy-blocking (committed recurring event
/// carves availability), conflict note, and click-to-deselect.
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
// The availability wire is in UTC (mytime.ts localToUtcWeekly) and the carve assertion below
// names UTC hours, so the page runs in UTC: on a machine at UTC+2 the same carve is 07–10 + 11–15.
const page = await browser.newPage({ timezoneId: 'UTC' });   // (the harness's newPage carries the seam hook)
const errs = [];
page.on('pageerror', e => errs.push(String(e)));
const ALL = ['monday','tuesday','wednesday','thursday','friday','saturday','sunday'];
const seed = (avail, events) => page.evaluate(({ avail, events }) => {
  localStorage.setItem('pn.ring.avail:local', JSON.stringify(avail));
  localStorage.setItem('pn.ring.events:local', JSON.stringify(events));
}, { avail, events });
const connect = () => page.evaluate(() => {
  window.__availWire = null;
  window.__seam?.status && window.__seam.status('connected');
  window.__seam = window.__seam || {}; window.__seam.handlers = window.__seam.handlers || {};
  // the wasm spine registers its own setAvailability bridge whenever it
  // finishes loading — a plain assignment here loses that race, so the stub
  // pins itself: writes are absorbed, reads always see the capture
  const stub = (j) => { window.__availWire = j; return Promise.resolve('ok'); };
  Object.defineProperty(window.__seam.handlers, 'setAvailability',
                        { configurable: true, get: () => stub, set: () => {} });
});
// A REAL TAP on the ribbon, not a synthetic click.
//
// The ribbon is DRAGGABLE — selection happens on the drag's start, and d3.drag
// swallows a dispatched MouseEvent because it never went through a pointer
// down/up. So aim at the midpoint of its fat transparent hit-arc and drive a
// true mouse down/up there, which is what a finger does. (Case 7 below already
// said this in prose; the helper now does it too.)
const tapPid = async () => {
  const at = await page.evaluate(() => {
    const g = document.querySelector('g.clickable[data-pid]'); if (!g) return null;
    const p = [...g.querySelectorAll('path')].pop(); if (!p) return null;
    const m = p.getPointAtLength(p.getTotalLength() / 2), ctm = p.getScreenCTM();
    return { x: ctm.a * m.x + ctm.c * m.y + ctm.e, y: ctm.b * m.x + ctm.d * m.y + ctm.f };
  });
  if (!at) return false;
  await page.mouse.move(at.x, at.y); await page.mouse.down();
  await sleep(40); await page.mouse.up();
  return true;
};

try {
  // ?face=time explicitly: the map is the default face now, and ribbon editing
  // is offered in the SETTLED DAY VIEW only — off it the geometry is not stable,
  // so a drag would mean something else by the time you let go.
  await page.goto(`${BASE}/app.html?face=time`, { waitUntil: 'domcontentloaded' });
  await seed([{ id: 'a1', t0: 9, t1: 17, days: ALL }],
             [{ id: 'e1', title: 'lunch', t0: 12, t1: 13, repeat: true, days: ALL, committed: true }]);
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 30000 });
  await connect();
  await sleep(400);

  // 1. the personal event renders as a RIBBON (not a thin ring arc)
  const ribbon = await page.evaluate(() => {
    const g = document.querySelector('g.clickable[data-pid]');
    return { present: !!g, label: g ? [...g.querySelectorAll('text')].map(t => t.textContent).join('') : '',
             // no leftover thin yellow ring arc for a non-selected event
             ringArc: [...document.querySelectorAll('svg g path')]
               .some(p => /eccf94|e3a72f/i.test(p.getAttribute('stroke') || '')) };
  });
  h.rec('personal event renders as a ribbon (data-pid group)', ribbon.present === true);
  h.rec('it is NOT left as a thin arc on the ring', ribbon.ringArc === false);

  // 2. clicking the ribbon opens the editor IN THE BELOW-DIAL CARD (#evdetail) —
  //    no popover floating over the dial; the editor "is open" when the card
  //    holds the title input (vs. the "select an event" placeholder).
  await tapPid();
  await sleep(300);
  const ed = await page.evaluate(() => {
    const e = document.querySelector('#evdetail');
    const input = e && e.querySelector('input[type="text"]');
    if (!input) return { open: false };
    const t = e.textContent;
    return { open: true, title: true,
             once: /once/.test(t), repeats: /repeats/.test(t),
             commit: /committed|tentative/.test(t), del: /delete/.test(t) };
  });
  h.rec('clicking the ribbon opens the editor', ed.open === true);
  h.rec('editor has title · once/repeats · commit · delete',
        ed.title && ed.once && ed.repeats && ed.commit && ed.del);
  // and NO floating popover exists (the old #myeventedit is gone)
  h.rec('no floating editor popover over the dial',
        await page.evaluate(() => { const e = document.querySelector('#myeventedit');
          return !e || getComputedStyle(e).display === 'none'; }));

  // 3. BUSY-BLOCK: committed recurring event carves the availability sent to the
  //    planner. Toggle commit off→on to fire av_sync, then read the wire.
  const viewed = await page.evaluate(() => (document.getElementById('datelabel') || {}).textContent || '');
  const WD = { Sun:'sunday',Mon:'monday',Tue:'tuesday',Wed:'wednesday',Thu:'thursday',Fri:'friday',Sat:'saturday' };
  const vd = WD[(viewed.trim().split(/\s+/)[0]) || 'Mon'] || 'monday';
  const toggleCommit = () => page.evaluate(() => {
    const s = [...document.querySelectorAll('#evdetail span')].find(x => /committed|tentative/.test(x.textContent));
    s && s.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  });
  await toggleCommit(); await sleep(80); await toggleCommit();   // → tentative → committed
  await sleep(900);
  const dayEntries = await page.evaluate((vd) => {
    let p = null; try { p = JSON.parse(window.__availWire); } catch (_) {}
    return Array.isArray(p) ? p.filter(e => e.days.includes(vd)) : [];
  }, vd);
  h.rec('committed event carves the hole (09–12 + 13–17)',
        dayEntries.some(e => e.start === '09:00' && e.end === '12:00') &&
        dayEntries.some(e => e.start === '13:00' && e.end === '17:00'));
  h.rec('no full 09–17 block survives', !dayEntries.some(e => e.start === '09:00' && e.end === '17:00'));

  await page.screenshot({ path: 'tests/ux/_artifacts/day-events.png' }).catch(() => {});

  // 4. DESELECT by clicking elsewhere (not the element again)
  await page.evaluate(() => document.querySelector('#dial').dispatchEvent(new MouseEvent('click', { bubbles: true })));
  await sleep(200);
  h.rec('clicking empty space deselects (editor closes)',
        await page.evaluate(() => { const e = document.querySelector('#evdetail');
          return !e || !e.querySelector('input[type="text"]'); }));

  // 4b. CREATE via "+ new" (no editing ring) + edit time via −/+ steppers
  await page.evaluate(() => localStorage.setItem('pn.ring.events:local', '[]'));
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 30000 });
  await connect();
  await sleep(300);
  await page.evaluate(() => document.querySelector('#newevent').dispatchEvent(new MouseEvent('click', { bubbles: true })));
  await sleep(250);
  h.rec('"+ new" creates an own event (ribbon + editor open)',
        await page.evaluate(() => {
          const r = document.querySelector('g.clickable[data-pid]'), e = document.querySelector('#evdetail');
          return !!r && !!e && !!e.querySelector('input[type="text"]');
        }));
  const tBefore = await page.evaluate(() => (document.querySelector('#evdetail') || {}).textContent || '');
  await page.evaluate(() => {            // click the start "+" stepper
    const plus = [...document.querySelectorAll('#evdetail span')].find(s => s.textContent.trim() === '+');
    plus && plus.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  });
  await sleep(200);
  const tAfter = await page.evaluate(() => (document.querySelector('#evdetail') || {}).textContent || '');
  h.rec('time steppers edit the event time', tBefore !== tAfter && /\d\d:\d\d/.test(tAfter));

  // 5. CONFLICTS: two overlapping committed events → editor flags "⚠ overlaps"
  await seed([{ id: 'a1', t0: 9, t1: 17, days: ALL }], [
    { id: 'c1', title: 'lunch',   t0: 12,   t1: 13,   repeat: true, days: ALL, committed: true },
    { id: 'c2', title: 'standup', t0: 12.5, t1: 13.5, repeat: true, days: ALL, committed: true },
  ]);
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 30000 });
  await connect();
  await sleep(400);
  await tapPid();
  await sleep(250);
  h.rec('overlapping commitments are flagged (⚠ overlaps)',
        await page.evaluate(() => /⚠ overlaps/.test((document.querySelector('#evdetail') || {}).textContent || '')));

  // 6. RADIAL LANES: two TIME-OVERLAPPING events must land on different lanes
  //    (different radius → distinct touch zones, no overlap).
  await seed([], [
    { id: 'L1', title: 'one', t0: 10, t1: 14, repeat: true, days: ALL, committed: true },
    { id: 'L2', title: 'two', t0: 12, t1: 16, repeat: true, days: ALL, committed: true },
    { id: 'L3', title: 'three', t0: 18, t1: 19, repeat: true, days: ALL, committed: true },
  ]);
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 30000 });
  await connect();
  await sleep(400);
  const lanes = await page.evaluate(async () => {
    const m = {}; ((await import('/app/stage.js')).stage.evs || []).forEach(e => { if (e._pid) m[e._pid] = e.lane; });
    return m;
  });
  h.rec('overlapping events take different radial lanes',
        lanes.L1 !== undefined && lanes.L2 !== undefined && lanes.L1 !== lanes.L2,
        `L1=${lanes.L1} L2=${lanes.L2} L3=${lanes.L3}`);

  // 7. REAL TAP stays selected. A synthetic click() can't reproduce the
  //    drag-start-opens-then-click-deselects race; drive a true mouse down/up on
  //    a point ON the ribbon and assert the editor stays open (fat hit-arc).
  await seed([], [{ id: 'T1', title: 'tap me', t0: 8, t1: 11, repeat: true, days: ALL, committed: true }]);
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 30000 });
  await connect();
  await sleep(400);
  const onArc = await page.evaluate(() => {
    const g = document.querySelector('g.clickable[data-pid]'); if (!g) return null;
    // the fat transparent hit-arc is the last band-level path; any band path works
    const p = [...g.querySelectorAll('path')].pop(); if (!p) return null;
    const m = p.getPointAtLength(p.getTotalLength() / 2), ctm = p.getScreenCTM();
    return { x: ctm.a * m.x + ctm.c * m.y + ctm.e, y: ctm.b * m.x + ctm.d * m.y + ctm.f };
  });
  if (onArc) { await page.mouse.move(onArc.x, onArc.y); await page.mouse.down();
    await sleep(40); await page.mouse.up(); await sleep(350); }
  h.rec('a real tap on a ribbon stays selected (editor open)',
        await page.evaluate(() => !!document.querySelector('#evdetail input[type="text"]')));

  // 8. RESIZE tracks the mouse the WHOLE way. drawEvents() recreates the dragged
  //    handle each tick; without a stable drag container, coords break after the
  //    first tick and the handle stalls part-way. Drag the t1 handle (hour 11) to
  //    the t0 end (hour 8) → t1 must clamp near t0 (it tracked all the way).
  await seed([], [{ id: 'R1', title: 'resize me', t0: 8, t1: 11, repeat: true, days: ALL, committed: true }]);
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 30000 });
  await connect();
  await sleep(400);
  await tapPid(); await sleep(350);   // select → resize handles render (steady day view)
  const diag = await page.evaluate(() => ({
    selOpen: !!document.querySelector('#evdetail input[type="text"]'),
    circles: document.querySelectorAll('g.clickable[data-pid] circle').length,
  }));
  h.rec('selecting renders the editor', diag.selOpen === true, JSON.stringify(diag));
  const handles = await page.evaluate(() => [...document.querySelectorAll('g.clickable[data-pid] circle')]
    .map(c => { const r = c.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; }));
  h.rec('resize handles appear on a selected event', handles.length >= 2, `n=${handles.length}`);
  if (handles.length >= 2) {
    const a = handles[handles.length - 1], b = handles[0];   // t1 end → t0 end
    await page.mouse.move(a.x, a.y); await page.mouse.down();
    for (let i = 1; i <= 8; i++) await page.mouse.move(a.x + (b.x - a.x) * i / 8, a.y + (b.y - a.y) * i / 8);
    await page.mouse.up(); await sleep(300);
  }
  const t1 = await page.evaluate(() => (JSON.parse(localStorage.getItem('pn.ring.events:local') || '[]')[0] || {}).t1);
  h.rec('resize tracks the mouse all the way (t1 shrank to ~t0)', t1 !== undefined && t1 <= 9, `t1=${t1}`);

  h.rec('no page errors during the flow', errs.length === 0);
  if (errs.length) console.log('PAGE ERRORS:', errs.slice(0, 3).join(' | '));
} finally {
  await browser.close();
  closeServer();
}

summarize(h, ['personal event renders as a ribbon (data-pid group)',
              'clicking the ribbon opens the editor',
              'committed event carves the hole (09–12 + 13–17)',
              'clicking empty space deselects (editor closes)',
              'no page errors during the flow']);
