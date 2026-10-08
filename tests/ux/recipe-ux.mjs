/// tests/ux/recipe-ux.mjs — the scope plan, as a sidebar section (PLAN, under
/// PROPOSALS): a ledger line (coverage · labour · yields) over a provisioning
/// map, one row per need with its met bar and the recipe + work that fills it.
/// Tapping a need opens the recipe ribbon card under the dial (process boxes,
/// flows); resources within it follow to the recipes that make them; the
/// card's back-trail closes back to the list. Static demo data — no gateway.
///
/// Run via: make test-recipe-ux
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
page.on('pageerror', e => h.errs.push(String(e).slice(0, 160)));

try {
  // ?face=time explicitly: the map is the default face now, and the plan column
  // is the time face's sidebar — the rows are built either way, they are simply
  // not on screen until that face is up.
  await page.goto(`${BASE}/app.html?face=time`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#planlist li', { timeout: 30000 });
  h.rec('plan section renders in the sidebar', true);

  // The dial bands render; the recipe drill-down is hidden until a need is tapped.
  h.rec('desire bands render',
        await page.$eval('#dial', el => el.querySelectorAll('g')[1].childNodes.length > 0));
  h.rec('recipe drill-down hidden by default',
        await page.$eval('#planrecipe', el => getComputedStyle(el).display === 'none'));

  const plan = await page.evaluate(() => ({
    ledger: document.querySelector('#planledger')?.textContent || '',
    needs: [...document.querySelectorAll('#planlist li')].map(n => n.textContent),
    tappable: document.querySelectorAll('#planlist li.tappable').length,
  }));
  h.rec('ledger shows coverage % + labour h',
        /\d+% met/.test(plan.ledger) && /h/.test(plan.ledger));
  h.rec('provisioning map lists needs', plan.needs.length >= 4);
  h.rec('a need names its recipe (Cooked meal ×12)',
        plan.needs.some(t => t.includes('Cooked meal') && t.includes('12')));
  h.rec('needs with recipes are tappable', plan.tappable >= 2);
  h.rec('least-met need is sorted first (learning 40%)',
        plan.needs[0].includes('learning') && plan.needs[0].includes('40'));

  await page.screenshot({ path: 'tests/ux/_artifacts/day-plan.png' }).catch(() => {});

  // Tap the meals need → the recipe expands IN PLACE (list gives way to it).
  await page.evaluate(() => {
    const row = [...document.querySelectorAll('#planlist li.tappable')]
      .find(n => n.textContent.includes('meals'));
    row?.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  });
  await sleep(300);
  h.rec('tapping a need opens its recipe in place (Cooked meal)',
        await page.$eval('#planrecipe', el =>
          getComputedStyle(el).display !== 'none' &&
          el.querySelector('.rf-head')?.textContent.includes('Cooked meal')));
  h.rec('the plan list yields to the recipe (in place)',
        await page.$eval('#planlist', el => getComputedStyle(el).display === 'none'));
  h.rec('the recipe flow draws its steps',
        await page.$eval('#planrecipe svg', el =>
          el.textContent.includes('Shop') && el.textContent.includes('Cook')));

  // Follow the vegetables resource → a recipe that makes it. The library has more than
  // one maker of vegetables (Morning harvest, Garden greens), and the trail takes the
  // first, so the claim is "a maker", read off the library, not one name.
  await page.evaluate(() => {
    const t = [...document.querySelectorAll('#planrecipe svg text')]
      .find(el => el.textContent.includes('2 kg'));
    t?.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  });
  await sleep(300);
  const makers = await page.evaluate(async () =>
    (await import('/app/recipe-graph.js')).recipes().filter(r => r.produces === 'vegetables').map(r => r.name));
  const head = await page.$eval('#planrecipe .rf-head', el => el.textContent);
  h.rec('following 🥬 navigates to a recipe that makes vegetables',
        makers.length > 1 && makers.some(n => head.includes(n)) && !/Cooked meal\s*›?\s*$/.test(head.trim()),
        `head="${head.trim()}" makers=${makers.join(', ')}`);

  await page.screenshot({ path: 'tests/ux/_artifacts/day-plan-recipe.png' }).catch(() => {});

  // Back up the trail: Garden greens → Cooked meal → close to the list.
  await page.click('#planrecipe .rf-back');
  await sleep(250);
  h.rec('back returns to Cooked meal',
        await page.$eval('#planrecipe .rf-head', el => el.textContent.includes('Cooked meal')));
  await page.click('#planrecipe .rf-back');
  await sleep(250);
  h.rec('back again closes to the plan list',
        await page.$eval('#planrecipe', el => getComputedStyle(el).display === 'none')
        && await page.$eval('#planlist', el => getComputedStyle(el).display !== 'none'));

  // The plan list is right back where it was, in the same column.
  h.rec('plan list restored in place',
        (await page.$$('#planlist li.tappable')).length >= 2);
  h.rec('dial bands stayed live throughout',
        await page.$eval('#dial', el => el.querySelectorAll('g')[1].childNodes.length > 0));
} finally {
  await browser.close();
  closeServer();
}

summarize(h, ['plan section renders in the sidebar',
              'ledger shows coverage % + labour h',
              'a need names its recipe (Cooked meal ×12)',
              'tapping a need opens its recipe in place (Cooked meal)',
              'the plan list yields to the recipe (in place)',
              'following 🥬 navigates to a recipe that makes vegetables',
              'back again closes to the plan list',
              'plan list restored in place']);
