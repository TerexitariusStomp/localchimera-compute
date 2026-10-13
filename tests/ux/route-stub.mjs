// tests/ux/route-stub.mjs — answer a page's /route calls from the synthetic
// engine (tests/browser/route-fixture.mjs), so a probe exercises the route UI
// with no Valhalla running. Headless chromium has no WebGL, so a probe asserts
// what the page computed from the answers, never tiles.
import { routeReply } from '../browser/route-fixture.mjs';

/**
 * Intercept `/route?…` on `page`. Returns `{calls}`, the queries seen, in order.
 * `down: true` answers `{}` for every call — an engine that is not there.
 */
export async function stubRoute(page, { down = false } = {}) {
  const calls = [];
  await page.route(/\/route\?/, route => {
    const q = new URL(route.request().url()).searchParams;
    calls.push(q.toString());
    route.fulfill({ status: 200, contentType: "application/json",
                    body: JSON.stringify(down ? {} : routeReply(q)) });
  });
  return { calls };
}
