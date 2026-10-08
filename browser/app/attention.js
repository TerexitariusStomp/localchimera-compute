// app/attention.ts — what on this device is waiting for the person, standing.
//
// Two things happen to the device itself and stay true until the person acts:
// a new build is installed and waiting for a reload, and the device's storage
// has refused a write. Each is said once on a toast as it happens
// (app/update.ts, app/storage-notice.ts); a toast passes, so this is where
// they stand afterwards:
//
//   matters()   the list, read by any surface that shows it — the settings'
//               "what this device keeps" section heads its rows with it
//               (app/storage-view.ts)
//   the mark    a dot on the identity chip (#idrow.wants) while the list has
//               an entry, described to a screen reader by the entries
//
// A matter carries its own remedy where there is one.
import { signal, effect } from "./reactive.js";
import { lastFault } from "./storage-health.js";
import { applyUpdate } from "./pwa.js";
/** A newer build is installed and waiting for this page (set by app/update.ts). */
export const updateReady = signal(false);
/** What is waiting, most actionable first. Reads signals: call it inside an effect to follow it. */
export function matters() {
    const out = [];
    if (updateReady())
        out.push({ id: "update", says: "A new version of playnet is installed and waiting.",
            act: { label: "reload now", run: applyUpdate } });
    const f = lastFault();
    if (f)
        out.push({ id: "storage",
            says: `This device's storage refused a write at ${new Date(f.at).toLocaleTimeString()} (${f.what}). `
                + "What changed since lasts until the page closes." });
    return out;
}
// the mark on the identity chip
if (typeof document !== "undefined") {
    effect(() => {
        const list = matters();
        const chip = document.getElementById("idrow");
        if (!chip)
            return;
        chip.classList.toggle("wants", list.length > 0);
        // a screen reader hears what the dot stands for
        if (list.length)
            chip.setAttribute("aria-description", list.map(m => m.says).join(" "));
        else
            chip.removeAttribute("aria-description");
    });
}
