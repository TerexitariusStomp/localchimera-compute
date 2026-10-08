// app/storage-health.ts — how the device's storage stands: whether the
// browser has promised to keep it, how much is used, and the last refusal.
//
// Browser storage is best-effort by default: under disk pressure, or after a
// week unused on an iOS site that is not on the Home Screen, the browser may
// clear all of it — the key event log and the device key along with the
// pictures. `persist()` asks the browser to keep it. It is asked when
// something worth keeping first exists (an identity, a kept picture), which
// is also when a browser that asks the person has a reason they can see.
//
// No DOM and no toast here, so the photo store and a node test can import it;
// the card that tells the person is app/storage-notice.ts.
import { signal } from "./reactive.js";
import { onFault } from "./store.js";
/** The most recent storage refusal this session, or null. */
export const lastFault = signal(null);
onFault(f => lastFault.set(f));
/** Whether the browser has promised to keep this origin's storage; null where it cannot say. */
export const persisted = signal(null);
const manager = () => typeof navigator !== "undefined" && navigator.storage ? navigator.storage : null;
/** Read the standing promise without asking for one. */
export async function readPersisted() {
    try {
        const m = manager();
        const yes = m?.persisted ? await m.persisted() : null;
        persisted.set(yes);
        return yes;
    }
    catch {
        return null;
    }
}
/**
 * Ask the browser to keep this origin's storage. Answers what it said. A
 * browser asks at most once in earnest, and a second call returns the
 * standing answer, so every caller with something worth keeping may ask.
 */
export async function ensurePersistent() {
    try {
        const m = manager();
        if (!m?.persist)
            return null;
        const yes = (await m.persisted?.()) || (await m.persist());
        persisted.set(yes);
        return yes;
    }
    catch {
        return null;
    }
}
/** What the origin holds against what it may, or null where the browser does not say. */
export async function usage() {
    try {
        const e = await manager()?.estimate?.();
        return e && e.quota ? { used: e.usage ?? 0, quota: e.quota } : null;
    }
    catch {
        return null;
    }
}
/** The last reading of usage(), for a surface that draws from signals. */
export const usageNow = signal(null);
/** Take a fresh reading of both the promise and the usage. */
export async function refreshHealth() {
    await readPersisted();
    usageNow.set(await usage());
}
/** Bytes as a person reads them: "412 KB", "79 MB", "1.3 GB". */
export function bytes(n) {
    if (n < 1024 * 1024)
        return Math.round(n / 1024) + " KB";
    if (n < 1024 * 1024 * 1024)
        return Math.round(n / (1024 * 1024)) + " MB";
    return (n / (1024 * 1024 * 1024)).toFixed(1) + " GB";
}
