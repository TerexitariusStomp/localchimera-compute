/// tests/ux/feedback-ux.mjs — the FEEDBACK lane: tier 1 of the issue flow.
///
/// A visitor with no account says what they think of the interface, points at
/// the parts they mean, and sends. The lane is layout chrome, so it rides on
/// every face; the pointing mode names an element and drops a [n] marker in
/// the prose; a chip taps back to flash what it refers to; the draft survives
/// a reload; and the body that leaves the page carries the text, the refs and
/// the device context the pool needs to be worth reading.
///
/// The POST is intercepted rather than served: ux-serve.mjs is a static file
/// server (the real endpoint lives in serve-static.scm, covered by
/// tests/server/test-feedback-endpoint.scm). What this suite owns is the
/// BODY the browser builds and the behaviour around it.
///
/// Run via: make test-feedback-ux
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
// the 💬 button shows once feedback is switched on (account sheet, settings → feedback and developer)
await page.addInitScript(() => localStorage.setItem('pn.prefs', JSON.stringify({ feedbackMode: true })));
page.on('pageerror', e => h.errs.push(String(e).slice(0, 160)));

// Catch the submit without a server: the route never reaches ux-serve.
let posted = null;
await page.route('**/feedback', async route => {
  posted = route.request().postData();
  await route.fulfill({ status: 200, contentType: 'application/json',
                        body: JSON.stringify({ ok: true, id: 'fb-test-1' }) });
});

try {
  // opened the way `make serve` prints it: the gateway sturdyref in the query
  const CAP = 'ocapn://qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq.websocket'
            + '/s/rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr';
  await page.goto(`${BASE}/app.html?face=time&gateway=${encodeURIComponent(CAP)}`,
                  { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#sharebar .sharebar-row', { timeout: 30000 });

  // ── the lane mounts, on the bar, closed ────────────────────────────
  h.rec('the feedback button rides in the share bar row',
        await page.evaluate(() => {
          const row = document.querySelector('#sharebar .sharebar-row');
          const btn = document.querySelector('#fbbtn');
          return !!row && !!btn && row.contains(btn);
        }));
  // closed/open is a class the lane's signal toggles; CSS answers it
  h.rec('the panel starts closed',
        await page.$eval('#fbpanel', el => !el.classList.contains('on')
                                        && getComputedStyle(el).display === 'none'));

  await page.click('#fbbtn');
  h.rec('the button opens the panel',
        await page.$eval('#fbpanel', el => el.classList.contains('on')
                                        && getComputedStyle(el).display !== 'none'));
  h.rec('opening marks the button on',
        await page.$eval('#fbbtn', el => el.classList.contains('on')));
  h.rec('the panel carries the tools: point, attach, send',
        await page.evaluate(() => {
          const p = document.querySelector('#fbpanel');
          return !!p.querySelector('.fb-text') && !!p.querySelector('.fb-send')
                 && p.querySelectorAll('.fb-tool').length === 2;
        }));
  const [chooser] = await Promise.all([
    page.waitForEvent('filechooser', { timeout: 5000 }).catch(() => null),
    page.click('#fbpanel .fb-tool[title^="attach a screenshot"]'),
  ]);
  h.rec('attach opens the file chooser, for an image', !!chooser);
  // ONE mic in the bar, not two: the panel grows no mic of its own, and the
  // footer's universal mic is what speaks into it while it is open.
  h.rec('the panel grows no second mic',
        await page.$eval('#fbpanel', el => !el.querySelector('button[class*=mic]')
                                        && !el.textContent.includes('🎙')));
  h.rec('the bar still carries exactly one mic',
        await page.$$eval('#sharebar button', els =>
          els.filter(e => e.textContent.includes('🎙')).length === 1));
  h.rec('the panel says the feedback is anonymous',
        await page.$eval('.fb-note', el => /anonymous/i.test(el.textContent)));

  // ── the footer mic speaks in here while the panel is open ──────────
  // pressToSpeak needs a real hold + real audio, so drive the seam the mic
  // drives: the claimed voice sink. What is asserted is the ROUTING — that
  // the one bar mic reaches the feedback draft rather than the slots draft.
  h.rec('the footer mic is routed to the feedback draft while it is open',
        await page.evaluate(async () => {
          const { voiceSink } = await import('/app/voice/sink.js');
          const sink = voiceSink();
          if (!sink) return false;
          sink.hear('spoken words', false);
          return document.querySelector('.fb-text').value.includes('spoken words');
        }));
  h.rec('a live caption reads as provisional, and is replaced on release',
        await page.evaluate(async () => {
          const { voiceSink } = await import('/app/voice/sink.js');
          const ta = document.querySelector('.fb-text');
          voiceSink().hear('half a sen', true);
          const live = ta.classList.contains('live') && ta.value.includes('…');
          voiceSink().hear('half a sentence', false);
          return live && !ta.classList.contains('live')
                 && ta.value.includes('half a sentence') && !ta.value.includes('half a sen …');
        }));
  await page.evaluate(() => { document.querySelector('.fb-text').value = ''; });

  // ── typing, and pointing at an element ─────────────────────────────
  await page.type('.fb-text', 'the wheel is hard to read at night, and ');
  await page.click('.fb-tool >> nth=0');            // 👆 point
  h.rec('pointing arms the page as a target',
        await page.$eval('body', el => el.classList.contains('fb-picking')));

  // The scope pill inside the crumb: a real element with a real ancestor, so
  // the selector has to carry a chain rather than a bare id. A click lands on
  // the INNERMOST element at that point (here the pill's label span, not the
  // pill), which is the element the reference must name — so the test asks
  // the page what is actually under the click rather than assuming a depth.
  await page.evaluate(() => {
    const pill = document.querySelector('#crumb .scopepill');
    const r = pill.getBoundingClientRect();
    window.__aimed = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
  });
  await page.click('#crumb .scopepill');
  await sleep(120);
  h.rec('pointing at an element leaves the picking mode',
        await page.$eval('body', el => !el.classList.contains('fb-picking')));
  h.rec('the reference becomes a chip',
        await page.$$eval('.fb-chip', els => els.length === 1));
  h.rec('the chip names the element pointed at, not its container',
        await page.evaluate(() =>
          document.querySelector('.fb-chip').textContent
            .includes(window.__aimed.classList.item(0))));
  h.rec('a [n] marker lands in the prose at the cursor',
        await page.$eval('.fb-text', el => /\[1\]/.test(el.value)));

  // The property the whole reference rests on: the stored selector finds the
  // element that was pointed at, and no other.
  h.rec('the stored selector resolves back to exactly that element',
        await page.evaluate(() => {
          const d = JSON.parse(localStorage.getItem('pn.feedback.draft') || '{}');
          const sel = d.refs && d.refs[0] && d.refs[0].sel;
          if (!sel) return false;
          const found = document.querySelectorAll(sel);
          return found.length === 1 && found[0] === window.__aimed;
        }));
  h.rec('the reference reaches down through the crumb, so it carries a chain',
        await page.evaluate(() => {
          const d = JSON.parse(localStorage.getItem('pn.feedback.draft') || '{}');
          return d.refs[0].sel.startsWith('#crumb >') && d.refs[0].face === 'time';
        }));

  // a second reference numbers itself
  await page.click('.fb-tool >> nth=0');
  await page.click('#sbmic');
  await sleep(120);
  h.rec('a second reference numbers itself [2]',
        await page.evaluate(() => {
          const chips = [...document.querySelectorAll('.fb-chip')].map(c => c.textContent);
          const ta = document.querySelector('.fb-text');
          return chips.length === 2 && chips[1].includes('[2]') && /\[2\]/.test(ta.value);
        }));

  // ── a chip taps back to the element ────────────────────────────────
  await page.click('.fb-chip >> nth=0');
  h.rec('tapping a chip flashes the element it refers to',
        await page.evaluate(() => window.__aimed.classList.contains('pn-flash')));
  await sleep(1800);
  h.rec('the flash clears itself',
        await page.evaluate(() => !window.__aimed.classList.contains('pn-flash')));

  // ── the draft survives a reload ────────────────────────────────────
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#fbbtn', { timeout: 30000 });
  await page.click('#fbbtn');
  h.rec('the draft text survives a reload',
        await page.$eval('.fb-text', el => el.value.includes('hard to read at night')));
  h.rec('the references survive a reload',
        await page.$$eval('.fb-chip', els => els.length === 2));

  // ── dropping a reference ───────────────────────────────────────────
  // the chip and its [n] marker are one reference in two places
  await page.click('.fb-chip >> nth=1 >> .fb-chip-x');
  h.rec('a chip can be dropped',
        await page.$$eval('.fb-chip', els => els.length === 1));
  h.rec('dropping a chip takes its marker out of the prose too',
        await page.$eval('.fb-text', el => !/\[2\]/.test(el.value) && /\[1\]/.test(el.value)));

  // A number may be reused once its chip is gone — what must hold is that
  // the LIVE references stay distinct and every marker in the prose has a
  // chip. Re-point after dropping [2] and the prose must not end up with two
  // markers naming different things.
  await page.click('.fb-tool >> nth=0');
  await page.click('#sbmic');
  await sleep(120);
  h.rec('live reference numbers stay distinct, and every marker has a chip',
        await page.evaluate(() => {
          const chips = [...document.querySelectorAll('.fb-chip')];
          const nums = chips.map(c => Number(c.textContent.match(/\[(\d+)\]/)[1]));
          const marks = [...document.querySelector('.fb-text').value
                           .matchAll(/\[(\d+)\]/g)].map(m => Number(m[1]));
          const distinct = new Set(nums).size === nums.length;
          const paired = marks.every(m => nums.includes(m))
                      && nums.every(n => marks.includes(n));
          return chips.length === 2 && distinct && paired;
        }));
  await page.click('.fb-chip >> nth=1 >> .fb-chip-x');

  // ── the diagnostic: offered, readable, and off unless asked for ────
  h.rec('the diagnostic is offered, with a count of what it holds',
        await page.$eval('.fb-diag-ask', el => /attach what the page said/.test(el.textContent)
                                             && /\d+ lines/.test(el.textContent)));
  h.rec('…and nothing is attached until it is asked for',
        await page.evaluate(() => !document.querySelector('.fb-diag')
                                && !document.querySelector('.fb-diag-ask input').checked));
  // an error the page really threw must be in the ring and countable
  await page.evaluate(() => { setTimeout(() => { throw new Error('kaboom-probe'); }, 0); });
  await sleep(150);
  await page.click('.fb-diag-ask input');
  h.rec('asking for it shows the actual lines, to be read before sending',
        await page.$eval('.fb-diag', el => el.textContent.length > 0));
  h.rec('an uncaught error is in the ring, and counted as a fault',
        await page.evaluate(() =>
          document.querySelector('.fb-diag').textContent.includes('kaboom-probe')
          && /error|errors/.test(document.querySelector('.fb-diag-ask').textContent)));

  // ── send ───────────────────────────────────────────────────────────
  await page.click('.fb-send');
  await sleep(400);
  h.rec('sending POSTs a body', !!posted);
  const body = posted ? JSON.parse(posted) : {};
  h.rec('the body carries the prose',
        typeof body.text === 'string' && body.text.includes('hard to read at night'));
  h.rec('the body carries the surviving reference, with its selector and label',
        Array.isArray(body.refs) && body.refs.length === 1
        && body.refs[0].n === 1
        && body.refs[0].sel.startsWith('#crumb >')
        && typeof body.refs[0].label === 'string' && body.refs[0].label.length > 0
        && body.refs[0].face === 'time');
  h.rec('the body carries the face and the path',
        body.face === 'time' && typeof body.path === 'string' && body.path.includes('app.html'));
  // the dial's own documented local flow is ?gateway=<sturdyref>, so the URL
  // is a live route for the very capability the ring is scrubbed of
  h.rec('a capability in the URL does not ride out in the path',
        !/ocapn:\/\/[^\s]*\/s\/[A-Za-z0-9_-]{20,}/.test(body.path)
        && !/[A-Za-z0-9_-]{32,}/.test(body.path), String(body.path).slice(0, 100));
  h.rec('the body carries the device context',
        typeof body.vw === 'number' && typeof body.vh === 'number'
        && typeof body.dpr === 'number' && typeof body.ua === 'string'
        && body.ua.length > 0 && typeof body.lang === 'string');
  h.rec('the body carries no screenshot when none was attached',
        body.shot === undefined);
  h.rec('the body carries the diagnostic that was asked for',
        typeof body.diag === 'string' && body.diag.includes('kaboom-probe'));
  // the dial logs its OCapN sturdyref while booting; a bearer capability must
  // not ride out on anonymous feedback
  h.rec('no bearer capability rides out with the diagnostic',
        !/ocapn:\/\/[^\s"']*\/s\/[A-Za-z0-9_-]{20,}/.test(String(body.diag) + String(body.boot)),
        String(body.boot).slice(0, 90));
  h.rec('…and no long secret-shaped token either',
        !/[A-Za-z0-9_-]{32,}/.test(String(body.diag) + String(body.boot)));
  h.rec('the reference carries its enclosure, for finding the code',
        typeof body.refs[0].within === 'string');
  h.rec('the body fits the pool\'s cap',
        posted.length < 262144, `${posted.length} bytes`);

  // ── after a send ───────────────────────────────────────────────────
  h.rec('sending clears the draft',
        await page.evaluate(() => {
          const ta = document.querySelector('.fb-text');
          return ta.value === '' && document.querySelectorAll('.fb-chip').length === 0;
        }));
  h.rec('sending closes the panel',
        await page.$eval('#fbpanel', el => !el.classList.contains('on')
                                        && getComputedStyle(el).display === 'none'));
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#fbbtn', { timeout: 30000 });
  await page.click('#fbbtn');
  h.rec('a sent draft does not come back on reload',
        await page.$eval('.fb-text', el => el.value === ''));

  // ── an empty send is refused ───────────────────────────────────────
  posted = null;
  await page.click('.fb-send');
  await sleep(250);
  h.rec('an empty feedback is not sent', posted === null);

  // the probe error above is deliberate; anything else is not
  const unexpected = h.errs.filter(e => !e.includes('kaboom-probe'));
  h.rec('no page errors', unexpected.length === 0, unexpected.join(' | '));
} catch (e) {
  h.rec('fatal', false, e.message);
} finally {
  await browser.close();
  await closeServer();
}

summarize(h);
