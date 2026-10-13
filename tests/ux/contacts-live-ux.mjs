/// tests/ux/contacts-live-ux.mjs — the contact row is the relationship, live.
///
/// One real gateway, two people. Alice is the founder's first person; Bo
/// asks to be recognised. Alice pastes Bo's link into the bar: the card says
/// the commune holds Bo's key log, and one tap puts Bo in her book. Bo's row
/// carries his ask, and Alice witnesses it from the row. Bo is told Alice
/// connected and connects back from the card. Then the three states of a row,
/// each from its own deliberate act: a tag signs nothing; Alice's vouch reads
/// "you vouch for them" on her row and "vouches for you" on Bo's; Bo's vouch
/// makes both read "you vouch for each other"; Alice withdraws. Then how to
/// reach her: she lists an address and a number in settings, tells the commune
/// the address (the code arrives by mail, and said back it is bound), and gives
/// Bo a card — Bo's row shows it, the commune's file of it is ciphertext, and
/// taking it back erases the file. Last, Alice forgets Bo.
///
/// Run via:  make test-contacts-live-ux

import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { harness, launch, newPage, sleep, summarize } from './ux-harness.mjs';
import { openIdentityCard, tickCard, putAway } from './probe-lib.mjs';

const BASE = process.argv[2] || 'http://localhost:8089';
const DATA = process.env.PLAYNET_DATA_DIR || '.ux-e2e-data';
const MAIL = process.env.PLAYNET_MAIL_DIR || `${DATA}/mail`;
const filesIn = dir => (existsSync(dir) ? readdirSync(dir).map(f => `${dir}/${f}`) : []);
const cardFiles = () => filesIn(`${DATA}/cards`).filter(f => f.endsWith('.card'));
const h = harness();
const browser = await launch();

const dial = (page, expr) =>
  page.evaluate(`(() => { const H = window.__seam.handlers; return ${expr}; })()`);
const parse = (s, fallback = {}) => { try { return JSON.parse(s); } catch { return fallback; } };
async function until(fn, ms = 40000, step = 700) {
  const dl = Date.now() + ms;
  while (Date.now() < dl) { const v = await fn(); if (v) return v; await sleep(step); }
  return await fn();
}
const chipOf = (page) => page.evaluate(() => document.querySelector('#idrow .who')?.textContent ?? '');

/// A citizen: real one-tap create. Returns { page, aid }.
async function citizen(label) {
  const ctx = await browser.newContext();
  const page = await newPage(ctx, h);
  await page.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 60000 });
  await until(async () => /create your identity/i.test(await chipOf(page)), 180000, 1000);
  await openIdentityCard(page);
  await tickCard(page, 'consent', 'age');
  await page.click('.idc .ob-next:has-text("create my identity")');
  await page.waitForSelector('.idc[data-view="reveal"] input[name="username"]', { timeout: 120000 }).catch(() => {});
  const aid = await page.evaluate(() => document.querySelector('.idc[data-view="reveal"] input[name="username"]')?.value ?? '');
  h.rec(`${label}: identity minted`, /^E[A-Za-z0-9_-]{43}$/.test(aid), aid || '(none)');
  await until(() => page.evaluate(() => document.querySelector('#idrow .dot')?.classList.contains('live')), 30000);
  // the held "save your passcode" sheet stands over the page: saved, then closed
  await putAway(page);
  return { page, aid };
}

// ── the Contacts view, driven as a person would ──────────────────────────
const ROWS = '#sharebar .share-contacts .contacts li.crow';
async function openContacts(page) {
  await page.evaluate(() => {
    const bar = document.getElementById('sharebar');
    if (!bar.classList.contains('sb-open')) bar.querySelector('.sharebar-handle').click();
  });
  await sleep(300);
  await page.evaluate(() => document.querySelector('#sharebar .share-seg.seg-contact').click());
  await sleep(400);
}
const row = (page, name) => page.evaluate(([sel, n]) => {
  const r = [...document.querySelectorAll(sel)].find(r => r.querySelector('.calias').textContent === n);
  return r ? { line: r.querySelector('.cline')?.textContent.trim() ?? '',
               mark: !!r.querySelector('.cmark'),
               kind: r.querySelector('.crel')?.textContent ?? '',
               state: [...r.classList].find(c => /^crow-(none|mine|theirs|mutual)$/.test(c)),
               open: r.classList.contains('open'),
               acts: [...r.querySelectorAll('.crow-acts .slot-btn')].map(b => b.textContent.trim()),
               checked: /key checked/.test(r.querySelector('.crow-id')?.textContent ?? '') } : null;
}, [ROWS, name]);
const waitRow = (page, name, ok, ms = 30000) => until(async () => {
  await dial(page, `(H.contactsRefresh(), 1)`);
  await sleep(500);
  const r = await row(page, name);
  return r && ok(r) ? r : null;
}, ms);
async function openRow(page, name) {
  const r = await row(page, name);
  if (r && !r.open) await page.evaluate(([sel, n]) =>
    [...document.querySelectorAll(sel)].find(r => r.querySelector('.calias').textContent === n).querySelector('.crow-head').click(), [ROWS, name]);
  await sleep(250);
}
const tap = (page, name, re) => page.evaluate(([sel, n, src]) => {
  const r = [...document.querySelectorAll(sel)].find(r => r.querySelector('.calias').textContent === n);
  const b = [...r.querySelectorAll('.crow-acts .slot-btn, .crow-kinds .sl-chip')].find(b => new RegExp(src).test(b.textContent.trim()));
  if (b) b.click();
  return !!b;
}, [ROWS, name, re.source]);
const card = (page) => page.evaluate(() => {
  const c = document.querySelector('#sharebar .share-contacts .cask');
  return c ? { q: c.querySelector('.cask-q').textContent, key: c.querySelector('.cask-key').textContent,
               name: c.querySelector('.cask-name').value } : null;
});
async function acceptCard(page, alias) {
  await page.fill('#sharebar .share-contacts .cask .cask-name', alias);
  await page.evaluate(() => [...document.querySelectorAll('#sharebar .cask .slot-btn')].find(b => b.textContent.trim() === 'connect').click());
}
const vouchesIn = async (page) => {
  const b = await dial(page, `H.fpMyVouches()`);
  return typeof b === 'string' ? (b.match(/playnet-relationship/g) || []).length : 0;
};

try {
  const alice = await citizen('Alice');
  const bo = await citizen('Bo');
  await sleep(1500);
  h.rec('genesis: Alice is the first person', (await dial(alice.page, `H.fpGrant(${JSON.stringify(alice.aid)})`)) === 'ok');
  await until(async () => !!parse(await dial(alice.page, `H.fpStatus()`)).person, 20000);
  h.rec('Bo asks to be recognised', (await dial(bo.page, `H.fpEnroll()`)) === 'ok');

  // ── connect: a link in the bar, a checked key, one tap ─────────────────
  await openContacts(alice.page);
  h.rec('Alice\'s book starts empty, and says so',
        await alice.page.$$eval('#sharebar .share-contacts .contacts li.empty', ls => ls.length === 1 && ls[0].textContent === 'no contacts yet'));
  const boLink = `${BASE}/app.html?connect=${bo.aid}`;
  await alice.page.click('#sharebar .share-name');
  await alice.page.fill('#sharebar .share-name', boLink);
  await sleep(300);
  await alice.page.evaluate(() => document.querySelector('#sharebar .share-name').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true })));
  const asked = await until(async () => { const c = await card(alice.page); return c && /key checked/.test(c.key) ? c : null; }, 20000);
  h.rec('the card asks, and says the commune holds Bo\'s key log', !!asked && /Connect with this person/.test(asked.q), JSON.stringify(asked));
  await acceptCard(alice.page, 'Bo');
  let r = await waitRow(alice.page, 'Bo', r => !!r.line);
  h.rec('Bo is in Alice\'s book, his row carrying his ask',
        !!r && /^asking to be recognised · 0 of \d+$/.test(r.line) && r.state === 'crow-none' && !r.mark, JSON.stringify(r));
  await openRow(alice.page, 'Bo');
  r = await row(alice.page, 'Bo');
  h.rec('…with his key checked', !!r && r.checked);

  // ── the ask is witnessed from the row ──────────────────────────────────
  h.rec('Alice witnesses Bo from his row', await tap(alice.page, 'Bo', /^✍ witness$/));
  r = await waitRow(alice.page, 'Bo', r => r.mark);
  h.rec('Bo\'s row carries the recognised mark, and the ask is gone', !!r && r.mark && r.line === '', JSON.stringify(r));
  h.rec('Bo is a recognised person', await until(async () => !!parse(await dial(bo.page, `H.fpStatus()`)).person, 20000));

  // ── connect back: Bo was told, and his card offers it ──────────────────
  await openContacts(bo.page);
  const back = await until(async () => { const c = await card(bo.page); return c && /key checked/.test(c.key) ? c : null; }, 20000);
  h.rec('Bo\'s Contacts holds a card: Alice connected with him', !!back && /connected with you/.test(back.q), JSON.stringify(back));
  await acceptCard(bo.page, 'Alice');
  let b = await waitRow(bo.page, 'Alice', r => r.mark);
  h.rec('Alice is in Bo\'s book, recognised, nothing signed', !!b && b.state === 'crow-none' && b.line === '', JSON.stringify(b));

  // ── a tag signs nothing ────────────────────────────────────────────────
  await openRow(alice.page, 'Bo');
  await tap(alice.page, 'Bo', /^friend$/);
  r = await waitRow(alice.page, 'Bo', r => r.kind === 'friend');
  h.rec('Alice tags Bo a friend: the row is retagged and nothing is signed',
        !!r && r.state === 'crow-none' && (await vouchesIn(alice.page)) === 0, JSON.stringify(r));

  // ── a vouch is its own tap, and each side reads it ─────────────────────
  await openRow(alice.page, 'Bo');
  h.rec('Alice taps vouch', await tap(alice.page, 'Bo', /^✍ vouch as a friend$/));
  r = await waitRow(alice.page, 'Bo', r => r.state === 'crow-mine');
  h.rec('Alice\'s row for Bo: you vouch for them', !!r && r.line === 'you vouch for them', JSON.stringify(r));
  b = await waitRow(bo.page, 'Alice', r => r.state === 'crow-theirs');
  h.rec('Bo\'s row for Alice: vouches for you', !!b && b.line === 'vouches for you', JSON.stringify(b));
  await openRow(bo.page, 'Alice');
  await tap(bo.page, 'Alice', /^✍ vouch as a contact$/);
  b = await waitRow(bo.page, 'Alice', r => r.state === 'crow-mutual');
  r = await waitRow(alice.page, 'Bo', r => r.state === 'crow-mutual');
  h.rec('both rows read: you vouch for each other',
        !!b && !!r && b.line === 'you vouch for each other' && r.line === 'you vouch for each other');

  // ── withdrawing is the voucher's own, two taps ─────────────────────────
  await openRow(alice.page, 'Bo');
  await tap(alice.page, 'Bo', /withdraw$/);
  await sleep(200);
  await tap(alice.page, 'Bo', /^withdraw\?$/);
  r = await waitRow(alice.page, 'Bo', r => r.state === 'crow-theirs');
  b = await waitRow(bo.page, 'Alice', r => r.state === 'crow-mine');
  h.rec('Alice withdraws: her row falls to "vouches for you", Bo\'s to "you vouch for them"',
        !!r && !!b && r.line === 'vouches for you' && b.line === 'you vouch for them');

  // ── how to reach you: your list, told to the commune by a confirmed code ──
  await alice.page.evaluate(async () => (await import('/app/account.js')).openAccountPage('profile')); await sleep(500);
  await alice.page.waitForSelector('.reach .reach-add', { timeout: 15000 });
  const addPoint = async (kind, value) => {
    await alice.page.selectOption('.reach .reach-add select', kind);
    await alice.page.fill('.reach .reach-add input', value);
    await alice.page.evaluate(() => [...document.querySelectorAll('.reach .reach-add .slot-btn')].find(b => b.textContent.trim() === 'add').click());
    await sleep(250);
  };
  await addPoint('email', 'alice@example.org');
  await addPoint('phone', '+49 30 1234567');
  const reachRows = () => alice.page.evaluate(() => [...document.querySelectorAll('.reach .reach-row')].map(r => ({
    kind: r.querySelector('.reach-kind').textContent, value: r.querySelector('.reach-value').textContent,
    side: r.querySelector('.reach-side').textContent.replace(/\s+/g, ' ').trim(),
    btns: [...r.querySelectorAll('.slot-btn')].map(b => b.textContent.trim()) })));
  const tapReach = (value, re) => alice.page.evaluate(([v, src]) => {
    const r = [...document.querySelectorAll('.reach .reach-row')].find(r => r.querySelector('.reach-value').textContent === v);
    const b = [...r.querySelectorAll('.slot-btn')].find(b => new RegExp(src).test(b.textContent.trim()));
    if (b) b.click(); return !!b;
  }, [value, re.source]);
  let rr = await until(async () => { const x = await reachRows(); return x.length === 2 && x[0].btns.includes('notify me here') ? x : null; }, 15000);
  h.rec('settings lists the two ways to reach Alice; the email can be told to the commune, the phone is for people only',
        !!rr && rr[0].value === 'alice@example.org' && rr[1].value === '+49 30 1234567' && !rr[1].btns.includes('notify me here'),
        JSON.stringify(rr));
  h.rec('Alice taps "notify me here"', await tapReach('alice@example.org', /^notify me here$/));
  const mail = await until(() => { const m = filesIn(MAIL).map(f => readFileSync(f, 'utf8')).find(t => /To: alice@example\.org/.test(t)); return m || null; }, 20000);
  const code = mail && (mail.match(/\n\s+(\d{6})\n/) || [])[1];
  h.rec('the commune mailed a code to the address itself', !!code, mail ? mail.slice(0, 80).replace(/\n/g, ' ⏎ ') : '(no mail)');
  h.rec('nothing is bound until the code is said back',
        (parse(await dial(alice.page, `H.reachRead()`)).points || []).every(p => p.state === 'pending'));
  await alice.page.waitForSelector('.reach .reach-code', { timeout: 10000 });
  await alice.page.fill('.reach .reach-code', code || '');
  await tapReach('alice@example.org', /^confirm$/);
  rr = await until(async () => { const x = await reachRows(); return /notifies you here/.test(x[0]?.side || '') ? x : null; }, 15000);
  h.rec('the code binds it: the row reads that this commune notifies her there', !!rr, JSON.stringify(rr && rr[0]));
  h.rec('…and the commune\'s kept registry holds the confirmed address',
        await until(() => existsSync(`${DATA}/recipients.scm`) && /alice@example\.org/.test(readFileSync(`${DATA}/recipients.scm`, 'utf8')), 8000));
  await alice.page.keyboard.press('Escape'); await sleep(400);

  // ── a card: how to reach Alice, for Bo alone ───────────────────────────
  await openContacts(alice.page);
  await openRow(alice.page, 'Bo');
  h.rec('Alice opens her card for Bo', await tap(alice.page, 'Bo', /share my card/));
  await sleep(300);
  const picks = await alice.page.$$eval(ROWS + '.open .crow-pick', ls => ls.map(l => ({ text: l.textContent.replace(/\s+/g, ' ').trim(), on: l.querySelector('input').checked })));
  h.rec('the picker offers every point on her list, each left on', picks.length === 2 && picks.every(p => p.on), JSON.stringify(picks));
  await tap(alice.page, 'Bo', /^give this card$/);
  r = await waitRow(alice.page, 'Bo', r => r.acts.some(a => /your card · change/.test(a)));
  h.rec('her row for Bo reads that he holds her card', !!r, JSON.stringify(r && r.acts));
  const boReach = () => bo.page.evaluate(sel => {
    const row = [...document.querySelectorAll(sel)].find(r => r.querySelector('.calias').textContent === 'Alice');
    const box = row && row.querySelector('.crow-reach');
    return box ? { text: box.textContent.replace(/\s+/g, ' ').trim(), links: [...box.querySelectorAll('a')].map(a => a.getAttribute('href')) } : null;
  }, ROWS);
  await waitRow(bo.page, 'Alice', r => true);
  await openRow(bo.page, 'Alice');
  const got = await until(async () => { await dial(bo.page, `(H.contactsRefresh(), 1)`); await sleep(500); await openRow(bo.page, 'Alice'); return boReach(); }, 30000);
  h.rec('Bo\'s row for Alice shows how to reach her, each point a link where its kind has one',
        !!got && /alice@example\.org/.test(got.text) && /\+49 30 1234567/.test(got.text)
        && got.links.includes('mailto:alice@example.org') && got.links.some(l => /^tel:/.test(l)), JSON.stringify(got));
  const kept = cardFiles().map(f => readFileSync(f, 'utf8'));
  h.rec('the commune keeps one file of it, and the file is ciphertext',
        kept.length === 1 && !/alice@example\.org/.test(kept[0]) && !/1234567/.test(kept[0]) && /"sealed"/.test(kept[0]),
        `${kept.length} file(s), ${kept[0] ? kept[0].length : 0} bytes`);
  await openRow(alice.page, 'Bo');
  await tap(alice.page, 'Bo', /^take my card back$/);
  await sleep(200);
  await tap(alice.page, 'Bo', /^take it back\?$/);
  const taken = await until(async () => { await dial(bo.page, `(H.contactsRefresh(), 1)`); await sleep(500); return (await boReach()) === null && cardFiles().length === 0; }, 30000);
  h.rec('Alice takes her card back: Bo\'s row no longer shows it, and the commune\'s file is gone', taken);
  h.rec('Alice takes the address back from the commune',
        (await dial(alice.page, `H.reachWithdraw("email", "alice@example.org")`)) === 'ok'
        && await until(() => !/alice@example\.org/.test(readFileSync(`${DATA}/recipients.scm`, 'utf8')), 8000));

  // ── forgetting takes the row, and leaves the other person's book alone ──
  await openRow(alice.page, 'Bo');
  await tap(alice.page, 'Bo', /^forget$/);
  await sleep(200);
  await tap(alice.page, 'Bo', /^forget\?$/);
  const gone = await until(async () => (await row(alice.page, 'Bo')) === null, 20000);
  h.rec('Alice forgets Bo: his row is gone from her book', gone);
  b = await row(bo.page, 'Alice');
  h.rec('…and Alice stays in Bo\'s', !!b && b.state === 'crow-mine');
  await alice.page.screenshot({ path: process.env.SHOT_A || '/tmp/contacts-live-alice.png' });
  await bo.page.screenshot({ path: process.env.SHOT_B || '/tmp/contacts-live-bo.png' });
} catch (e) { h.rec('fatal', false, e.message); }
finally { await browser.close(); }

summarize(h);
