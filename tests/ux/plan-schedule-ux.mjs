/// tests/ux/plan-schedule-ux.mjs — the plan face's SCHEDULE BOARD renders the
/// solve's space-time coordinates as they are: days × places, work rows with
/// named providers, hauls (a pickup and its dropoff on one run) collapsed to one origin row with a destination
/// arrow, and a spanning run's output tagged as LANDING on
/// a later day than its work. Injected data mirrors the village demonstration
/// plan (farm grows, haul to town, bake, 30 h brew) so the assertions are the
/// same coherence facts the planner's own tests prove.
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
const errs = [];
page.on('pageerror', e => errs.push(String(e)));

try {
  await page.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
  await sleep(1200);

  // the village plan, as the snapshot would deliver it (live solve + schedule)
  await page.evaluate(async () => {
    const { emit } = await import('/app/bus.js');
    const W = (who, skill, effort, place, when) => ({ who, skill, effort, place, when, until: when, proc: skill });
    const M = (action, spec, qty, place, when, proc = "", note = "") => ({ action, spec, qty, place, when, proc, note });
    emit('plan', {
      scope: "village", coverage: 1.0, feasible: "yes", labourH: 15.3,
      produced: [{ spec: "bread", q: 6.8 }, { spec: "brew", q: 2.7 }],
      needs: [{ id: "bread", label: "Bread", met: 1.0, want: 6, recipeId: "", runs: 2, labourH: 5.4, willing: 0 }],
      flow: [{ id: "bake", spec: "Bread", specId: "bread", name: "Bake bread", q: 6.8, u: "kg", period: "0",
               in: [{ spec: "Grain", id: "grain", q: 4.5, action: "consume" }] }],
      schedule: {
        work: [
          W("Ana", "grow grain", 3.40, "farm", "2026-08-17"),
          W("Bo",  "drive",      0.85, "farm", "2026-08-17"),
          W("Cal", "bake",       2.01, "town", "2026-08-17"),
          W("Cal", "brew",       1.02, "town", "2026-08-17"),
          W("Ana", "grow grain", 1.48, "farm", "2026-08-18"),
          W("Cal", "bake",       1.67, "town", "2026-08-18"),
        ],
        material: [
          M("produce", "grain", 10.45, "farm", "2026-08-17", "grow"),
          M("pickup",  "grain",  5.78, "farm", "2026-08-17", "haul"),
          M("dropoff", "grain",  5.78, "town", "2026-08-17", "haul"),
          M("consume", "grain",  1.73, "town", "2026-08-17", "bake"),
          M("produce", "bread",  2.59, "town", "2026-08-17", "bake"),
          M("consume", "grain",  0.87, "town", "2026-08-17", "brew"),
          M("produce", "brew",   1.75, "town", "2026-08-18", "brew"),   // lands a day after its work began
          M("produce", "grain",  3.95, "farm", "2026-08-18", "grow"),
        ],
      },
    });
  });
  await sleep(400);

  // open the plan face so the board is actually laid out
  await page.evaluate(() => { document.querySelector('#face-plan')?.click(); });
  await sleep(600);

  const board = await page.evaluate(() => {
    const sb = document.querySelector('.sb');
    if (!sb) return null;
    return {
      days: [...sb.querySelectorAll('.sb-date')].map(e => e.textContent),
      places: [...new Set([...sb.querySelectorAll('.sb-pname')].map(e => e.textContent))],
      haul: sb.querySelector('.sb-row.sb-haul')?.textContent || "",
      lands: sb.querySelector('.sb-lands')?.textContent || "",
      work: [...sb.querySelectorAll('.sb-row.sb-work')].map(e => e.textContent),
    };
  });

  h.rec('app.html loads without page errors', errs.length === 0, errs.join(' | '));
  h.rec('schedule board renders', !!board);
  if (board) {
    h.rec('both days present', board.days.length === 2 && board.days[0] === '2026-08-17');
    h.rec('both places present as lanes', board.places.includes('farm') && board.places.includes('town'));
    h.rec('the haul collapses to origin → destination', /5\.8.*grain.*→ town/.test(board.haul), board.haul);
    h.rec('the spanning brew is tagged as landing', board.lands === 'lands');
    h.rec('work rows carry named providers', board.work.some(w => /Ana.*grow grain.*3\.4 h/.test(w)),
          board.work.join(' | '));
  }
  await page.screenshot({ path: process.env.SHOT_OUT || '/tmp/plan-schedule.png', fullPage: false });
  h.info(`screenshot: ${process.env.SHOT_OUT || '/tmp/plan-schedule.png'}`);
} catch (e) { h.rec('fatal', false, e.message); }
finally { await browser.close(); closeServer(); }

summarize(h, ['schedule board renders']);
