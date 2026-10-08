// app/family-local.ts — the household's solve, on the device.
//
// The family face's week is a solve over the household's own ledger, and the
// planner's family solve is a pure function of it. It runs in a worker of its
// own (browser/family-worker.js, the planner compiled for the browser — hoot/
// family-worker.scm): the ledger never leaves the page, an answer needs no
// network, and a solve — a few hundred milliseconds — holds neither the page nor
// the spine's vat.
//
// `askLocal` is the whole surface: a door name and its arguments in, the solve's
// JSON (or "err:…") out. A reply beginning UNAVAILABLE means the device could not
// run the solve at all (no Worker, no family.wasm, the wasm failed to boot) —
// the caller may ask the commons instead. Any other "err:…" is the planner's own
// refusal, which the commons would give too.
//
// `?solve=commons` on the page's URL asks the commons instead: the comparison
// run, and how the face's tests reach the session's door.
import { doorWorker, UNAVAILABLE } from "./rpc.js";
export { UNAVAILABLE };
const commonsOnly = () => new URLSearchParams(location.search).get("solve") === "commons";
// one worker, started on the first solve; a solve it does not live to answer
// ends with the reason, and the next ask starts a fresh one (app/rpc.ts)
const solver = doorWorker({
    spawn: () => new Worker(new URL("../family-worker.js", import.meta.url)),
});
export function askLocal(door, args) {
    if (commonsOnly())
        return Promise.resolve(`${UNAVAILABLE}: ?solve=commons`);
    return solver(door, args);
}
