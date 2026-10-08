/// tests/ux/forum-ux.mjs — the FORUM face: governance read as threads
/// (tabs/governance.js). The gateway is stubbed at the HANDLERS seam, so
/// what is checked is the face's reading of the wire and the acts it sends:
///
///   the stage     ?face=forum lands on the #forumface overlay, the rail shut
///   open          every open proposal is a row titled by its QUESTION (the
///                 wire's text), chipped by class and domain; the UC merge
///                 sits among them
///   a thread      opens with the tally, the weight of your voice for that
///                 class, the stances, and the discussion off the chat rail
///   a post        goes out on the thread's scoped topic and comes back
///   a cast        reaches the handler with the id and stance
///   decided       the closed ballot keeps its question and shows its verdict
///   voice         your two voices, the flow bar, a revoke, a delegation
///   compose       the governor's form opens a ballot with the domain chosen
///
/// Run via: make test-forum-ux
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();
const h = harness();
const browser = await launch();
const page = await browser.newPage();
page.on('pageerror', e => h.errs.push(String(e).slice(0, 160)));

const text = sel => page.evaluate(s => (document.querySelector(s) || {}).textContent || '', sel);
const count = sel => page.evaluate(s => document.querySelectorAll(s).length, sel);
const click = sel => page.evaluate(s => { document.querySelector(s).dispatchEvent(new MouseEvent('click', { bubbles: true })); }, sel);
const setVal = (sel, v) => page.evaluate(([s, val]) => { document.querySelector(s).value = val; }, [sel, v]);
const calls = () => page.evaluate(() => window.__forumCalls);

try {
  await page.goto(`${BASE}/app.html?face=forum`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#forumface.on', { timeout: 30000 });
  h.rec('?face=forum deep link lands on the forum overlay', true);
  const panelShown = await page.evaluate(() => {
    const p = document.querySelector('#panel'); if (!p) return false;
    const r = p.getBoundingClientRect(); return r.width > 40 && getComputedStyle(p).visibility !== 'hidden' && getComputedStyle(p).display !== 'none';
  });
  h.rec('the sidebar is shut — the forum stands on the stage alone', !panelShown);
  await page.waitForSelector('#forumstage .fo-row', { timeout: 30000 });
  h.rec('with no gateway the forum reads the demo docket, and says so',
        await count('#forumstage .fo-row') >= 4 && /demo docket/.test(await text('#forumstage .fo-sub')));
  h.rec('a demo thread is born from a demo object — its row names the subject',
        await count('#forumstage .fo-rowsubj') >= 3);
  await page.evaluate(() => [...document.querySelectorAll('#forumstage .fo-row')].find(r => /Adopt the sourdough/.test(r.textContent)).dispatchEvent(new MouseEvent('click', { bubbles: true })));
  await sleep(80);
  h.rec('the sourdough thread shows the recipe itself — its steps and flows',
        await count('#forumstage .fo-subjcard .fo-steps li') >= 1 && await count('#forumstage .fo-flowchip') >= 2);
  h.rec('and the demo discussion under it', await count('#forumstage .fo-msg') === 4);
  await click('#forumstage .fo-back'); await sleep(40);
  await click('#forumstage .seg-voice'); await sleep(60);
  h.rec('the voice map lays out franchise × class with a cell per commune',
        await count('#forumstage .fo-map .fo-maphead') >= 4 && await count('#forumstage .fo-map .fo-cell') >= 6);
  h.rec('a per-scope delegation shows in its commune\'s cell alone',
        (await page.evaluate(() => [...document.querySelectorAll('#forumstage .fo-map .fo-cellnote')].map(n => n.textContent).join('|'))).includes('Luca'));
  h.rec('the topics strip covers every domain', await count('#forumstage .fo-topic') === 6);
  await page.evaluate(() => [...document.querySelectorAll('#forumstage .fo-topic')].find(t => /recipes/.test(t.textContent)).dispatchEvent(new MouseEvent('click', { bubbles: true })));
  await sleep(60);
  h.rec('a topic tile narrows the list to that domain, with a way back',
        await count('#forumstage .fo-row') === 1 && /recipes/.test(await text('#forumstage .fo-filter')) && await count('#forumstage .fo-filter-x') === 1);
  await click('#forumstage .fo-filter-x'); await sleep(40);
  h.rec('every topic again', await count('#forumstage .fo-row') >= 4);
  await click('#forumstage .seg-open'); await sleep(40);

  // ── a stubbed gateway at the seam, then a forced refresh ─────────────────
  await page.evaluate(async () => {
    const { HANDLERS } = await import('/app/core.js');
    const { seam: __seam } = await import('/app/seam.js');
    const { scopesSig } = await import('/app/scope.js');
    scopesSig.set([{ id: 'EScopeAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', name: 'Testhaven' }]);
    __seam.scope = 'EScopeAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    window.__forumCalls = [];
    const log = (k, ...a) => window.__forumCalls.push([k, ...a]);
    const props = {
      'p-recipe-1': { state: 'open', kind: 'ballot', domain: 'recipe', text: 'Bake the commune bread in the wood oven?', franchise: 'federation', subject: 'recipe:rp-sourdough', openedAt: Math.floor(Date.now() / 1000) - 3 * 86400, tally: { yes: 3, no: 1 } },
      'p-policy-2': { state: 'open', kind: 'ballot', domain: 'policy', text: 'Open the tool library to the neighbouring commune?', franchise: 'federation', tally: {} },
      'p-plan-3':   { state: 'closed', kind: 'ballot', domain: 'plan', text: 'Accept the winter plan?', franchise: 'federation', tally: { yes: 5, no: 2 } },
    };
    const msgs = {};
    HANDLERS.listProposals = async () => JSON.stringify(Object.entries(props).map(([id, p]) => ({ id, status: p.state === 'closed' ? 'closed' : 'open' })));
    HANDLERS.getResult = async id => JSON.stringify(props[id] || { state: 'error' });
    HANDLERS.listUcProposals = async () => JSON.stringify([{ a: 'EAAAAAAAAAAAAAAAAAAAAAAAAAAA', b: 'EBBBBBBBBBBBBBBBBBBBBBBBBBBB' }]);
    HANDLERS.myVoice = async () => JSON.stringify({ producer: 0.25, consumer: 0.1 });
    HANDLERS.listDelegations = async () => JSON.stringify([{ to: 'EDelegateXXXXXXXXXXXXXXXXXXXXX', fraction: 0.4, mandated: true }]);
    HANDLERS.cast = async (id, stance) => { log('cast', id, stance); props[id].tally[stance] = (props[id].tally[stance] || 0) + 1; return 'ok'; };
    HANDLERS.close = async id => { log('close', id); return 'ok'; };
    HANDLERS.openProposal = async (kind, domain, id, t, fr, subject) => { log('open', kind, domain, id, t, fr, subject); props[id] = { state: 'open', kind, domain, text: t, franchise: fr, subject, tally: {} }; return 'ok'; };
    HANDLERS.voiceIn = async sid => { log('voiceIn', sid); return JSON.stringify({ producer: 0.25 }); };
    HANDLERS.setDelegation = async (to, f) => { log('delegate', to, f); return 'ok'; };
    HANDLERS.revokeDelegation = async to => { log('revoke', to); return 'ok'; };
    HANDLERS.chat = async (op, topic, body) => {
      log('chat', op, topic, body);
      if (op === 'post') { (msgs[topic] ||= []).push({ id: 'm' + Date.now(), author: 'EMe', stratum: 'public', body }); return 'ok:public'; }
      return JSON.stringify(msgs[topic] || []);
    };
    const { refreshGovernance } = await import('/app/tabs/governance.js');
    await refreshGovernance(true);
  });
  await sleep(100);

  // ── open ─────────────────────────────────────────────────────────────────
  h.rec('the rail offers open · decided · voice', await count('#forumstage .fo-seg') === 3);
  const rows = await count('#forumstage .fo-row');
  h.rec('open lists the two open threads and the UC merge', rows === 3, `rows=${rows}`);
  const titles = await page.evaluate(() => [...document.querySelectorAll('#forumstage .fo-rowtitle')].map(n => n.textContent.trim()));
  h.rec('a row is titled by the question, in the proposer\'s words', titles.includes('Bake the commune bread in the wood oven?') && titles.includes('Open the tool library to the neighbouring commune?'), titles.join(' | '));
  const chips = await page.evaluate(() => [...document.querySelectorAll('#forumstage .fo-row .fo-chip')].map(n => n.textContent.trim()));
  h.rec('every row is chipped by its class', chips.filter(c => c === 'production').length === 2 && chips.filter(c => c === 'consumption').length === 1, chips.join(','));
  h.rec('the open count sits on its tab', /3/.test(await text('#forumstage .seg-open')));
  h.rec('the head names the commune and offers a new proposal', /Testhaven/.test(await text('#forumstage .fo-scope')) && await count('#forumstage .fo-new') === 1);

  // ── a thread ─────────────────────────────────────────────────────────────
  await page.evaluate(() => [...document.querySelectorAll('#forumstage .fo-row')].find(r => /wood oven/.test(r.textContent)).dispatchEvent(new MouseEvent('click', { bubbles: true })));
  await sleep(120);
  h.rec('the thread opens on its question', /wood oven/.test(await text('#forumstage .fo-q')));
  h.rec('a live thread resolves its subject from the wire field and shows the recipe', await count('#forumstage .fo-subjcard .fo-steps li') >= 1);
  h.rec('a live thread reads its age off the registry clock', /3 days ago/.test(await text('#forumstage .fo-meta')), await text('#forumstage .fo-meta'));
  const vi = (await calls()).find(c => c[0] === 'voiceIn');
  h.rec('the voice map asked each commune for your producer voice there', !!vi && /^EScope/.test(vi[1]));
  h.rec('the weight says why: producer voice, 25% of the scope\'s labour', /producer voice.*25%/.test(await text('#forumstage .fo-weightrow')), await text('#forumstage .fo-weightrow'));
  h.rec('the tally reads yes 75% · no 25%', /yes 75%/.test(await text('#forumstage .fo-legend')) && /no 25%/.test(await text('#forumstage .fo-legend')));
  h.rec('the three stances and the governor\'s close are offered', await count('#forumstage .fo-vote') === 3 && await count('#forumstage .fo-close') === 1);
  const flex = await page.evaluate(() =>
    [...document.querySelectorAll('#forumstage .fo-tallybox .fo-bar .fo-bseg')].map(e => ({
      grow: getComputedStyle(e).flexGrow, w: Math.round(e.getBoundingClientRect().width), title: e.getAttribute('title') })));
  h.rec('each stance takes its share of the bar, widest first', flex.map(f => f.grow).join() === '3,1' && flex[0].w > flex[1].w, JSON.stringify(flex));
  h.rec('a stance is titled with its own percentage', flex[0].title === 'yes 75%', flex[0].title);
  const hist = (await calls()).find(c => c[0] === 'chat' && c[1] === 'history');
  h.rec('the discussion is asked of the thread\'s scoped topic', !!hist && hist[2] === 'forum/EScopeAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/p-recipe-1', hist && hist[2]);
  h.rec('an empty discussion invites the first word', /say what you think/.test(await text('#forumstage .fo-disc')));

  await setVal('#forumstage .fo-reply', 'the oven is free on Tuesdays');
  await click('#forumstage .fo-post'); await sleep(120);
  const posted = (await calls()).find(c => c[0] === 'chat' && c[1] === 'post');
  h.rec('a post goes out on the topic with the words', !!posted && /Tuesdays/.test(posted[3]));
  h.rec('and comes back into the thread', await count('#forumstage .fo-msg') === 1 && /Tuesdays/.test(await text('#forumstage .fo-msgbody')));

  await click('#forumstage .fo-vote.fo-yes'); await sleep(150);
  const cast = (await calls()).find(c => c[0] === 'cast');
  h.rec('a cast reaches the gateway with id and stance', !!cast && cast[1] === 'p-recipe-1' && cast[2] === 'yes');
  h.rec('the refresh redraws the tally (yes 80%)', /yes 80%/.test(await text('#forumstage .fo-legend')), await text('#forumstage .fo-legend'));
  h.rec('the thread remembers your stance', /you said yes/.test(await text('#forumstage .fo-tallybox')) && await count('#forumstage .fo-vote.on') === 1);

  await click('#forumstage .fo-back'); await sleep(60);
  h.rec('back returns to the open list', await count('#forumstage .fo-row') === 3);
  await page.evaluate(() => [...document.querySelectorAll('#forumstage .fo-row')].find(r => /tool library/.test(r.textContent)).dispatchEvent(new MouseEvent('click', { bubbles: true })));
  await sleep(100);
  h.rec('a thread with no votes says so, rather than drawing a zero bar', /no votes yet/.test(await text('#forumstage .fo-tallybox')));
  h.rec('a consumption thread weighs your consumer voice', /consumer voice.*10%/.test(await text('#forumstage .fo-weightrow')));
  await click('#forumstage .fo-back'); await sleep(40);

  // ── decided ──────────────────────────────────────────────────────────────
  await click('#forumstage .seg-decided'); await sleep(60);
  h.rec('decided lists the closed ballot by its question', await count('#forumstage .fo-row') === 1 && /winter plan/.test(await text('#forumstage .fo-rowtitle')));
  h.rec('with its verdict', /yes · 71%/.test(await text('#forumstage .fo-verdict')), await text('#forumstage .fo-verdict'));
  await click('#forumstage .fo-row'); await sleep(80);
  h.rec('a decided thread has no stances to cast', await count('#forumstage .fo-vote') === 0 && /what it decided/i.test(await text('#forumstage .fo-tallybox')));
  await click('#forumstage .fo-back'); await sleep(40);

  // ── voice ────────────────────────────────────────────────────────────────
  await click('#forumstage .seg-voice'); await sleep(60);
  const vt = await text('#forumstage .fo-voice');
  h.rec('the voice map shows your producer voice in the commune you stand in (25%) and your consumer voice over the federation (10%)',
        /25%/.test(await text('#forumstage .fo-map .fo-map-here')) || (await page.evaluate(() => [...document.querySelectorAll('#forumstage .fo-map .fo-cell.fo-cls-production .fo-cellnum')].map(n => n.textContent).join())).includes('25%')
        && (await page.evaluate(() => [...document.querySelectorAll('#forumstage .fo-map .fo-cell.fo-cls-consumption .fo-cellnum')].map(n => n.textContent).join())).includes('10%'), vt.slice(0, 120));
  h.rec('the flow: 60% kept, 40% with the mandated delegate', /you act directly.*60%/.test(vt) && /EDeleg.*40%/.test(vt) && /mandated/.test(vt));
  await click('#forumstage .fo-revoke'); await sleep(100);
  const rv = (await calls()).find(c => c[0] === 'revoke');
  h.rec('revoke names the delegate', !!rv && /^EDelegate/.test(rv[1]));
  await setVal('#forumstage .fo-dto', 'ENewDelegateYYYYYYYYYYYYYYYYYYYY'); await setVal('#forumstage .fo-dfrac', '30');
  await click('#forumstage .fo-delegform .fo-go'); await sleep(100);
  const dg = (await calls()).find(c => c[0] === 'delegate');
  h.rec('a delegation carries the AID and the share as a fraction', !!dg && dg[1] === 'ENewDelegateYYYYYYYYYYYYYYYYYYYY' && Math.abs(dg[2] - 0.3) < 1e-9, dg && dg.join(','));

  // ── compose: a proposal is born from something ───────────────────────────
  await click('#forumstage .fo-new'); await sleep(60);
  h.rec('the composer is a picker over recipes, needs, means and communes', await count('#forumstage .fo-band') >= 4 && await count('#forumstage .fo-rail') === 0);
  await click('#forumstage .fo-askgo'); await sleep(80);
  h.rec('an empty question opens nothing', !(await calls()).some(c => c[0] === 'open') && await count('#forumstage .fo-compose') === 1);
  await page.evaluate(() => document.querySelector('#forumstage .fo-band .fo-subj').dispatchEvent(new MouseEvent('click', { bubbles: true })));
  await sleep(80);
  const drafted = await page.evaluate(() => (document.querySelector('#forumstage .fo-draft-q') || {}).value || '');
  h.rec('picking a recipe drafts the question in words', /Adopt/.test(drafted) && await count('#forumstage .fo-draft .fo-steps') === 1, drafted);
  await click('#forumstage .fo-draft .fo-go'); await sleep(150);
  const op = (await calls()).find(c => c[0] === 'open');
  h.rec('open sends a ballot in the recipe domain, the subject as its own field', !!op && op[1] === 'ballot' && op[2] === 'recipe' && /^recipe:rp-/.test(op[6] || '') && !/⟨/.test(op[4]), op && op.join(','));
  h.rec('a production ballot is opened under the commune\'s franchise — its producers weigh it', !!op && op[5] === 'scope:EScopeAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', op && op[5]);
  h.rec('and lands in the new thread, subject card and all', /Adopt/.test(await text('#forumstage .fo-q')) && await count('#forumstage .fo-subjcard') === 1);

  // ── the three ways the commons does not answer ───────────────────────────
  // core.js's askJSON exists to make these read alike: no gateway configured, a
  // gateway that refuses, and a reply that is not JSON. All three mean the same
  // thing to a face, and none of them may throw.
  for (const [name, install] of [
    ['a handler that rejects', () => { window.__seam.handlers.listProposals = async () => { throw new Error('gateway said no'); }; }],
    ['a reply that is not JSON', () => { window.__seam.handlers.listProposals = async () => '<html>504</html>'; }],
  ]) {
    await page.evaluate(install);
    await page.evaluate(async () => {
      const { refreshGovernance } = await import('/app/tabs/governance.js');
      window.__seam.handlers.listUcProposals = async () => '[]';
      document.querySelector('#forumstage .fo-back')?.dispatchEvent(new MouseEvent('click', { bubbles: true }));
      document.querySelector('#forumstage .seg-open')?.dispatchEvent(new MouseEvent('click', { bubbles: true }));
      await refreshGovernance(true);
    });
    await sleep(120);
    const txt = await text('#forumstage .fo-body');
    h.rec(`${name} leaves no threads and says so, rather than throwing`,
          await count('#forumstage .fo-row') === 0 && /nothing open/.test(txt) && !/undefined/.test(txt), txt.replace(/\s+/g, ' ').slice(0, 60));
  }

  await page.evaluate(async () => {
    (await import('/app/scope.js')).scopesSig.set([]);
    await (await import('/app/tabs/governance.js')).refreshGovernance(true);
  });
  await sleep(120);
  h.rec('no roster is the demo day again — the docket comes back', await count('#forumstage .fo-row') >= 4 && /demo docket/.test(await text('#forumstage .fo-sub')));

  h.rec('no page errors', h.errs.length === 0, h.errs.join(' | '));
} catch (e) {
  h.rec('the run completed', false, String(e).slice(0, 200));
} finally {
  await browser.close(); await closeServer();
}
process.exit(summarize(h) ? 0 : 1);
