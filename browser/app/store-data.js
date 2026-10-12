// app/store-data.ts — what is held, as the faces that show it read it.
//
// The inventory list in the time face's rail and the store face on the stage
// show the same stock, so they read one set of signals from one module: the row
// model (a live inventory record, or the demo stock), the readings and history
// of each spec, the schedule of counts and the offering of those that are due,
// the contests of this person's counts, and the prints. A face draws; this holds
// and fetches. Nothing here draws a row.
import { isAdjustment } from "./actions-catalogue.js";
import { MODES, HANDLERS } from './core.js';
import { signal } from './reactive.js';
import { openCapture } from './capture.js';
import { placePath } from './store-tree.js';
import { labelSheet, nameCards, print } from './labels.js';
import { forgetContests } from './contests.js';
import { readSchedule, cadence, parseReply, replyRows, refused, finite } from './count.js';
import { stockOf, lotDate } from './stock.js';
import { attached, knownPlaces, knownResources } from './books.js';
import { demoStore } from './demo/store.js';
import { perishable } from './store-view.js';
import { withCodes } from './label-codes.js';
import { on } from './bus.js';
// the rails, in the order inventory groups them and in MODES' own colours (the
// single source of truth for what each rail means — main.js MODES). `own` is
// the physical-custody default when a resource declares no distribution-mode.
export const RAIL_ORDER = ["own", "common", "claim"];
export const railMeta = (k) => MODES[k] || MODES.own;
// spec → emoji, so resources that carry none still read at a glance: seeded
// from the demo commons (demo/store.ts), which names one for each of its specs.
const EMOJI = {};
for (const r of demoStore().inventory.resources ?? []) {
    const spec = String(r["conforms-to"] ?? "");
    if (spec && r.emoji && !EMOJI[spec])
        EMOJI[spec] = String(r.emoji);
}
export const emojiFor = (spec) => (spec && EMOJI[spec]) || "📦";
// an inventory record, the gateway's or the demo's → the row shape the list draws. Lenient: the wire may
// omit a field (distribution-mode isn't always projected), so rail defaults to
// physical custody (yours) and the perishability reads from stage/state.
function normRow(r) {
    const s = stockOf(r);
    const dm = s.mode || r.distributionMode;
    const rail = dm === "communal" ? "common"
        : dm === "individual-claimable" ? "claim"
            : (r.rail || "own");
    // where it is: the place's path through the places it is inside, when the
    // scope's table knows the place; else what the wire says
    const at = s.location ? placePath(s.location, knownPlaces()) : "";
    // how it keeps: a lot's date says which date it is
    const dated = lotDate(s.expires, s.expiresKind);
    const keeps = String(r.keeps || dated || s.stage || s.state || "");
    return {
        id: s.id || undefined,
        emoji: String(r.emoji || emojiFor(s.spec)),
        name: String(r.name || s.spec || "resource"),
        spec: s.spec,
        onhand: s.onhand, unit: s.unit,
        rail, where: String(r["location-name"] || at || s.custodian || ""),
        keeps,
        location: s.location || undefined,
        containedIn: s.containedIn || undefined,
        expected: s.expected,
        code: s.code || undefined,
        perishable: perishable(keeps, s.expiresKind),
    };
}
const readings = new Map();
const history = new Map();
export const readingsTick = signal(0);
const num = (v) => finite(v) ?? 0;
function fetchHistory(spec) {
    if (history.has(spec))
        return;
    if (!HANDLERS.readingsBetween)
        return;
    history.set(spec, []); // asked once, the whole window open
    HANDLERS.readingsBetween(spec, "", "").then(r => {
        // an unreadable reply leaves the history line empty
        history.set(spec, replyRows(r).map(x => ({
            technique: String(x.technique || ""), action: String(x.action || ""), unit: String(x.unit || ""),
            latest: num(x.latest), at: String(x.at || ""),
        })));
        readingsTick.set(readingsTick() + 1);
    }).catch(() => { });
}
export function fetchReadings(spec) {
    fetchHistory(spec);
    if (readings.has(spec))
        return;
    const none = { rows: [], drift: { n: 0, meanAbs: 0, net: 0 }, latest: null };
    if (!HANDLERS.scopeReadings)
        return;
    readings.set(spec, none); // asked once
    HANDLERS.scopeReadings(spec).then(r => {
        const j = parseReply(r);
        if (refused(j))
            return; // an unreadable reply leaves the counts line empty
        readings.set(spec, {
            rows: Array.isArray(j.rows) ? j.rows : [],
            drift: { n: num(j.drift?.n), meanAbs: num(j.drift?.meanAbs), net: num(j.drift?.net) },
            latest: j.latest && typeof j.latest === "object" ? j.latest : null,
        });
        readingsTick.set(readingsTick() + 1);
    }).catch(() => { });
}
// the history line: the last readings in time order, each as its technique saw it —
// a flow as a quantity, a count as the signed difference it found
const HISTORY_SHOWN = 5;
export function historyLine(spec) {
    const rows = history.get(spec);
    if (!rows || !rows.length)
        return "";
    const shown = rows.slice(-HISTORY_SHOWN);
    const one = (r) => {
        const count = isAdjustment(r.action);
        const q = count ? `${r.latest > 0 ? "+" : ""}${r.latest.toFixed(1)}` : `${r.latest.toFixed(1)}${r.unit ? " " + r.unit : ""}`;
        return `${r.technique ? r.technique + " " : ""}${q}`;
    };
    return `seen ${shown.map(one).join(" → ")}${rows.length > shown.length ? ` (${rows.length} readings)` : ""}`;
}
// the counts line: how many counts have found the ledger off, and by how much
export function countsLine(spec, unit) {
    const w = readings.get(spec);
    if (!w || !w.drift.n)
        return "";
    const sign = w.drift.net > 0 ? "+" : "";
    return `${w.drift.n} count${w.drift.n === 1 ? "" : "s"} found the ledger off by ${sign}${w.drift.net.toFixed(1)}${unit ? " " + unit : ""}`;
}
// a count of a row: the capture sheet opens on the stock
export function countRow(r) {
    if (!r.id)
        return;
    openCapture({ resource: r.id, name: r.name, emoji: r.emoji, unit: r.unit, onhand: r.onhand, expected: r.expected, where: r.where });
}
// what a count lands is the next reading of the spec and moves the stock's own
// due date, whichever way the count was made (the figure screen, a photo row,
// the desk), so the counts and history lines and the schedule are asked again
// (docs/observation/capture.md §10)
on("counted", resource => {
    const spec = (stockData() ?? []).find(r => r.id === resource)?.spec;
    if (spec) {
        readings.delete(spec);
        history.delete(spec);
    }
    scheduleAsked = false;
    readingsTick.set(readingsTick() + 1);
});
// the schedule of counts (session/count-schedule): when each target is due and
// how often the plan's reliance and the ledger's drift have it counted. Asked
// once per stock push; a row reads its own line off it.
export const schedule = signal(new Map());
let scheduleAsked = false;
export function fetchSchedule() {
    if (scheduleAsked)
        return;
    scheduleAsked = true;
    Promise.resolve(HANDLERS.countSchedule?.("")).then(readSchedule)
        .then(rs => { schedule.set(new Map(rs.map(r => [r.id, r]))); }).catch(() => { scheduleAsked = false; });
}
// the counts that are due, laid as offers to whoever's turn it is
export function offerCounts() {
    if (!HANDLERS.planCounts) {
        printNote.set("sign in to offer counts");
        return;
    }
    printNote.set("offering…");
    HANDLERS.planCounts("announced", "", 3).then(raw => {
        const j = parseReply(raw);
        if (refused(j)) {
            printNote.set(j.err);
            return;
        }
        const n = Array.isArray(j.laid) ? j.laid.length : 0;
        printNote.set(n ? `${n} count${n === 1 ? "" : "s"} offered — each reaches its counter among their proposals`
            : j.refused === "max-open" ? "the offers already open are at their bound; the rest wait for them"
                : "every count that is due is already asked");
        scheduleAsked = false;
        fetchSchedule();
    }).catch(() => printNote.set("the gateway did not answer"));
}
// a row's line of the schedule: how often, and whether it is due
export function cadenceLine(id) {
    const r = id ? schedule().get(id) : undefined;
    if (!r)
        return "";
    return `counted ${cadence(r.interval)}${r.overdue ? " — due" : ""}`;
}
/** What is known of a stock besides its figure: how often it is counted, what the counts found, what was seen. */
export function rowFacts(r) {
    return [cadenceLine(r.id), r.spec ? countsLine(r.spec, r.unit) : "", r.spec ? historyLine(r.spec) : ""].filter(Boolean);
}
// the prints of what is shown: every thing on a sheet is known by a code, and
// one that has none is given it on the way (session/label-stock)
export const printNote = signal("");
export async function printShown(rows, cards) {
    if (!HANDLERS.labelStock) {
        printNote.set("sign in to print labels");
        return;
    }
    printNote.set("laying the sheet out…");
    const out = (await withCodes(rows)).map(r => ({ code: r.code, name: r.name, emoji: r.emoji, where: r.where }));
    if (!out.length) {
        printNote.set("nothing shown can carry a label");
        return;
    }
    print((cards ? nameCards : labelSheet)(out));
    printNote.set("");
}
// the stock: the gateway's books while they hold any, else the demo commons
// (demo/store.ts, the same row shape). A signal so a fresh push (the "inventory"
// topic) re-renders the list through the effect.
export const stockData = signal(null);
export function currentStock() {
    return knownResources().map(r => normRow(r));
}
/** The stock a count can land on: every row that names itself. */
export const heldStock = () => (stockData() ?? []).filter(r => !!r.id);
// the seam pushes a fresh inventory snapshot → update the signal; the faces
// redraw through their effects. A SUBSCRIBER, not a slot: the map face reads the
// same rows (seam.js "inventory" topic), so neither reader can take the
// notification over.
let booksWere = attached();
on("inventory", () => {
    // the books changed hands (a seat taken, or let go): what was read of the others is not theirs
    if (attached() !== booksWere) {
        booksWere = attached();
        readings.clear();
        history.clear();
    }
    scheduleAsked = false;
    forgetContests();
    stockData.set(currentStock());
});
/** Seed the stock from what the seam already holds. */
export const seedStock = () => stockData.set(currentStock());
