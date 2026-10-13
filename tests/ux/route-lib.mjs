// tests/ux/route-lib.mjs — what every route probe does first: open the map face over the synthetic
// engine, put the device where a journey begins, drop a pin where it ends, and feed the page fixes.
//
// The device is set aside (app/position.ts `simulate`), so a probe moves the person by `feed` and
// nothing else does. Software WebGL (WEBGL_ARGS, from ux-harness) gives the page a real map.
import { sleep } from './ux-harness.mjs';
import { stubRoute } from './route-stub.mjs';

/** Where a journey begins, and where the spot it goes to is. */
export const START = { lat: 37.7749, lng: -122.4194 };
export const SPOT = { lat: 37.7849, lng: -122.4094 };

/**
 * Open the map face on `page`, answering /route from the synthetic engine (`down: true`: an engine that
 * is not there), and wait for a real map. `query` rides on the URL ("&simdrive=60"). Returns the stub's
 * record of the queries it saw.
 */
export async function openMap(page, base, { down = false, query = "" } = {}) {
  await page.context().grantPermissions(["geolocation"]);
  await page.context().setGeolocation({ latitude: START.lat, longitude: START.lng });
  const stub = await stubRoute(page, { down });
  await page.goto(`${base}/app.html?face=map${query}`, { waitUntil: "domcontentloaded" });
  for (let i = 0; i < 60; i++) {
    if (await page.evaluate(async () => !!(await import("/app/mapview.js")).theMap())) break;
    await sleep(500);
  }
  await sleep(800);
  return stub;
}

/** Drop a pin at SPOT: its card opens, with ↦ directions. */
export const showSpot = (page, at = SPOT) =>
  page.evaluate(async ({ lat, lng }) => (await import("/app/tabs/map/mapsearch.js")).showSpot(lat, lng), at);

/** One fix, as the device would give it. */
export const feed = (page, lat, lng, heading, speed = 1.4) =>
  page.evaluate(async a => (await import("/app/position.js")).feed({ ...a, accuracy: 5 }), { lat, lng, heading, speed });

/** Set the device aside (or take it back). */
export const device = (page, on) => page.evaluate(async on => (await import("/app/position.js")).simulate(on), on);

/** The trimmed text of the first element matching `sel`, or null. */
export const txt = (page, sel) => page.evaluate(s => document.querySelector(s)?.textContent?.trim() ?? null, sel);

/** The route lines the page last drew on its map: [{ kind, coords }] (app/route/lines.ts `drawnLines`). */
export const drawnLines = page => page.evaluate(async () => {
  const m = (await import("/app/mapview.js")).theMap();
  return m ? (await import("/app/route/lines.js")).drawnLines(m) : [];
});

/** The sheet's grip, where a pointer would press it. */
export const gripPoint = page => page.evaluate(() => {
  const b = document.querySelector("#sharebar .sheet-grab").getBoundingClientRect();
  return { x: b.left + b.width / 2, y: b.top + b.height / 2 };
});

/** Press the grip and let go again. */
export async function tapGrip(page) {
  const g = await gripPoint(page);
  await page.mouse.click(g.x, g.y);
  await sleep(450);
}

/** Drag the grip `dy` pixels (up is negative) and let go. */
export async function swipeGrip(page, dy) {
  const g = await gripPoint(page);
  await page.mouse.move(g.x, g.y); await page.mouse.down();
  await page.mouse.move(g.x, g.y + dy / 2, { steps: 3 }); await page.mouse.move(g.x, g.y + dy, { steps: 3 });
  await page.mouse.up(); await sleep(400);
}

/** The journey sheet's rest: "peek", "mid" or "full". */
export const restOf = page => page.evaluate(() => document.querySelector(".jv")?.dataset.rest);
