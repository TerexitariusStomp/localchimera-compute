/// tests/ux/bodies-ux.mjs — the legal bodies you steward: the account row opens
/// the page, the declaration reads as a sentence whose words are its pickers,
/// the steward picker lists the contact book, a body shows "1 of 2 signed",
/// a holding wears the law's status, the law's stance on the body reads in the
/// law face's words, its jurisdiction opens the law face on that place, and a
/// refusal from the commune lands as one hint. The seam is stubbed
/// (window.__seam.handlers), no gateway.
///
/// Run via: make test-bodies-ux
import { harness, launch, summarize, sleep, installSeamHook } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();
const h = harness();
const browser = await launch();
const page = await browser.newPage();
await installSeamHook(page);
const errs = [];
page.on('pageerror', e => errs.push(String(e)));
const shot = process.env.SHOT_DIR || '/tmp';
const vis = sel => page.evaluate(s => { const e = document.querySelector(s); if (!e) return false; const r = e.getBoundingClientRect(); return getComputedStyle(e).display !== 'none' && r.width > 0 && r.height > 0; }, sel);
// the account opens as a view of the sheet: the card is the root
const text = sel => page.evaluate(s => document.querySelector(s)?.textContent || '', sel);

const SCOPE = 'EScopeAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const BODY = { id: 'body:abc123', name: 'Le Four Commun', tags: ['body', 'kind:association', 'role:provider', 'jurisdiction:fr'],
               steward: true, jurisdiction: 'fr', holdings: [], exposure: {},
               ceremony: { have: 1, need: 2, published: null, what: 'inception' } };
const WHOLE = { ...BODY, stewards: ['EAliceAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'EBobAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'],
                members: [], crossings: ['organise'],
                holdings: [{ id: 'res:fr/rc-auto', spec: 'fr/rc-auto', name: 'RC auto', validUntil: '2025-01-01', status: 'expired' }],
                findings: [{ severity: 'warning', kind: 'selling', subject: 'body:abc123', detail: 'one body sells at the market' }],
                exposure: { stance: 'notice', doors: ['sell'], holds: [{ demand: 'RC auto', status: 'expired' }],
                            owes: ['Registrierung als Lebensmittelunternehmer'], forbidden: [], doubted: [] } };

// the stubbed commune: the seam's body handlers, and a scope to act in
const stub = async () => page.evaluate(async ({ SCOPE, BODY, WHOLE }) => {
  const { seam } = await import('/app/seam.js');
  const { scopesSig, scopeSig } = await import('/app/scope.js');
  scopesSig.set([{ id: SCOPE, name: 'Testhaven' }]);
  scopeSig.set(SCOPE);
  seam.scope = SCOPE;
  window.__bodyCalls = [];
  const log = (k, ...a) => window.__bodyCalls.push([k, ...a]);
  seam.handlers.bodiesRead = async (s) => { log('bodiesRead', s); return JSON.stringify([BODY]); };
  seam.handlers.bodyRead = async (id) => { log('bodyRead', id); return JSON.stringify(WHOLE); };
  seam.handlers.bodyDeclare = async (s, j) => { log('bodyDeclare', s, j); return 'ok:' + JSON.stringify({ id: 'body:new', name: JSON.parse(j).name, tags: [] }); };
  seam.handlers.bodyAddSteward = async (id, aid) => { log('bodyAddSteward', id, aid); return 'ok'; };
  seam.handlers.bodyOpenCeremony = async (id, k) => { log('bodyOpenCeremony', id, k); return 'ok:' + JSON.stringify({ have: 0, need: k, published: null, what: 'inception' }); };
  seam.handlers.bodySign = async (id, what) => { log('bodySign', id, what); return 'err:the signature is not yours'; };
  seam.handlers.bodyHold = async (id, j) => { log('bodyHold', id, j); return 'ok:res:x'; };
  seam.handlers.bodyAdmit = async (s, id) => { log('bodyAdmit', s, id); return 'err:a body is admitted by a governor'; };
  const { readBodies } = await import('/app/bodies.js');
  await readBodies();
}, { SCOPE, BODY, WHOLE });

for (const [label, vp] of [['desktop', { width: 1400, height: 900 }], ['phone', { width: 390, height: 800 }]]) {
  try {
    await page.setViewportSize(vp);
    await page.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
    await sleep(1800);
    await stub();
    await sleep(200);

    // the account sheet carries the row, and the row opens the page
    // the scope set raises the capability notice over the header: the button is pressed from the page itself
    await page.evaluate(() => document.querySelector('#idrow .who').click()); await sleep(400);
    const rows = await page.$$eval('.acct-card .acct-row .acct-l', ls => ls.map(l => l.textContent));
    h.rec(`${label}: the account sheet has a "legal bodies" row`, rows.includes('legal bodies'), rows.join(' | '));
    await page.evaluate(() => [...document.querySelectorAll('.acct-card .acct-row')].find(r => r.querySelector('.acct-l')?.textContent === 'legal bodies').click());
    await sleep(500);
    h.rec(`${label}: the row opens the bodies view`, await vis('.acct-card .bodies'));
    await page.screenshot({ path: `${shot}/bodies-${label}.png` });

    // the declaration reads as a sentence; its words are pickers
    const say = await text('.acct-card .bodies .bd-say');
    // the jurisdiction reads by the law snapshot's name once it is in, by its code until then
    h.rec(`${label}: the declaration is a sentence`, /Declare .*a association acting as provider in (France|fr), assets locked, register inspectable/.test(say.replace(/\s+/g, ' ')), say);
    await page.evaluate(() => [...document.querySelectorAll('.acct-card .bodies .bd-say .ld-tok')].find(t => t.textContent === 'association').click());
    await sleep(150);
    const kinds = await page.$$eval('.acct-card .bodies .sl-presets .sl-chip', cs => cs.map(c => c.textContent));
    h.rec(`${label}: the kind word opens its chips`, kinds.includes('cooperative') && kinds.includes('operator'), kinds.join(' '));
    await page.evaluate(() => [...document.querySelectorAll('.acct-card .bodies .sl-chip')].find(c => c.textContent === 'cooperative').click());
    await sleep(150);
    h.rec(`${label}: a chip picked rewrites the sentence`, /a cooperative acting/.test((await text('.acct-card .bodies .bd-say')).replace(/\s+/g, ' ')));
    const kept = await page.evaluate(() => { try { return JSON.parse(localStorage.getItem('pn.bodies.draft') || 'null')?.kind; } catch (_) { return null; } });
    h.rec(`${label}: the draft is kept on this device`, kept === 'cooperative', String(kept));

    // the steward picker is the contact book
    await page.evaluate(() => [...document.querySelectorAll('.acct-card .bodies .bd-say .ld-tok')].find(t => t.textContent === 'you alone').click());
    await sleep(200);
    const people = await page.$$eval('.acct-card .bodies .ld-who .sl-chip', cs => cs.map(c => c.textContent));
    h.rec(`${label}: the steward picker lists the book`, people.length > 2 && people.some(p => /anyone/.test(p)), people.slice(0, 5).join(' | '));

    // the body read from the commune: 1 of 2 signed
    const row = (await text('.acct-card .bodies .bd-list')).replace(/\s+/g, ' ');
    h.rec(`${label}: the body reads "1 of 2 signed"`, /Le Four Commun/.test(row) && /1 of 2 signed/.test(row), row);
    await page.evaluate(() => document.querySelector('.acct-card .bodies .bd-row .slot-btn').click());
    await sleep(300);
    h.rec(`${label}: open reads the body whole`, await vis('.acct-card .bodies .bd-body') && /1 of 2 signed/.test(await text('.acct-card .bodies .bd-signed')));
    const stewards = await page.$$eval('.acct-card .bodies .bd-stewards .reach-row', ls => ls.length);
    h.rec(`${label}: both stewards are listed`, stewards >= 2, String(stewards));
    const status = await text('.acct-card .bodies .bd-holding .bd-status');
    h.rec(`${label}: the holding wears the law's status: expired`, status === 'expired', status);
    const law = (await text('.acct-card .bodies .bd-law')).replace(/\s+/g, ' ');
    h.rec(`${label}: the law's stance on the body reads in the law face's words, with what it owes`,
          (await text('.acct-card .bodies .bd-law .bd-stance')) === 'notice' && /owes Registrierung/.test(law), law);
    h.rec(`${label}: the admission finding shows`, /selling/.test(await text('.acct-card .bodies .bd-findings')));

    // a refusal lands as one hint
    await page.evaluate(() => document.querySelector('#toasts')?.replaceChildren());
    await page.evaluate(() => [...document.querySelectorAll('.acct-card .bodies .bd-ceremony .slot-btn')].find(b => b.textContent === 'sign').click());
    await sleep(500);
    const toasts = await page.$$eval('#toasts .toast:not(.out) .toast-msg', ms => ms.map(m => m.textContent));
    h.rec(`${label}: the commune's refusal is one hint, in its words`, toasts.length === 1 && toasts[0] === 'the signature is not yours', toasts.join(' | '));
    const calls = await page.evaluate(() => window.__bodyCalls.map(c => c[0]));
    h.rec(`${label}: the sign handler was asked once, the body read again after the act was not (it was refused)`, calls.filter(c => c === 'bodySign').length === 1, calls.join(','));

    await page.keyboard.press('Escape'); await sleep(300);
    await page.evaluate(() => localStorage.clear());
  } catch (e) { h.rec(`${label}: fatal`, false, e.message); }
}

// the face: ?face=bodies mounts the same block on the stage
try {
  await page.goto(`${BASE}/app.html?face=bodies`, { waitUntil: 'domcontentloaded' });
  await sleep(1800);
  h.rec('?face=bodies mounts the bodies face', await vis('#bodiesface .bodies .bd-say'));
  // the jurisdiction picker offers the snapshot's places by name
  await stub(); await sleep(200);
  await page.evaluate(() => [...document.querySelectorAll('#bodiesface .bodies .bd-say .ld-tok')].find(t => /France|^fr$/.test(t.textContent)).click());
  await sleep(150);
  const places = await page.$$eval('#bodiesface .bodies .bd-juris .sl-chip', cs => cs.map(c => c.textContent));
  h.rec('the jurisdiction picker lists the law snapshot\'s nations and regions by name', places.includes('Germany') && places.includes('California'), places.slice(0, 8).join(' | '));
  // a body's jurisdiction is a link into the law face, on that place
  await page.evaluate(() => document.querySelector('#bodiesface .bodies .bd-row .slot-btn').click());
  await sleep(300);
  const juris = await text('#bodiesface .bodies .bd-head a.bd-juris');
  h.rec('the body\'s jurisdiction is named as the law face names it', juris === 'France', juris);
  await page.evaluate(() => document.querySelector('#bodiesface .bodies .bd-head a.bd-juris').click());
  await page.waitForSelector('#lawdocket .dk-head h4', { timeout: 8000 }); await sleep(600);
  const landed = await page.evaluate(() => ({ face: document.getElementById('main')?.dataset.face,
    title: document.querySelector('#lawdocket .dk-head h4')?.textContent, bodies: !!document.querySelector('#bodiesface.on') }));
  h.rec('the jurisdiction link opens the law face on that place', landed.face === 'law' && landed.title === 'France' && !landed.bodies, JSON.stringify(landed));
} catch (e) { h.rec('face: fatal', false, e.message); }

h.rec('no page errors', errs.length === 0, errs.slice(0, 2).join(' | '));
await browser.close(); closeServer();
summarize(h);
