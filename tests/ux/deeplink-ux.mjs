/// tests/ux/deeplink-ux.mjs — the boot deep links that are not a face.
/// ?focus=<need> opens the dial already zoomed into that need, and the priority
/// stack shows the level above it. Its regression is invisible without a test:
/// the parameter is read by NAME out of the query string, so a rename that
/// reaches the string leaves a dial that boots fine and simply ignores the link.
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';
const { base: BASE, close: closeServer } = await serveBrowser();
const h=harness(); const browser=await launch(); const page=await browser.newPage();
const errs=[]; page.on('pageerror',e=>errs.push(String(e)));
const cur=()=>page.evaluate(()=>[...document.querySelectorAll('#prioritybar .pribar.current .priseg .pl')].map(n=>n.textContent.trim()));
await page.goto(`${BASE}/app.html?face=time&focus=nourishment`,{waitUntil:'networkidle'}); await sleep(1600);
const c = await cur();
h.rec('?focus=nourishment opens zoomed into that need',
      c.length>0 && !c.includes('nourishment'), c.join(' '));
const rows = await page.evaluate(()=>document.querySelectorAll('#prioritybar .pribar').length);
h.rec('and the stack shows the level above it', rows===2, `rows=${rows}`);
// the live toggle restores through the same handler a click would use
const live = await page.evaluate(()=>({checked:document.getElementById('live')?.checked}));
h.rec('the live toggle is on at boot', live.checked===true, JSON.stringify(live));

// ?doy= moves the viewed window to that day (gohere.openHereFromUrl); read it
// back off the same turnAnchor the date row names the window from.
const page2 = await browser.newPage(); page2.on('pageerror',e=>errs.push(String(e)));
const iso = new Date(Date.now()+3*86400000).toISOString().slice(0,10);
await page2.goto(`${BASE}/app.html?face=calendar&doy=${iso}`,{waitUntil:'networkidle'}); await sleep(1600);
const dl = await page2.evaluate(async (iso)=>{
  const { turnAnchor } = await import('./app/events.js');
  const { dateOf } = await import('./app/timefmt.js');
  return { viewed: dateOf(Math.floor(turnAnchor()/24)).toISOString().slice(0,10), want: iso };
}, iso);
h.rec('?doy=YYYY-MM-DD opens the calendar on that day', dl.viewed===dl.want, JSON.stringify(dl));

// ?ev= stands until ingest names the id, then selects it (resolveHere).
// A commitment is YOURS only with your AID on it (ingest keeps provider === me), so the
// page remembers an identity and the commitment names that same AID.
const AID = 'EDeepLinkAid000000000000000000000000000000';
const ev = await page2.evaluate(async (aid)=>{
  window.__seam.ingest({ commitments: [{ id:'c-dl-1', label:'deep-linked shift', provider: aid,
                                         sh:10, sm:0, eh:12, em:0 }] });
  await new Promise(r=>setTimeout(r,500));
  const { selectedEv } = await import('./app/ribbons.js');
  return { sel: selectedEv() && selectedEv().vfId };
}, AID);
h.rec('?ev=<vfId> selects the event once ingest names it — pending until then',
      ev.sel !== 'c-dl-1', 'no ?ev on this page: nothing selected — see next');
const page3 = await browser.newPage(); page3.on('pageerror',e=>errs.push(String(e)));
await page3.addInitScript(a => localStorage.setItem('pn.id.hint', a + '|Dee|dee@example.org|'), AID);
await page3.goto(`${BASE}/app.html?face=calendar&ev=c-dl-9`,{waitUntil:'networkidle'}); await sleep(1600);
const ev3 = await page3.evaluate(async (aid)=>{
  window.__seam.ingest({ commitments: [{ id:'c-dl-9', label:'deep-linked shift', provider: aid,
                                         sh:10, sm:0, eh:12, em:0 }] });
  await new Promise(r=>setTimeout(r,500));
  const { selectedEv } = await import('./app/ribbons.js');
  const { stage } = await import('./app/stage.js');
  return { sel: selectedEv() && selectedEv().vfId, face: stage.face };
}, AID);
h.rec('?ev resolves on ingest: the event is selected on the calendar',
      ev3.sel==='c-dl-9' && ev3.face==='cal', JSON.stringify(ev3));

h.rec('no page errors', errs.length===0, errs.slice(0,2).join(' | '));
await browser.close(); closeServer();
summarize(h);
