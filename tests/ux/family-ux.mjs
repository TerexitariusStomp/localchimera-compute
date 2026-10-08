/// tests/ux/family-ux.mjs — the FAMILY face: a household purse split across
/// its members' needs by harmony (tabs/family.js). Standalone/demo mode (no
/// gateway): the default ledger shows the split the planner test measured
/// (tests/family-money-harmony-test.scm), so the face's reading of it is
/// checked against the same numbers —
///
///   the ledger      twenty needs over four people and the household, each
///                   with a kind (right / need / want) and a level 0–9
///   the split       spent = purse + Pfand income to the euro; medicine met,
///                   the videogame sacrificed; per-person bars
///   the toggle      uniform weights spread the cut differently (groceries,
///                   the bulky want, sinks); ample purse meets everyone
///   the edit        an edited ledger offline says the commons must solve it;
///                   a stubbed gateway handler is called with the rows as JSON
///   the voice       undeclared members reach the wire as an empty list (the
///                   flat voice every split always used); the consumer-voice
///                   panel's capacity/hours inputs reach it as a real member
///
/// The device solve (last section, a page of its own): with no session and
/// family.wasm built, an edited ledger is solved ON THE DEVICE — the answer
/// draws, and the commons' handler is never called (the ledger stays here).
/// Every section before it runs `?solve=commons`, the door the stubs reach.
///
/// Run via: make test-family-ux
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();
const h = harness();
const browser = await launch();
const page = await browser.newPage();
page.on('pageerror', e => h.errs.push(String(e).slice(0, 160)));

const bars = () => page.evaluate(() =>
  [...document.querySelectorAll('#familystage .fm-need')].map(n => ({
    label: [...n.querySelector('.fm-nlbl').childNodes].filter(c => c.nodeType === 3).map(c => c.textContent.trim()).join('').split(' ')[0],
    pct: parseInt(n.querySelector('.fm-npct').textContent, 10),
  })));
const sumText = () => page.evaluate(() => (document.querySelector('#familystage .fm-sum') || {}).textContent || '');
const setInput = (sel, v) => page.evaluate(([s, val]) => {
  const el = document.querySelector(s); el.value = val; el.dispatchEvent(new Event('change', { bubbles: true })); }, [sel, v]);
const click = sel => page.evaluate(s => { document.querySelector(s).dispatchEvent(new MouseEvent('click', { bubbles: true })); }, sel);

try {
  await page.goto(`${BASE}/app.html?face=family&solve=commons`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#familyface.on', { timeout: 30000 });
  await page.waitForSelector('#familystage .fm-need', { timeout: 30000 });
  h.rec('?face=family deep link lands on the family face', true);

  const rows = await page.evaluate(() => document.querySelectorAll('#familystage .fm-table tbody tr').length);
  h.rec('the ledger lists the twenty stated needs', rows === 20, `rows=${rows}`);
  const kinds = await page.evaluate(() => [...document.querySelectorAll('#familystage .fm-kind')].map(k => k.value));
  h.rec('every row carries a kind (right / need / want)', kinds.length === 20 && kinds.includes('floor') && kinds.includes('held') && kinds.includes('des'));

  // ── the measured weighted split at €250 ──────────────────────────────────
  let b = await bars(); let s = await sumText();
  const by = name => (b.find(x => x.label === name) || {}).pct;
  h.rec('spent reads purse + Pfand income to the euro (€253.00)', /spent\s*€253\.00/.test(s), s.slice(0, 80));
  h.rec('the rights are whole: groceries and medicine 100%', by('groceries') === 100 && by('medicine') === 100, `${by('groceries')},${by('medicine')}`);
  // a property, not a pin: the held needs sit strictly inside (0, 100) — the
  // exact fractions move whenever the ledger's masses do (family-masses)
  h.rec('the needs are short but never zero (shoes, physio strictly between 0 and 100%)',
        by('shoes') > 0 && by('shoes') < 100 && by('physio') > 0 && by('physio') < 100, `${by('shoes')},${by('physio')}`);
  h.rec('every want is set aside (videogame, concert 0%)', by('videogame') === 0 && by('concert') === 0);
  const people = await page.evaluate(() => [...document.querySelectorAll('#familystage .fm-pname')].map(n => n.textContent.trim().split(' ')[0]));
  h.rec('one bar per member and the household, household first', people[0] === 'all' && people.length === 5, people.join(','));

  // ── the rights themselves: a governance object apart from the ledger ─────
  // groceries's floor is on nutrition, not the good itself (family.scm's
  // need-substance); medicine names none, so it reduces to itself.
  const rightRows = () => page.evaluate(() =>
    [...document.querySelectorAll('#familystage .fm-rights-rows > span')].map(n => n.textContent.trim()));
  const rr = await rightRows();
  h.rec('the rights panel lists nutrition (fed by groceries) and medicine (fed by itself)',
        rr.includes('nutrition') && rr.includes('medicine') && rr.some(t => /fed by groceries/.test(t)) && rr.some(t => /fed by medicine.*no substitute/.test(t)),
        JSON.stringify(rr));
  h.rec("nutrition's floor reads the ledger's own quantity (7)", rr.some(t => /^7/.test(t)), JSON.stringify(rr));
  // the split's own "short by €X" repeats the bills panel's wants-tier figure
  // exactly here (both net the same purse+Pfand against the same total ask),
  // so the split panel says nothing about it at all — "what the week would
  // take" is the one place it lives.
  h.rec('a repeating short is not restated here — only in what the week would take',
        !/short/.test(s) && !/rights whole, needs never zero/.test(s), s.slice(0, 80));

  // ── the week asked backwards: three bills, offline the ledger's own arithmetic ──
  // €250 purse + €3 weekly Pfand (WEEKLY_PFAND_EUR — the one income a real
  // solve always finds worth collecting, netted the same way "short by"
  // already does) covers the rights (€114); rights+needs ask €363, so €110
  // more; all three ask €609.50, so €356.50 more — each tier held whole, the
  // softer set aside.
  const billRows = () => page.evaluate(() =>
    [...document.querySelectorAll('#familystage .fm-bills-rows')].flatMap(g => {
      const c = [...g.children].map(x => x.textContent.trim());
      const out = []; for (let i = 0; i + 3 < c.length; i += 4) out.push({ tier: c[i], eur: c[i + 1], hours: c[i + 2], step: c[i + 3] });
      return out;
    }));
  let br = await billRows();
  h.rec('the bills panel lists the three tiers in order', br.length === 3 && /rights/.test(br[0].tier) && /needs/.test(br[1].tier) && /wants/.test(br[2].tier), JSON.stringify(br.map(r => r.tier)));
  h.rec('at €250 the rights are whole on this purse', /whole/.test(br[0].eur), br[0].eur);
  h.rec('…the needs tier asks €110.00 more', /€110\.00 more/.test(br[1].eur), br[1].eur);
  h.rec('…and the wants tier €356.50 more, a €246.50 step over the needs', /€356\.50 more/.test(br[2].eur) && /\+€246\.50/.test(br[2].step), `${br[2].eur} ${br[2].step}`);
  const billNote = await page.evaluate(() => (document.querySelector('#familystage .fm-bills .fm-note') || {}).textContent || '');
  h.rec('offline the panel says the bills are the ledger\'s own arithmetic', /offline/.test(billNote), billNote);

  // ── uniform weights ──────────────────────────────────────────────────────
  await setInput('#familystage .fm-row label input', '400');
  await click('#familystage .fm-tog input'); await click('#familystage .fm-go'); await sleep(150);
  b = await bars();
  h.rec('uniform, €400: the quietest want (videogame) now gets something (> 10%)', by('videogame') > 10, `videogame=${by('videogame')}`);
  h.rec('uniform, €400: the rights still whole', by('groceries') === 100 && by('medicine') === 100);

  // ── below the floors ─────────────────────────────────────────────────────
  await click('#familystage .fm-tog input'); await setInput('#familystage .fm-row label input', '100');
  await click('#familystage .fm-go'); await sleep(150);
  s = await sumText();
  h.rec('a purse below the rights has no plan, and says so', /no plan/.test(s) && /€114\.00/.test(s), s.slice(0, 90));

  // ── an ample purse ───────────────────────────────────────────────────────
  await setInput('#familystage .fm-row label input', '1000'); await click('#familystage .fm-go'); await sleep(150);
  b = await bars(); s = await sumText();
  h.rec('an ample purse meets everyone', b.every(x => x.pct === 100) && /everyone met/.test(s), s.slice(0, 60));

  // ── an edited ledger, offline ────────────────────────────────────────────
  await setInput('#familystage .fm-table tbody tr:nth-child(1) .fm-num', '13'); await click('#familystage .fm-go'); await sleep(150);
  const note = await page.evaluate(() => (document.querySelector('#familystage .fm-note') || {}).textContent || '');
  // The family solve runs ON THE DEVICE now (family-local.ts), so an edited ledger with no
  // gateway is answered here and the note says whose arithmetic it is — it is no longer
  // refused for want of a live solve.
  h.rec('an edited ledger offline is answered on the device, and says so', /own arithmetic\s*—\s*offline/.test(note), note);

  // ── a stubbed gateway: the handler gets the rows (kind included) and its reply draws ──
  const got = await page.evaluate(async () => {
    const { HANDLERS } = await import('/app/core.js');
    return new Promise(res => {
      HANDLERS.familySplit = (needsJson, purse, labourH, weighted, membersJson, perCitizenHours, reply) => {
        const ns = JSON.parse(needsJson);
        reply(JSON.stringify({ feasible: "yes", floors: 0, needs: ns.map((n, i) => ({ ...n, got: i === 0 ? n.want : 0, met: i === 0 ? 1 : 0 })),
                               spent: ns[0].cost * ns[0].want, purse, income: 0, pfandTrips: 0, labourH }));
        res({ n: ns.length, purse, weighted, firstCost: ns[0].cost, firstKind: ns[0].kind, members: JSON.parse(membersJson), perCitizenHours });
      };
      document.querySelector('#familystage .fm-go').dispatchEvent(new MouseEvent('click', { bubbles: true }));
    });
  });
  await sleep(150);
  b = await bars();
  h.rec('the gateway handler receives the edited rows, kinds and the purse', got.n === 20 && got.firstCost === 13 && got.firstKind === 'floor' && got.purse === 1000 && got.weighted === true, JSON.stringify(got));
  h.rec("the gateway's reply draws — only the first need met", by('groceries') === 100 && by('medicine') === 0);
  h.rec('the handler also receives MEMBERS (empty, undeclared) and a full week in hours',
        Array.isArray(got.members) && got.members.length === 0 && got.perCitizenHours > 0, JSON.stringify(got));

  // ── the consumer-voice panel: declaring a member's capacity + hours reaches the wire ──
  await setInput('#familystage .fm-voice-row[data-p="1"] input[data-field="capacity"]', '20');
  await setInput('#familystage .fm-voice-row[data-p="1"] input[data-field="hours"]', '5');
  const gotVoice = await page.evaluate(async () => {
    const { HANDLERS } = await import('/app/core.js');
    return new Promise(res => {
      HANDLERS.familySplit = (needsJson, purse, labourH, weighted, membersJson, perCitizenHours, reply) => {
        res({ members: JSON.parse(membersJson) });
        reply('err:stub');
      };
      document.querySelector('#familystage .fm-go').dispatchEvent(new MouseEvent('click', { bubbles: true }));
    });
  });
  const alice = (gotVoice.members || []).find(m => m.person === 'alice');
  h.rec("declaring alice's capacity 20% and 5 hours reaches the split call",
        !!alice && Math.abs(alice.capacity - 0.2) < 1e-6 && alice.hours === 5, JSON.stringify(gotVoice));

  // ── a stubbed bills gateway: its reply draws, and an infeasible tier names the wall ──
  const gotBills = await page.evaluate(async () => {
    const { HANDLERS } = await import('/app/core.js');
    return new Promise(res => {
      HANDLERS.familyBills = (needsJson, purse, labourH, weighted, eurPerHour, membersJson, perCitizenHours, reply) => {
        reply(JSON.stringify({ tiers: [ { tier: "rights", eur: "0", hours: "0", stepEur: "0", stepHours: "0", feasible: "yes" },
                                        { tier: "needs", eur: "12.5", hours: "3", stepEur: "12.5", stepHours: "3", feasible: "yes" },
                                        { tier: "wants", eur: "0", hours: "0", stepEur: "0", stepHours: "0", feasible: "no" } ],
                               eurPerHour, residueEur: "1.5", residueHours: "0.2" }));
        res({ n: JSON.parse(needsJson).length, purse, eurPerHour });
      };
      document.querySelector('#familystage .fm-go').dispatchEvent(new MouseEvent('click', { bubbles: true }));
    });
  });
  await sleep(150);
  br = await billRows();
  h.rec('the bills handler receives the rows, the purse and the euro price in hours', gotBills.n === 20 && gotBills.purse === 1000 && gotBills.eurPerHour === 15, JSON.stringify(gotBills));
  h.rec("the gateway's bills draw — needs €12.50 and 3.0 h more, wants a wall nothing sells",
        /€12\.50 more/.test(br[1].eur) && /3\.0 h more/.test(br[1].hours) && /no plan/.test(br[2].eur), JSON.stringify(br));
  const billNote2 = await page.evaluate(() => (document.querySelector('#familystage .fm-bills .fm-note') || {}).textContent || '');
  h.rec('…and the residue is stated beside the bills', /€1\.50/.test(billNote2) && /0\.2 h/.test(billNote2), billNote2);

  // ── the device solve: no ?solve=commons, no session — the ledger is solved where it lives ──
  const dev = await browser.newPage();
  dev.on('pageerror', e => h.errs.push(String(e).slice(0, 160)));
  await dev.goto(`${BASE}/app.html?face=family`, { waitUntil: 'domcontentloaded' });
  await dev.waitForSelector('#familystage .fm-need', { timeout: 30000 });
  await dev.evaluate(async () => {
    const { HANDLERS } = await import('/app/core.js');
    window.__commonsAsked = 0;
    HANDLERS.familySplit = (...a) => { window.__commonsAsked++; a[a.length - 1]('err:stub'); };
    HANDLERS.familyBills = (...a) => { window.__commonsAsked++; a[a.length - 1]('err:stub'); };
    const el = document.querySelector('#familystage .fm-table tbody tr:nth-child(1) .fm-num');
    el.value = '13'; el.dispatchEvent(new Event('change', { bubbles: true }));       // an edited ledger: the table cannot answer it
    document.querySelector('#familystage .fm-go').dispatchEvent(new MouseEvent('click', { bubbles: true }));
  });
  // the solve is a few hundred milliseconds of wasm in a worker; wait for the face to stop saying it is splitting
  await dev.waitForFunction(() => { const g = document.querySelector('#familystage .fm-go'); return g && !g.classList.contains('busy') && document.querySelector('#familystage .fm-need'); }, { timeout: 120000 });
  const devSum = await dev.evaluate(() => (document.querySelector('#familystage .fm-sum') || {}).textContent || '');
  const devNote = await dev.evaluate(() => (document.querySelector('#familystage .fm-note') || {}).textContent || '');
  const devBars = await dev.evaluate(() => [...document.querySelectorAll('#familystage .fm-need')].map(n => parseInt(n.querySelector('.fm-npct').textContent, 10)));
  const commonsAsked = await dev.evaluate(() => window.__commonsAsked);
  h.rec('an edited ledger with no session is solved on the device — a plan draws, no offline note',
        /spent/.test(devSum) && devBars.length === 20 && devBars.some(p => p === 100) && !/offline|commons/.test(devNote), `${devSum.slice(0, 60)} | ${devNote}`);
  h.rec('…and the commons was never asked: the ledger stayed on the device', commonsAsked === 0, `asked ${commonsAsked}×`);
} finally {
  await browser.close();
  closeServer();
}

summarize(h, ['?face=family deep link lands on the family face',
              'the ledger lists the twenty stated needs',
              'spent reads purse + Pfand income to the euro (€253.00)',
              'the rights are whole: groceries and medicine 100%',
              'the needs are short but never zero (shoes, physio strictly between 0 and 100%)',
              'a purse below the rights has no plan, and says so',
              'an ample purse meets everyone',
              'the gateway handler receives the edited rows, kinds and the purse',
              'at €250 the rights are whole on this purse',
              "the gateway's bills draw — needs €12.50 and 3.0 h more, wants a wall nothing sells",
              'an edited ledger with no session is solved on the device — a plan draws, no offline note',
              '…and the commons was never asked: the ledger stayed on the device']);
