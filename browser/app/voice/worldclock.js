// app/worldclock.ts — the world clock: other people's hours, named.
//
// A federation is not in one place, so "14:19 here, 05:19 there" is a fact about
// who you can reach, not decoration. The zone list is chosen in settings and read
// by the calendar rail; it is a way of looking, so it stays on the device.
//
// The hours come from Intl with an explicit `timeZone` — the browser's own tz
// database, no table to go stale — read off the SAME instant the dial is showing
// when that instant is now, so the rail never disagrees with the hand. (The dial
// runs on one clock; see the timescale note in (playnet utils clock). What Intl
// converts here is civil labelling, which is exactly the boundary that clock
// draws: instants inside, civil labels at the edge.)
import { signal } from '../reactive.js';
import { readJSON, writeJSON } from '../store.js';
import { K } from "../keys.js";
const KEY = K.worldClocks;
// The device's own zone leads the list, because "here" is the row you compare
// everything else against.
const here = () => {
    try {
        return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
    }
    catch (_) {
        return "UTC";
    }
};
const load = () => {
    const raw = readJSON(KEY, null);
    // Anything without a tz is not a row — a hand-edited or older store can hold
    // whatever, and one bad entry must not cost the whole list.
    if (Array.isArray(raw))
        return raw.filter((z) => Boolean(z && z.tz));
    return [{ tz: here(), label: "" }];
};
const zs = signal(load());
export const zones = () => zs();
export const zonesPeek = () => zs.peek();
const persist = (list) => {
    zs.set(list);
    writeJSON(KEY, list); // a store that refuses loses the memory, not the list
};
export function addZone(tz, label = "") {
    if (!tz || !zoneValid(tz))
        return false;
    const list = zs.peek();
    if (list.some(z => z.tz === tz))
        return false;
    persist([...list, { tz, label }]);
    return true;
}
export function removeZone(tz) {
    persist(zs.peek().filter(z => z.tz !== tz));
}
export function labelZone(tz, label) {
    persist(zs.peek().map(z => (z.tz === tz ? { ...z, label } : z)));
}
// a zone is valid when Intl will format in it — the browser is the authority, so
// a typo is caught here rather than throwing inside a render
export function zoneValid(tz) {
    try {
        new Intl.DateTimeFormat("en", { timeZone: tz });
        return true;
    }
    catch (_) {
        return false;
    }
}
// the zones this browser knows, for the settings picker; where the full list is
// unavailable (older engines), a short spread of the federation's own reach.
export function knownZones() {
    try {
        const all = Intl.supportedValuesOf && Intl.supportedValuesOf("timeZone");
        if (all && all.length)
            return all;
    }
    catch (_) { /* older engine — fall through to the short list */ }
    return ["UTC", "Europe/Berlin", "Europe/Paris", "Europe/London", "Europe/Sofia",
        "America/Los_Angeles", "America/New_York", "America/Sao_Paulo",
        "Africa/Nairobi", "Asia/Kolkata", "Asia/Tokyo", "Australia/Sydney"];
}
// the current clock in a zone, plus whether it is daylight there — the glyph is
// the whole point of the row: can I call them, or are they asleep?
export function zoneNow(tz, at = new Date()) {
    let clock = "—", hour = 12;
    try {
        clock = new Intl.DateTimeFormat("en-GB", { timeZone: tz, hour: "2-digit", minute: "2-digit", hour12: false }).format(at);
        hour = +new Intl.DateTimeFormat("en-GB", { timeZone: tz, hour: "2-digit", hour12: false }).format(at);
    }
    catch (_) { /* an invalid zone shows the em dash rather than breaking the rail */ }
    // 07:00–19:00 reads as day. A true sunrise per zone needs that zone's latitude,
    // which a tz name does not carry — so this is a civil day, and says so.
    return { clock, hour, day: hour >= 7 && hour < 19 };
}
// the offset label a settings row shows: "(GMT+02:00) Europe/Berlin"
export function zoneOffsetLabel(tz, at = new Date()) {
    try {
        const s = new Intl.DateTimeFormat("en", { timeZone: tz, timeZoneName: "longOffset" })
            .formatToParts(at).find(p => p.type === "timeZoneName");
        return `(${(s && s.value) || "GMT"}) ${tz.replace(/_/g, " ")}`;
    }
    catch (_) {
        return tz;
    }
}
