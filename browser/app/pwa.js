// app/pwa.ts — the page's side of the service worker: one registration door
// for the dial (app.html) and the REPL page (index.html).
//
// A build is whole. browser/sw.js keeps one cache per build, and a new worker
// waits while a page runs the build before it, so every module a page imports
// during its life comes from the build it booted on. The page moves to the new
// build at a moment it chooses: registerSW hands `onUpdateReady` when a worker
// is waiting, applyUpdate tells that worker to take over, and the
// controllerchange that follows reloads the page onto it.
//
// This module imports nothing, so either page can load it before anything else.
/**
 * Live-editing: `?dev` / `?nosw` in the URL, or a loopback host over plain
 * http (`make serve`). There the worker is torn down and its build caches
 * cleared, so every refresh serves files off disk. The Capacitor shell's
 * origin is https://localhost and is a production origin.
 */
export function isDev(loc = location) {
    const q = new URLSearchParams(loc.search);
    // the flag is on by its presence (?dev, ?dev=1) and off when it says so (?dev=0)
    const flagged = (name) => q.has(name) && !/^(0|false|off)$/.test(q.get(name) ?? "");
    if (flagged("dev") || flagged("nosw"))
        return true;
    const loopback = loc.hostname === "localhost" || loc.hostname === "127.0.0.1" || loc.hostname === "[::1]";
    return loopback && loc.protocol === "http:";
}
/** The native shell the dial runs inside, or null in a browser. */
export function shell() {
    const cap = globalThis.Capacitor;
    return cap && (!cap.isNativePlatform || cap.isNativePlatform()) ? cap : null;
}
/** The worker's own caches. Every other cache on the origin belongs to its writer. */
export const ownsCache = (name) => name.startsWith("playnet-");
let waiting = null;
/** Hand control to the waiting build. The page reloads on the controllerchange. */
export function applyUpdate() {
    waiting?.postMessage({ type: "skip-waiting" });
}
/** True while a newer build is installed and waiting for this page. */
export const updateWaiting = () => waiting != null;
function devTeardown() {
    navigator.serviceWorker.getRegistrations()
        .then(rs => rs.forEach(r => { void r.unregister(); }))
        .catch(() => { });
    if (!("caches" in self))
        return;
    caches.keys()
        .then(ks => ks.filter(ownsCache).forEach(k => { void caches.delete(k); }))
        .catch(() => { });
}
export function registerSW(opts = {}) {
    if (!("serviceWorker" in navigator))
        return;
    if (isDev()) {
        devTeardown();
        return;
    }
    const sw = navigator.serviceWorker;
    const safe = opts.safeToReload ?? (() => true);
    // A page that booted under a worker reloads when another takes control. A
    // first visit has no controller, and the worker claiming it changes nothing
    // the page has loaded.
    if (sw.controller) {
        let reloading = false;
        sw.addEventListener("controllerchange", () => {
            if (reloading)
                return;
            reloading = true;
            (function whenSafe() {
                if (!safe()) {
                    setTimeout(whenSafe, 1500);
                    return;
                }
                window.location.reload();
            })();
        });
    }
    const ready = (w) => {
        // With no controller the installed worker is the page's first; it
        // activates by itself and there is no build to move from.
        if (!w || !sw.controller)
            return;
        waiting = w;
        if (opts.onUpdateReady)
            opts.onUpdateReady();
        else
            applyUpdate();
    };
    // register() asks for the worker; `ready` hands over the registration once
    // a worker is active, and that is the one to watch. The two are kept apart
    // because register()'s promise settles late or rejects (offline, an update
    // check in flight) on a page whose earlier registration stands and works.
    sw.register("/sw.js").catch(() => { });
    sw.ready.then(reg => {
        if (reg.waiting)
            ready(reg.waiting);
        reg.addEventListener("updatefound", () => {
            const w = reg.installing;
            if (!w)
                return;
            w.addEventListener("statechange", () => {
                if (w.state === "installed")
                    ready(w);
            });
        });
    }).catch(() => { });
}
