// app/seam.ts — THE SEAM: the one object the app shares with its capability
// spine (day-boot.js + day-boot.wasm — gateway CapTP, KERI login, the planner).
//
// Next to a leaf at RUNTIME — its runtime imports are bus.ts and the generated
// seam-wire.ts, both leaves; every other import is `import type`, which the
// emit erases — so it is
// evaluated before anything that touches the seam. (The type it borrows is
// ring.ts's, and ring.ts reaches back here through events.ts; the cycle exists
// only in the type graph, where cycles are fine, and never in the emitted
// JavaScript, where this one would deadlock the boot.)
//
// day-boot.js imports this same object and only MUTATES its fields, never
// replaces it, so late-arriving handlers and data are seen at call time.
// Standalone (no spine loaded) the app keeps its demo fallbacks.
//
// Two sides fill this object and neither can see the other's shape at build
// time: the app is TypeScript, the spine is Scheme compiled to wasm. The types
// below are the contract written down — what the app may assume is there and
// what the spine promises to call. Payloads the spine owns are `unknown`
// rather than `any`, so a reader has to narrow rather than assume.
import { emit } from './bus.js';
import { SEAM_PUSHES, SEAM_WIRE } from "./seam-wire.js";
/**
 * A door's reply read as the table it is: the object, or null for a refusal
 * ("err:…"), an unanswered door, or an unreadable answer. The handler's type
 * (seam-wire.ts, generated from the seam table) says which table.
 */
export function readJson(raw) {
    const s = typeof raw === "string" ? raw : "";
    if (!s.startsWith("{"))
        return null;
    try {
        const j = JSON.parse(s);
        return j && typeof j === "object" ? j : null;
    }
    catch {
        return null;
    }
}
// ── the object ──────────────────────────────────────────────────────────────
// One module instance, so one object: the app imports it, day-boot.js (an ES
// module too) imports it and hands its push functions to the wasm, and the UX
// harness imports it into the page for its probes. Nothing hangs off window.
// The cast outruns the truth for exactly the lines below, which install the
// two containers and every push before any importer can look.
export const seam = {};
seam.data = {};
seam.handlers = {};
// ── the push half ───────────────────────────────────────────────────────────
// Every push the spine makes lands on the bus under its own name: the topic IS
// the push, typed from SeamPushes in bus.ts. Installed for every name in the
// table, so a push that arrives before its reader is a push nobody wanted yet,
// never a missing method.
// The one loose cast: the loop is generic over the table, and each push's
// arguments are typed at the reader (bus.ts) from the same SeamPushes.
const forward = emit;
for (const name of SEAM_PUSHES)
    seam[name] =
        (...args) => forward(name, ...args);
// ── the sinks ───────────────────────────────────────────────────────────────
// What the wasm calls, by the name it imports: strings off the wire. Each sink
// reads its arguments as the table says (a JSON one parsed, a raw one as it
// is), keeps the first under seam.data for a reader that arrives later, and
// raises the push. day-boot.js hands these to the wasm — on the page directly,
// or through the spine worker by name — and adds the page's own plumbing
// (the trace, the scope setter, the status side effects) around them.
// A wire argument that does not parse is a spine bug, reported and dropped:
// the push it carried never lands, and the seam keeps its last good value.
export const seamSinks = {};
for (const sink of Object.keys(SEAM_WIRE)) {
    const { push, args: kinds, keep } = SEAM_WIRE[sink];
    seamSinks[sink] = (...wire) => {
        let args;
        try {
            args = wire.map((w, i) => kinds[i] === "json" ? JSON.parse(w) : w);
        }
        catch (e) {
            console.warn(`[seam] bad ${sink} from the spine:`, e);
            return;
        }
        if (keep)
            seam.data[keep] = args[0];
        forward(push, ...args);
    };
}
