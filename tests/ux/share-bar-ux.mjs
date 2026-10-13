/// tests/ux/share-bar-ux.mjs — the share surface is LAYOUT CHROME: a footer
/// drawer, the last member of #main's flex column, present on every face the
/// way the header is. Collapsed: the expression alone. Expanded (via the 🎒
/// handle, or an old ?face=share deep-link): your slot cards, one rail at a
/// time.
///
/// The need/offer switch in the expression is ONE control for two things: what
/// the next declaration will be, and which half of your inventory you are
/// looking at. Asserted on desktop and at phone width.
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
await page.setViewportSize({ width: 1400, height: 900 });
const errs = [];
page.on('pageerror', e => errs.push(String(e)));

const barState = () => page.evaluate(() => {
  const bar = document.getElementById('sharebar');
  if (!bar) return null;
  const r = bar.getBoundingClientRect();
  const app = bar.parentElement.getBoundingClientRect();
  const row = bar.querySelector('.sharebar-row');
  const handle = bar.querySelector('.sharebar-handle');
  // scoped past share-scope (the I/We toggle sits before it and is also .on)
  const lit = bar.querySelector('.share-rail:not(.share-scope) .share-seg.on');
  const drawer = bar.querySelector('.share-drawer');
  return {
    open: bar.classList.contains('sb-open'),
    visible: r.height > 20 && r.width > 100,
    // the bar is #app's flex column's last real member (app.html): it spans
    // the column and closes it
    atFoot: Math.abs(r.left - app.left) < 2 && Math.abs(r.bottom - app.bottom) < 2
            && Math.abs(r.width - app.width) < 2,
    handleTitle: handle ? handle.title : '',
    rail: lit ? lit.dataset.rail : null,
    heads: [...bar.querySelectorAll('.share-lists .share-h')].map(e => e.textContent.trim()),
    cards: [...bar.querySelectorAll('.share-lists .slot-card .slot-name')].map(e => e.value),
    // the lent rail: its column is the offer side's, and it stays EMPTY until a
    // gateway pushes grants (drawLent draws nothing while grants are null —
    // offline there is nothing to be honest about yet), so this test asserts the
    // column's presence and that the need side clears it, not its contents.
    lentCol: !!bar.querySelector('.share-lent-col'),
    lentEmpty: !bar.querySelector('.share-lent-col')?.childElementCount,
    handle: handle ? handle.textContent.trim() : '',
    // the handle is the row's RIGHTMOST item at every width
    handleAtRight: !!(handle && row &&
      row.getBoundingClientRect().right - handle.getBoundingClientRect().right < 16),
    // nothing may scroll sideways — the bar sizes to the STAGE, not the window
    overflowX: drawer ? drawer.scrollWidth - drawer.clientWidth : 0,
    docOverflowX: document.documentElement.scrollWidth - document.documentElement.clientWidth,
  };
});
const flipTo = seg => page.evaluate(s => document.querySelector(`.share-seg.seg-${s}`).click(), seg);

try {
  await page.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
  await sleep(1500);

  let b = await barState();
  h.rec('app.html loads without page errors', errs.length === 0, errs.slice(0, 2).join(' | '));
  h.rec('the bar exists on load, collapsed, closing #app’s column',
        !!b && b.visible && !b.open && b.atFoot);
  h.rec('there is no share NAV button — the surface is chrome, not a face',
        await page.evaluate(() => !document.getElementById('face-share')));
  h.rec('the drawer handle is the 🎒 glyph, its title names the inventory, at the row’s right',
        !!b && /🎒/.test(b.handle) && /inventory/.test(b.handleTitle) && b.handleAtRight,
        b && `${b.handle} · ${b.handleTitle.slice(0, 40)}`);
  h.rec('the rail switch shows both states with NEED lit', b && b.rail === 'need', b && b.rail);

  // the handle opens the drawer — over whatever face is showing
  const faceBefore = await page.evaluate(() => document.getElementById('main').getAttribute('data-face'));
  await page.evaluate(() => document.querySelector('.sharebar-handle').click());
  await sleep(400);
  b = await barState();
  const faceAfter = await page.evaluate(() => document.getElementById('main').getAttribute('data-face'));
  h.rec('the inventory button OPENS the drawer', !!b && b.open && b.cards.length > 0);
  h.rec('…without leaving the current face', faceAfter === faceBefore,
        `${faceBefore} → ${faceAfter}`);

  // need mode: needs only, no lent rail (lending is an act on an OFFER)
  h.rec('NEED mode shows your needs and only those',
        !!b && b.cards.some(c => /bread/.test(c)) && !b.cards.some(c => /bike repair/.test(c)),
        b && b.cards.join(' | '));
  h.rec('…with the needs heading, and the lent rail cleared',
        !!b && b.heads.some(t => /^my needs/.test(t)) && b.lentEmpty, b && b.heads.join(' | '));

  // the switch filters the inventory: offer mode swaps the column and the rail
  await flipTo('offer'); await sleep(400);
  b = await barState();
  h.rec('the switch flips to OFFER', b && b.rail === 'offer', b && b.rail);
  h.rec('OFFER mode shows your offers and only those',
        !!b && b.cards.some(c => /bike repair/.test(c)) && !b.cards.some(c => /bread/.test(c)),
        b && b.cards.join(' | '));
  h.rec('…and the lent-into-the-commons rail belongs to this side', !!b && b.lentCol);
  h.info('the lent rail stays empty with no gateway — grants are a live push');

  // declaring through the expression lands on the rail that is lit
  await page.evaluate(() => {
    const bar = document.getElementById('sharebar');
    bar.querySelector('.share-name').value = 'lathe time';
    bar.querySelector('.share-name').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    bar.querySelector('.sp-close')?.click();
  });
  await sleep(350);
  b = await barState();
  h.rec('declaring adds a card on the LIT rail',
        !!b && b.cards.some(c => /lathe time/.test(c)), b && b.cards.join(' | '));
  await flipTo('need'); await sleep(350);
  b = await barState();
  h.rec('…and it is not on the other one', !!b && !b.cards.some(c => /lathe time/.test(c)),
        b && b.cards.join(' | '));

  // ── how a need is met: the badge and its section (their allocations panel,
  // read as communal · credit · gap) — the demo housing need is 67% provisioned
  // by the plan (rest/shelter · rp-shelter-night), so it carries the badge
  await flipTo('need'); await sleep(300);
  const met = await page.evaluate(() => {
    const card = [...document.querySelectorAll('#sharebar .slot-card')].find(c => /housing/.test(c.querySelector('.slot-name')?.value || ''));
    if (!card) return null;
    const badge = card.querySelector('.slot-btn-alloc');
    badge?.click();
    const body = card.querySelector('.slot-body');
    return { badge: badge?.textContent, fill: card.querySelector('.slot-fill')?.style.width,
             title: body?.querySelector('.met-title')?.textContent || '',
             tiers: [...body?.querySelectorAll('.met-item') || []].map(i => i.className.replace('met-item ', '')),
             verbs: [...body?.querySelectorAll('.met-verb') || []].map(v => v.textContent) };
  });
  h.rec('a provisioned need carries the allocation badge and a fill wash',
        !!met && met.badge === '1' && met.fill === '67%', JSON.stringify(met));
  h.rec('the badge opens “how it\'s met”: communal first, then the gap with its verbs',
        !!met && /1\.3 of 2 person-nights met/.test(met.title) && met.tiers[0] === 'communal'
        && met.tiers.includes('gap') && met.verbs.some(v => /contribute/.test(v)) && met.verbs.some(v => /propose/.test(v)),
        met && `${met.title} · ${met.tiers.join('|')} · ${met.verbs.join('|')}`);
  h.rec('a bare need (no provision, nothing claimable) carries no badge',
        await page.evaluate(() => {
          const card = [...document.querySelectorAll('#sharebar .slot-card')].find(c => /bread/.test(c.querySelector('.slot-name')?.value || ''));
          return !!card && !card.querySelector('.slot-btn-alloc');
        }));

  // ── the matcher-only sidecar on the card: ⚙️ divisibility · 🔒 eligibility ──
  const crit = await page.evaluate(async () => {
    const card = [...document.querySelectorAll('#sharebar .slot-card')].find(c => /bread/.test(c.querySelector('.slot-name')?.value || ''));
    const btns = [...card.querySelectorAll('.slot-btn')];
    const gear = btns.find(b => /⚙️/.test(b.textContent)); gear.click();
    const inp = card.querySelector('.sl-div-in');
    inp.value = '2'; inp.dispatchEvent(new Event('change', { bubbles: true }));
    await new Promise(r => setTimeout(r, 300));
    const c2 = [...document.querySelectorAll('#sharebar .slot-card')].find(c => /bread/.test(c.querySelector('.slot-name')?.value || ''));
    const gear2 = [...c2.querySelectorAll('.slot-btn')].find(b => /⚙️/.test(b.textContent));
    const lock = [...c2.querySelectorAll('.slot-btn')].find(b => /🔒/.test(b.textContent)); lock.click();
    const chips = [...c2.querySelectorAll('.slot-body .sl-chip')].map(c => c.textContent);
    c2.querySelectorAll('.slot-body .sl-chip')[1].click();     // nobody
    await new Promise(r => setTimeout(r, 300));
    const c3 = [...document.querySelectorAll('#sharebar .slot-card')].find(c => /bread/.test(c.querySelector('.slot-name')?.value || ''));
    const lock2 = [...c3.querySelectorAll('.slot-btn')].find(b => /🔒/.test(b.textContent));
    return { gear: gear2.textContent, chips, lock: lock2.textContent, locked: lock2.classList.contains('locked') };
  });
  h.rec('⚙️ sets the smallest useful piece and reads it back on the button',
        /size ≥ 2/.test(crit.gear), crit.gear);
  h.rec('🔒 offers the presets — anyone · nobody · only… · not… · custom',
        crit.chips.length === 5 && /anyone/.test(crit.chips[0]) && /custom/.test(crit.chips[4]), crit.chips.join('|'));
  h.rec('a lock reads back on the button and lights it', /nobody/.test(crit.lock) && crit.locked, crit.lock);

  // ── the name doubles as the search: typing sifts the cards below ─────────
  await page.evaluate(() => document.querySelector('#sharebar .sp-close')?.click());
  await page.click('#sharebar .share-name');
  await page.type('#sharebar .share-name', 'bre'); await sleep(300);
  const sift = await page.evaluate(() => ({
    cards: [...document.querySelectorAll('#sharebar .share-lists .slot-card .slot-name')].map(e => e.value),
    head: document.querySelector('#sharebar .share-h')?.textContent,
  }));
  h.rec('typing a name sifts your cards to what it names, and says so',
        sift.cards.length === 1 && /bread/.test(sift.cards[0]) && /1 of 3 match/.test(sift.head || ''),
        `${sift.cards.join('|')} · ${sift.head}`);
  await page.evaluate(() => { const n = document.querySelector('#sharebar .share-name'); n.value = ''; n.dispatchEvent(new Event('input', { bubbles: true })); });
  await page.evaluate(() => document.querySelector('#sharebar .sp-close')?.click());
  await sleep(250);
  h.rec('clearing the name brings every card back',
        await page.$$eval('#sharebar .share-lists .slot-card', cs => cs.length === 3));

  // ── the Contacts subtab: one row per person, and the row is the relationship ──
  await flipTo('contact'); await sleep(400);
  const rowsSel = '#sharebar .share-lists .share-contacts .contacts li.crow';
  const ct = await page.evaluate(sel => {
    const bar = document.getElementById('sharebar');
    const rows = [...document.querySelectorAll(sel)];
    const state = cls => rows.filter(r => r.classList.contains(cls)).length;
    return { on: bar.querySelector('.share-seg.seg-contact')?.classList.contains('on'),
             ph: bar.querySelector('.share-name')?.placeholder,
             rows: rows.length,
             chips: [...bar.querySelectorAll('.share-contacts .cfilter')].map(c => c.textContent.trim()),
             states: { none: state('crow-none'), mine: state('crow-mine'), theirs: state('crow-theirs'), mutual: state('crow-mutual') },
             lines: rows.map(r => r.querySelector('.cline')?.textContent.trim()).filter(Boolean),
             marks: rows.filter(r => r.querySelector('.cmark')).length,
             first: rows[0]?.querySelector('.calias')?.textContent,
             demo: getComputedStyle(bar.querySelector('.share-contacts > .opt')).display !== 'none',
             sidebar: !!document.getElementById('contactsSec') };
  }, rowsSel);
  h.rec('the Contacts segment lights, the bar asks for a contact, the book lists',
        ct.on && /contact/i.test(ct.ph) && ct.rows > 0 && ct.chips[0].startsWith('all'), JSON.stringify(ct));
  h.rec('…and the day face no longer carries its own contacts section', !ct.sidebar);
  h.rec('the demo book shows every state a row can be in, and says it is a demo',
        ct.demo && Object.values(ct.states).every(n => n > 0) && ct.marks > 0 && ct.marks < ct.rows,
        JSON.stringify(ct.states));
  h.rec('a row says what is signed in words, and an open ask leads the list',
        ct.lines.includes('you vouch for each other') && ct.lines.includes('you vouch for them')
        && ct.lines.includes('vouches for you') && ct.lines.some(l => /^asking to be recognised · \d+ of \d+$/.test(l))
        && ct.chips.some(c => /^asking 1$/.test(c)), `${ct.first} · ${ct.lines.join(' | ')}`);
  // a row opens to its acts, and stays open across a redraw
  const openRow = name => page.evaluate(([sel, n]) => {
    [...document.querySelectorAll(sel)].find(r => r.querySelector('.calias').textContent === n).querySelector('.crow-head').click();
  }, [rowsSel, name]);
  const rowState = name => page.evaluate(([sel, n]) => {
    const r = [...document.querySelectorAll(sel)].find(r => r.querySelector('.calias').textContent === n);
    return r && { open: r.classList.contains('open'), expanded: r.querySelector('.crow-head').getAttribute('aria-expanded'),
                  story: r.querySelector('.crow-story')?.textContent || '',
                  acts: [...r.querySelectorAll('.crow-acts .slot-btn')].map(b => b.textContent.trim()),
                  kind: r.querySelector('.crel')?.textContent,
                  chipOn: r.querySelector('.crow-kinds .sl-chip.on')?.textContent,
                  cls: r.className };
  }, [rowsSel, name]);
  await openRow('Ana'); await sleep(250);
  let ana = await rowState('Ana');
  h.rec('a row opens: the story of the two of you, and the acts',
        ana.open && ana.expanded === 'true' && /You know Ana as a friend\. You vouch for them as a friend\. They vouch for you as a friend\./.test(ana.story)
        && ana.acts.some(a => /^✓ vouched as a friend · withdraw$/.test(a)) && ana.acts.some(a => /invite/.test(a))
        && ana.acts.some(a => /recovery friend/.test(a)) && ana.acts.some(a => /^forget$/.test(a))
        && !ana.acts.some(a => /^✍ vouch/.test(a)), JSON.stringify(ana));
  // the card Ana gave is how to reach her; your own card for her is an act on the row
  const reachAna = await page.evaluate(sel => {
    const r = [...document.querySelectorAll(sel)].find(r => r.querySelector('.calias').textContent === 'Ana');
    const box = r.querySelector('.crow-reach');
    return { mark: !!r.querySelector('.crow-head .ccard'),
             text: box ? box.textContent.replace(/\s+/g, ' ').trim() : '',
             links: box ? [...box.querySelectorAll('a')].map(a => a.getAttribute('href')) : [],
             acts: [...r.querySelectorAll('.crow-acts .slot-btn')].map(b => b.textContent.trim()) };
  }, rowsSel);
  h.rec('a row whose person gave a card shows how to reach them, with a link where the kind has one',
        reachAna.mark && /how to reach Ana/.test(reachAna.text) && /ring twice/.test(reachAna.text)
        && reachAna.links.includes('mailto:ana@example.org') && reachAna.links.some(l => /^tel:/.test(l)), JSON.stringify(reachAna));
  h.rec('…and carries your own card for them: change it, or take it back',
        reachAna.acts.some(a => /your card · change/.test(a)) && reachAna.acts.includes('take my card back'), reachAna.acts.join(' | '));
  await page.evaluate(sel => [...document.querySelectorAll(sel + '.open .crow-acts .slot-btn')].find(b => /your card · change/.test(b.textContent)).click(), rowsSel);
  await sleep(250);
  h.rec('with nothing on your list yet, the card picker points to settings',
        await page.$$eval(rowsSel + '.open .crow-card .slot-btn', bs => bs.some(b => /settings/.test(b.textContent))));
  await page.evaluate(sel => [...document.querySelectorAll(sel + '.open .crow-card .slot-btn')].find(b => /not now/.test(b.textContent)).click(), rowsSel);
  await sleep(200);
  await page.evaluate(() => [...document.querySelectorAll('#sharebar .cfilter')].find(c => /^online/.test(c.textContent.trim())).click());
  await sleep(250);
  const online = await page.$$eval(rowsSel, ls => ls.length);
  h.rec('a filter chip narrows the list', online > 0 && online < ct.rows, `${online} of ${ct.rows}`);
  ana = await rowState('Ana');
  h.rec('…and the open row stays open across the redraw', !!ana && ana.open);
  await page.evaluate(() => [...document.querySelectorAll('#sharebar .cfilter')].find(c => /^all/.test(c.textContent.trim())).click());
  await sleep(200);
  // the tag is a label: choosing a kind changes the tag and signs nothing
  await page.evaluate(sel => [...document.querySelectorAll(sel + '.open .crow-kinds .sl-chip')].find(c => c.textContent === 'colleague').click(), rowsSel);
  await sleep(250);
  ana = await rowState('Ana');
  h.rec('choosing a kind retags the row, and the vouch that stands is untouched',
        ana.kind === 'colleague' && ana.chipOn === 'colleague' && /crow-mutual/.test(ana.cls)
        && ana.acts.some(a => /^✍ vouch as a colleague instead$/.test(a))
        && ana.acts.some(a => /^✓ vouched as a friend · withdraw$/.test(a)), JSON.stringify(ana));
  // withdraw and forget each take two taps
  await page.evaluate(sel => [...document.querySelectorAll(sel + '.open .crow-acts .slot-btn')].find(b => /withdraw$/.test(b.textContent)).click(), rowsSel);
  await sleep(200);
  ana = await rowState('Ana');
  h.rec('withdraw arms on the first tap and asks', ana.acts.includes('withdraw?'), ana.acts.join(' | '));
  await page.evaluate(sel => [...document.querySelectorAll(sel + '.open .crow-kinds .sl-chip')].find(c => c.textContent === 'friend').click(), rowsSel);
  await openRow('Ana'); await sleep(200);
  ana = await rowState('Ana');
  h.rec('the head closes the row again', !ana.open && ana.expanded === 'false');
  await openRow('dad'); await sleep(200);
  const dad = await rowState('dad');
  h.rec('a row with nothing signed says so, and offers the vouch and the introduction',
        /Nothing is signed between you\./.test(dad.story) && dad.acts.some(a => /^✍ vouch as family$/.test(a))
        && dad.acts.some(a => /introduce/.test(a)), JSON.stringify(dad));
  await openRow('mama'); await sleep(200);
  const mama = await rowState('mama');
  h.rec('one row is open at a time, and an ask is witnessed from its row',
        mama.open && mama.acts.some(a => /^✍ witness$/.test(a)) && !mama.acts.some(a => /introduce/.test(a))
        && !(await rowState('dad')).open, JSON.stringify(mama.acts));
  await openRow('mama');
  // connect: the strip opens on your link; a person's link in the bar and ↵ opens the card
  h.rec('the bar carries no ➕ button — ↵ is the one way to commit', await page.evaluate(() => !document.querySelector('#sharebar .share-add')));
  await page.evaluate(() => [...document.querySelectorAll('#sharebar .cconnect-strip .slot-btn')].find(b => /connect/.test(b.textContent)).click());
  await sleep(300);
  h.rec('＋ connect opens your page on the scanner — a way to paste a link in it, the toggle to your own code, and no camera held when none is here',
        await page.$$eval('#sharebar .me-view.me-scanning .me-paste', xs => xs.length === 1)
        && await page.$$eval('#sharebar .me-view .share-seg', xs => xs.map(x => x.textContent.trim()).join('|') === 'My code|Scan'));
  await page.evaluate(() => document.querySelector('#sharebar .cdetail-me .cback').click());
  await sleep(200);
  h.rec('yourself is the first tile of your contacts',
        await page.$eval('#sharebar .share-contacts .contacts .crow', li => li.classList.contains('crow-you')));
  const someone = 'E' + 'a1B2-c3D4_'.repeat(5).slice(0, 43);
  await page.fill('#sharebar .share-name', `https://playnet.example/app.html?connect=${someone}&name=Tia`);
  await sleep(250);
  await page.evaluate(() => document.querySelector('#sharebar .share-name').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true })));
  await sleep(400);
  const ask = await page.evaluate(() => {
    const c = document.querySelector('#sharebar .share-contacts .cask');
    return c && { q: c.querySelector('.cask-q').textContent, name: c.querySelector('.cask-name').value,
                  key: c.querySelector('.cask-key').textContent, aid: c.querySelector('.caid').textContent,
                  bar: document.querySelector('#sharebar .share-name').value };
  });
  h.rec('the card asks about that person by the name the link gave, and the bar is clear again',
        !!ask && /Connect with this person/.test(ask.q) && ask.name === 'Tia' && ask.aid === someone && ask.bar === ''
        && /not checked yet/.test(ask.key), JSON.stringify(ask));
  await page.evaluate(() => [...document.querySelectorAll('#sharebar .cask .slot-btn')].find(b => b.textContent.trim() === 'not now').click());
  await sleep(200);
  h.rec('"not now" puts the card down', await page.$$eval('#sharebar .cask', cs => cs.length === 0));
  await page.click('#sharebar .share-name');
  await page.type('#sharebar .share-name', 'zzzz'); await sleep(300);
  h.rec('typing into the bar finds among contacts (no match → "no one here")',
        await page.$$eval('#sharebar .share-contacts .contacts li.empty', ls => ls.length === 1 && ls[0].textContent === 'no one here'));
  await page.evaluate(() => { const n = document.querySelector('#sharebar .share-name'); n.value = ''; n.dispatchEvent(new Event('input', { bubbles: true })); });
  await page.evaluate(() => [...document.querySelectorAll('#sharebar .cfilter')].find(c => /^all/.test(c.textContent.trim())).click());
  await flipTo('need'); await sleep(350);

  // ── the rhythm as ONE SENTENCE (free-association's SentenceBuilder): "in
  // [months] on [weeks] on [days] at [time]", four dropdowns; picking
  // "specific months…" reveals a month-pill grid IN PLACE, and days/time are
  // already showing their own custom pickers since bread's arc (mon wed fri
  // 17:00–19:00) matches no named preset on either axis — both stay visible
  // at once, not one at a time.
  const tiers = await page.evaluate(async () => {
    const card = [...document.querySelectorAll('#sharebar .slot-card')].find(c => /bread/.test(c.querySelector('.slot-name')?.value || ''));
    [...card.querySelectorAll('.slot-btn')].find(b => /🕐/.test(b.textContent)).click();
    const sels = [...card.querySelectorAll('.sl-mode')];   // months, weeks, days, time — in that order
    const already = { days: sels[2].value, time: sels[3].value };
    const monthsSel = sels[0];
    monthsSel.value = 'custom';
    monthsSel.dispatchEvent(new Event('change', { bubbles: true }));
    const pills = [...card.querySelectorAll('.sl-arc-custom .sl-tier.sl-months .sl-tierpill')];
    const hiddenBefore = pills.length;
    // both the day pills (custom days) AND the time pair (custom time) are
    // ALREADY showing, unprompted — the point of per-axis reveal slots
    const dayPillsShowing = card.querySelectorAll('.sl-arc-custom .sl-days .sl-day').length;
    const timeInputsShowing = card.querySelectorAll('.sl-arc-custom .sl-times .sl-time').length;
    pills.find(p => p.textContent === 'Oct').click();
    await new Promise(r => setTimeout(r, 300));
    const c2 = [...document.querySelectorAll('#sharebar .slot-card')].find(c => /bread/.test(c.querySelector('.slot-name')?.value || ''));
    const btn = [...c2.querySelectorAll('.slot-btn')].find(b => /🕐/.test(b.textContent));
    return { already, hiddenBefore, dayPillsShowing, timeInputsShowing, label: btn.textContent };
  });
  h.rec('the rhythm reads as a sentence: days and time already read custom (no named preset fits)',
        tiers.already.days === 'custom' && tiers.already.time === 'custom', JSON.stringify(tiers.already));
  h.rec('picking "specific months…" reveals all twelve, unfiltered', tiers.hiddenBefore === 12);
  h.rec('the day pills and the time pair show TOGETHER, not one at a time',
        tiers.dayPillsShowing === 7 && tiers.timeInputsShowing === 2,
        `days=${tiers.dayPillsShowing} time=${tiers.timeInputsShowing}`);
  h.rec('picking a month puts it in the rhythm and the button reads it back',
        /Oct · mon wed fri 17:00–19:00/.test(tiers.label), tiers.label);

  // ── where: a real tab strip — None · Known · Specific · Coordinates · Online
  // (free-association's LocationEditor structure); Specific is their five-field
  // mailing address, Coordinates their two number inputs, both declare-place
  const where = await page.evaluate(async () => {
    const find = () => [...document.querySelectorAll('#sharebar .slot-card')].find(c => /childcare/.test(c.querySelector('.slot-name')?.value || ''));
    let card = find();
    [...card.querySelectorAll('.slot-btn')].find(b => /📍/.test(b.textContent)).click();
    const tabs = [...card.querySelectorAll('.sl-where-tab')].map(t => t.textContent);
    card.querySelector('[data-tab=specific]').click();
    const specificFields = [...card.querySelectorAll('.sl-addr-form .sl-in')].map(i => i.placeholder);
    // no save button — the group commits when focus leaves it entirely
    card.querySelector('.sl-placein').value = 'The old mill';
    card.querySelector('.sl-addr-street').value = '12 Bread St';
    const cityIn = card.querySelector('.sl-addr-city');
    cityIn.value = 'Sofia';
    cityIn.focus();
    cityIn.blur();
    await new Promise(r => setTimeout(r, 400));
    card = find();
    const btn = [...card.querySelectorAll('.slot-btn')].find(b => /📍/.test(b.textContent));
    // the where section stays open across the refresh (openSections carries it)
    card.querySelector('[data-tab=coordinates]').click();
    const coordFields = [...card.querySelectorAll('.sl-addr-form .sl-in')].map(i => i.placeholder);
    return { tabs, specificFields, coordFields, where: btn.textContent };
  });
  h.rec('the where editor is a tab strip: None · Known · Specific · Coordinates · Online',
        ['None', 'Known', 'Specific', 'Coordinates', 'Online'].every(t => where.tabs.includes(t)), where.tabs.join('|'));
  h.rec('Specific is a five-field mailing address, like theirs',
        ['its name', 'street address', 'city', 'state / province', 'postal code', 'country']
          .every(f => where.specificFields.includes(f)), where.specificFields.join('|'));
  h.rec('naming a place in Specific puts the slot there (demo: the name is the place)',
        /The old mill/.test(where.where), where.where);
  h.rec('Coordinates is name + two number inputs, not one combined field',
        where.coordFields.includes('latitude') && where.coordFields.includes('longitude')
        && !where.coordFields.some(f => /,/.test(f)), where.coordFields.join('|'));

  // ── the toolbar's OWN dialled place narrows the list too, exact match: only
  // childcare stands at "The old mill" now (just set above); the demo's other
  // two are still "anywhere" and drop out — proved at the state layer (the
  // "Known" tab lists the SCOPE's own places, and a demo-local declare-place
  // never registers there — the filter logic is what's under test here, not
  // that particular affordance).
  await page.evaluate(() => document.querySelector('#sharebar .sp-close')?.click());
  const placeFiltered = await page.evaluate(async () => {
    const m = await import('./app/tabs/social/share.js');
    const before = [...document.querySelectorAll('#sharebar .share-lists .slot-card .slot-name')].map(e => e.value);
    m.draftWhere.set('The old mill');
    await new Promise(r => setTimeout(r, 300));
    const after = [...document.querySelectorAll('#sharebar .share-lists .slot-card .slot-name')].map(e => e.value);
    m.draftWhere.set('');
    await new Promise(r => setTimeout(r, 300));
    const cleared = [...document.querySelectorAll('#sharebar .share-lists .slot-card .slot-name')].map(e => e.value);
    return { before, after, cleared };
  });
  h.rec('dialling a place narrows the list to an exact match — only childcare stands there',
        placeFiltered.before.length === 3 && placeFiltered.after.length === 1 && placeFiltered.after[0] === 'childcare',
        JSON.stringify(placeFiltered));
  h.rec('clearing the dialled place brings every card back', placeFiltered.cleared.length === 3);

  // ── ⭐ on a capacity only: who it serves first ────────────────────────────
  await flipTo('offer'); await sleep(300);
  const star = await page.evaluate(() => {
    const cards = [...document.querySelectorAll('#sharebar .slot-card')];
    return { onOffer: cards.some(c => [...c.querySelectorAll('.slot-btn')].some(b => /⭐/.test(b.textContent))) };
  });
  await flipTo('need'); await sleep(300);
  const starNeed = await page.evaluate(() =>
    [...document.querySelectorAll('#sharebar .slot-card')].some(c => [...c.querySelectorAll('.slot-btn')].some(b => /⭐/.test(b.textContent))));
  h.rec('⭐ priority sits on capacities and not on needs', star.onOffer && !starNeed);

  // ── I ⇄ We: the SAME rail (need/offer) reads a different pool depending on
  // whose inventory is on screen — your own, edited inline, or the commons'
  // read-only. flipTo('need') above left the switch on need/mine.
  const scopeState = () => page.evaluate(() => {
    const bar = document.getElementById('sharebar');
    return {
      lit: bar.querySelector('.share-scope .share-seg.on')?.textContent.trim(),
      editable: [...bar.querySelectorAll('.share-lists .slot-card')].every(c => !c.classList.contains('slot-ro')),
      cards: [...bar.querySelectorAll('.share-lists .slot-card .slot-name')].map(e => e.value),
    };
  });
  let sc = await scopeState();
  h.rec('the My/Our switch starts lit on My, your own cards editable',
        /My/.test(sc.lit || '') && sc.editable && sc.cards.length > 0, JSON.stringify(sc));
  await page.evaluate(() => document.querySelector('.share-seg.seg-social').click()); await sleep(300);
  sc = await scopeState();
  // Our is the FOLD: the scope's needs summed per cell, read-only, your own
  // share named inside the sum and nobody else's name anywhere
  const fold = await page.evaluate(() => {
    const bar = document.getElementById('sharebar');
    const cells = [...bar.querySelectorAll('.share-lists .slot-card.slot-cell')];
    return {
      cells: cells.length,
      ro: cells.every(c => c.classList.contains('slot-ro')),
      mine: cells.filter(c => c.querySelector('.slot-mine')).map(c => c.querySelector('.slot-mine').textContent),
      who: cells.some(c => c.querySelector('.slot-who:not(.slot-mine)')),
      heads: [...bar.querySelectorAll('.share-lists .share-h')].map(e => e.textContent.trim()),
      foot: bar.querySelector('.share-foot')?.textContent || '',
      // the chip is parked (SHOW_QTY_UNIT in share.ts): absent counts as hidden
      qtyHidden: (q => !q || getComputedStyle(q).display === 'none')(bar.querySelector('.share-qtygrp')),
      placeholder: bar.querySelector('.share-name').placeholder,
      sift: bar.classList.contains('sb-sift'),
    };
  });
  h.rec('switching to Our shows the scope\'s SUM as read-only cells, not anyone\'s cards',
        /Our/.test(sc.lit || '') && fold.cells > 0 && fold.ro, `${JSON.stringify(sc)} · ${fold.cells} cells`);
  h.rec('…headed as our needs, the scope\'s sum', fold.heads.some(t => /^our needs/.test(t)), fold.heads.join(' | '));
  h.rec('…your own share reads inside the sum ("of which yours"), and no other name travels',
        fold.mine.length > 0 && fold.mine.every(t => /of which yours/.test(t)) && !fold.who, fold.mine.join(' | '));
  h.rec('…the foot states the fold: everyone\'s, summed; add yours under My', /summed/.test(fold.foot) && /under My/.test(fold.foot), fold.foot);
  h.rec('under Our the pill is the sift alone — no quantity, a sift placeholder',
        fold.qtyHidden && fold.sift && /^Sift our/.test(fold.placeholder), fold.placeholder);
  await page.evaluate(() => document.querySelector('.share-seg.seg-mine').click()); await sleep(300);
  sc = await scopeState();
  h.rec('switching back to My restores your own editable cards',
        /My/.test(sc.lit || '') && sc.editable && sc.cards.length > 0,
        JSON.stringify(sc));

  // ── the draft read back as one line before ↵ ─────────────────────
  await page.fill('#sharebar .share-name', 'flour'); await sleep(200);
  const pv = await page.evaluate(() => {
    const p = document.querySelector('#sharebar .share-preview');
    return { on: p.classList.contains('on'), text: p.textContent };
  });
  h.rec('typing a name shows the draft as one line — the thing, the amount, place and rhythm',
        pv.on && /need · flour · 1 each/.test(pv.text) && /anywhere/.test(pv.text) && /any time/.test(pv.text), pv.text);
  await page.fill('#sharebar .share-name', ''); await page.evaluate(() => document.querySelector('#sharebar .share-name').dispatchEvent(new Event('input'))); await sleep(200);
  h.rec('…and leaves with the name', !(await page.evaluate(() => document.querySelector('#sharebar .share-preview').classList.contains('on'))));

  // ── no separate clock/sort chrome, no saved views — the pill's own fields
  // (the name, already proven above) are the only filter there is
  h.rec('there is no separate facet row or saved-views UI',
        await page.evaluate(() =>
          !document.querySelector('#sharebar .share-facets') && !document.querySelector('#sharebar .share-views')));

  // ── the toolbar IS the filter: its query and rail are EXPORTED, so the map's
  // own marker renderer (markers.ts) can AND them onto its own search without
  // a second control anywhere. Proved at the state level — the map itself
  // can't render (no WebGL in this headless run) — by importing the same
  // module the drawer runs on and watching its exports move as the pill does.
  await page.evaluate(() => { const n = document.querySelector('#sharebar .share-name'); n.value = ''; n.dispatchEvent(new Event('input', { bubbles: true })); });
  const wiring = await page.evaluate(async () => {
    const m = await import('./app/tabs/social/share.js');
    const before = m.F.query();
    const railBefore = m.rail();
    document.querySelector('#sharebar .share-name').value = 'lantern';
    document.querySelector('#sharebar .share-name').dispatchEvent(new Event('input', { bubbles: true }));
    const afterType = m.F.query();
    document.querySelector('.share-seg.seg-offer').click();
    const afterRail = m.rail();
    document.querySelector('.share-seg.seg-need').click();   // leave it as every other test expects
    return { before, railBefore, afterType, afterRail };
  });
  h.rec('the pill\'s name IS the exported query the map also reads',
        wiring.before === '' && wiring.afterType === 'lantern', JSON.stringify(wiring));
  h.rec('the rail switch IS the exported kind the map\'s pool markers also read',
        wiring.railBefore === 'need' && wiring.afterRail === 'capacity', JSON.stringify(wiring));
  // leave the pill and the panel exactly as every test after this expects them
  await page.evaluate(() => { const n = document.querySelector('#sharebar .share-name'); n.value = ''; n.dispatchEvent(new Event('input', { bubbles: true })); });
  await page.evaluate(() => document.querySelector('#sharebar .sp-close')?.click());
  await sleep(200);

  // ── 💬 unread: a live push on a card's conversation badges its button ─────
  const unread = await page.evaluate(async () => {
    const m = await import('./app/unread.js');
    m.trackUnread([]);                                   // installs the push reader
    window.__seam.chatMessage('slot:d1', { t: 1, body: 'hi' });
    window.__seam.chatMessage('slot:d1', { t: 2, body: 'still there?' });
    await new Promise(r => setTimeout(r, 250));
    const card = [...document.querySelectorAll('#sharebar .slot-card')].find(c => /bread/.test(c.querySelector('.slot-name')?.value || ''));
    const b = card?.querySelector('.slot-unread');
    return { badge: b?.textContent, unreadOf: m.unreadOf('slot:d1') };
  });
  h.rec('a message on a card\'s conversation badges its 💬 with the count',
        unread.badge === '2' && unread.unreadOf === 2, JSON.stringify(unread));

  // ── the expanded draft panel: BELOW the toolbar row, not above ───────────
  // The pill's name input doubles as the search; the panel's tabs are
  // when · where · unit · emoji (the folksonomy "type" tab is off).
  const panelState = () => page.evaluate(() => {
    const bar = document.getElementById('sharebar');
    const panel = bar.querySelector('.share-panel');
    return {
      on: !!panel && panel.classList.contains('on'),
      tab: panel?.classList.contains('on') ? bar.querySelector('.sp-body')?.title : null,
      // the panel sits BELOW the toolbar row now (in flow, above the
      // drawer's own list) — its box begins at or after the row's own bottom
      below: !!panel && panel.classList.contains('on')
             && panel.getBoundingClientRect().top >= bar.querySelector('.sharebar-row').getBoundingClientRect().bottom - 2,
      segs: [...bar.querySelectorAll('.sp-segrow')].map(row => [...row.querySelectorAll('.sp-seg')].map(s => s.textContent.trim())),
      name: bar.querySelector('.share-name').value,
      emoji: bar.querySelector('.share-emoji')?.textContent ?? null,
      togTime: bar.querySelector('.share-tog')?.classList.contains('set'),
      arcsRows: bar.querySelectorAll('.share-panel .sl-arc').length,
    };
  });
  h.rec('the panel is closed until asked', !(await panelState()).on);
  // the folksonomy is OFF and isolated from the panel: tapping or typing in the
  // name raises no strip, and the name stays a plain search
  await page.click('#sharebar .share-name'); await sleep(200);
  let ps = await panelState();
  h.rec('tapping the name opens no panel and no taxonomy strip', !ps.on && ps.segs.length === 0, JSON.stringify(ps.segs));
  await page.type('#sharebar .share-name', 'fresh'); await sleep(200);
  ps = await panelState();
  h.rec('typing in the name keeps the panel shut and the name as typed',
        !ps.on && ps.segs.length === 0 && ps.name === 'fresh', `${ps.on} · ${ps.name}`);

  // ── the dialled rhythm and place narrow the list LIVE, before any ↵ ──────
  // bread's own arc is mon/wed/fri 17:00–19:00; childcare's is tue/thu
  // 09:00–12:00; housing carries none (arcs:[] reads "anytime" — always
  // passes, the same rule `timeBy` already keeps). Dialling "weekdays
  // evenings" (mon–fri 17:00–21:00) overlaps bread, not childcare.
  await page.evaluate(() => { const n = document.querySelector('#sharebar .share-name'); n.value = ''; n.dispatchEvent(new Event('input', { bubbles: true })); });
  await page.click('#sharebar .share-name'); await sleep(200);
  await page.evaluate(() => document.querySelector('#sharebar .sp-close')?.click());
  await page.evaluate(() => document.querySelector('#sharebar .share-tog-time').click()); await sleep(200);
  await page.evaluate(() => {
    const chip = [...document.querySelectorAll('#sharebar .share-panel .sl-chip')]
      .find(c => c.textContent.trim() === 'weekdays evenings');
    chip.click();
  });
  await sleep(300);
  const rhythmFiltered = await page.evaluate(() =>
    [...document.querySelectorAll('#sharebar .share-lists .slot-card .slot-name')].map(e => e.value));
  h.rec('a dialled rhythm narrows the list to what overlaps it — bread stays, childcare (a different time) does not, housing (no rhythm) always does',
        rhythmFiltered.includes('housing') && rhythmFiltered.includes('bread') && !rhythmFiltered.includes('childcare'),
        rhythmFiltered.join('|'));
  // remove the dialled arc — the draft (and the filter riding it) empties
  await page.evaluate(() => document.querySelector('#sharebar .share-panel .sl-x')?.click());
  await sleep(300);
  const rhythmCleared = await page.evaluate(() =>
    [...document.querySelectorAll('#sharebar .share-lists .slot-card .slot-name')].map(e => e.value));
  h.rec('clearing the dialled rhythm brings every card back',
        rhythmCleared.length === 3, rhythmCleared.join('|'));
  await page.evaluate(() => document.querySelector('#sharebar .sp-close')?.click());
  await sleep(200);

  // 🕐 before adding: the time toggle opens the SAME arcs editor the card uses.
  // Names its own draft rather than riding whatever an earlier test left in
  // the pill — a dialled rhythm now filters the list live (the point of this
  // whole suite), so an EMPTY name here would make submit() bail silently.
  await page.type('#sharebar .share-name', 'evening class'); await sleep(200);
  await page.evaluate(() => document.querySelector('#sharebar .sp-close')?.click());
  await page.evaluate(() => document.querySelector('#sharebar .share-tog').click()); await sleep(200);
  ps = await panelState();
  h.rec('🕐 opens the time tab with the card\'s own arcs editor', ps.on && /time/i.test(ps.tab || ''), ps.tab);
  await page.evaluate(() => document.querySelector('#sharebar .share-panel .sl-chip').click()); await sleep(200);
  ps = await panelState();
  h.rec('a preset chip sets a rhythm on the draft and lights the toggle', ps.arcsRows === 1 && ps.togTime);
  await page.evaluate(() => document.querySelector('#sharebar .share-name').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))); await sleep(400);
  const declared = await page.evaluate(() => {
    const t = document.querySelector('#sharebar .share-lists').textContent;
    return { window: /weekdays mornings|weekdays 08:00–12:00/.test(t), t: t.slice(0, 200) };
  });
  ps = await panelState();
  h.rec('↵ declares with the draft\'s window and clears the draft',
        declared.window && !ps.togTime && ps.name === '', declared.t);
  // the mic's landing place is the Express input itself — no box of its own.
  // A TAP on the mic (not a hold) puts the caret in the name to type
  await page.evaluate(() => document.querySelector('#sharebar .share-name').blur());
  await page.click('#sbmic'); await sleep(300);
  ps = await panelState();
  h.rec('a tap on the mic puts the caret in the Express input and opens no box',
        !ps.on && await page.evaluate(() => document.activeElement === document.querySelector('#sharebar .share-name')
                                           && !document.querySelector('#sharebar .sp-text')));
  h.rec('the mic sits INSIDE the pill, at its left end',
        await page.evaluate(() => { const p = document.querySelector('#sharebar .share-pill'), m = document.querySelector('#sbmic');
          return p.contains(m) && p.firstElementChild === m; }));
  // ── the bar as omnibar: one sentence = [locus-delta] [act] (app/utter.ts) ──
  // a place the scope knows, so a typed place has somewhere to land
  await page.evaluate(async () => {
    const { EXT } = await import('./app/core.js');
    EXT.snapshot = { ...(EXT.snapshot || {}), locations: [{ id: 'p-garden', name: 'community garden', lat: 48.85, lng: 2.35 }] };
  });
  const clearName = async () => page.evaluate(() => { const n = document.querySelector('#sharebar .share-name'); n.value = ''; n.dispatchEvent(new Event('input')); });
  const readings = () => page.evaluate(() => ({
    on: document.querySelector('#sharebar .share-preview').classList.contains('on'),
    reads: [...document.querySelectorAll('#sharebar .share-read')].map(e => e.textContent),
    lit: document.querySelector('#sharebar .share-read.on')?.textContent || null,
    go: document.querySelector('#sharebar .share-preview-go')?.textContent || '',
    face: document.getElementById('main').getAttribute('data-face'),
    cards: [...document.querySelectorAll('#sharebar .share-lists .slot-card .slot-name')].map(e => e.value),
  }));
  // what is DECLARED — the slot lists themselves, not what the drawer happens to show
  const declaredCount = () => page.evaluate(async () => { const m = await import('./app/tabs/social/share.js'); return m.myNeeds().length; });
  await clearName();
  await page.evaluate(async () => { const { setFace } = await import('./app/faces.js'); setFace('time'); });
  await page.type('#sharebar .share-name', 'community garden friday 2pm'); await sleep(250);
  let rd = await readings();
  h.rec('a sentence that is only a locus reads as GO, lit, with "nothing written"',
        rd.on && /^🗺 go: 📍 community garden · 🕐 friday 14:00/.test(rd.lit || '') && /nothing written/.test(rd.go), JSON.stringify({ lit: rd.lit, go: rd.go }));
  const cardsBefore = await declaredCount();
  await page.press('#sharebar .share-name', 'Enter'); await sleep(900);
  rd = await readings();
  h.rec('↵ on a locus reading opens the map there — the name clears, no card is declared',
        rd.face === 'map' && (await declaredCount()) === cardsBefore && !rd.on
        && (await page.evaluate(() => document.querySelector('#sharebar .share-name').value)) === '',
        `face=${rd.face} declared=${await declaredCount()} (before ${cardsBefore})`);
  await page.evaluate(async () => { const { setFace } = await import('./app/faces.js'); setFace('time'); }); await sleep(300);
  await page.type('#sharebar .share-name', 'need 3 kilograms flour at the community garden'); await sleep(250);
  rd = await readings();
  h.rec('an act with an amount, a unit and a place reads as a NEED with them folded in',
        /^🌱 need · flour · 3 kilograms/.test(rd.lit || '') && /📍 community garden/.test(rd.lit || '') && /declares/.test(rd.go), rd.lit);
  h.rec('…the other readings are a tap away (offer, log, go)', rd.reads.length >= 3 && rd.reads.some(r => /🤲 offer/.test(r)) && rd.reads.some(r => /🗺 go/.test(r)), rd.reads.join(' | '));
  await page.press('#sharebar .share-name', 'Enter'); await sleep(500);
  const landed = await page.evaluate(() => {
    const c = [...document.querySelectorAll('#sharebar .share-lists .slot-card')].find(c => c.querySelector('.slot-name')?.value === 'flour');
    return c ? { qty: c.querySelector('.slot-qty')?.value, unit: c.querySelector('.slot-unit')?.textContent || c.querySelector('.slot-unit')?.value || c.querySelector('select.slot-unit')?.value, where: c.textContent } : null;
  });
  h.rec('↵ on the act declares it with the parsed amount, unit and place — the same commit',
        !!landed && landed.qty === '3' && /kilogram|kg/.test(landed.unit || '') && /community garden/.test(landed.where), JSON.stringify(landed));
  await page.type('#sharebar .share-name', '!cal'); await sleep(200);
  rd = await readings();
  h.rec('a bang names a face: "!cal" reads as OPEN calendar', /^◉ open: ◉ calendar/.test(rd.lit || ''), rd.lit);
  await page.press('#sharebar .share-name', 'Enter'); await sleep(600);
  rd = await readings();
  h.rec('…and ↵ opens it', rd.face === 'cal', rd.face);
  await page.evaluate(async () => { const { setFace } = await import('./app/faces.js'); setFace('time'); }); await sleep(300);
  await page.type('#sharebar .share-name', 'guix channels'); await sleep(200);
  rd = await readings();
  h.rec('no bang → the web is never offered', !rd.reads.some(r => /🌐/.test(r)), rd.reads.join(' | '));
  await clearName();
  // the mic's words land in the same input, so they read the same way: the
  // readings row under the bar is the verb list (go · open · search · need · offer · log)
  await page.evaluate(async () => { const { setFace } = await import('./app/faces.js'); setFace('time'); }); await sleep(300);
  await page.type('#sharebar .share-name', 'show me the plan'); await sleep(250);
  rd = await readings();
  h.rec('"show me the plan" reads as ◉ open: ◉ plan — lit, nothing written',
        /^◉ open: ◉ plan/.test(rd.lit || '') && /nothing written/.test(rd.go), JSON.stringify({ lit: rd.lit, go: rd.go }));
  await page.press('#sharebar .share-name', 'Enter'); await sleep(600);
  {
    const after = await readings(), n = await declaredCount();
    h.rec('…↵ opens the plan face, nothing declared',
          after.face === 'plan' && n === cardsBefore + 1, `face=${after.face} declared=${n} (before ${cardsBefore}+flour)`);
  }
  await page.evaluate(async () => { const { setFace } = await import('./app/faces.js'); setFace('time'); }); await sleep(300);
  await page.type('#sharebar .share-name', 'picked tomatoes at the garden'); await sleep(250);
  rd = await readings();
  h.rec('a plain sentence offers need · offer · 📓 log as readings (the old verb box, in the row)',
        rd.reads.some(r => /need/.test(r)) && rd.reads.some(r => /offer/.test(r)) && rd.reads.some(r => /📓 log/.test(r)), rd.reads.join(' | '));
  h.rec('✕ shows while the bar holds words, and empties it',
        await page.evaluate(async () => {
          const x = document.querySelector('#sharebar .share-clear'); if (x.hidden) return false;
          x.click(); await new Promise(r => setTimeout(r, 150));
          return document.querySelector('#sharebar .share-name').value === '' && document.querySelector('#sharebar .share-clear').hidden;
        }));
  await page.type('#sharebar .share-name', 'what fixes nitrogen in soil'); await sleep(250);
  rd = await readings();
  h.rec('"what fixes nitrogen in soil" reads as 🔎 search — the same verb the typed bar always read',
        /🔎/.test(rd.lit || ''), JSON.stringify({ lit: rd.lit }));
  await clearName();

  // ── the AI normalizer: over the RESIDUAL only, never a verb of its own ──
  // it may only rewrite words into more of the floor's own vocabulary; the
  // floor re-parses the rewrite, so the AI can never surface a reading the
  // deterministic parser wouldn't also produce for those words
  await page.evaluate(() => {
    window.__seam = window.__seam || {};
    window.__seam.handlers = window.__seam.handlers || {};
    window.__seam.handlers.ai = async (_system, user) => {
      // the mock "AI": nothing in "the harvest starts" is in the floor's own
      // vocabulary (no weekday, no ISO date, no known place), so it rewrites
      // the residual into a date the floor CAN read — never invents a verb,
      // never invents a quantity nobody stated
      if (/harvest starts/.test(user)) return '{"rewrite":"need bricks 2026-08-22"}';
      return '{"rewrite":null}';
    };
  });
  await clearName();
  await page.type('#sharebar .share-name', 'need bricks the day the harvest starts'); await sleep(600);
  // the floor alone finds no coordinate in this residual, so it asks the AI —
  // whose (mocked) reply lands well inside this wait
  rd = await readings();
  h.rec('the AI\'s rewrite is re-parsed by the SAME floor and marked ✨ — a real date, not invented',
        rd.reads.some(r => /^✨/.test(r) && /2026-08-22|🕐/.test(r)), rd.reads.join(' | '));
  const aiMark = await page.evaluate(() => !!document.querySelector('#sharebar .share-read.ai'));
  h.rec('…and it is visually marked apart from the deterministic readings', aiMark);
  await clearName();
  await page.type('#sharebar .share-name', 'need flour'); await sleep(300);
  rd = await readings();
  h.rec('a confidently-read sentence (known spec) never asks the AI at all',
        !rd.reads.some(r => /^✨/.test(r)), rd.reads.join(' | '));
  // ── ONE ask per sentence: the AI is a paid gateway call, asked once the
  // typing pauses, and its readings stay through every redraw of the same
  // words — a quantity edit, a rail flip — rather than being wiped and re-asked
  await clearName();
  await page.evaluate(() => {
    window.__aiAsks = 0;
    window.__seam.handlers.ai = async (_system, user) => {
      window.__aiAsks++;
      return /harvest starts/.test(user) ? '{"rewrite":"need bricks 2026-08-22"}' : '{"rewrite":null}';
    };
  });
  await page.type('#sharebar .share-name', 'need bricks once the harvest starts'); await sleep(700);
  const asksTyped = await page.evaluate(() => window.__aiAsks);
  h.rec('typing a whole sentence asks the AI ONCE, after the typing pauses', asksTyped === 1, `asked ${asksTyped}×`);
  await page.evaluate(() => document.querySelector('.share-seg.seg-offer').click()); await sleep(500);
  await page.evaluate(() => document.querySelector('.share-seg.seg-need').click()); await sleep(500);
  const asksAfter = await page.evaluate(() => window.__aiAsks);
  rd = await readings();
  h.rec('…and rail flips re-merge its readings, asking nothing more',
        asksAfter === 1 && rd.reads.some(r => /^✨/.test(r) && /bricks · \d+ /.test(r)),
        `asked ${asksAfter}× · ${rd.reads.join(' | ')}`);
  await page.evaluate(() => { delete window.__seam.handlers.ai; });
  await clearName();

  // ── a log reading says what ↵ does ─────────
  await page.type('#sharebar .share-name', 'log walked to the well'); await sleep(250);
  rd = await readings();
  h.rec('a lit log reading reads "↵ logs"', /^↵ logs/.test(rd.go), rd.go);
  await clearName();

  // ── a slot's delete is two taps: arm, then confirm; silence disarms ─────
  await page.evaluate(() => { const b = document.getElementById('sharebar'); if (!b.classList.contains('sb-open')) b.querySelector('.sharebar-handle').click(); });
  await page.evaluate(() => document.querySelector('.share-seg.seg-need').click()); await sleep(300);
  const nCards = await page.evaluate(() => document.querySelectorAll('#sharebar .slot-card').length);
  await page.evaluate(() => document.querySelector('#sharebar .slot-card .slot-btn-delete').click()); await sleep(50);
  const armed = await page.evaluate(() => { const d = document.querySelector('#sharebar .slot-card .slot-btn-delete'); return { text: d.textContent, arm: d.classList.contains('arm'), n: document.querySelectorAll('#sharebar .slot-card').length }; });
  h.rec('one tap on 🗑️ arms it ("sure?") and deletes nothing', armed.text === 'sure?' && armed.arm && armed.n === nCards, JSON.stringify(armed));
  await sleep(3200);
  const rested = await page.evaluate(() => { const d = document.querySelector('#sharebar .slot-card .slot-btn-delete'); return { text: d.textContent, arm: d.classList.contains('arm') }; });
  h.rec('…and silence disarms it', rested.text === '🗑️' && !rested.arm, JSON.stringify(rested));
  await page.evaluate(() => { const d = document.querySelector('#sharebar .slot-card .slot-btn-delete'); d.click(); d.click(); }); await sleep(300);
  const after = await page.evaluate(() => document.querySelectorAll('#sharebar .slot-card').length);
  h.rec('two taps inside the window delete the slot', after === nCards - 1, `${nCards} → ${after}`);

  // ── revealSlot (the map's tap-through) moves the SWITCH with the drawer ──
  await page.evaluate(() => document.querySelector('.share-seg.seg-need').click());
  await page.evaluate(() => import('/app/tabs/social/share.js').then(m => m.revealSlot('nothing-here', 'capacity')));
  await sleep(400);
  b = await barState();
  const revealPh = await page.evaluate(() => document.querySelector('#sharebar .share-name').placeholder);
  h.rec('revealSlot to the offer rail lights the Offers segment above the offers it shows',
        b.rail === 'offer' && b.heads.some(t => /^my offers/.test(t)) && /capacity/.test(revealPh),
        JSON.stringify({ rail: b.rail, heads: b.heads, revealPh }));
  await page.evaluate(() => document.querySelector('.share-seg.seg-need').click()); await sleep(200);

  // ── the corpus's own verb: a question routes to the corpus face ─────────
  await page.evaluate(() => {
    window.__seam = window.__seam || {};
    window.__seam.handlers = window.__seam.handlers || {};
    window.__seam.handlers.corpusSearch = async (domain, query) => JSON.stringify({
      hits: [{ domain: "permaculture", text: `a passage about ${query}`, heading: "",
               source: "test-src", title: "Test Source", author: "", score: 1 }],
    });
    window.__seam.handlers.corpusDomains = async () => JSON.stringify({ domains: ["permaculture"] });
  });
  await clearName();
  await page.type('#sharebar .share-name', 'what fixes nitrogen in soil'); await sleep(250);
  const searchRd = await readings();
  h.rec('a question reads as search, distinct from need/offer/log/go',
        /^🔎 search: fixes nitrogen in soil/.test(searchRd.lit || ''), searchRd.lit);
  await page.press('#sharebar .share-name', 'Enter'); await sleep(600);
  const corpusState = await page.evaluate(() => ({
    face: document.getElementById('main').getAttribute('data-face'),
    input: document.getElementById('cp-q')?.value,
    hitText: document.querySelector('#corpusstage .cp-hit-text')?.textContent,
  }));
  h.rec('↵ on a search reading opens the corpus face with the query already run',
        corpusState.face === 'corpus' && /fixes nitrogen in soil/.test(corpusState.input || '')
        && /fixes nitrogen in soil/.test(corpusState.hitText || ''), JSON.stringify(corpusState));
  await page.evaluate(async () => { const { setFace } = await import('./app/faces.js'); setFace('time'); }); await sleep(300);
  await clearName();

  // a raw .value='' write doesn't fire 'input', so it never clears F.query
  // (now that a programmatic pill fill moves it too — the very thing this
  // suite proved above) — dispatch, the same as every other clear in this file
  await page.evaluate(() => { const n = document.querySelector('#sharebar .share-name'); n.value = ''; n.dispatchEvent(new Event('input', { bubbles: true })); });
  await flipTo('need'); await sleep(300);
  b = await barState();

  h.rec('nothing scrolls sideways on desktop', !!b && b.overflowX === 0 && b.docOverflowX === 0,
        b && `drawer=${b.overflowX} doc=${b.docOverflowX}`);
  await page.screenshot({ path: process.env.SHOT_DESK || '/tmp/share-bar-desktop.png' });

  // the bar persists across faces
  await page.evaluate(() => document.querySelector('#face-plan')?.click());
  await sleep(500);
  b = await barState();
  h.rec('the bar rides along to the PLAN face', !!b && b.visible && b.cards.length > 0);

  // an old deep-link still lands on the drawer
  await page.goto(`${BASE}/app.html?face=share`, { waitUntil: 'domcontentloaded' });
  await sleep(1500);
  b = await barState();
  h.rec('?face=share opens the drawer instead of a face', !!b && b.open);

  // phone width: the expression takes its own line, the handle stays right
  await page.setViewportSize({ width: 390, height: 800 });
  await sleep(600);
  b = await barState();
  const onScreen = await page.evaluate(() => {
    const r = document.getElementById('sharebar').getBoundingClientRect();
    return r.top >= 0 && r.bottom <= window.innerHeight + 1 && r.height > 20;
  });
  h.rec('at phone width the bar stays visible and usable',
        !!b && b.visible && errs.length === 0, errs.slice(0, 2).join(' | '));
  h.rec('…pinned inside the phone viewport (sticky footer)', onScreen);
  h.rec('…the handle is still at the right', !!b && b.handleAtRight);
  h.rec('…and nothing scrolls sideways', !!b && b.overflowX === 0 && b.docOverflowX === 0,
        b && `drawer=${b.overflowX} doc=${b.docOverflowX}`);
  // the two switches read as ONE phrase at this width — the words are the meaning
  const ph = await page.evaluate(() => {
    const bar = document.getElementById('sharebar');
    const sel = bar.querySelector('.share-phrase');
    return { shown: getComputedStyle(sel).display !== 'none',
             railsHidden: [...bar.querySelectorAll('.share-rail')].every(r => getComputedStyle(r).display === 'none'),
             reads: sel.options[sel.selectedIndex].textContent,
             options: [...sel.options].map(o => o.textContent) };
  });
  h.rec('…the two switches read as one phrase ("My Needs") in place of four bare glyphs',
        ph.shown && ph.railsHidden && /^My (Needs|Offers)$/.test(ph.reads)
        && ph.options.join(',') === 'My Needs,My Offers,Our Needs,Our Offers', JSON.stringify(ph));
  await page.selectOption('#sharebar .share-phrase', 'social:capacity'); await sleep(300);
  const phAfter = await page.evaluate(() => ({
    lit: document.querySelector('#sharebar .share-seg.seg-social').classList.contains('on'),
    rail: document.querySelector('#sharebar .share-seg.seg-offer').classList.contains('on'),
    head: [...document.querySelectorAll('#sharebar .share-lists .share-h')].map(e => e.textContent.trim()).join('|') }));
  h.rec('…and picking "Our Offers" moves both switches', phAfter.lit && phAfter.rail && /^our offers/.test(phAfter.head), JSON.stringify(phAfter));
  await page.screenshot({ path: process.env.SHOT_MOB || '/tmp/share-bar-mobile.png' });
  h.info(`screenshots: ${process.env.SHOT_DESK || '/tmp/share-bar-desktop.png'} · ${process.env.SHOT_MOB || '/tmp/share-bar-mobile.png'}`);
} catch (e) { h.rec('fatal', false, e.message); }
finally { await browser.close(); closeServer(); }

summarize(h, ['the bar exists on load, collapsed, closing #app’s column']);
