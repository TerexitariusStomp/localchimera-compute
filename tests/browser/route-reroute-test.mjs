// tests/browser/route-reroute-test.mjs — when you have left the way (browser/app/route/reroute.js, from
// ui/app/route/reroute.ts): beyond reach for several fixes running, the reach widening with a fix's own
// doubt, a pause after asking, and never on a vehicle.
//
// Run: node tests/browser/route-reroute-test.mjs

import { harness } from './assert.mjs';
const { offRouteWatch } = await import("../../browser/app/route/reroute.js");
const { check, section, done } = harness();

section("what counts as off the way");
{
  const w = offRouteWatch();
  check("on the line is not off it", !w.see(0, 5, 0, false) && !w.see(0.005, 5, 1, false));
  check("a stray fix or two is not off the way", !w.see(0.2, 5, 2, false) && !w.see(0.2, 5, 3, false));
  check("the third in a row is", w.see(0.2, 5, 4, false));
  const v = offRouteWatch();
  check("a fix back on the line starts the count afresh", !v.see(0.2, 5, 0, false) && !v.see(0.2, 5, 1, false) && !v.see(0, 5, 2, false) &&
        !v.see(0.2, 5, 3, false) && !v.see(0.2, 5, 4, false) && v.see(0.2, 5, 5, false));
}

section("the reach");
{
  const floor = offRouteWatch();
  check("under the floor is on the way, whatever the fix", !floor.see(0.025, 3, 0, false) && !floor.see(0.025, 3, 1, false) && !floor.see(0.025, 3, 2, false));
  const doubt = offRouteWatch();
  const far = (acc) => { const x = offRouteWatch(); return x.see(0.1, acc, 0, false) || x.see(0.1, acc, 1, false) || x.see(0.1, acc, 2, false); };
  check("100 m off with a sharp fix is off", far(5));
  check("100 m off with a 80 m fix is not: the fix may be wrong by that", !far(80));
  check("a fix with no accuracy is taken at the floor", (() => { const x = offRouteWatch(); return x.see(0.05, null, 0, false) || x.see(0.05, null, 1, false) || x.see(0.05, null, 2, false); })());
  check("the floor and the multiple can be set", (() => { const x = offRouteWatch({ floorKm: 0.5, fixes: 1 }); return !x.see(0.4, 5, 0, false) && x.see(0.6, 5, 1, false); })());
}

section("holding still");
{
  const w = offRouteWatch({ cooldownMs: 1000 });
  w.see(0.3, 5, 0, false); w.see(0.3, 5, 1, false);
  check("off the way: ask", w.see(0.3, 5, 2, false));
  w.asked(2);
  check("having asked, nothing more is asked of the same stretch", !w.see(0.3, 5, 3, false) && !w.see(0.3, 5, 500, false) && !w.see(0.3, 5, 900, false));
  check("after the pause the count starts again, from nothing", !w.see(0.3, 5, 1100, false) && !w.see(0.3, 5, 1101, false) && w.see(0.3, 5, 1102, false));
  const r = offRouteWatch();
  r.see(0.3, 5, 0, false); r.see(0.3, 5, 1, false); r.reset();
  check("a way taken up counts afresh", !r.see(0.3, 5, 2, false));
}

section("on a vehicle");
{
  const w = offRouteWatch({ fixes: 1 });
  check("never off the way while riding", !w.see(5, 5, 0, true) && !w.see(5, 5, 1, true));
  check("and the stretch before getting off does not count against you", !w.see(0.3, 5, 2, true) && w.see(0.3, 5, 3, false));
}

done();
