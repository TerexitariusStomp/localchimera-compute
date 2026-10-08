// app/runway.ts — the socialized purse over time: how long the money the
// household holds IN COMMON carries the week it has stated.
//
// The family face states a week (tabs/family.ts) and splits one purse across
// it. This module asks the next question: with the capital the members have
// pooled, the incomes that start and stop on their own calendar, and the
// costs that fall away as loans clear, in which month does the pool run dry —
// or does it carry the household to the horizon. Everything is in real terms
// (today's euros), one step per month, and the pool is ONE pool: a gift from
// parent to child moves money inside it and changes nothing here, which is
// exactly what "socialized" means (docs/common-property.typ).
//
// Pure: no DOM, no signals. tests/browser/runway-test.mjs pins its claims.
const ym2i = (ym) => { const [y, m] = ym.split("-").map(Number); return y * 12 + (m - 1); };
const i2ym = (i) => `${Math.floor(i / 12)}-${String((i % 12) + 1).padStart(2, "0")}`;
/** Does STREAM flow in month I? */
const flows = (s, i) => (s.from === undefined || ym2i(s.from) <= i) && (s.until === undefined || i <= ym2i(s.until));
export function simulate(cfg) {
    const a = ym2i(cfg.start), b = ym2i(cfg.horizon);
    const points = [];
    let balance = cfg.capital;
    let runsOut = null;
    let lowest = { ym: cfg.start, balance };
    for (let i = a; i <= b; i++) {
        const ym = i2ym(i);
        const income = cfg.incomes.filter(s => flows(s, i)).reduce((t, s) => t + s.monthly, 0);
        const outflow = cfg.outflows.filter(s => flows(s, i)).reduce((t, s) => t + s.monthly, 0);
        const oneOff = cfg.oneOffs.filter(o => ym2i(o.when) === i).reduce((t, o) => t + o.amount, 0);
        balance = balance * (1 + cfg.realReturn / 12) + income - outflow + oneOff;
        const p = { ym, balance, income, outflow, oneOff, net: income - outflow };
        points.push(p);
        if (balance < lowest.balance)
            lowest = { ym, balance };
        if (runsOut === null && balance < 0)
            runsOut = ym;
    }
    return {
        points, runsOut, lowest, now: points[0],
        monthsFunded: runsOut === null ? points.length : ym2i(runsOut) - a,
        integral: balance - cfg.capital,
        toEarn: Math.max(0, -lowest.balance),
    };
}
/** "YYYY-MM" for the month N months after START. */
export function monthsAfter(start, n) { return i2ym(ym2i(start) + n); }
/** The current month as "YYYY-MM". */
export function thisMonth(d = new Date()) { return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`; }
