// app/demo/seat.ts — the demo, played through the gateway's own door.
//
// A gateway sends the scope's snapshot and every face reads it off the seam. With
// no gateway the demo world (demo/world.ts) is sent the same way: the seat builds
// the snapshot in the wire's shapes and pushes it through the sink the spine
// pushes through (seam.ts seamSinks), so a face reads one path, seated or not.
// The snapshot the seat pushes says it is the demo's; a gateway's own snapshot
// replaces it whole when one arrives.
//
// What it carries is the places (each with its id, its name, the place it is
// inside and its position, set down around the map's anchor) and the stock the
// books hold. The store, the Resources face, the capture sheet, the location
// popover and the map's containment all read them from the snapshot, as they
// read a live scope's.
//
// The seat also answers doors. While no gateway's books stand, the doors the
// device's scope takes are the scope's: the schedule of counts, a stock's counts,
// a spec's readings, a count itself. The scope is the planner's own code held on
// the device (scope-local.ts), so a count made with no gateway lands as a count
// lands. Where the scope cannot run, the recording answers the reads and a count
// is refused. The doors only a gateway answers (the contests, the week's reads)
// are the recording's. A position snaps to the demo's nearest place. Once a seat
// is taken the same door is the spine's own. A face calls HANDLERS.countSchedule
// or HANDLERS.countStock either way.
import { seam, seamSinks } from "../seam.js";
import { attached } from "../books.js";
import { MAP_ANCHOR, onMapAnchor } from "../tabs/map/atlas.js";
import { WORLD_PLACES } from "./world.js";
import { demoStore } from "./store.js";
import { RECORDING } from "./recording.js";
import { askScope, holdReplica, keptScope, replicaOf, UNAVAILABLE } from "../scope-local.js";
import { ask, flush, QUEUED } from "../outbox.js";
import { idbBox } from "../outbox-idb.js";
import { on } from "../bus.js";
/** The snapshot standing on the seam is the demo's own. */
export const demoSeated = () => !!seam.data.snapshot?.demo;
/** The world's places as the wire names them, set down around the map's anchor. */
export function demoLocations(anchor) {
    return WORLD_PLACES.map(p => ({
        id: p.id, name: p.name, lat: anchor.lat + p.dLat, lng: anchor.lng + p.dLng,
        ...(p.containedIn ? { containedIn: p.containedIn } : {}),
    }));
}
const doors = seam.handlers;
const placed = new Set();
/** The spine's own door of each name the seat stands in front of. */
const own = new Map();
/** Stand SERVED in front of the spine's door NAME: SERVED is handed the spine's own door, kept as the spine assigns it. */
function standIn(name, served) {
    if (placed.has(name))
        return;
    placed.add(name);
    own.set(name, doors[name]);
    Object.defineProperty(doors, name, {
        configurable: true, enumerable: true,
        get: () => served(own.get(name)),
        set: (door) => { own.set(name, door); },
    });
}
/**
 * NAME answers from the demo while no gateway's books stand, and is the spine's
 * own door after. The spine assigns its doors whenever it loads, gateway or none;
 * the assignment is kept and served once the seat is attached.
 */
function demoDoor(name, demo) {
    standIn(name, spine => (attached() ? spine : demo));
}
/** How far apart two positions are, as a flat distance in degrees: enough to tell which place is nearest. */
const apart = (a, lat, lng) => Math.hypot(a.lat - lat, a.lng - lng);
/** A position is at a place when it is within this of it, about four hundred metres. */
const NEAR = 0.004;
/** The stocks' emoji, by id: what a face shows a stock by, which no record carries. */
const STOCK_EMOJI = RECORDING.face.stocks;
/** A snapshot as the demo pushes it: places set down around the anchor, the stock marked the demo's. */
const pushed = (locations, resources) => JSON.stringify({ demo: true, locations, inventory: { demo: true, resources } });
/** The recording's books, as of today: the first paint, and the books where the device's scope cannot run. */
const recordedSnapshot = () => pushed(demoLocations(MAP_ANCHOR), demoStore().inventory.resources ?? []);
// The device's scope (scope-local.ts) holds the neighbourhood as a real scope and
// answers its doors with the planner's own code. It starts when a door is first
// asked. From its first answer the books on the seam are its own, pushed again
// after every count.
let scopeStands = false;
async function pushScopeBooks() {
    const raw = await askScope("snapshot");
    if (raw.startsWith("err:"))
        return;
    // a copy of a gateway's scope is pushed as the gateway pushes it: its places stand where they stand
    if (replicaOf()) {
        seamSinks.data(raw);
        return;
    }
    if (!demoSeated())
        return;
    const snap = JSON.parse(raw);
    const locations = (snap.locations ?? []).map(l => ({ ...l, lat: MAP_ANCHOR.lat + Number(l.lat), lng: MAP_ANCHOR.lng + Number(l.lng) }));
    const resources = (snap.inventory?.resources ?? []).map(r => ({ ...r, emoji: STOCK_EMOJI[String(r.id)] ?? "" }));
    seamSinks.data(pushed(locations, resources));
}
// ── a seat taken ─────────────────────────────────────────────────────────────
// With a gateway in reach again, what waited is sent in order, each act through
// the spine's own door, and the device then holds the scope afresh as the
// gateway answers it: the gateway's answer is the one that stands.
let catching = null;
function catchUp() {
    catching ??= (async () => {
        try {
            await flush(BOX, (door, args) => {
                const spine = own.get(door);
                return spine ? Promise.resolve(spine(...args)).then(String) : Promise.resolve("err:offline");
            });
            const scopeId = seam.scope, me = seam.data.aid;
            const replica = own.get("scopeReplica");
            const text = scopeId && me && replica ? String(await replica()) : "";
            if (scopeId && me && text && !text.startsWith("err:"))
                await holdReplica(scopeId, me, text);
        }
        finally {
            catching = null;
        }
    })();
}
on("status", (s) => { if (typeof s === "string" && s.startsWith("ok:"))
    catchUp(); });
// The scope takes a while to stand the first time. Until the demo neighbourhood's
// stands, a read is answered by the recording, which holds the same books, while
// the scope starts behind it; an act waits for the scope, since it needs the ledger.
let warming = null;
function warm() {
    warming ??= askScope("snapshot").then(reply => {
        if (!reply.startsWith("err:")) {
            scopeStands = true;
            void pushScopeBooks();
        }
    });
}
/** What the device's scope answers DOOR; where it cannot run or takes no such door, what RECORDED gives. */
async function answer(door, args, recorded) {
    if (!scopeStands && READS.has(door) && !(await keptScope())) {
        warm();
        return recorded();
    }
    const reply = await askScope(door, args);
    // the recording stands in for the demo neighbourhood only: a copy of a gateway's scope has no other voice
    if (reply.startsWith(UNAVAILABLE))
        return replicaOf() ? reply : recorded();
    if (!scopeStands) {
        scopeStands = true;
        void pushScopeBooks();
    }
    return reply;
}
// The doors the device's scope takes, each with what the recording answers in its
// place where the scope is the demo's and cannot run (a door asked of a stock or a
// spec is asked of its first argument); and the doors only a gateway answers,
// which the recording answers for the demo.
const SCOPE_DOORS = [
    ["countSchedule", false], ["countHistory", true], ["scopeReadings", true], ["readingsBetween", true],
    ["mySlots", false],
];
const READS = new Set(SCOPE_DOORS.map(([door]) => door));
const GATEWAY_DOORS = ["contests", "allotment", "ourSlots"];
// the acts the device's scope lands: a count, an observation, a need or an offer declared
const ACT_DOORS = ["countStock", "declareNeed", "declareMeans", "logObserve"];
const BOX = idbBox();
/**
 * NAME is asked the same way with a gateway in reach or none (outbox.ts `ask`):
 * the spine's door answers where a gateway does; where none does the device's
 * scope answers, and an act that may wait is kept for the next flush.
 */
function deviceDoor(name, recorded) {
    standIn(name, spine => ((...args) => ask({
        gateway: (_door, asked) => (attached() && spine
            ? Promise.resolve(spine(...asked)).then(String)
            : Promise.resolve("err:offline")),
        device: async (door, asked) => {
            const reply = await answer(door, asked, () => recorded(asked));
            // an act the device's scope landed moved its books: the faces read them again
            if (door in QUEUED && !reply.startsWith("err:"))
                void pushScopeBooks();
            return reply;
        },
        // an act on the demo neighbourhood is no gateway's to take
        ...(replicaOf() ? { box: BOX } : {}),
        now: () => new Date(),
    }, name, args, READS)));
}
function placeDoors() {
    standIn("scopeReplica", spine => spine); // kept as the spine assigns it, for the catch-up
    for (const [door, asked] of SCOPE_DOORS)
        deviceDoor(door, args => demoStore().reply(door, asked ? String(args[0] ?? "") : ""));
    for (const door of GATEWAY_DOORS)
        demoDoor(door, (() => Promise.resolve(demoStore().reply(door))));
    // a count lands on the device's scope where no gateway is in reach, and its books
    // are pushed again; where the scope cannot run there is no ledger to land it on
    for (const door of ACT_DOORS)
        deviceDoor(door, () => "err:this needs the books, which this device could not open");
    // a position snaps to the nearest of the demo's places, as the spine snaps it to a scope's
    demoDoor("setPositionHere", ((_mode, lat, lng) => {
        const near = demoLocations(MAP_ANCHOR)
            .map(l => ({ id: String(l.id), d: apart({ lat: Number(l.lat), lng: Number(l.lng) }, lat, lng) }))
            .sort((a, b) => a.d - b.d)[0];
        return Promise.resolve(near && near.d <= NEAR ? near.id : "ok");
    }));
}
/** Push the demo's snapshot, unless a gateway's stands or the seat is attached. */
export function seatDemo() {
    if (attached() || (seam.data.snapshot && !demoSeated()))
        return;
    if (scopeStands)
        void pushScopeBooks();
    else
        seamSinks.data(recordedSnapshot());
}
// the doors stand from the moment the seam's inbound side loads this module
placeDoors();
// the anchor moves once, when the person's position is first known: the demo's
// places are set down again around it, as the map's own demo fabric is
onMapAnchor(() => { if (demoSeated())
    seatDemo(); });
