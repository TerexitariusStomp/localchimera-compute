// app/rpc.ts — asking a worker a question and getting its answer.
//
// The wire is one convention: a request is posted as `{ id, …request }` and
// the worker answers `{ id, …reply }`. This holds what every caller of that
// convention needs and each used to spell out: the id counter, the map of
// questions still open, and what happens to them when the worker dies — every
// one is rejected, the worker is let go, and the next ask starts a fresh one.
// A caller that names a `deadline` also has a question rejected when no answer
// comes within it (the worker is left running: it may be answering another).
// An open question therefore always ends.
//
// A message that carries no open id (a progress report, say) goes to `other`.
export function workerRpc(opts) {
    let worker = null;
    let seq = 0;
    const open = new Map();
    function stop(why) {
        worker?.terminate();
        worker = null;
        const err = new Error(why);
        for (const o of open.values())
            o.rej(err);
        open.clear();
    }
    function start() {
        const w = opts.spawn();
        w.onmessage = (e) => {
            const data = e.data;
            const o = data && typeof data.id === "number" ? open.get(data.id) : undefined;
            if (!o) {
                opts.other?.(e.data);
                return;
            }
            open.delete(data.id); // `o` was found under this id, so both are set
            o.res(e.data);
        };
        w.onerror = (e) => stop(e.message || "the worker stopped");
        return w;
    }
    return {
        stop,
        ask(request, transfer = []) {
            return new Promise((res, rej) => {
                try {
                    worker ??= start();
                }
                catch (e) {
                    rej(e instanceof Error ? e : new Error(String(e)));
                    return;
                }
                const id = ++seq;
                if (opts.deadline === undefined)
                    open.set(id, { res, rej });
                else {
                    const late = setTimeout(() => {
                        if (open.delete(id))
                            rej(new Error(`no answer in ${opts.deadline} ms`));
                    }, opts.deadline);
                    const settled = (f) => (a) => { clearTimeout(late); f(a); };
                    open.set(id, { res: settled(res), rej: settled(rej) });
                }
                worker.postMessage({ id, ...request }, transfer);
            });
        },
    };
}
/** How a reply begins when the device could not run the worker's wasm at all, or the worker takes no such door. */
export const UNAVAILABLE = "err:unavailable";
/**
 * A worker that answers doors: `{ door, args }` in, `{ reply }` out, the reply the
 * door's JSON or "err:…". Asking gives the reply as a string, and a worker that
 * cannot be asked (no Worker, a failed boot, a deadline passed) answers
 * UNAVAILABLE and why, so a caller has one thing to read either way.
 */
export function doorWorker(opts) {
    const rpc = workerRpc(opts);
    return (door, args) => rpc.ask({ door, args }).then(r => String(r.reply), (e) => `${UNAVAILABLE}: ${e.message || "no worker"}`);
}
