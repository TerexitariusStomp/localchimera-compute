/// tests/ux/spacetime-ux.mjs — the lived layer renders beside the plan, a span
/// that crosses midnight covers both its columns, and a move with two located
/// ends derives a journey inside the turn window.
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();
const h = harness();
const browser = await launch();
const page = await browser.newPage();
const errs = [];
page.on('pageerror', e => errs.push(String(e)));

try {
  await page.goto(`${BASE}/app.html?face=calendar`, { waitUntil: 'networkidle' });
  await sleep(1500);
  const r = await page.evaluate(async () => {
    const { lived, sched } = await import('./app/events.js');
    const { mapOffers, inTurnWindow } = await import('./app/offers.js');
    const d = (n) => { const x = new Date(Date.now() + n * 86400000); return x.toISOString().slice(0, 10); };
    window.__seam.ingest({
      locations: [
        { id: 'loc-mill', name: 'the mill', lat: 37.79, lng: -122.40 },
        { id: 'loc-store', name: 'the store', lat: 37.77, lng: -122.42 }],
      plan: { needs: [{ id: 'bread', label: 'bread', met: 1 }], feasible: 'yes',
        schedule: {
          // a run that crosses midnight: 22:00 today → 02:00 tomorrow
          work: [{ who: 'ana', skill: 'night milling', effort: 4, place: 'loc-mill',
                   when: d(0) + 'T22:00', until: d(1) + 'T02:00', proc: 'p1' }],
          material: [] } },
      events: [
        { id: 'ev1', label: 'work night milling', action: 'work', spec: 'skill-milling',
          from: 'ana', at: 'loc-mill', to: '', date: d(0), endDate: '',
          sh: 9, sm: 0, eh: 12, em: 0 },
        { id: 'ev2', label: 'move flour', action: 'move', spec: 'flour',
          from: 'ana', at: 'loc-mill', to: 'loc-store', date: d(0), endDate: '',
          sh: 13, sm: 0, eh: 14, em: 0 }],
    });
    await new Promise(r => setTimeout(r, 600));
    // week view so both columns of the midnight span show — the view picker is
    // a <select> now; re-find and retry across redraws
    for (let i = 0; i < 4 && document.querySelectorAll('.calhead').length < 2; i++) {
      const sel = document.querySelector('.calvsel');
      if (sel) { sel.value = 'week'; sel.dispatchEvent(new Event('change', { bubbles: true })); }
      await new Promise(r => setTimeout(r, 500));
    }
    const livedBlocks = [...document.querySelectorAll('.calev.lived')].map(b => b.textContent.slice(0, 24));
    const nightBlocks = [...document.querySelectorAll('.calev')]
      .filter(b => /night milling/.test(b.textContent) && !b.classList.contains('lived'))
      .map(b => b.textContent.slice(0, 30));
    const journeys = mapOffers().filter(o => o.loc && o.toLoc && o.toLoc.lat != null);
    return { lived: lived.map(e => ({ label: e.label, doy: e.doy, to: e.toLoc && e.toLoc.name })),
             schedRow: sched[0] && { doy: sched[0].doy, doy1: sched[0].doy1, t0: sched[0].t0, t1: sched[0].t1 },
             livedBlocks, nightBlocks,
             journey: journeys[0] && { from: journeys[0].loc.name, to: journeys[0].toLoc.name,
                                       inWin: inTurnWindow(journeys[0]) } };
  });
  h.rec('lived events ingested with resolved ends', r.lived.length === 2 && r.lived[1].to === 'the store',
        JSON.stringify(r.lived));
  h.rec('lived blocks render in the grid', r.livedBlocks.length === 2, JSON.stringify(r.livedBlocks));
  h.rec('midnight span carries doy1 (t0=22, t1=2)', r.schedRow && r.schedRow.doy1 === r.schedRow.doy + 1
        && r.schedRow.t0 === 22 && r.schedRow.t1 === 2, JSON.stringify(r.schedRow));
  h.rec('the span draws on BOTH columns', r.nightBlocks.length === 2, JSON.stringify(r.nightBlocks));
  h.rec('the move derives a journey (both ends, in window)', !!r.journey && r.journey.from === 'the mill'
        && r.journey.to === 'the store' && r.journey.inWin, JSON.stringify(r.journey));
  h.rec('no page errors', errs.length === 0, errs.join(' | ').slice(0, 200));
} finally {
  await browser.close();
  await closeServer();
}
summarize(h);
