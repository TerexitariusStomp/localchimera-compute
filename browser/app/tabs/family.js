// app/tabs/family.ts — the "family" face: a household purse split across its
// members' needs by harmony.
//
// Four people and the household they share state a week of needs as they ARE
// — quantity, cost, a KIND and an attached VOICE — with no eye to whether the
// purse covers it. The kind is the social statement of how far a need may be
// sacrificed (tension-kinds.scm): a FLOOR is a right (a hard wall; a purse
// below the floors has no plan — and it takes no voice: the wall is free), a
// HELD need trades at the margin but can never be zeroed, a WANT (des) can be
// set aside for exactly the voice attached to it, quietest first. The solve
// (planner/doors/family/solve.scm, the one the planner test pins)
// turns every need into an acquisition recipe (euros in, the need out), holds
// the purse as a finite stock, and lets the household's own Pfand run add to
// it. When the purse is short the sacrifice SPREADS; nothing is cut by a queue.
//
// The family is the scope where the person is still known, so the rows come
// back keyed per member — the one place a per-person reading of harmony is
// legitimate (governance/demand-fold.scm: a person is resolved where they are
// known; a total is what crosses a fold).
//
// The solve runs on the device (family-local.ts: the planner compiled for the
// browser, in a worker), so the ledger stays there; the commons answers only when
// the device cannot run it. With neither, the default ledger shows the three
// splits the planner test measured, and an edited ledger says it needs a solve.
import { html, render } from '../template.js';
import { signal, effect } from '../reactive.js';
import { HANDLERS } from '../core.js';
import { askLocal, UNAVAILABLE } from '../family-local.js';
import { VOICE_LADDER, ladderIndex } from '../slots/model.js';
import { simulate, monthsAfter, thisMonth } from '../runway.js';
import { membersOf, individualsOf, blockRank, blockPath, vertices, SORT_ORDERS } from '../partition.js';
export const KINDS = ["floor", "held", "des"];
export const KIND_LABEL = { floor: "right", held: "need", des: "want" };
const KIND_HINT = {
    floor: "a hard wall — a purse below it has no plan",
    held: "can be short, but never zeroed",
    des: "set aside for exactly the voice attached to it, quietest first",
};
// WHO gets its own colour channel, never the kind's: eight stable slots (CSS
// data-p, app.html). "all" — the household itself — always wears slot 0;
// every other name in the CURRENT ledger takes the next free slot in the
// order it first appears, so any two people sharing a ledger always wear
// two different colours (up to eight). A ninth-and-beyond person falls back
// to a hash of their name, same as before.
export function personSlots(people) {
    const slots = {};
    let next = 1;
    for (const raw of people) {
        const key = raw.trim().toLowerCase();
        if (key in slots)
            continue;
        if (key === "all") {
            slots[key] = 0;
            continue;
        }
        if (next <= 7) {
            slots[key] = next++;
            continue;
        }
        let h = 0;
        for (let i = 0; i < key.length; i++)
            h = (h * 31 + key.charCodeAt(i)) >>> 0;
        slots[key] = 1 + (h % 7);
    }
    return slots;
}
let personSlotOf = {};
export function personSlot(name) {
    return personSlotOf[name.trim().toLowerCase()] ?? 0;
}
// Every WHO is a block of the household's individuals (partition.ts), and
// wears its block as an icon: the individuals on a circle, this row's members
// joined by a rounded shape in the row's colour, the others faint dots.
// Named groups beyond "a+b" arrive with the local ledger (`groups`).
const groups = signal({});
const sortOrder = signal("all-individuals-groups");
const ICON_R = 5.2;
function personIcon(who, ns) {
    const ind = individualsOf(ns.map(n => n.person), groups());
    const n = ind.length;
    const mine = membersOf(who, ind, groups()).map(m => ind.indexOf(m));
    const vs = vertices(n, ICON_R);
    const size = mine.length;
    return html `<svg class="fm-pico" viewBox="-8 -8 16 16" title="${who}: ${size} of ${n}">${vs.map((v, i) => mine.includes(i) ? "" : html `<circle class="fm-pico-o" cx=${v[0]} cy=${v[1]} r="1"></circle>`)}<path class="fm-pico-b" d=${blockPath(mine, n, ICON_R)}></path></svg>`;
}
/** The block size of WHO, for the sort. */
function blockSize(who, ns) {
    return membersOf(who, individualsOf(ns.map(n => n.person), groups()), groups()).length;
}
/** The three tiers in the order the bills are read, and what the row says. */
const BILL_TIERS = [
    { tier: "floor", label: "rights", hint: "every right whole — the floors alone, nothing softer bought" },
    { tier: "held", label: "+ needs", hint: "rights whole and every need at its stated quantity" },
    { tier: "des", label: "+ wants", hint: "rights, needs, and every want at its ask" },
];
const WIRE_TIER = { rights: "floor", needs: "held", wants: "des" };
/** The family's default ledger — the planner test's fixture, verbatim. One week:
 *  Bob (15) and Dennis (9) are at school, Christine commutes to work, Alice is on a
 *  prescription and in physio; "all" is what the four share. */
export const DEMO_NEEDS = [
    { person: "all", what: "groceries", cost: 12, want: 7, voice: 0, kind: "floor", substance: "nutrition" },
    { person: "all", what: "fresh-produce", cost: 3, want: 7, voice: 100, kind: "held" },
    { person: "all", what: "household-goods", cost: 8, want: 1, voice: 46, kind: "held" },
    { person: "all", what: "internet-phone", cost: 30, want: 1, voice: 215, kind: "held" },
    { person: "all", what: "treats", cost: 4, want: 3, voice: 10, kind: "des" },
    { person: "alice", what: "medicine", cost: 30, want: 1, voice: 0, kind: "floor" },
    { person: "alice", what: "physio", cost: 25, want: 1, voice: 464, kind: "held" },
    { person: "alice", what: "newspaper", cost: 1.5, want: 7, voice: 5, kind: "des" },
    { person: "bob", what: "schoolbooks", cost: 25, want: 2, voice: 464, kind: "held" },
    { person: "bob", what: "transit-school", cost: 30, want: 1, voice: 464, kind: "held" },
    { person: "bob", what: "phone-credit", cost: 10, want: 1, voice: 10, kind: "des" },
    { person: "bob", what: "videogame", cost: 50, want: 1, voice: 1, kind: "des" },
    { person: "christine", what: "transit-pass", cost: 40, want: 1, voice: 464, kind: "held" },
    { person: "christine", what: "work-lunches", cost: 5, want: 5, voice: 22, kind: "des" },
    { person: "christine", what: "coffee-beans", cost: 9, want: 1, voice: 5, kind: "des" },
    { person: "christine", what: "concert", cost: 35, want: 1, voice: 2, kind: "des" },
    { person: "dennis", what: "shoes", cost: 45, want: 1, voice: 215, kind: "held" },
    { person: "dennis", what: "swimming", cost: 15, want: 2, voice: 100, kind: "des" },
    { person: "dennis", what: "birthday-gift", cost: 15, want: 1, voice: 10, kind: "des" },
    { person: "dennis", what: "videogame", cost: 50, want: 1, voice: 1, kind: "des" },
];
// What the solve returns for the default ledger at 20 h of labour — `got` per
// need in ledger order, and the Pfand trips the plan raises. Keyed by purse
// and weighting so the face can show a real split with no gateway; any other
// ledger is the commons' to solve. €100 is below the floors (€114) and has no
// plan — an empty row. Regenerate whenever the demo ledger changes: run
// family-split at each (purse, weighted?) key and print each row's `got` in
// ledger order plus `pfand-trips` (the harmony test's `show` prints the same
// numbers).
const DEMO_SPLITS = {
    "100:w": { got: [], trips: 0 }, "100:u": { got: [], trips: 0 },
    "250:w": { got: [7.0000, 3.5507, 0.5431, 0.5854, 0.0000, 1.0000, 0.7187, 0.0000, 0.9178, 0.5548, 0.0000, 0.0000, 0.6232, 0.0000, 0.0000, 0.0000, 0.5324, 0.0000, 0.0000, 0.0000], trips: 0.6 },
    "400:w": { got: [7.0000, 6.5126, 0.9413, 0.9521, 1.6695, 1.0000, 0.9758, 0.1284, 1.8246, 0.9445, 0.0650, 0.0000, 0.9602, 2.2098, 0.1163, 0.0000, 0.9383, 1.8052, 0.5131, 0.0000], trips: 0.6 },
    "400:u": { got: [7.0000, 5.4288, 0.8936, 0.7168, 2.4321, 1.0000, 0.8469, 6.4201, 1.2458, 0.7168, 0.8423, 0.2114, 0.6649, 3.0282, 0.8580, 0.4480, 0.6429, 1.0536, 0.7634, 0.2114], trips: 0.6 },
    "1000:w": { got: [7.0436, 6.9995, 1.0000, 1.0000, 2.9992, 1.0222, 1.0000, 6.9886, 2.0000, 1.0000, 0.9998, 0.9977, 1.0000, 4.9986, 0.9998, 0.9994, 1.0000, 2.0000, 0.9999, 0.9992], trips: 0.013 },
};
const PFAND_PER_TRIP = 5; // 20 × €0.25
// The runway's frame: what the members hold in common today, and the incomes
// that start and stop on their own calendar. The ledger supplies the outflows
// (each row's weekly ask, until its `until`). The demo family: a modest pot,
// a wage with fourteen months left in it, a pension five years out — enough
// to show the pool run dry and then refill. A household's real frame arrives
// with its local ledger (`runway` in family-data*.local.json).
//
// Disabled for now: the section is out of the ledger's view, its effect never
// runs, and nothing in drawRunway computes on the ledger's changes.
const RUNWAY_ENABLED = false;
const WEEKS_PER_MONTH = 4.348;
const DEMO_RUNWAY = (start) => ({
    capital: 18000, start, horizon: monthsAfter(start, 12 * 12), realReturn: 0,
    incomes: [
        { what: "wage", monthly: 2600, until: monthsAfter(start, 14) },
        { what: "pension", monthly: 1400, from: monthsAfter(start, 60) },
    ],
    outflows: [], oneOffs: [],
});
const needs = signal(DEMO_NEEDS.map(n => ({ ...n })));
const runway = signal(DEMO_RUNWAY(thisMonth()));
const purse = signal(250);
const labourH = signal(20);
const weighted = signal(true);
const split = signal(null);
const busy = signal(false);
const note = signal("");
// the commons' own words when a solve fails — shown as a state of the face, never as a raw line
const fault = signal("");
const bills = signal(null);
const eurPerHour = signal(15);
const billsNote = signal("");
// Empty by default: every owner reads as an equal citizen, the flat voice
// the split always used. Declaring a member (drawMembers) gives them a real
// consumer voice off their capacity + hours (family-voice-of).
const members = signal([]);
const perCitizenHours = signal(40);
// the runway plot's width in CSS pixels, kept current by a ResizeObserver
const plotWidth = signal(720);
const PEOPLE_ORDER = ["all", "alice", "bob", "christine", "dennis"];
const KIND_ORDER = { floor: 0, held: 1, des: 2 };
const num = (x) => { const n = parseFloat(String(x)); return isFinite(n) ? n : 0; };
const eur = (x) => "€" + x.toFixed(2);
const pct = (f) => Math.round(100 * Math.min(1, f)) + "%";
/** The total ask of the ledger as stated, or of one kind of it. */
export const totalAsk = (ns, kind) => ns.filter(n => !kind || n.kind === kind).reduce((s, n) => s + n.cost * n.want, 0);
/** The rights, in and of themselves — docs/rights.md, form-and-substance.typ
 *  "The substance is a vector": every floor names a substance (`n.substance`)
 *  it reduces to, or, absent one, reduces to itself (medicine: no substitute
 *  form in this ledger, the doc's degenerate case where the form forced
 *  indirectly IS the substance forced directly). A WANT is exactly a row
 *  with no floor anywhere on its substance — nothing here derives that from
 *  the ledger's per-row `kind`, since most held/des rows (physio, treats)
 *  name no substance at all; this reads only the rows that do. */
export function rightsVector(ns) {
    const by = new Map();
    for (const n of ns) {
        if (n.kind !== "floor")
            continue;
        const substance = n.substance ?? n.what;
        const key = `${n.person}::${substance}`;
        const row = by.get(key);
        if (row) {
            row.qty += n.want;
            row.forms.push(n.what);
        }
        else
            by.set(key, { person: n.person, substance, qty: n.want, forms: [n.what] });
    }
    return [...by.values()].sort((a, b) => PEOPLE_ORDER.indexOf(a.person) - PEOPLE_ORDER.indexOf(b.person));
}
/** The per-person reading of a split: mean fraction met across that person's needs. */
export function byPerson(rows) {
    const acc = new Map();
    for (const r of rows) {
        const a = acc.get(r.person) || { met: [], got: 0, ask: 0 };
        a.met.push(r.met);
        a.got += r.cost * r.got;
        a.ask += r.cost * r.want;
        acc.set(r.person, a);
    }
    return [...acc.entries()]
        .map(([person, a]) => ({ person, got: a.got, ask: a.ask, met: a.met.reduce((s, m) => s + m, 0) / a.met.length }))
        .sort((x, y) => PEOPLE_ORDER.indexOf(x.person) - PEOPLE_ORDER.indexOf(y.person));
}
/** Is this ledger the default one, row for row? */
function isDemoLedger(ns) {
    return ns.length === DEMO_NEEDS.length && ns.every((n, i) => {
        const d = DEMO_NEEDS[i];
        return n.person === d.person && n.what === d.what && n.cost === d.cost && n.want === d.want && n.voice === d.voice && n.kind === d.kind;
    });
}
function demoSplit() {
    const key = `${purse()}:${weighted() ? "w" : "u"}`;
    // the pinned table was measured at the flat voice every owner reads with
    // no members declared — a declared member needs the commons to solve
    const pinned = isDemoLedger(needs()) && labourH() === 20 && members().length === 0 ? DEMO_SPLITS[key] : undefined;
    if (!pinned)
        return null;
    const { got, trips } = pinned;
    const feasible = got.length > 0;
    const rows = needs().map((n, i) => ({ ...n, got: feasible ? got[i] : 0, met: feasible ? Math.min(1, got[i] / n.want) : 0 }));
    return {
        feasible, floors: totalAsk(needs(), "floor"),
        needs: rows, purse: purse(), labourH: 20, demo: true,
        spent: rows.reduce((s, r) => s + r.cost * r.got, 0),
        pfandTrips: trips, income: trips * PFAND_PER_TRIP,
    };
}
/** ROWS keyed by wire kind, or — for the best-effort nest, where every
 *  demoted floor comes back as `held` — by the OUTER solve's row at the same
 *  index, the last place the true kind (a right stays a right) still reads. */
function parseRows(arr, trueKindOf) {
    return (Array.isArray(arr) ? arr : []).map((r, i) => ({
        person: String(r.person), what: String(r.what),
        cost: num(r.cost), want: num(r.want), voice: num(r.voice), got: num(r.got), met: num(r.met),
        kind: trueKindOf ? trueKindOf[i].kind : (KINDS.includes(String(r.kind)) ? r.kind : "des"),
    }));
}
function parseReply(reply) {
    if (typeof reply !== "string" || !reply || reply.startsWith("err:"))
        return null;
    try {
        const v = JSON.parse(reply);
        const rows = parseRows(v.needs);
        const be = v.bestEffort;
        const bestEffort = be ? {
            feasible: be.feasible !== "no" && be.feasible !== false, floors: num(be.floors),
            needs: parseRows(be.needs, rows), spent: num(be.spent), purse: num(be.purse),
            income: num(be.income), pfandTrips: num(be.pfandTrips), labourH: num(be.labourH),
        } : undefined;
        return { feasible: v.feasible !== "no" && v.feasible !== false, floors: num(v.floors),
            needs: rows, spent: num(v.spent), purse: num(v.purse), income: num(v.income),
            pfandTrips: num(v.pfandTrips), labourH: num(v.labourH), bestEffort };
    }
    catch {
        return null;
    }
}
// One week of living is always pinned (family.scm: with-col-fixed! on
// p|rp-hh-living), and household.scm's rp-hh-living always deposits the same
// 12 containers a week regardless of the ledger — 0.6 of PFAND_PER_TRIP's 20,
// the same 0.6 trips every purse level clears in the pinned table above. The
// real solve always finds the 0.24 h to cash it in (it is far cheaper than
// anything it buys); the estimate below assumes the same.
const WEEKLY_PFAND_EUR = 0.6 * PFAND_PER_TRIP;
/** The bills the ledger's own arithmetic gives, with no solve: each tier's €
 *  asked less the purse and the household's own weekly Pfand income
 *  (WEEKLY_PFAND_EUR — the one household income a real solve always finds
 *  worth collecting, so the estimate nets it the same way "spent"/"short by"
 *  already do), and its errands (a quarter-hour per unit bought, the
 *  acquisition recipe's own labour) less the week's hours — both clamped at
 *  zero. What the commons still prices beyond this: whether the labour is
 *  actually there to run each errand, and any income beyond the Pfand. */
export function estimateBills(ns, purseEur, hours) {
    const ERRAND_H = 0.25;
    const fundsEur = purseEur + WEEKLY_PFAND_EUR;
    let askEur = 0, askH = 0, prevE = 0, prevH = 0;
    const tiers = BILL_TIERS.map(({ tier }) => {
        for (const n of ns.filter(n => n.kind === tier)) {
            askEur += n.cost * n.want;
            askH += ERRAND_H * n.want;
        }
        const eur = Math.max(0, askEur - fundsEur), h = Math.max(0, askH - hours);
        const row = { tier, eur, hours: h, stepEur: eur - prevE, stepHours: h - prevH, feasible: true };
        prevE = eur;
        prevH = h;
        return row;
    });
    return { tiers, eurPerHour: eurPerHour(), residueEur: 0, residueHours: 0, estimate: true };
}
function parseBills(reply) {
    if (typeof reply !== "string" || !reply || reply.startsWith("err:"))
        return null;
    try {
        const v = JSON.parse(reply);
        const rows = (Array.isArray(v.tiers) ? v.tiers : []).map((r) => ({
            tier: WIRE_TIER[String(r.tier)] ?? "floor",
            eur: num(r.eur), hours: num(r.hours), stepEur: num(r.stepEur), stepHours: num(r.stepHours),
            feasible: r.feasible !== "no" && r.feasible !== false,
        }));
        if (rows.length !== BILL_TIERS.length)
            return null;
        return { tiers: rows, eurPerHour: num(v.eurPerHour), residueEur: num(v.residueEur), residueHours: num(v.residueHours) };
    }
    catch {
        return null;
    }
}
/** One door of the household's solve. The device answers first — the ledger stays
 *  on it — and the commons only when the device cannot run the solve at all; the
 *  planner's own refusal is final either way. ARGS are the door's arguments, the
 *  same in the worker's and the session's spelling; COMMONS is the session's door,
 *  when there is one. */
function ask(door, args, commons, done) {
    askLocal(door, args).then(reply => {
        if (reply.startsWith(UNAVAILABLE) && commons)
            commons(...args, done);
        else
            done(reply);
    });
}
const offline = (reply) => typeof reply === "string" && reply.startsWith(UNAVAILABLE);
let billsSeq = 0, splitSeq = 0; // the latest ask wins: an older answer arriving late is dropped
/** The three bills: this device's solve, else the commons, else the ledger's own arithmetic. */
export function solveBills() {
    const fallback = estimateBills(needs(), purse(), labourH());
    const mine = ++billsSeq;
    billsNote.set("");
    ask("bills", [JSON.stringify(needs()), purse(), labourH(), weighted(), eurPerHour(),
        JSON.stringify(members()), perCitizenHours()], HANDLERS.familyBills, (reply) => {
        if (mine !== billsSeq)
            return;
        const b = parseBills(reply);
        if (b) {
            bills.set(b);
            return;
        }
        bills.set(fallback);
        billsNote.set(offline(reply)
            ? "offline — the ledger's own arithmetic; the commons prices the errands and the Pfand run"
            : "the ledger's own arithmetic" +
                (typeof reply === "string" && reply.startsWith("err:") ? ` — ${reply.slice(4)}` : " — the commons did not answer"));
    });
}
/** Run the split: this device's solve, else the commons, else the measured table when the ledger is the default. */
export function solve() {
    solveBills();
    const fallback = demoSplit();
    const mine = ++splitSeq;
    busy.set(true);
    note.set("");
    fault.set("");
    ask("split", [JSON.stringify(needs()), purse(), labourH(), weighted(), JSON.stringify(members()), perCitizenHours()], HANDLERS.familySplit, (reply) => {
        if (mine !== splitSeq)
            return;
        busy.set(false);
        const s = parseReply(reply);
        if (s) {
            split.set(s);
            return;
        }
        split.set(fallback);
        if (offline(reply)) {
            note.set(fallback ? "offline — the split the planner test measured for this ledger"
                : "offline — an edited ledger needs a solve; sign in");
            return;
        }
        if (typeof reply === "string" && reply.startsWith("err:"))
            fault.set(reply.slice(4));
        note.set(fallback ? "the commons did not answer — showing the measured split" : "the commons did not answer");
    });
}
function update(i, key, value) {
    needs.update(ns => ns.map((n, j) => j !== i ? n
        : key === "person" || key === "what" ? { ...n, [key]: value.trim() }
            : key === "kind" ? { ...n, kind: KINDS.includes(value) ? value : "des" }
                : { ...n, [key]: Math.max(0, num(value)) }));
    split.set(null);
}
function remove(i) { needs.update(ns => ns.filter((_, j) => j !== i)); split.set(null); }
function add() { needs.update(ns => [...ns, { person: "", what: "", cost: 10, want: 1, voice: 10, kind: "des" }]); split.set(null); }
/** PERSON's declared standing, or the equal-citizen default (capacity 100%, 0 hours) if undeclared. */
function memberOf(person) { return members().find(m => m.person === person) ?? { person, capacity: 1, hours: 0 }; }
function updateMember(person, key, value) {
    const v = key === "capacity" ? Math.max(0, Math.min(1, num(value) / 100)) : Math.max(0, num(value));
    members.update(ms => {
        const i = ms.findIndex(m => m.person === person);
        if (i < 0)
            return [...ms, { ...memberOf(person), [key]: v }];
        return ms.map((m, j) => j === i ? { ...m, [key]: v } : m);
    });
    split.set(null);
}
function drawLedger() {
    const ns = needs();
    const individuals = individualsOf(ns.map(n => n.person), groups());
    personSlotOf = personSlots(ns.map(n => n.person));
    // the header names the week and its ask; the controls sit right under it,
    // in reach before the ledger is read. Rendered into its own host, adjacent
    // to (never over) the persistent .fm-bills sibling — what the week would
    // take belongs right after the purse, before the voice folds away.
    render("#familystage .fm-ledger-head", html `
    <div class="fm-head">
      <span class="fm-title">the family's week</span>
      <span class="fm-legend">${KINDS.map(k => html `<i class="fm-k" data-kind=${k} title="${KIND_HINT[k]}">${KIND_LABEL[k]}</i>`)}</span>
      <span class="fm-ask"><small>asked</small><b>${eur(totalAsk(ns))}</b><small>${KINDS.map(k => `${KIND_LABEL[k]}s ${eur(totalAsk(ns, k))}`).join(" · ")}</small></span>
    </div>
    <div class="fm-row">
      <label>purse €<input class="fm-in fm-num" type="number" min="0" step="10" value=${purse()} onchange=${(e) => { purse.set(Math.max(0, num(e.target.value))); split.set(null); }}></label>
      <label>hours<input class="fm-in fm-num" type="number" min="0" step="1" value=${labourH()} onchange=${(e) => { labourH.set(Math.max(0, num(e.target.value))); split.set(null); }}></label>
      <label class="fm-tog"><input type="checkbox" ${weighted() ? "checked" : ""} onchange=${(e) => { weighted.set(e.target.checked); split.set(null); }}> priority-weighted</label>
      <a class="fm-go ${busy() ? "busy" : ""}" onclick=${solve}>${busy() ? "splitting…" : "split the purse"}</a>
    </div>`);
    render("#familystage .fm-ledger-fields", html `
    <details class="fm-voice">
      <summary title="consumer voice (playnet.typ §The credit identity, the SAME law the federation reads): a member's capacity to labour and the hours they contributed to the household's own reproduction this week shape their voice on the split, atop the equal citizenship every member always carries — a child's, or anyone's, reduced capacity never reads as zero. Left at 100% capacity and 0 hours, every member reads as an equal citizen, exactly as before."><span class="fm-lbl">consumer voice</span><small>capacity and hours shape each member's say on the split; untouched, everyone is an equal citizen</small></summary>
      <div class="fm-voice-grid">
        <span class="fm-voice-hd"><span class="fm-lbl">member</span><span class="fm-lbl">capacity</span><span class="fm-lbl">hours this week</span></span>
        ${individuals.map(p => html `<span class="fm-voice-row" data-p=${personSlot(p)}><span class="fm-voice-name"><i class="fm-pdot"></i>${p}</span><label><input class="fm-in fm-num fm-voice-in" data-field="capacity" type="number" min="0" max="100" step="5" value=${Math.round(memberOf(p).capacity * 100)} onchange=${(e) => updateMember(p, "capacity", e.target.value)}><span class="fm-unit">%</span></label><label><input class="fm-in fm-num fm-voice-in" data-field="hours" type="number" min="0" step="1" value=${memberOf(p).hours} onchange=${(e) => updateMember(p, "hours", e.target.value)}><span class="fm-unit">h</span></label></span>`)}
        <span class="fm-voice-row fm-voice-week" title="the full week a member's hours are read against — social free time f = 1 − (everyone's hours) / (members × this), the citizenship share every member draws on top of contribution by ability"><span class="fm-voice-name">full week</span><span></span><label><input class="fm-in fm-num fm-voice-in" type="number" min="1" step="1" value=${perCitizenHours()} onchange=${(e) => { perCitizenHours.set(Math.max(1, num(e.target.value))); split.set(null); }}><span class="fm-unit">h</span></label></span>
      </div>
    </details>
    <table class="fm-table">
      <colgroup><col class="c-who"><col class="c-what"><col class="c-num"><col class="c-num"><col class="c-kind"><col class="c-lvl"><col class="c-x"></colgroup>
      <thead><tr><th>who</th><th>needs</th><th>€ each</th><th>qty</th><th title="a RIGHT is a hard wall (below it there is no plan); a NEED can be short but never zeroed; a WANT can be set aside for exactly the voice attached to it, quietest first">kind</th><th title="the voice attached to this row — the emphasis spent on it, on a geometric ladder to 1000; orders the needs among themselves and the wants among themselves. A right takes none: the wall is free">voice</th><th></th></tr></thead>
      <tbody>${ns.map((n, i) => html `
        <tr data-p=${personSlot(n.person)}>
          <td>${personIcon(n.person, ns)}<input class="fm-in fm-who" value=${n.person} onchange=${(e) => update(i, "person", e.target.value)}></td>
          <td><input class="fm-in fm-what" value=${n.what} onchange=${(e) => update(i, "what", e.target.value)}></td>
          <td><input class="fm-in fm-num" type="number" min="0" step="1" value=${n.cost} onchange=${(e) => update(i, "cost", e.target.value)}></td>
          <td><input class="fm-in fm-num" type="number" min="0" step="1" value=${n.want} onchange=${(e) => update(i, "want", e.target.value)}></td>
          <td><select class="fm-in fm-kind" data-kind=${n.kind} onchange=${(e) => update(i, "kind", e.target.value)}>${KINDS.map(k => html `<option value=${k} ${k === n.kind ? "selected" : ""}>${KIND_LABEL[k]}</option>`)}</select></td>
          <td>${n.kind === "floor" ? html `<span class="fm-novoice" title="a right takes no voice — the wall is free">free</span>`
        : html `<input class="fm-in fm-lvl" type="range" min="0" max=${VOICE_LADDER.length - 1} step="1" value=${ladderIndex(n.voice)} onchange=${(e) => update(i, "voice", String(VOICE_LADDER[Number(e.target.value)]))}><span class="fm-lvln">${n.voice}</span>`}</td>
          <td><a class="fm-x" title="drop this need" onclick=${() => remove(i)}>×</a></td>
        </tr>`)}
      </tbody>
    </table>
    <div class="fm-foot"><a class="fm-add" onclick=${add}>+ a need</a></div>`);
}
/** The rights themselves, as a governance object apart from the ledger of
 *  forms built on them — docs/rights.md, form-and-substance.typ "The
 *  substance is a vector": one row per (person, substance) a floor
 *  actually governs, blind to which form supplies it. Today that is
 *  nutrition (fed by groceries) and medicine (fed by itself, no substitute
 *  in this ledger) — the vector a real steward would extend with a housing
 *  row the same way, one more floor naming its own substance, no new UI. */
function drawRights() {
    const rows = rightsVector(needs());
    render("#familystage .fm-rights", rows.length === 0 ? "" : html `
    <div class="fm-rights-head">
      <span class="fm-lbl" title="a floor on the substance a form reduces to, blind to which form supplies it — the right itself, apart from any one need or want built on it (docs/rights.md, form-and-substance.typ)"><i class="fm-k" data-kind="floor">right</i> the rights</span>
    </div>
    <div class="fm-rights-rows">${rows.map(r => html `
      <span data-p=${personSlot(r.person)}><i class="fm-pdot"></i>${r.person}</span>
      <span class="fm-rights-sub">${r.substance}</span>
      <span class="fm-rights-qty">${r.qty}<small>/ week</small></span>
      <span class="fm-rights-forms">fed by ${r.forms.join(", ")}${r.forms.length === 1 && r.forms[0] === r.substance ? " — no substitute yet" : ""}</span>`)}
    </div>`);
}
/** The per-person breakdown, shared by a real split and a best-effort one:
 *  sort control, then each person's bar and their rows sorted kind-then-voice. */
function peopleBlocks(rows) {
    const ind = individualsOf(rows.map(r => r.person), groups());
    const order = sortOrder();
    const people = byPerson(rows)
        .map((p, i) => ({ p, i, rank: blockRank(blockSize(p.person, rows), ind.length, order) }))
        .sort((a, b) => a.rank - b.rank || a.i - b.i).map(x => x.p);
    const sorted = (rs) => [...rs].sort((a, b) => KIND_ORDER[a.kind] - KIND_ORDER[b.kind] || b.voice - a.voice);
    return html `
    <div class="fm-sort">
      <span class="fm-lbl" title="every row is a block of the household's individuals — the whole, one person, or a group between; this orders the blocks">sort</span>
      ${SORT_ORDERS.map(o => html `<a class="fm-sort-opt ${o.id === order ? "on" : ""}" onclick=${() => sortOrder.set(o.id)}>${o.label}</a>`)}
    </div>
    <div class="fm-people">${people.map(p => html `
      <div class="fm-person ${p.person.trim().toLowerCase() === "all" ? "fm-all" : ""}" data-p=${personSlot(p.person)}>
        <div class="fm-pname">${personIcon(p.person, rows)}${p.person} <small>${eur(p.got)} of ${eur(p.ask)}</small></div>
        <div class="fm-bar"><div class="fm-fill fm-fill-p" style="width:${pct(p.met)}"></div></div>
        ${sorted(rows.filter(r => r.person === p.person)).map(r => html `
          <div class="fm-need" title="${r.what} — ${r.kind === "floor" ? "a right" : `${KIND_LABEL[r.kind]}, voice ${r.voice}`}: ${r.got.toFixed(2)} of ${r.want} at ${eur(r.cost)} each">
            <span class="fm-nlbl"><i class="fm-k" data-kind=${r.kind}>${KIND_LABEL[r.kind]}</i>${r.what}${r.want !== 1 ? html ` <small>${r.got.toFixed(1)}/${r.want}</small>` : ""}</span>
            <div class="fm-bar"><div class="fm-fill" data-kind=${r.kind} style="width:${pct(r.met)}"></div></div>
            <span class="fm-npct">${pct(r.met)}</span>
          </div>`)}
      </div>`)}
    </div>`;
}
function drawSplit() {
    const s = split();
    const n = note();
    const f = fault();
    const faultBox = f ? html `<div class="fm-fault"><b>the planner could not solve this week</b><code>${f}</code></div>` : "";
    if (!s) {
        render("#familystage .fm-split", html `${faultBox}<div class="fm-note">${n || "state every need as it is, then split the purse"}</div>`);
        return;
    }
    if (!s.feasible) {
        // Two ways to have no plan, and the face says which: the purse cannot
        // cover the rights (money), or it can and the week's hours cannot run
        // the errands that bring every need home (time — each need is an
        // acquisition errand with a labour cost). Beside the refusal, best-effort
        // (when the commons could compute one) shows what the SAME purse still
        // does if every right is read as a need instead — never a plan, just the
        // honest floor under "raise the purse."
        const moneyShort = s.floors > s.purse;
        const be = s.bestEffort;
        render("#familystage .fm-split", html `
      ${moneyShort ? html `
        <div class="fm-sum"><span class="fm-short">no plan: the rights alone ask <b>${eur(s.floors)}</b> and the purse holds <b>${eur(s.purse)}</b></span></div>
        <div class="fm-note">a right is not shaved — the family cannot reproduce on this purse, and the split says so rather than pretend. Raise the purse, or restate a right as a need.</div>` : html `
        <div class="fm-sum"><span class="fm-short">no plan: the purse covers the rights (<b>${eur(s.floors)}</b> of <b>${eur(s.purse)}</b>), and <b>${s.labourH}&nbsp;h</b> cannot run the errands</span></div>
        <div class="fm-note">every need is an errand — someone walks it home, and that takes time from the week's hours. Raise the hours.</div>`}
      ${be && html `
        <div class="fm-sum fm-best-effort"><span class="fm-short">still not a plan — but here is the purse's best use anyway, every right read as a need so scarcity spreads instead of nothing being bought: spent <b>${eur(be.spent)}</b> of <b>${eur(be.purse)}</b></span></div>
        ${peopleBlocks(be.needs)}`}
      ${faultBox}
      ${n && html `<div class="fm-note">${n}</div>`}`);
        return;
    }
    const short = s.spent < totalAsk(s.needs) - 0.5;
    // "short by" and the bills panel's wants tier ("what the week would take")
    // are the SAME number whenever the household is short: at any shortfall
    // this solve always spends the whole purse+Pfand (every unmet row still
    // has a strictly beneficial margin), so spent = funds available and
    // totalAsk − spent = totalAsk − funds = the wants tier's own "more" — the
    // bills panel's own arithmetic (estimateBills's WEEKLY_PFAND_EUR, or a
    // real solve's own tally). When it repeats, this line says nothing at all
    // — "what the week would take" is the one place it lives — rather than
    // restate it as a bare, contextless "short". A shortfall the two panels
    // price differently (an hours-bound one can) still gets its own figure here.
    const gap = totalAsk(s.needs) - s.spent;
    const wantsBill = bills()?.tiers?.[2]?.eur;
    const repeats = short && wantsBill !== undefined && Math.abs(wantsBill - gap) < 0.5;
    render("#familystage .fm-split", html `
    <div class="fm-sum">
      <span class="fm-sum-main">spent <b>${eur(s.spent)}</b> of purse <b>${eur(s.purse)}</b>${s.income > 0.005 ? html ` + Pfand <b>${eur(s.income)}</b> <small>(${s.pfandTrips.toFixed(1)} trips)</small>` : ""}</span>
      ${short && repeats ? "" : html `<span class="${short ? "fm-short" : "fm-ok"}">${short
        ? html `short by ${eur(gap)}<small>rights whole, needs never zero, wants by voice</small>`
        : "everyone met"}</span>`}
    </div>
    ${peopleBlocks(s.needs)}
    ${faultBox}
    ${n && html `<div class="fm-note">${n}</div>`}`);
}
/** The week asked backwards: one row per tier, what it would take beyond the
 *  purse and the hours on hand. Whole = nothing more to find; a tier the
 *  commons certifies infeasible hit a wall nothing sells. Rendered into its
 *  own host in the ledger column, right below the purse row and above
 *  consumer voice — the positive read of the week (what it takes, tier by
 *  tier, with the covered tiers reading as "whole on this purse") is what a
 *  household should see right after stating the purse, before it edits the
 *  ledger further. */
function drawBills() {
    const b = bills();
    const n = billsNote();
    if (!b) {
        render("#familystage .fm-bills", html `<div class="fm-note">${n}</div>`);
        return;
    }
    const hrs = (h) => h.toFixed(1) + " h";
    const stepOf = (e, h) => {
        const parts = [];
        if (Math.abs(e) >= 0.5)
            parts.push((e > 0 ? "+" : "−") + eur(Math.abs(e)));
        if (Math.abs(h) >= 0.05)
            parts.push((h > 0 ? "+" : "−") + hrs(Math.abs(h)));
        return parts.length ? parts.join(" ") : "same";
    };
    render("#familystage .fm-bills", html `
      <div class="fm-bills-head">
        <span class="fm-lbl" title="the plan asked backwards: assume the tier is met, and read what meeting it needs beyond the purse of ${eur(purse())} and ${labourH()} h — each tier held as a wall, the softer tiers set aside, so a bill is exactly its tier">what the week would take</span>
        <label title="a euro priced in hours, so the solve can weigh finding money against finding time">€ per hour <input class="fm-in fm-num" type="number" min="1" step="1" value=${eurPerHour()} onchange=${(e) => { eurPerHour.set(Math.max(1, num(e.target.value))); solveBills(); }}></label>
      </div>
      <div class="fm-bills-rows">${b.tiers.map((t, i) => {
        const whole = t.feasible && t.eur < 0.5 && t.hours < 0.05;
        const spec = BILL_TIERS[i];
        return html `<span class="fm-bills-tier" title="${spec.hint}"><i class="fm-k" data-kind=${t.tier}>${KIND_LABEL[t.tier]}</i>${spec.label}</span><span class="${!t.feasible ? "fm-bills-wall" : whole ? "fm-bills-whole" : "fm-bills-eur"}">${!t.feasible ? "no plan — a wall nothing sells" : whole ? "whole on this purse" : `${eur(t.eur)} more`}</span><span class="fm-bills-h">${t.feasible && t.hours >= 0.05 ? hrs(t.hours) + " more" : ""}</span><span class="fm-bills-step" title="the price of this tier over the one below">${i === 0 ? "" : stepOf(t.stepEur, t.stepHours)}</span>`;
    })}</div>
      ${n ? html `<div class="fm-note">${n}</div>` : b.estimate ? "" : html `<div class="fm-note">read net of the ${eur(b.residueEur)} and ${hrs(b.residueHours)} a solve holding nothing buys anyway</div>`}`);
}
/** € as the header reads it: "€1.13M", "€753k", "€2,100". */
const money = (x) => {
    const a = Math.abs(x), s = x < 0 ? "−" : "";
    return s + (a >= 1e6 ? "€" + (a / 1e6).toFixed(2) + "M" : a >= 1e4 ? "€" + Math.round(a / 1e3) + "k" : "€" + Math.round(a).toLocaleString("en"));
};
const ymLabel = (ym) => { const [y, m] = ym.split("-"); return ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][Number(m) - 1] + " " + y; };
/** The ledger as the runway's outflows: each row's weekly ask, monthly, until its last month. */
function ledgerOutflows(ns) {
    return ns.map(n => ({ what: `${n.person}: ${n.what}`, monthly: n.cost * n.want * WEEKS_PER_MONTH, until: n.until }));
}
function drawRunway() {
    const cfg = { ...runway(), outflows: ledgerOutflows(needs()) };
    const r = simulate(cfg);
    const pts = r.points;
    // the plot: a balance line over a deficit strip, month on the x axis. The
    // viewBox is the plot's own width in CSS pixels, so its text is never
    // stretched — a resize redraws (plotWidth, observed at boot).
    const W = plotWidth(), H = 190, L = 46, Rt = 12, top = 12, mid = 130, strip = 176;
    // Time runs logarithmically: the first year takes as much of the axis as
    // the last three decades, because the next months are what the household
    // can act on — the far horizon is there, at its true value, but small.
    const xl = d3.scaleLog().domain([1, pts.length]).range([L, W - Rt]);
    const x = (i) => xl(i + 1);
    const xw = (i) => Math.max(0.6, x(Math.min(pts.length - 1, i + 1)) - x(i));
    const bmax = Math.max(cfg.capital, ...pts.map(p => p.balance)), bmin = Math.min(0, ...pts.map(p => p.balance));
    const y = d3.scaleLinear().domain([bmin, bmax]).range([mid, top]);
    const nmax = Math.max(1, ...pts.map(p => Math.abs(p.net)));
    const yn = d3.scaleLinear().domain([-nmax, nmax]).range([strip, mid + 10]);
    const bal = d3.line().x((_, i) => x(i)).y(p => y(p.balance));
    const red = d3.area().x((_, i) => x(i)).y0(() => y(0)).y1(p => y(Math.min(0, p.balance)));
    // year ticks: the Januaries, thinned to the ones that keep 34px apart on
    // the log axis — dense near now, sparse toward the horizon
    const years = [];
    let lastTick = -Infinity;
    pts.forEach((p, i) => { if (p.ym.endsWith("-01") && x(i) - lastTick >= 34) {
        years.push({ i, p });
        lastTick = x(i);
    } });
    const marks = [
        ...cfg.oneOffs.map(o => ({ i: pts.findIndex(p => p.ym === o.when), what: o.what })),
        ...cfg.incomes.flatMap(s => [s.from && { i: pts.findIndex(p => p.ym === s.from), what: `${s.what} begins` },
            s.until && { i: pts.findIndex(p => p.ym === s.until), what: `${s.what} ends` }]),
    ].filter((m) => !!m && m.i >= 0);
    const out = r.runsOut === null ? null : pts.findIndex(p => p.ym === r.runsOut);
    const deficit = r.now.net < 0;
    const yrs = (m) => (m / 12).toFixed(1) + " y";
    const fact = (k, v, sub) => html `<span class="fm-rw-fact"><span class="fm-lbl">${k}</span><b>${v}</b>${sub ? html `<small>${sub}</small>` : ""}</span>`;
    render("#familystage .fm-runway", html `
    <div class="fm-rw-side">
      <span class="fm-lbl">runway</span>
      <b class="fm-rw-hero ${r.runsOut ? "fm-short" : "fm-ok"}">${r.runsOut ? `runs out ${ymLabel(r.runsOut)}` : `funded through ${ymLabel(cfg.horizon)}`}</b>
      <span class="fm-rw-sub">${r.runsOut ? `${yrs(r.monthsFunded)} funded on ${money(cfg.capital)} pooled` : `${money(cfg.capital)} pooled`}</span>
      <div class="fm-rw-facts">
        ${fact("this month", (deficit ? "−" : "+") + money(Math.abs(r.now.net)), `${money(r.now.income)} in · ${money(r.now.outflow)} out`)}
        ${fact("lowest", money(r.lowest.balance), ymLabel(r.lowest.ym))}
        ${fact("over the horizon", (r.integral < 0 ? "−" : "+") + money(Math.abs(r.integral)), `to ${ymLabel(cfg.horizon)}`)}
        ${fact("to earn & socialize", r.toEarn > 0 ? money(r.toEarn) : "nothing", r.toEarn > 0 ? `${money(r.toEarn / Math.max(1, r.monthsFunded))} a month until it runs out` : undefined)}
      </div>
      <div class="fm-rw-row">
        <label>pooled €<input class="fm-in fm-num fm-rw-in" type="number" min="0" step="1000" value=${cfg.capital} onchange=${(e) => runway.update(c => ({ ...c, capital: Math.max(0, num(e.target.value)) }))}></label>
        <label>real return %<input class="fm-in fm-num fm-rw-in" type="number" step="0.5" value=${(cfg.realReturn * 100).toFixed(1)} onchange=${(e) => runway.update(c => ({ ...c, realReturn: num(e.target.value) / 100 }))}></label>
      </div>
    </div>
    <div class="fm-rw-main">
      <svg class="fm-rw-plot" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none">
        <line class="fm-rw-zero" x1=${L} x2=${W - Rt} y1=${y(0)} y2=${y(0)}></line>
        <path class="fm-rw-red" d=${red(pts) || ""}></path>
        <path class="fm-rw-bal" d=${bal(pts) || ""}></path>
        ${pts.map((p, i) => html `<rect class="fm-rw-net ${p.net < 0 ? "neg" : "pos"}" x=${x(i)} width=${xw(i)} y=${Math.min(yn(0), yn(p.net))} height=${Math.abs(yn(p.net) - yn(0))}></rect>`)}
        <line class="fm-rw-zero" x1=${L} x2=${W - Rt} y1=${yn(0)} y2=${yn(0)}></line>
        ${years.map(({ i, p }) => html `<text class="fm-rw-tick" x=${x(i)} y=${H - 2}>${p.ym.slice(0, 4)}</text>`)}
        <text class="fm-rw-ax" x=${L - 4} y=${y(bmax) + 4}>${money(bmax)}</text>
        ${y(0) - y(bmax) > 11 && html `<text class="fm-rw-ax" x=${L - 4} y=${y(0) + 4}>0</text>`}
        <text class="fm-rw-ax" x=${L - 4} y=${yn(nmax) + 4}>+${money(nmax)}</text>
        <text class="fm-rw-ax" x=${L - 4} y=${yn(-nmax) + 1}>−${money(nmax)}</text>
        ${marks.map((m, k) => html `<line class="fm-rw-mark" x1=${x(m.i)} x2=${x(m.i)} y1=${top} y2=${mid}></line><text class="fm-rw-mlbl" x=${x(m.i) + 4} y=${mid - 6 - (k % 6) * 11}>${m.what}</text>`)}
        ${out !== null && html `<circle class="fm-rw-out" cx=${x(out)} cy=${y(0)} r="4"></circle>`}
      </svg>
      <span class="fm-rw-legend"><i class="fm-rw-li bal"></i>the pool <i class="fm-rw-li neg"></i>monthly deficit <i class="fm-rw-li pos"></i>monthly surplus · in today's euros; a gift between members moves nothing here</span>
    </div>`);
}
// Opt-in, machine-local ledgers — one per scale a household states its own
// week or its own capital at. Every file here is gitignored: never
// committed, never shipped to anyone else's clone or onion visit, so this is
// the one door real names/amounts can come in by without touching this
// repo's (public, pseudonymous) history. `?familydata=<key>` selects one;
// absent the flag, or absent the file, nothing changes — every other
// visitor, and every test, still sees the pinned demo week untouched.
const LOCAL_LEDGERS = {
    local: "app/family-data.local.json",
    capital: "app/family-data-capital.local.json",
};
async function loadLocalLedger() {
    const key = new URLSearchParams(location.search).get("familydata");
    const path = key ? LOCAL_LEDGERS[key] : undefined;
    if (!path)
        return null;
    try {
        const res = await fetch(path);
        if (!res.ok)
            return null;
        const v = await res.json();
        if (!Array.isArray(v.needs))
            return null;
        const ym = (s) => typeof s === "string" && /^\d{4}-\d{2}$/.test(s) ? s : undefined;
        const rows = v.needs.map((r) => ({
            person: String(r.person), what: String(r.what),
            cost: num(r.cost), want: num(r.want), voice: num(r.voice),
            kind: KINDS.includes(String(r.kind)) ? r.kind : "des",
            until: ym(r.until),
        }));
        const stream = (s) => ({ what: String(s.what), monthly: num(s.monthly), from: ym(s.from), until: ym(s.until) });
        const rw = v.runway;
        const runwayCfg = rw && typeof rw === "object" ? {
            capital: num(rw.capital), start: ym(rw.start) ?? thisMonth(), horizon: ym(rw.horizon) ?? monthsAfter(thisMonth(), 12 * 30),
            realReturn: num(rw.realReturn),
            incomes: Array.isArray(rw.incomes) ? rw.incomes.map(stream) : [],
            outflows: [],
            oneOffs: Array.isArray(rw.oneOffs) ? rw.oneOffs.map((o) => ({ what: String(o.what), amount: num(o.amount), when: ym(o.when) ?? thisMonth() })) : [],
        } : undefined;
        return {
            needs: rows,
            purse: typeof v.purse === "number" ? v.purse : undefined,
            labourH: typeof v.labourH === "number" ? v.labourH : undefined,
            weighted: typeof v.weighted === "boolean" ? v.weighted : undefined,
            runway: runwayCfg,
            groups: v.groups && typeof v.groups === "object"
                ? Object.fromEntries(Object.entries(v.groups)
                    .filter(([, m]) => Array.isArray(m)).map(([g, m]) => [g.trim().toLowerCase(), m.map(String)]))
                : undefined,
        };
    }
    catch {
        return null;
    }
}
let booted = false;
export function initFamily() {
    if (!booted) {
        booted = true;
        const stage = document.getElementById("familystage");
        if (!stage)
            return;
        // the ledger on the left, its consequence (the split, then the week
        // asked backwards) on the right, and the runway as a band beneath both
        // — the runway band itself only when RUNWAY_ENABLED. Inside the ledger,
        // .fm-bills and .fm-rights sit between the head (drawLedger's -head
        // host) and the voice/table (drawLedger's -fields host) — their own
        // persistent elements, never replaced by drawLedger's re-renders, so an
        // edit to the ledger never blanks either panel out from under it. What
        // the week would take, then what is actually protected regardless, then
        // the editable forms themselves.
        stage.innerHTML = '<div class="fm-ledger"><div class="fm-ledger-head"></div><div class="fm-bills"></div><div class="fm-rights"></div><div class="fm-ledger-fields"></div></div><div class="fm-right"><div class="fm-split"></div></div>'
            + (RUNWAY_ENABLED ? '<div class="fm-runway"></div>' : '');
        effect(drawLedger);
        effect(drawRights);
        effect(drawSplit);
        effect(drawBills);
        if (RUNWAY_ENABLED) {
            effect(drawRunway);
            const main = stage.querySelector(".fm-runway");
            // the runway band is [side | main]; the plot spans the main column, so
            // its width is the band's less the side's — measured, so the svg's
            // viewBox equals its rendered box and nothing in it is stretched
            new ResizeObserver(() => {
                const side = main.querySelector(".fm-rw-side");
                const w = main.clientWidth - (side ? side.offsetWidth + 26 : 0);
                if (w > 200)
                    plotWidth.set(Math.round(w));
            }).observe(main);
        }
        loadLocalLedger().then(local => {
            if (local) {
                needs.set(local.needs);
                if (local.purse !== undefined)
                    purse.set(local.purse);
                if (local.labourH !== undefined)
                    labourH.set(local.labourH);
                if (local.weighted !== undefined)
                    weighted.set(local.weighted);
                if (local.runway !== undefined)
                    runway.set(local.runway);
                if (local.groups !== undefined)
                    groups.set(local.groups);
            }
            solve();
        });
    }
}
