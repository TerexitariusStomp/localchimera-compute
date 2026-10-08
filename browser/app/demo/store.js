// app/demo/store.ts — the offline store: the recording's books, as of today.
//
// The store face and the rail's inventory read their stock, the schedule of
// counts, the readings of each spec, the counts of each stock and the contests
// open from the gateway. Offline they read this: what the planner and
// governance answered the demo's person in the demo neighbourhood
// (demo/recording.ts, written by tools/demo-emit.scm from a real scope), read
// by the readers a gateway's replies are read by (count.ts, contest.ts). So
// the figures here are the engine's own, in the wire's own shapes.
//
// The recording was made on one day; its dates are moved by whole days to the
// day the page is opened on, so "due yesterday" and "use by today" hold
// whatever day it is.
//
// The recording is what the page shows before the device's own scope has
// answered (demo/seat.ts, scope-local.ts), and what answers a read where that
// scope cannot run.
import { readSchedule } from "../count.js";
import { readHistory, readContests } from "../contest.js";
import { readsOf } from "../allotment.js";
import { RECORDING } from "./recording.js";
const DAY = 86400000;
const STAMP = /^(\d{4}-\d{2}-\d{2})(T\d{2}:\d{2}:\d{2}Z)?$/;
/** The recording, each of its dates moved DAYS on. */
function moved(value, days) {
    const walk = (v) => {
        if (typeof v === "string") {
            const m = STAMP.exec(v);
            if (!m)
                return v;
            const day = new Date(Date.parse(`${m[1]}T00:00:00Z`) + days * DAY).toISOString().slice(0, 10);
            return day + (m[2] ?? "");
        }
        if (Array.isArray(v))
            return v.map(walk);
        if (v && typeof v === "object")
            return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, walk(x)]));
        return v;
    };
    return walk(value);
}
const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : Number(v) || 0);
function build(now) {
    const today = Math.floor(now / DAY) * DAY;
    // a copy of the recording, its dates moved to today
    const rec = moved(RECORDING, Math.round((today - Date.parse(`${RECORDING.day}T00:00:00Z`)) / DAY));
    const face = rec.face;
    const stockEmoji = face.stocks;
    const iso = (t) => new Date(t).toISOString().slice(0, 19) + "Z";
    const places = rec.snapshot.locations;
    // a stock's row is the snapshot's, with the emoji a face shows it by
    const resources = rec.snapshot.inventory.resources
        .map(r => ({ ...r, onhand: num(r.onhand), emoji: stockEmoji[String(r.id)] ?? "" }));
    const scheduled = rec.replies.countSchedule;
    const histories = rec.replies.countHistory;
    const said = rec.replies.scopeReadings;
    const between = rec.replies.readingsBetween;
    // a recording moved by days keeps its figures; the week opens again on the Monday after today
    const toMonday = ((8 - new Date(now).getUTCDay()) % 7) || 7;
    const reads = { ...rec.replies.allotment, opens: iso(today + toMonday * DAY) };
    const NONE = { rows: [], drift: { n: 0, meanAbs: 0, net: 0 }, latest: null };
    const reply = (door, of = "") => JSON.stringify(door === "countSchedule" ? scheduled
        : door === "countHistory" ? histories[of] ?? { rows: [] }
            : door === "scopeReadings" ? said[of] ?? NONE
                : door === "readingsBetween" ? between[of] ?? { rows: [], fold: [] }
                    : door === "contests" ? rec.replies.contests
                        : door === "mySlots" ? rec.replies.mySlots
                            : door === "ourSlots" ? rec.replies.ourSlots
                                : reads);
    return {
        inventory: { resources },
        places,
        reply,
        get schedule() { return readSchedule(reply("countSchedule")); },
        readings: spec => { const r = said[spec]; return r && (r.drift.n > 0 || r.latest) ? r : null; },
        history: spec => (between[spec]?.rows ?? []).map(x => ({
            technique: String(x.technique ?? ""), action: String(x.action ?? ""), unit: String(x.unit ?? ""),
            latest: num(x.latest), at: String(x.at ?? ""),
        })),
        counts: rid => readHistory(reply("countHistory", rid)),
        get contests() { return readContests(reply("contests")); },
        get allot() { return readsOf(reply("allotment")); },
    };
}
let held = null;
/** The offline store as of NOW (default: the present), built once per day. */
export function demoStore(now = Date.now()) {
    const day = Math.floor(now / DAY);
    if (!held || held.day !== day)
        held = { day, store: build(now) };
    return held.store;
}
