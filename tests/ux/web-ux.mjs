/// tests/ux/web-ux.mjs — the web face: the selected scope's recipes as ONE graph
/// with its cycles kept. Sectors start folded (one dashed node each) and open
/// in place on a tap, into a dashed hull of their processes; the hull's name
/// folds them back. A tap on a good traces it — everything upstream and
/// downstream lit, the rest faded. The rail lists the open ends (goods the
/// scope reaches for and no recipe here accounts for), heaviest flow first;
/// tapping one opens the sectors that touch it and selects it on the web.
/// Static demo data — no gateway.
///
/// Run via: make test-web-ux
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
await page.setViewportSize({ width: 1280, height: 800 });
page.on('pageerror', e => h.errs.push(String(e).slice(0, 160)));

// a tap on an svg node: d3 listens through addEventListener, so a bubbling
// click reaches its handler; the handler stops it short of the stage's own
const tap = (sel) => page.evaluate(s => {
  const el = document.querySelector(s);
  if (!el) return false;
  el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
  return true;
}, sel);
const count = (sel) => page.$$eval(sel, els => els.length);
// the rail starts shut on this face, so the builder's fields are driven by dispatch too
const type = (sel, value) => page.evaluate(([s, v]) => {
  const el = document.querySelector(s); if (!el) return false;
  el.value = v; el.dispatchEvent(new Event('input', { bubbles: true })); return true;
}, [sel, value]);

try {
  // the face opens plain (every process in view) in the reactions drawing; the
  // suite starts from there, then turns the folksonomy fold on to exercise it
  await page.goto(`${BASE}/app.html?face=web`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#webstage svg g.wb-node', { timeout: 30000 });
  await sleep(400);
  h.rec('the face opens drawing arrows and reactions together', await page.$eval('#webhead .wb-tg[data-mode="both"]', el => el.classList.contains('is-on')));
  const markers = (sel) => page.$$eval(sel, els => els.map(e => getComputedStyle(e).markerEnd));
  h.rec('…each reaction a bundle over its hull, with an arrowhead where a product lands',
        (await count('#webstage .wb-edge')) >= 10
        && (await markers('#webstage .wb-link.wb-produce')).every(m => m.includes('wb-arrow'))
        && (await markers('#webstage .wb-link.wb-consume')).every(m => m === 'none'));
  h.rec('…with no sector folded: every process in view', (await count('#webstage .wb-node.wb-sector')) === 0 && (await count('#webstage .wb-node.wb-proc')) >= 10);
  h.rec('…and no cut toggle shown while sectors are off', (await count('#webhead .wb-cut')) === 0);
  await page.click('#webhead .wb-tg[data-mode="arrows"]');
  await page.click('#webhead .wb-tg[data-mode="sectors"]');
  await sleep(300);
  await page.waitForSelector('#webstage svg g.wb-node', { timeout: 30000 });
  await sleep(600);   // the force layout settles its first frames
  h.rec('the web face takes the stage',
        await page.$eval('#webface', el => el.classList.contains('on') && getComputedStyle(el).display !== 'none'));

  const head = await page.$eval('#webhead', el => el.textContent);
  h.rec('the head counts processes, goods, loops and open ends',
        /\d+ processes/.test(head) && /\d+ goods/.test(head) && /loops? closed/.test(head) && /open ends?/.test(head));

  // every sector starts folded: one dashed node per sector, no process drawn
  const sectors = await count('#webstage .wb-node.wb-sector');
  h.rec('sectors start folded, one node each (≥ 3)', sectors >= 3, `${sectors} sectors`);
  h.rec('no process is drawn while every sector is folded', (await count('#webstage .wb-node.wb-proc')) === 0);
  h.rec('no hull is drawn while every sector is folded', (await count('#webstage .wb-hull')) === 0);

  // the boundary shows through the fold: the open ends are drawn dashed
  const holesDrawn = await count('#webstage .wb-node.is-hole');
  h.rec('open ends draw as dashed holes on the web', holesDrawn >= 1, `${holesDrawn}`);
  const holeRows = await page.$$eval('#webpanel .wb-hole', els => els.map(e => e.textContent));
  // an explicit hole is a process: folded into its sector until the sector opens, listed on the rail regardless
  const explicitRows = holeRows.filter(t => t.includes('Waste management')).length;
  h.rec('the rail lists the open ends to map, the declared hole among them',
        explicitRows === 1 && holeRows.length === holesDrawn + explicitRows, `${holeRows.length} rows vs ${holesDrawn} drawn + ${explicitRows} declared`);
  h.rec('water is an open end of the demo scope (consumed, made nowhere here)',
        holeRows.some(t => t.includes('water') && t.includes('from outside')));
  const flows = await page.$$eval('#webpanel .wb-hole .wb-h-flow', els => els.map(e => parseFloat(e.textContent) || 0));
  h.rec('open ends are ranked heaviest flow first',
        flows.every((v, i) => i === 0 || flows[i - 1] >= v), flows.join(' ≥ '));

  await page.screenshot({ path: 'tests/ux/_artifacts/web-folded.png' }).catch(() => {});

  // tap the nourishment sector → it opens in place: a hull, its processes inside
  const nourish = await page.evaluate(() => {
    const n = [...document.querySelectorAll('#webstage .wb-node.wb-sector')].find(e => e.textContent.includes('nourishment'));
    return n ? n.dataset.id : null;
  });
  h.rec('the demo scope has a nourishment sector', !!nourish, nourish);
  await tap(`#webstage .wb-node[data-id="${nourish}"]`);
  await sleep(700);
  h.rec('tapping a sector opens it: its hull is drawn', (await count('#webstage .wb-hull')) === 1);
  const procs = await count('#webstage .wb-node.wb-proc');
  h.rec('its processes appear inside (≥ 2)', procs >= 2, `${procs}`);
  h.rec('the sector node itself is gone', (await count(`#webstage .wb-node[data-id="${nourish}"]`)) === 0);
  h.rec('the other sectors stay folded', (await count('#webstage .wb-node.wb-sector')) === sectors - 1);
  h.rec('Cook is one of the processes drawn',
        await page.$$eval('#webstage .wb-node.wb-proc', els => els.some(e => e.textContent.includes('Cook'))));
  // the stove Cook uses shows inside the open sector as a means — dotted, and never an open end
  h.rec('a tool only ever used is a means, never an open end (stove)',
        await page.$$eval('#webstage .wb-node.is-means', els => els.some(e => e.dataset.id === 'g:stove'))
        && !(await page.$$eval('#webpanel .wb-hole', els => els.some(e => e.textContent.includes('stove')))));

  await page.screenshot({ path: 'tests/ux/_artifacts/web-open.png' }).catch(() => {});

  // tap a good → the trace: it and what it touches stay lit, the rest fades
  const veg = await page.evaluate(() => {
    const n = [...document.querySelectorAll('#webstage .wb-node.wb-good')].find(e => e.dataset.id === 'g:vegetables');
    return n ? n.dataset.id : null;
  });
  h.rec('vegetables is a good of the open sector', !!veg);
  await tap('#webstage .wb-node[data-id="g:vegetables"]');
  await sleep(200);
  h.rec('tapping a good starts a trace', await page.$eval('#webstage', el => el.classList.contains('is-tracing')));
  const lit = await count('#webstage .wb-node.is-on'), all = await count('#webstage .wb-node');
  h.rec('the trace lights the good and what it touches, and not everything', lit >= 3 && lit < all, `${lit} of ${all}`);
  h.rec('the traced good is marked selected', (await count('#webstage .wb-node.is-selected')) === 1);
  h.rec('the rail shows the traced good', await page.$eval('#webpanel .wb-focus', el => el.textContent.includes('vegetables')));

  await page.screenshot({ path: 'tests/ux/_artifacts/web-trace.png' }).catch(() => {});

  // the reactions drawing: each process becomes a hull over its goods, its node hidden
  await page.click('#webhead .wb-tg[data-mode="reactions"]');
  await sleep(700);
  h.rec('the reactions toggle draws one hull per process', (await count('#webstage .wb-edge')) === procs);
  h.rec('…and drops the arrowheads, the bundle alone',
        (await markers('#webstage .wb-link.wb-produce')).every(m => m === 'none'));
  h.rec('…and hides the process nodes', await page.$eval('#webstage .wb-node.wb-proc circle', el => getComputedStyle(el).display === 'none'));
  h.rec('the Cook reaction names itself at its junction',
        await page.$$eval('#webstage .wb-edge text', els => els.some(e => e.textContent.includes('Cook'))));
  h.rec('…and its tails and heads are curves into the junction',
        await page.$$eval('#webstage .wb-link.wb-consume, #webstage .wb-link.wb-produce', els => els.length > 0 && els.every(e => (e.getAttribute('d') || '').includes('C'))));
  await page.screenshot({ path: 'tests/ux/_artifacts/web-reactions.png' }).catch(() => {});
  await page.click('#webhead .wb-tg[data-mode="arrows"]');
  await sleep(300);
  h.rec('back to arrows: the hulls go', (await count('#webstage .wb-edge')) === 0);

  // the PROCESS is the default unit (docs/valueflows/algorithms/dependent-demand.md:
  // "a Recipe is not really a thing, it's just a graph"): touching a step — a hull,
  // its node, or one of its own flow lines — selects it NARROWLY: its own flows
  // light, its recipe is named but not lit. "The whole recipe" and "trace what it
  // depends on" are explicit widenings from the rail, not a second tap's hidden meaning.
  await page.click('#webhead .wb-tg[data-mode="both"]');   // the default drawing: hulls, junctions and arrowheads
  await sleep(500);
  await tap('#webstage .wb-edge path');   // any hull
  await sleep(200);
  h.rec('touching a hull selects that ONE process, not its recipe',
        (await page.$eval('#webstage', el => el.classList.contains('is-tracing')))
        && !(await page.$eval('#webstage', el => el.classList.contains('is-picking')))
        && (await count('#webstage .wb-edge.is-selected')) === 1
        && (await count('#webstage .wb-edge.is-pick')) === 0);
  await page.evaluate(() => document.querySelector('#webstage svg').dispatchEvent(new MouseEvent('click', { bubbles: true })));
  await sleep(150);
  const cookNode = await page.evaluate(() => [...document.querySelectorAll('#webstage .wb-node.wb-proc')].find(n => n.textContent.includes('Cook'))?.dataset.id);
  await tap(`#webstage .wb-node[data-id="${cookNode}"]`);
  await sleep(200);
  h.rec('touching Cook selects just Cook, not Shop', (await count('#webstage .wb-node.is-selected')) === 1
        && await page.$eval(`#webstage .wb-node[data-id="${cookNode}"]`, el => el.classList.contains('is-selected')));
  h.rec('…the rail names its recipe, without lighting it', /Cooked meal/.test(await page.$eval('#webpanel .wb-focus', el => el.textContent))
        && (await count('#webstage .wb-node.is-pick')) === 0);
  h.rec('…and offers two explicit widenings', !!(await page.$('#webpanel .wb-trace-up')) && !!(await page.$('#webpanel .wb-see-recipe')));
  const narrowCount = await count('#webstage .wb-node.is-on');   // Cook's own flows: itself, veg, stove, meal
  await tap('#webpanel .wb-trace-up');
  await sleep(200);
  const wideCount = await count('#webstage .wb-node.is-on');
  h.rec('tracing what it depends on widens past the one step', wideCount > narrowCount, `${narrowCount} → ${wideCount}`);
  await tap('#webpanel .wb-trace-up');   // back to narrow
  await sleep(150);
  h.rec('…tapping it again narrows back to just the step', (await count('#webstage .wb-node.is-on')) === narrowCount);
  await tap('#webpanel .wb-see-recipe');
  await sleep(200);
  const picked = () => page.$$eval('#webstage .wb-edge.is-pick text', els => els.map(e => e.textContent).join('|'));
  h.rec('the whole recipe, from the rail: Shop and Cook light together', /Shop/.test(await picked()) && /Cook/.test(await picked()), await picked());
  h.rec('…and no other recipe\'s step', (await count('#webstage .wb-edge.is-pick')) === 2);
  h.rec('…the two hulls wear one colour, so they read as one recipe',
        await page.$$eval('#webstage .wb-edge.is-pick path', els => new Set(els.map(e => getComputedStyle(e).fill)).size === 1));
  h.rec('…and the head says which recipe and its steps in order',
        /Cooked meal/.test(await page.$eval('#webhead .wb-hint', el => el.textContent)) && /Shop → Cook/.test(await page.$eval('#webhead .wb-hint', el => el.textContent)));
  h.rec('…the rest recedes', await page.$eval('#webstage', el => el.classList.contains('is-picking')) && (await count('#webstage .wb-node.wb-good:not(.is-pick)')) > 5);
  h.rec('the rail names the recipe and lists both steps',
        await page.$eval('#webpanel .wb-recipe', el => el.textContent.includes('Cooked meal') && el.textContent.includes('Shop') && el.textContent.includes('Cook') && /2 steps/.test(el.textContent)));
  await page.screenshot({ path: 'tests/ux/_artifacts/web-recipe.png' }).catch(() => {});
  await page.evaluate(() => document.querySelector('#webstage svg').dispatchEvent(new MouseEvent('click', { bubbles: true })));
  await sleep(150);
  h.rec('tapping the stage lets the recipe go, and the head stops naming it',
        !(await page.$eval('#webstage', el => el.classList.contains('is-picking'))) && !(await count('#webhead .wb-pick')));
  // a flow line selects its process too, narrowly — not its whole recipe
  const shopLink = await page.evaluate(() => { const l = [...document.querySelectorAll('#webstage .wb-link.wb-produce')].find(e => !e.classList.contains('is-back')); return l ? [...document.querySelectorAll('#webstage .wb-link')].indexOf(l) : -1; });
  h.rec('a flow line selects its process, tracing but not picking the recipe', shopLink >= 0 && await page.evaluate(i => {
    document.querySelectorAll('#webstage .wb-link')[i].dispatchEvent(new MouseEvent('click', { bubbles: true }));
    const stage = document.querySelector('#webstage');
    return stage.classList.contains('is-tracing') && !stage.classList.contains('is-picking');
  }, shopLink));
  await page.evaluate(() => document.querySelector('#webstage svg').dispatchEvent(new MouseEvent('click', { bubbles: true })));
  await sleep(150);
  await page.click('#webhead .wb-tg[data-mode="arrows"]');
  await sleep(300);

  // the flow layout: columns by stage — Cook stands right of Harvest, which stands right of Sow & tend
  await page.click('#webhead .wb-tg[data-mode="flow"]');
  await sleep(1200);
  const xs = await page.evaluate(() => Object.fromEntries([...document.querySelectorAll('#webstage .wb-node')]
    .map(n => [n.dataset.id, +(n.getAttribute('transform') || '').replace(/translate\(([-\d.]+),.*/, '$1')])));
  const xOf = (name) => Object.entries(xs).find(([k]) => k.startsWith('p:') && k.includes(name))?.[1];
  const sow = await page.evaluate(() => [...document.querySelectorAll('#webstage .wb-node.wb-proc')].find(n => n.textContent.includes('Sow'))?.dataset.id);
  const cook = await page.evaluate(() => [...document.querySelectorAll('#webstage .wb-node.wb-proc')].find(n => n.textContent.includes('Cook'))?.dataset.id);
  const stages = await page.evaluate(() => Object.fromEntries([...document.querySelectorAll('#webstage .wb-node')].map(n => [n.dataset.id, n.dataset.stage])));
  h.rec('flow layout: Cook stands right of Sow & tend', xs[cook] > xs[sow] + 100, `${Math.round(xs[sow])} → ${Math.round(xs[cook])} · stages ${JSON.stringify(stages)}`);
  h.rec('flow layout: the source hole water stands left of Cook', xs['g:water'] < xs[cook], `${Math.round(xs['g:water'])} < ${Math.round(xs[cook])}`);
  void xOf;
  await page.click('#webhead .wb-tg[data-mode="free"]');
  await sleep(300);

  // the flanks: supply on the left traces DOWN, demand on the right traces UP
  h.rec('the supply flank lists what enters from outside (water among them)',
        await page.$$eval('#websupply .wb-fitem', els => els.some(e => e.textContent.includes('water'))));
  h.rec('the demand flank lists the plan\'s needs (meals among them)',
        await page.$$eval('#webdemand .wb-fitem', els => els.some(e => e.textContent.includes('meals'))));
  await tap('#websupply .wb-fitem[data-id="g:water"]');
  await sleep(700);
  const down = await page.$$eval('#webstage .wb-node.is-on', els => els.map(e => e.dataset.id));
  h.rec('tapping water on the supply flank traces DOWN to the meal', down.includes('g:water') && down.includes('g:meal'), down.join(' '));
  h.rec('…and not up: seed is not lit', !down.includes('g:seed'));
  const mealRow = await page.evaluate(() => [...document.querySelectorAll('#webdemand .wb-fitem')].find(e => e.textContent.includes('meals'))?.dataset.id);
  await tap(`#webdemand .wb-fitem[data-id="${mealRow}"]`);
  await sleep(700);
  const up = await page.$$eval('#webstage .wb-node.is-on', els => els.map(e => e.dataset.id));
  h.rec('tapping meals on the demand flank traces UP to water and seed', up.includes('g:water') && up.includes('g:seed'), up.join(' '));
  h.rec('…and not down past the meal: nothing beyond it is lit', up.filter(id => id.startsWith('g:')).every(id => id !== 'g:tomatoes'));
  await page.screenshot({ path: 'tests/ux/_artifacts/web-flow.png' }).catch(() => {});
  await page.evaluate(() => document.querySelector('#webstage svg').dispatchEvent(new MouseEvent('click', { bubbles: true })));
  await sleep(150);

  // a tap on the empty stage ends the trace
  await page.evaluate(() => document.querySelector('#webstage svg').dispatchEvent(new MouseEvent('click', { bubbles: true })));
  await sleep(150);
  h.rec('tapping the stage ends the trace', await page.$eval('#webstage', el => !el.classList.contains('is-tracing')));

  // the hull's name folds the sector back
  await tap('#webstage .wb-hull text');
  await sleep(600);
  h.rec('tapping the hull name folds the sector back', (await count('#webstage .wb-hull')) === 0
        && (await count('#webstage .wb-node.wb-sector')) === sectors);

  // an open end on the rail: tapping it opens the sectors that touch it and selects it
  // the rail starts shut on this face, so the row is reached by dispatch rather than a pointer
  await tap('#webpanel .wb-hole');
  await sleep(700);
  h.rec('tapping an open end on the rail selects it on the web',
        (await count('#webstage .wb-node.is-selected.is-hole')) === 1);
  h.rec('…and opens the sector that reaches for it', (await count('#webstage .wb-hull')) >= 1);

  // the loop the demo hole closes: kitchen waste → waste management → compost → garden → vegetables → kitchen
  h.rec('the head counts the loop the declared hole closes', /[1-9]\d* loops? closed/.test(await page.$eval('#webhead', el => el.textContent)));

  // the explicit hole: open its sector, and it draws as a declared hole with its term
  await page.evaluate(() => { const n = [...document.querySelectorAll('#webstage .wb-node.wb-sector')].find(e => e.textContent.includes('nourishment')); n?.dispatchEvent(new MouseEvent('click', { bubbles: true })); });
  await sleep(700);
  const holeId = await page.evaluate(() => document.querySelector('#webstage .wb-node.is-explicit')?.dataset.id);
  h.rec('the declared hole draws as a dashed process with its term', !!holeId
        && await page.$eval('#webstage .wb-node.is-explicit', el => el.textContent.includes('waste-management')), holeId);
  // this demo's hole is ALSO strained (its record breaks under the heat live
  // now) — a hole's own boundary fill and the strain ring must both survive
  // on one node, not one silently winning the cascade
  h.rec('a hole that is also strained keeps its boundary fill AND wears the ring, in proportion',
        await page.$eval('#webstage .wb-node.is-explicit', el => {
          const c = getComputedStyle(el.querySelector('circle'));
          const strain = +el.style.getPropertyValue('--strain');
          return el.classList.contains('is-strained') && c.fill === 'rgb(239, 236, 248)' && c.stroke === 'rgb(168, 69, 90)'
              && Math.abs(strain - 0.60) < 0.011 && Math.abs(parseFloat(c.strokeWidth) - (1.5 + 3 * strain)) < 0.05;
        }));
  await tap(`#webstage .wb-node[data-id="${holeId}"]`);
  await sleep(300);
  h.rec('…and the rail shows the hole\'s own standing, not just its ports',
        await page.$eval('#webpanel', el => /delivers 40% of what the weather allows/.test(el.textContent) && el.textContent.includes('produce · compost')));
  h.rec('tapping it opens the space of offers on the rail', await page.$eval('#webpanel', el => el.textContent.includes('space of offers') && el.textContent.includes('who could make')));
  h.rec('…which names the port it answers for (compost)', await page.$$eval('#webpanel .wb-port-h', els => els.some(e => e.textContent.includes('compost'))));
  h.rec('…and offers the door to write a recipe for it', (await count('#webpanel .wb-write[data-term="compost"]')) === 1);
  await page.screenshot({ path: 'tests/ux/_artifacts/web-offers.png' }).catch(() => {});

  // writing a recipe: the door opens the builder with a draft that makes the port's good, drawn on the web
  await tap('#webpanel .wb-write[data-term="compost"]');
  await sleep(800);
  h.rec('the builder opens on a draft', await page.$eval('#webdraft', el => el.classList.contains('is-open') && el.querySelector('.wd-makes')?.value === 'compost'));
  h.rec('the draft\'s step is drawn on the web, dashed', (await count('#webstage .wb-node.is-draft')) === 1);
  // the web half: arm the step for its inputs and tap a good
  await tap('#webdraft .wd-arm[data-side="in"]');
  await sleep(600);
  h.rec('arming a step for inputs says so on the stage', await page.$eval('#webstage', el => el.classList.contains('is-arming')));
  await tap('#webstage .wb-node[data-id="g:organic-waste"]');
  await sleep(800);
  h.rec('tapping a good while armed makes it an input of the step',
        await page.$$eval('#webdraft .wd-flow[data-side="in"] .wd-spec', els => els.some(e => e.value === 'organic-waste')));
  h.rec('…and the web draws the new edge into the draft',
        await page.$$eval('#webstage .wb-link.wb-consume', els => els.some(e => e.classList.length && e.getAttribute('d'))) && (await count('#webstage .wb-node.is-draft')) === 1);
  // the form half: name it, and add an output row by hand
  await type('#webdraft .wd-name', 'Hot compost heap');
  await sleep(500);
  h.rec('the form names the draft and the rail lists it', await page.$eval('#webpanel', el => el.textContent.includes('Hot compost heap')));
  await page.screenshot({ path: 'tests/ux/_artifacts/web-builder.png' }).catch(() => {});
  // propose: offline the forum keeps it on this device, and the docket carries the recipe
  await tap('#webdraft .wd-propose');
  await sleep(600);
  h.rec('proposing offline keeps it on this device', await page.$eval('#webdraft .wd-outcome', el => el.textContent.includes('kept')));
  const draftsStored = await page.evaluate(() => { try { return JSON.parse(localStorage.getItem('web.drafts') || '[]'); } catch (e) { return []; } });
  h.rec('the draft persists on the device with its outcome', draftsStored.length === 1 && draftsStored[0].proposed === 'kept' && draftsStored[0].name === 'Hot compost heap');
  // the cut by activity: the hole's own term becomes a sector
  await page.click('#webhead .wb-tg[data-mode="activity"]');
  await sleep(700);
  h.rec('cutting by activity folds the declared hole under its own term',
        await page.$$eval('#webstage .wb-node.wb-sector', els => els.some(e => e.textContent.includes('waste-management'))));
  await page.click('#webhead .wb-tg[data-mode="need"]');
  await sleep(300);

  // the balance mark rides the wire per step: fed through the library's own door, a leaking step rings amber
  h.rec('the demo tracks no substances, so no step is marked', (await count('#webstage .wb-node.is-leak, #webstage .wb-node.is-closed')) === 0);
  await page.click('#webhead .wb-tg[data-mode="plain"]');   // every process in view, so the marks are on the stage
  await sleep(300);
  await page.evaluate(async () => {
    const m = await import('/app/recipe-graph.js');
    m.setRecipes([{ id: 'rp-kiln', name: 'Lime kiln', emoji: '🔥', produces: 'quicklime', need: 'rest/shelter',
      standing: 'observed', yield: 0.3,
      profile: [{ channel: 'produce · quicklime', word: 'fragile', n: 5, confident: false,
                  curve: [[0, 100], [2, 98], [4, 90], [6, 70], [8, 30]].map(([s, c]) => ({ s, c })),
                  bend: { kind: 'harm', gap: 25, from: 0, at: 4, to: 8 } }],
      steps: [{ name: 'Calcine', hours: 3, balance: 'open',
                in: [{ spec: 'limestone', q: 100, u: 'kg', action: 'consume', emoji: '🪨' }],
                out: [{ spec: 'quicklime', q: 56, u: 'kg', action: 'produce', primary: true, emoji: '⚪' }] },
              { name: 'Slake', hours: 1, balance: 'closed',
                in: [{ spec: 'quicklime', q: 56, u: 'kg', action: 'consume', emoji: '⚪' }, { spec: 'water', q: 18, u: 'L', action: 'consume', emoji: '🚰' }],
                out: [{ spec: 'slaked-lime', q: 74, u: 'kg', action: 'produce', primary: true, emoji: '⚪' }] }] }]);
  });
  await sleep(800);
  h.rec('a step the wire marks open rings as a leak (the CO₂ the kiln vents unnamed)', (await count('#webstage .wb-node.is-leak')) === 1);
  h.rec('…and a closed one is marked balanced', (await count('#webstage .wb-node.is-closed')) === 1);
  h.rec('the head counts them', await page.$eval('#webhead', el => /1 balanced · 1 leak/.test(el.textContent)));

  // what a recipe delivers reads on the graph too, not only the flat list —
  // same reading (recipes.ts's pill), the SAME shared render (recipe-render.ts)
  h.rec('a strained recipe\'s steps ring on the graph, both of them, and say what they deliver',
        (await count('#webstage .wb-node.is-strained')) === 2
        && await page.$$eval('#webstage .wb-node.is-strained .wb-sub', els => els.every(e => /delivers 30%/.test(e.textContent))));
  await tap('#webstage .wb-node.is-strained');
  await sleep(200);
  h.rec('picking it shows what it delivers and its stressor in the rail',
        await page.$eval('#webpanel', el => /delivers 30% /.test(el.textContent) && el.textContent.includes('produce · quicklime')));

  h.rec('no page errors', h.errs.length === 0, h.errs.join(' | '));
} catch (e) {
  h.rec('suite ran to the end', false, String(e).slice(0, 200));
} finally {
  await browser.close();
  await closeServer();
}
summarize(h);
