// app/push.ts — this device's browser notifications.
//
// A commune reaches a person on the channels they tell it (app/reach.ts).
// The browser is one more: the service worker can show a notification with
// the page closed, when the commune sends a Web Push to the subscription
// this browser made. Three parties hold a part each:
//
//   the browser   Notification permission, and the PushSubscription made
//                 with the commune's key (pushManager, on the worker's
//                 registration)
//   the commune   the subscription, under this DEVICE's id, bound to the
//                 person's `push` channel (session register-push)
//   this module   the device id, and keeping the two in step
//
// The commune holds subscriptions in memory, so the page tells it again each
// time it is seated (sync). The worker tells the page when the browser has
// replaced the subscription (sw.js pushsubscriptionchange), and the page
// tells the commune.
import { signal } from "./reactive.js";
import { on } from "./bus.js";
import { HANDLERS } from "./core.js";
import { readStr, writeStr } from "./store.js";
import { fromBase64Url } from "./bytes.js";
import { isDev } from "./pwa.js";
import { K } from "./keys.js";
const DEVICE_ID = K.deviceId;
/** This device's id, minted once. The REPL page reads the same key. */
export function deviceId() {
    let id = readStr(DEVICE_ID);
    if (!id) {
        id = crypto.randomUUID();
        writeStr(DEVICE_ID, id);
    }
    return id;
}
const supported = () => typeof Notification !== "undefined" && "serviceWorker" in navigator && "PushManager" in window && !isDev();
export const pushState = signal(supported()
    ? (Notification.permission === "denied" ? "blocked" : "off")
    : "unsupported");
const registration = () => navigator.serviceWorker.ready;
const said = (r) => (typeof r === "string" ? r : "err:offline");
/** Tell the commune the subscription this browser holds. "ok" | "err:…". */
async function register(sub) {
    const r = said(await HANDLERS.pushRegister?.(deviceId(), JSON.stringify(sub.toJSON())));
    if (r.startsWith("ok"))
        pushState.set("on");
    return r;
}
/**
 * Bring the commune in step with the browser: a subscription this browser
 * holds is told again. Called when the page is seated and when the worker
 * reports a replaced subscription.
 */
export async function syncPush() {
    if (!supported() || Notification.permission !== "granted")
        return;
    try {
        const sub = await (await registration()).pushManager.getSubscription();
        if (sub)
            await register(sub);
        else
            pushState.set("off");
    }
    catch { /* the next seating tries again */ }
}
/** Ask for the permission, subscribe, and tell the commune. "ok" | "err:…". */
export async function enablePush() {
    if (!supported())
        return "err:this browser has no push notifications";
    const permission = await Notification.requestPermission();
    if (permission !== "granted") {
        pushState.set(permission === "denied" ? "blocked" : "off");
        return "err:notifications are not allowed for this site";
    }
    const key = said(await HANDLERS.pushKey?.());
    if (!key || key.startsWith("err:"))
        return "err:this commune sends no push notifications";
    try {
        const reg = await registration();
        const sub = (await reg.pushManager.getSubscription())
            ?? (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: fromBase64Url(key) }));
        return await register(sub);
    }
    catch (e) {
        return "err:" + (e instanceof Error ? e.message : "the browser refused the subscription");
    }
}
/** Take the subscription back from the commune and end it in the browser. */
export async function disablePush() {
    try {
        const sub = await (await registration()).pushManager.getSubscription();
        await HANDLERS.pushUnregister?.(deviceId());
        if (sub)
            await sub.unsubscribe();
        pushState.set("off");
        return "ok";
    }
    catch (e) {
        return "err:" + (e instanceof Error ? e.message : "could not end the subscription");
    }
}
if (supported()) {
    // the spine reports a seat taken as "ok:<aid>…": tell that commune what
    // this browser holds
    on("status", (s) => { if (typeof s === "string" && s.startsWith("ok:"))
        void syncPush(); });
    navigator.serviceWorker.addEventListener("message", e => {
        if (e.data && e.data.type === "push-subscription")
            void syncPush();
    });
}
