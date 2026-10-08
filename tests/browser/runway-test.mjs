// tests/browser/runway-test.mjs — the socialized purse over time
// (browser/app/runway.js)
//
// The family face's runway is one pool stepped month by month. Its claims are
// arithmetic and the test states them as such: a pool with no income and a
// flat outflow runs out in exactly capital/outflow months; an income that
// covers the week never runs out; a cost with an `until` stops that month and
// not the one before; a one-off lands in its month alone; a gift between two
// members is not a movement of the pool at all.
//
// Run: node tests/browser/runway-test.mjs

import { installDomStub, harness } from "./dom-stub.mjs";
installDomStub();

const R = await import("../../browser/app/runway.js");
const { check, done } = harness();
const near = (a, b, eps = 1e-6) => Math.abs(a - b) < eps;

const base = { capital: 1200, start: "2026-09", horizon: "2028-08", realReturn: 0, incomes: [], outflows: [], oneOffs: [] };

// ── the flat case: capital / outflow ───────────────────────────────────────
{
  const r = R.simulate({ ...base, outflows: [{ what: "life", monthly: 100 }] });
  check("no income, €100/mo from €1,200: below zero in the 13th month", r.runsOut === "2027-09" && r.monthsFunded === 12);
  check("the balance after month 1 is capital − one month", near(r.points[0].balance, 1100));
  check("the lowest point is the horizon", r.lowest.ym === "2028-08");
  check("now reads today's net", r.now.net === -100 && r.now.ym === "2026-09");
}

// ── income that covers the week never runs out ─────────────────────────────
{
  const r = R.simulate({ ...base, incomes: [{ what: "wage", monthly: 100 }], outflows: [{ what: "life", monthly: 100 }] });
  check("income = outflow: funded to the horizon", r.runsOut === null && r.monthsFunded === r.points.length);
  check("the balance never moves", r.points.every(p => near(p.balance, 1200)));
}

// ── calendars: from / until are inclusive months ──────────────────────────
{
  const r = R.simulate({ ...base, outflows: [{ what: "loan", monthly: 100, until: "2026-11" }] });
  const by = Object.fromEntries(r.points.map(p => [p.ym, p]));
  check("a cost with until=2026-11 is paid in November", by["2026-11"].outflow === 100);
  check("and not in December", by["2026-12"].outflow === 0);
  check("so the pool stops falling after November", near(by["2026-12"].balance, by["2026-11"].balance));
  const s = R.simulate({ ...base, incomes: [{ what: "pension", monthly: 50, from: "2027-01" }] });
  const sb = Object.fromEntries(s.points.map(p => [p.ym, p]));
  check("an income with from=2027-01 is absent in December", sb["2026-12"].income === 0);
  check("and present in January", sb["2027-01"].income === 50);
}

// ── a one-off lands in its month alone ────────────────────────────────────
{
  const r = R.simulate({ ...base, oneOffs: [{ what: "tax", amount: -500, when: "2027-03" }] });
  const by = Object.fromEntries(r.points.map(p => [p.ym, p]));
  check("the month before is untouched", near(by["2027-02"].balance, 1200));
  check("the one-off month carries it", near(by["2027-03"].balance, 700) && by["2027-03"].oneOff === -500);
  check("a one-off is not part of the recurring net", by["2027-03"].net === 0);
}

// ── the pool is ONE pool: a gift inside it moves nothing ──────────────────
{
  const gift = R.simulate({ ...base, oneOffs: [{ what: "gift parent→child", amount: -300, when: "2027-01" }, { what: "gift parent→child", amount: 300, when: "2027-01" }] });
  check("a gift between members nets to zero in the pool", gift.points.every(p => near(p.balance, 1200)));
}

// ── the life integral, and what must be earned to cover it ────────────────
{
  // 24 months at −€100: the integral is −€2,400 and the pool bottoms at −€1,200
  const r = R.simulate({ ...base, outflows: [{ what: "life", monthly: 100 }] });
  check("the integral over the horizon is end − capital", near(r.integral, -2400));
  check("to earn = the depth of the lowest point", near(r.toEarn, 1200));
  const s = R.simulate({ ...base, incomes: [{ what: "wage", monthly: 150 }], outflows: [{ what: "life", monthly: 100 }] });
  check("a life surplus reads positive", near(s.integral, 1200));
  check("and nothing needs earning", s.toEarn === 0);
  // a dip that recovers: the integral can be positive while the pool still ran dry
  const d = R.simulate({ ...base, capital: 100, incomes: [{ what: "pension", monthly: 300, from: "2027-09" }], outflows: [{ what: "life", monthly: 100 }] });
  check("a positive integral does not mean funded — toEarn is the dip", d.integral > 0 && d.runsOut === "2026-10" && near(d.toEarn, 1100));
}

// ── a real return compounds monthly ───────────────────────────────────────
{
  const r = R.simulate({ ...base, realReturn: 0.12 });
  check("12%/yr is 1%/mo on the balance", near(r.points[0].balance, 1212) && near(r.points[1].balance, 1212 * 1.01));
}

// ── month arithmetic ──────────────────────────────────────────────────────
check("monthsAfter crosses the year", R.monthsAfter("2026-11", 3) === "2027-02");
check("thisMonth is zero-padded", /^\d{4}-\d{2}$/.test(R.thisMonth(new Date(2026, 0, 5))) && R.thisMonth(new Date(2026, 0, 5)) === "2026-01");

done();
