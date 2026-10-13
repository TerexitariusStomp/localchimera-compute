// tests/ux/route-stub.mjs — answer a page's /route calls from the synthetic engine
// (tests/browser/route-fixture.mjs), so a probe exercises the route UI with no Valhalla running.
// Headless chromium has no WebGL unless asked (WEBGL_ARGS); either way a probe asserts what the page
// computed from the answers, never tiles.
import { routeReply } from '../browser/route-fixture.mjs';

/**
 * Intercept `/route?…` on `page`. Returns the engine's live state: `calls`, the queries seen in order;
 * `delay`, milliseconds every answer is held back (set it to watch a request in flight); `down`, answer
 * `{}` to every call — an engine that is not there. `down: true` in the options starts it so.
 */
export async function stubRoute(page, { down = false } = {}) {
  const engine = { calls: [], delay: 0, down };
  await page.route(/\/route\?/, async route => {
    const q = new URL(route.request().url()).searchParams;
    engine.calls.push(q.toString());
    if (engine.delay) await new Promise(r => setTimeout(r, engine.delay));
    route.fulfill({ status: 200, contentType: "application/json",
                    body: JSON.stringify(engine.down ? {} : routeReply(q)) });
  });
  return engine;
}
