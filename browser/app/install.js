// app/install.ts — whether the dial is installed on this device, and the way
// to install it.
//
// An installed app (a Home Screen icon, a standalone window, the Capacitor
// shell) is the form the browser keeps: on iOS a site in a tab loses its
// storage after seven days unused, and an installed one does not. So the
// state is worth showing, and each engine has its own road to it:
//
//   promptable   Chromium has offered an install prompt; install() shows it.
//   ios-manual   Safari on iOS installs from Share → Add to Home Screen, and
//                gives a page no way to start that; the surface says how.
//   standalone   already running installed.
//   unavailable  this engine offers a page no install here.
//
// app/update.ts imports this ahead of the dial, since Chromium raises its
// prompt event once, early, and a listener added later never hears it.
import { signal } from "./reactive.js";
import { html } from "./template.js";
import { shell } from "./pwa.js";
function detect() {
    const nav = navigator;
    if (shell() || nav.standalone === true || matchMedia("(display-mode: standalone)").matches)
        return "standalone";
    // iPadOS reports itself as a Mac; the touch points tell them apart
    const ios = /iPhone|iPad|iPod/.test(nav.userAgent) || (/Macintosh/.test(nav.userAgent) && nav.maxTouchPoints > 1);
    return ios ? "ios-manual" : "unavailable";
}
export const installState = signal(detect());
let offered = null;
window.addEventListener("beforeinstallprompt", e => {
    e.preventDefault(); // the dial offers it from its own surface
    offered = e;
    installState.set("promptable");
});
window.addEventListener("appinstalled", () => {
    offered = null;
    installState.set("standalone");
});
/** Show the engine's install prompt. Answers whether the person accepted. */
export async function install() {
    if (!offered)
        return false;
    const e = offered;
    offered = null; // an offer can be shown once
    await e.prompt();
    const { outcome } = await e.userChoice;
    if (outcome !== "accepted")
        installState.set(detect());
    return outcome === "accepted";
}
/** How to install from Safari on iOS, where a page cannot start it. */
const IOS_INSTALL = "In Safari, tap Share, then “Add to Home Screen”.";
/** What installing is for, in one sentence. */
const INSTALL_WHY = "An installed app keeps what this device holds; a site left in a browser tab can be cleared after a week unused.";
/**
 * The install offer, as this engine can make it: a button where the engine
 * has offered a prompt, the instruction on iOS, a plain statement once
 * installed, and nothing where the engine offers a page no install. One
 * block, mounted on the walk's last screen and in the storage settings.
 */
export function installBlock() {
    const st = installState();
    if (st === "promptable")
        return html `<p class="ob-note">${INSTALL_WHY}</p>
      <button class="ob-next ob-wide" onclick=${() => { void install(); }}>install playnet on this device</button>`;
    if (st === "ios-manual")
        return html `<p class="ob-note">${IOS_INSTALL} ${INSTALL_WHY}</p>`;
    if (st === "standalone")
        return html `<p class="ob-note">Installed on this device.</p>`;
    return "";
}
