/// tests/ux/observe-ux.mjs — the confirmation mile in the browser: every planned
/// block carries its means of observation, partials leave the remainder
/// recordable, and the optimistic echo lands in the lived layer.
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();
const h = harness();
const browser = await launch();
const page = await browser.newPage();
const errs = [];
page.on('pageerror', e => errs.push(String(e)));

// A commitment is YOURS only with your AID on it (ingest keeps provider === me), so the
// page remembers an identity and the wire commitment below names that same AID.
const AID = 'EObserveAid0000000000000000000000000000000';
await page.addInitScript(a => localStorage.setItem('pn.id.hint', a + '|Mo|mo@example.org|'), AID);

try {
  await page.goto(`${BASE}/app.html?face=calendar`, { waitUntil: 'networkidle' });
  await sleep(1500);
  const r = await page.evaluate(async (aid) => {
    const { evs, sched, lived } = await import('./app/events.js');
    const { selectEvent } = await import('./app/ribbons.js');
    const { actionsFor } = await import('./app/day/respond.js');
    const calls = { flow: null, effort: null };
    window.__seam.handlers.recordFlow = (...a) => { calls.flow = a; return Promise.resolve("ok:ev-flow-1"); };
    window.__seam.handlers.recordEffort = (...a) => { calls.effort = a; return Promise.resolve('ok:evt-9'); };
    const d = (n) => { const x = new Date(Date.now() + n * 86400000); return x.toISOString().slice(0, 10); };
    window.__seam.ingest({
      locations: [{ id: 'loc-mill', name: 'the mill', lat: 37.79, lng: -122.40 }],
      commitments: [{ id: 'c-77', label: 'milling shift', provider: aid, sh: 9, sm: 0, eh: 12, em: 0,
                      at: 'loc-mill', date: d(0) }],
      plan: { needs: [{ id: 'bread', label: 'bread', met: 1 }], feasible: 'yes',
        schedule: { work: [{ who: 'ana', skill: 'kneading', effort: 2, place: 'loc-mill',
                             when: d(0) + 'T14:00', until: d(0) + 'T16:00', proc: 'p1' }],
                    material: [{ id: 'mc|produce|spec:flour|p1', specId: 'spec:flour',
                                 action: 'produce', spec: 'flour', qty: 4, place: 'loc-mill',
                                 when: d(0) + 'T10:00', proc: 'p1', note: '' }] } },
    });
    await new Promise(r => setTimeout(r, 500));

    const mat = sched.find(e => e.action === 'produce');
    const wk  = sched.find(e => e.action === 'work');
    const cmt = evs.find(e => e.vfId === 'c-77');
    const before = {
      matVerbs: actionsFor(mat).map(a => a.l),
      wkVerbs: actionsFor(wk).map(a => a.l),
      cmtVerbs: actionsFor(cmt).map(a => a.l),
      lived0: lived.length,
    };
    // tap the material row's verb through the real detail card
    selectEvent(mat);
    await new Promise(r => setTimeout(r, 300));
    const btn = [...document.querySelectorAll('#evdetail .respond span')]
      .find(x => /it happened/.test(x.textContent) && !x.querySelector('input'));
    if (btn) btn.click();
    await new Promise(r => setTimeout(r, 400));
    const after = {
      flowArgs: calls.flow, lived1: lived.length,
      matVerbsAfter: actionsFor(mat).map(a => a.l),
      livedBlocks: [...document.querySelectorAll('.calev.lived')].map(b => b.textContent.slice(0, 20)),
    };
    // and the committed work block's verb — a PARTIAL hour of its three
    const rec = actionsFor(cmt).find(a => /it happened/.test(a.l));
    const amt0 = rec && rec.amt;
    if (rec && rec.fa) rec.fa(1);
    await new Promise(r => setTimeout(r, 300));
    const again = actionsFor(cmt).find(a => /it happened/.test(a.l));
    return { before, after, effortArgs: calls.effort, lived2: lived.length,
             partial: { amt0, verbStays: !!again, amtLeft: again && again.amt } };
  }, AID);
  h.rec('material row offers ✓ it happened', r.before.matVerbs.join() === '✓ it happened',
        JSON.stringify(r.before.matVerbs));
  h.rec('schedule WORK row offers nothing (confirms via commit→record)', r.before.wkVerbs.length === 0,
        JSON.stringify(r.before.wkVerbs));
  h.rec('a wire commitment offers its record verb',
        /it happened/.test(r.before.cmtVerbs.join()),
        JSON.stringify(r.before.cmtVerbs));
  h.rec('recordFlow names the row by its id and the spec by its id, not its label',
        !!r.after.flowArgs && r.after.flowArgs[1] === 'produce' && r.after.flowArgs[2] === 'spec:flour'
        && r.after.flowArgs[3] === '4' && r.after.flowArgs[4] === '4'
        && r.after.flowArgs[5] === 'loc-mill' && r.after.flowArgs[7] === 'p1'
        && r.after.flowArgs[9] === 'mc|produce|spec:flour|p1',
        JSON.stringify(r.after.flowArgs));
  h.rec('optimistic echo: a lived block appears, the verb retires',
        r.after.lived1 === r.before.lived0 + 1 && r.after.matVerbsAfter.length === 0
        && r.after.livedBlocks.length > 0,
        JSON.stringify(r.after));
  h.rec('recordEffort got cid + the PARTIAL hour',
        !!r.effortArgs && r.effortArgs[1] === 'c-77' && r.effortArgs[2] === '1' && r.effortArgs[3] === 'hours',
        JSON.stringify(r.effortArgs));
  h.rec('partial: verb stays with the remainder (3 asked, 1 in, 2 left)',
        r.partial.amt0 === 3 && r.partial.verbStays && r.partial.amtLeft === 2,
        JSON.stringify(r.partial));
  h.rec('no page errors', errs.length === 0, errs.join(' | ').slice(0, 200));
} finally {
  await browser.close();
  await closeServer();
}
summarize(h);
