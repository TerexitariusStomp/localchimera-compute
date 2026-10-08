// app/update.ts — the dial's service-worker wiring: register through the one
// door (app/pwa.ts), and say so when a newer build is waiting.
//
// A waiting build is announced on a card that stays until answered; a tap
// moves the page onto it. A page left in the background moves by itself. An
// open identity popover (#idform) holds an unsaved passcode or recovery file,
// so the move waits for it to close.
//
// app.html loads this as a module of its own, ahead of the dial, so a build
// that fails to boot can still be replaced by the next one.
import { registerSW, applyUpdate, isDev } from "./pwa.js";
import { toast } from "./toast.js";
import { updateReady } from "./attention.js";
// hears the engine's install offer, which is raised once and early
import "./install.js";
const idle = () => !document.getElementById("idform");
let watching = false;
const whenHidden = () => {
    if (document.visibilityState === "hidden" && idle())
        applyUpdate();
};
registerSW({
    safeToReload: idle,
    onUpdateReady() {
        updateReady.set(true); // it stands in app/attention.ts once the card is gone
        toast("a new version is ready — tap to reload", "notice", { duration: 0, onTap: applyUpdate });
        // a second build arriving while the first waits finds the listener in place
        if (!watching) {
            watching = true;
            document.addEventListener("visibilitychange", whenHidden);
        }
        whenHidden();
    },
});
// Dev live-reload: a local watcher bumps /reload-token.txt whenever a file
// under browser/ changes; the page reloads when the token moves. Same-origin,
// so it works over the dev onion's single port.
if (isDev()) {
    let token = null;
    setInterval(() => {
        fetch("/reload-token.txt?_=" + Date.now(), { cache: "no-store" })
            .then(r => (r.ok ? r.text() : null))
            .then(t => {
            if (t == null)
                return;
            if (token == null) {
                token = t;
                return;
            }
            if (t !== token && idle())
                window.location.reload();
        })
            .catch(() => { });
    }, 1000);
}
