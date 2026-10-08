/// tests/ux/faces-ux.mjs — the face registry (app/faces.js). A face OWNS the
/// stage, and the table there says what each one owns; this drives every route
/// into it, because the routes are the part a reader can break silently. Covers
/// ?face=<f> for each face, the older hashes that alias onto one (#matter,
/// #fragility, #calendar, #ecology), the landing with nothing named (the walk for a device
/// that remembers no identity, the home face for one that does),
/// and ?face=share opening the drawer WITHOUT taking the stage — share is
/// layout chrome, not a face.
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';
const { base: BASE, close: closeServer } = await serveBrowser();
const h=harness(); const browser=await launch(); const page=await browser.newPage();
const errs=[]; page.on('pageerror',e=>errs.push(String(e)));
const live=()=>page.evaluate(()=>{const b=[...document.querySelectorAll('[id^=face-]')].find(n=>n.classList.contains('on'));
  return {nav:b?b.id.replace('face-',''):null, data:document.getElementById('main').getAttribute('data-face')};});
const CASES=[['?face=time','time'],['?face=rift','rift'],['?face=law','law'],['?face=frag','frag'],
  ['?face=cal','cal'],['?face=forum','forum'],['?face=shop','shop'],['?face=plan','plan'],
  ['?face=map','map'],['#matter','rift'],['#fragility','frag'],['#calendar','cal'],
  ['#ecology','eco'],['#taxonomy','taxonomy'],['?face=family','family'],['?face=store','store'],['?face=corpus','corpus'],
  // nothing named, and this device remembers no identity: the walk is the door (landingFace)
  ['','onboard']];
let i = 0;
for (const [q,want] of CASES) {
  // a cache-busting param so a hash-only change still RELOADS the document
  const url = q.startsWith('#') ? `${BASE}/app.html?_=${i++}${q}`
            : q ? `${BASE}/app.html${q}&_=${i++}` : `${BASE}/app.html?_=${i++}`;
  await page.goto(url,{waitUntil:'networkidle'});
  await sleep(1100);
  const s = await live();
  h.rec(`${q||'(no route)'} → ${want}`, s.data===want, JSON.stringify(s));
}
// …and a device that REMEMBERS an identity lands on the home face from settings (cal by default)
{
  const remembered = await browser.newPage();
  await remembered.addInitScript(() => localStorage.setItem('pn.id.hint', 'EAnaAid0000000000000000000000000000000000000|Ana|ana@example.org|'));
  await remembered.goto(`${BASE}/app.html?_=home`, { waitUntil: 'networkidle' }); await sleep(1100);
  const home = await remembered.evaluate(() => document.getElementById('main').getAttribute('data-face'));
  h.rec('(no route, identity remembered) → the home face', home === 'cal', String(home));
  await remembered.close();
}
// share is chrome: it opens the drawer and leaves the face alone
await page.goto(`${BASE}/app.html?face=share`,{waitUntil:'networkidle'}); await sleep(1100);
const sh = await page.evaluate(()=>({face:document.getElementById('main').getAttribute('data-face'),
  bar:document.getElementById('sharebar')?.className||null}));
h.rec('?face=share opens the drawer and leaves the stage alone',
      sh.face === null && /sb-open/.test(sh.bar || ''), JSON.stringify(sh));
h.rec('no page errors', errs.length===0, errs.slice(0,3).join(' | '));
await browser.close(); closeServer(); summarize(h);
