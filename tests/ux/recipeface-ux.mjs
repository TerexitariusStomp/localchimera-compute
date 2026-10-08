/// tests/ux/recipeface-ux.mjs — the recipes face (?face=recipes): the scope's
/// recipe library, each card carrying its computed barbell standing (the
/// fragile/robust/antifragile triad, docs/planning/solve/recipe-metabolism-barbell.md)
/// beside its steps, and a door to suggest a recipe — the SAME builder the
/// web face writes drafts with (web-draft.ts), so there is one way to write
/// one, not two. Static demo data — no gateway, so every recipe reads "not
/// yet run" (nothing to compute a character from).
///
/// Run via: make test-recipeface-ux
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
page.on('pageerror', e => h.errs.push(String(e).slice(0, 160)));

const tap = (sel) => page.evaluate(s => {
  const el = document.querySelector(s);
  if (!el) return false;
  el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
  return true;
}, sel);
const count = (sel) => page.$$eval(sel, els => els.length);
const type = (sel, value) => page.evaluate(([s, v]) => {
  const el = document.querySelector(s); if (!el) return false;
  el.value = v; el.dispatchEvent(new Event('input', { bubbles: true })); return true;
}, [sel, value]);

try {
  await page.goto(`${BASE}/app.html?face=recipes`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#recipesstage .rc-card', { timeout: 30000 });

  h.rec('the library lists the demo recipes', (await count('#recipesstage .rc-card')) >= 3);
  h.rec('a card names a real recipe (Cooked meal)',
        await page.$eval('#recipesstage', el => el.textContent.includes('Cooked meal')));
  h.rec('a card draws its steps\' flows', (await count('#recipesstage .rc-step')) >= 3);

  // no gateway ⇒ no observed runs of ITS OWN ⇒ a recipe with no demo-authored
  // runs reads "not yet run", never a guessed response. Three demo recipes DO
  // carry hand-authored runs (standing in for a scope that has actually run
  // them) — the mix is the realistic baseline, not the degenerate all-empty one.
  h.rec('a recipe with no observed runs reads "not yet run" rather than guessing a response',
        (await count('#recipesstage .rc-standing-none')) >= 3);
  h.rec('…and one that has run under stress is observed, however few its runs',
        (await count('#recipesstage .rc-pos-observed')) >= 3
        && (await count('#recipesstage .rc-pos-experimental')) === 0);
  h.rec('…each flow says how far its record reaches',
        await page.$eval('#recipesstage .rc-chan-reach', el => /proven to stress \d/.test(el.textContent)));

  // THE RESPONSE IS PROPORTIONAL: a recipe delivers what its own record shows
  // at the stress live right now, and says how much — no gate, no cap
  h.rec('a recipe whose record breaks under the heat live now says what it delivers: 40%',
        await page.evaluate(() => {
          const card = [...document.querySelectorAll('#recipesstage .rc-card')].find(e => e.textContent.includes('Waste management'));
          return /delivers 40% of what the weather allows/.test(card.querySelector('.rc-yield')?.textContent || '');
        }));
  h.rec('…one that slips a little says so in its own proportion, and wears a paler pill',
        await page.evaluate(() => {
          const pill = (name) => [...document.querySelectorAll('#recipesstage .rc-card')].find(e => e.textContent.includes(name)).querySelector('.rc-yield');
          const meal = pill('Cooked meal'), waste = pill('Waste management');
          const strain = (el) => +el.style.getPropertyValue('--strain');
          return /delivers 8\d% /.test(meal.textContent) && strain(meal) < strain(waste);
        }));
  h.rec('nothing is quarantined and nothing is capped', (await count('#recipesstage .rc-pos-quarantined, #recipesstage .rc-cap')) === 0);

  // a stressor is more than its word: opened, it shows the runs the curve was
  // read from — the chart, the bend in words, each run's own log
  h.rec('a stressor starts collapsed', (await count('#recipesstage details.rc-chan[open]')) === 0);
  const heatChan = await page.evaluateHandle(() =>
    [...document.querySelectorAll('#recipesstage details.rc-chan')].find(e => e.textContent.includes('produce · compost')));
  await page.evaluate(el => { el.open = true; }, heatChan);
  await sleep(100);
  h.rec('opening it draws the chart, one dot per run', await page.evaluate(el =>
    el.querySelectorAll('.rc-spark circle').length === 5, heatChan));
  h.rec('…and lists each run\'s own stress and captured value',
        await page.evaluate(el => /stress 2.*captured 90%/.test(el.textContent.replace(/\s+/g, ' ')), heatChan));
  h.rec('…the curve reads fragile — the same red as the pill, not the robust grey',
        await page.evaluate(el => getComputedStyle(el.querySelector('.rc-spark-line')).stroke === 'rgb(168, 69, 90)', heatChan));
  // the curve is the record itself: it passes THROUGH every reading, never beside it
  h.rec('…the curve the plan reads passes through every run\'s dot',
        await page.evaluate(el => {
          const dots = [...el.querySelectorAll('.rc-spark circle')].map(c => [+c.getAttribute('cx'), +c.getAttribute('cy')]);
          const p = [...el.querySelector('.rc-spark-line').getAttribute('d').matchAll(/[ML]([\d.-]+),([\d.-]+)/g)].map(m => [+m[1], +m[2]]);
          return p.length === dots.length && dots.every(([x, y], i) => Math.abs(p[i][0] - x) < 0.6 && Math.abs(p[i][1] - y) < 0.6);
        }, heatChan));
  h.rec('…past the record it is continued, dashed, and keeps falling',
        await page.evaluate(el => {
          const b = el.querySelector('.rc-spark-beyond');
          const p = [...b.getAttribute('d').matchAll(/[ML]([\d.-]+),([\d.-]+)/g)].map(m => [+m[1], +m[2]]);
          return getComputedStyle(b).strokeDasharray !== 'none' && p[1][0] > p[0][0] && p[1][1] > p[0][1];   // y grows downward
        }, heatChan));
  // the word is read off three stress levels: the line between the outer two, and the gap to the middle
  h.rec('…the three levels the word was read off are drawn: the straight line, and the gap to the middle run',
        await page.evaluate(el => {
          const pts = (n) => [...n.getAttribute('d').matchAll(/[ML]([\d.-]+),([\d.-]+)/g)].map(m => [+m[1], +m[2]]);
          const chord = pts(el.querySelector('.rc-spark-chord')), gap = pts(el.querySelector('.rc-spark-gap'));
          const onChord = chord[0][1] + (chord[1][1] - chord[0][1]) * (gap[0][0] - chord[0][0]) / (chord[1][0] - chord[0][0]);
          // the gap starts on the line and ends ABOVE it (smaller y): the recipe held more than proportion
          return Math.abs(gap[0][0] - gap[1][0]) < 0.1 && Math.abs(gap[0][1] - onChord) < 0.6 && gap[1][1] < gap[0][1] - 5;
        }, heatChan));
  h.rec('…and the note says it in words: held, then fell faster, by how much and over which stress',
        await page.evaluate(el => /held, then fell faster — at stress \d+, \d+(\.\d+)? points above the line from stress 2 to 9/
          .test(el.querySelector('.rc-fit').textContent.replace(/\s+/g, ' ')), heatChan));
  const droughtChan = await page.evaluateHandle(() =>
    [...document.querySelectorAll('#recipesstage details.rc-chan')].find(e => e.textContent.includes('produce · vegetables')));
  await page.evaluate(el => { el.open = true; }, droughtChan);
  await sleep(100);
  h.rec('two stress levels: a curve the plan already reads, and no word for its bend yet',
        await page.evaluate(el => el.querySelectorAll('.rc-spark circle').length === 2
                                   && el.querySelectorAll('.rc-spark-line').length >= 1
                                   && el.querySelectorAll('.rc-spark-chord').length === 0
                                   && /2 of the 3 stress levels a bend is read off/.test(el.querySelector('.rc-fit').textContent), droughtChan));

  // the observer log itself: each run is its OWN nested disclosure — the
  // date, then (opened) the raw claim the curve traces back to
  h.rec('each run in the stressor is a collapsed disclosure, one per run',
        await page.evaluate(el => el.querySelectorAll('.rc-chan-runs details.rc-run').length === 5, heatChan));
  h.rec('a run names its own day, closed',
        await page.evaluate(el => {
          const r = el.querySelector('.rc-chan-runs details.rc-run');
          return !r.open && /2026-08-12/.test(r.querySelector('summary').textContent);
        }, heatChan));
  await page.evaluate(el => { el.querySelector('.rc-chan-runs details.rc-run').open = true; }, heatChan);
  await sleep(100);
  h.rec('opening it shows the exact claim observed-capture divided to get its 90%',
        await page.evaluate(el => {
          const body = el.querySelector('.rc-chan-runs details.rc-run .rc-run-body').textContent.replace(/\s+/g, ' ');
          return /work · composting/.test(body) && /of 1\.5 claimed/.test(body) && /\(90%\)/.test(body);
        }, heatChan));

  h.rec('the panel names the library', await page.$eval('#recipespanel', el => /recipe/.test(el.textContent)));

  // ── suggesting a recipe: the builder opens, edits the SAME draft the web
  // face would propose, and a draft card appears in the stage marked as one
  h.rec('no draft open at the start', (await count('#rc-draftmount.is-open')) === 0);
  await tap('.rc-suggest');
  await sleep(150);
  h.rec('suggesting opens the builder in the rail', (await count('#rc-draftmount.is-open')) === 1);
  h.rec('a fresh draft card appears in the stage, marked as one',
        (await count('#recipesstage .rc-card-draft')) === 1);

  await type('#rc-draftmount .wd-name', 'Mended chair');
  await sleep(100);
  h.rec('typing a name updates the draft card',
        await page.$eval('#recipesstage .rc-card-draft', el => el.textContent.includes('Mended chair')));

  // arm the seed step's outputs and add a good by name — the form path works
  // with no web graph present to tap goods on (recipes.ts has no graph)
  await tap('#rc-draftmount .wd-arm[data-side="out"]');
  await type('#rc-draftmount .wd-ng', 'mended-chair');
  await tap('#rc-draftmount .wd-ng-add');
  await sleep(100);
  h.rec('a good added by name joins the armed step\'s flows',
        await page.$eval('#recipesstage .rc-card-draft', el => el.textContent.includes('mended-chair')));

  h.rec('the propose button reaches the forum door (kept offline, or proposed)', !!(await page.$('#rc-draftmount .wd-propose')));
  await tap('#rc-draftmount .wd-propose');
  await sleep(300);
  h.rec('the outcome reads back on the draft card',
        await page.$eval('#recipesstage .rc-card-draft', el => /kept|proposed|err/.test(el.textContent)));

  // ── deleting the draft closes it out everywhere
  await tap('#recipesstage .rc-drop-draft');
  await sleep(100);
  h.rec('deleting the draft drops its card', (await count('#recipesstage .rc-card-draft')) === 0);
  h.rec('…and closes the builder', (await count('#rc-draftmount.is-open')) === 0);

  h.rec('the real library is undisturbed by the draft\'s round trip',
        (await count('#recipesstage .rc-card')) >= 3
        && await page.$eval('#recipesstage', el => el.textContent.includes('Cooked meal')));

  // ── a populated standing: fed through the library's own door (recipe-graph.js),
  // the SAME shape service.scm/day-boot.scm put on the wire — never baked into
  // the demo, since the point is that it is READ, not authored
  await page.evaluate(async () => {
    const m = await import('/app/recipe-graph.js');
    const curve = (ps) => ps.map(([s, c]) => ({ s: String(s), c: String(c) }));   // day-boot writes numbers as strings
    m.setRecipes([{ id: 'rp-kiln', name: 'Lime kiln', emoji: '🔥', produces: 'quicklime', need: 'rest/shelter',
      standing: 'observed', yield: '0.3',
      profile: [{ channel: 'produce · quicklime', word: 'fragile', n: '5', confident: false,
                  curve: curve([[0, 100], [2, 98], [4, 90], [6, 70], [8, 30]]),
                  bend: { kind: 'harm', gap: '25', from: '0', at: '4', to: '8' } },
                { channel: 'consume · limestone', word: 'proportional', n: '6', confident: true, accel: '-0.3', se: '0.2',
                  curve: curve([[1, 90], [5, 70], [9, 50]]), bend: { kind: '', gap: '0', from: '0', at: '0', to: '0' } }],
      steps: [{ name: 'Calcine', hours: 3,
                in: [{ spec: 'limestone', q: 100, u: 'kg', action: 'consume', emoji: '🪨' }],
                out: [{ spec: 'quicklime', q: 56, u: 'kg', action: 'produce', primary: true, emoji: '⚪' }] }] }]);
  });
  await sleep(300);
  h.rec('off the wire, a recipe says what it delivers under the weather live now',
        await page.$eval('#recipesstage .rc-yield', el => /delivers 30% /.test(el.textContent)));
  h.rec('…one stressor per word shown, the bend in points of capture',
        (await count('#recipesstage .rc-chan.rc-cls-fragile')) === 1
        && (await count('#recipesstage .rc-chan.rc-cls-proportional')) === 1
        && await page.$eval('#recipesstage .rc-cls-fragile summary', el => el.textContent.includes('−25 pts')));
  h.rec('…harm in proportion has its own word, and no bend is claimed of it',
        await page.$eval('#recipesstage .rc-chan.rc-cls-proportional', el =>
          !el.querySelector('summary .rc-k') && /moves with the stress, in proportion/.test(el.textContent)));
  h.rec('…a probability-free reading carries no statistic',
        await page.$eval('#recipesstage .rc-cls-fragile', el => !el.textContent.includes('±')));
  h.rec('…a licensed regime\'s reading does',
        await page.$eval('#recipesstage .rc-cls-proportional', el => el.textContent.includes('±')));

  // THE UNTRIED MARGIN: beside a tried recipe for the same output, an untried
  // one is bounded — the plan holds every need without it
  await page.evaluate(async () => {
    const m = await import('/app/recipe-graph.js');
    m.setRecipes([{ id: 'rp-new-kiln', name: 'Shaft kiln', emoji: '🔥', produces: 'quicklime', need: 'rest/shelter',
      standing: 'observed', margin: 'bounded', yield: '1',
      profile: [{ channel: 'work · burning', word: 'unobserved', n: '2', confident: false,
                  curve: [{ s: '0', c: '100' }, { s: '3', c: '90' }], bend: { kind: '', gap: '0', from: '0', at: '0', to: '0' } }],
      steps: [] },
    { id: 'rp-pit-kiln', name: 'Pit kiln', emoji: '🕳️', produces: 'charcoal', need: 'rest/shelter',
      standing: 'experimental', margin: 'bare', yield: '1',
      profile: [{ channel: 'work · burning', word: 'unobserved', n: '2', confident: false,
                  curve: [{ s: '0', c: '100' }], bend: { kind: '', gap: '0', from: '0', at: '0', to: '0' } }],
      steps: [] }]);
  });
  await sleep(300);
  h.rec('a recipe beside one that has met heavier stress says needs rest on the longer record first',
        await page.$eval('#recipesstage .rc-margin-bounded', el => /needs rest on a longer record first/.test(el.textContent)));
  h.rec('a recipe whose runs were all calm is experimental, and says the need rests on it',
        (await count('#recipesstage .rc-pos-experimental')) === 1
        && await page.$eval('#recipesstage .rc-margin-bare', el => /the need rests on it/.test(el.textContent))
        && await page.$$eval('#recipesstage .rc-chan-reach', els => els.some(el => /calm runs only/.test(el.textContent))));

  h.rec('no page errors', h.errs.length === 0, h.errs.join(' | '));
} catch (e) {
  h.rec('suite ran to the end', false, String(e).slice(0, 200));
} finally {
  await browser.close();
  await closeServer();
}
summarize(h);
