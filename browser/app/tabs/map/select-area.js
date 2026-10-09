// app/tabs/map/select-area.ts — "Download a map of this area?": the frame over the live map.
//
// One overlay mounted in the map's own container: a clear frame with a dimmed
// surround, which the map pans and zooms UNDER (the overlay takes no pointer
// events but its head and foot), a head with the question and ✕, a foot with
// "Download will use up to N MB" and Download. The frame is CSS (a phone:
// inset from the edges above the bar; a desktop: a centred portrait rect);
// its corners read through map.unproject are the area, and on every moveend
// the figure is measured again — exactly, from the regions' directories
// (app/map-packs.ts measure), no tile bytes moving until Download.
import { signal, effect } from "../../reactive.js";
import { bytes } from "../../storage-health.js";
import { theMap } from "../../mapview.js";
import { measure, keep, freeName, landing } from "../../map-packs.js";
/** How deep an area is cut: the regions' own depth, street names readable. */
export const AREA_MAXZOOM = 15;
/** Whether the frame is up. */
export const selecting = signal(false);
let el = null;
let unbind = null;
/** The area under the frame, in degrees, or null before the map is up. */
export function framedBounds() {
    const map = theMap();
    const frame = el?.querySelector(".area-frame");
    if (!map || !frame)
        return null;
    const c = map.getContainer().getBoundingClientRect(), f = frame.getBoundingClientRect();
    const nw = map.unproject([f.left - c.left, f.top - c.top]);
    const se = map.unproject([f.right - c.left, f.bottom - c.top]);
    return [Math.min(nw.lng, se.lng), Math.min(nw.lat, se.lat), Math.max(nw.lng, se.lng), Math.max(nw.lat, se.lat)];
}
/** The last measure of the framed area, or null while it is being taken. */
export const measured = signal(null);
export const trouble = signal(null);
let pending = null;
let serial = 0;
function remeasure() {
    if (pending)
        clearTimeout(pending);
    pending = setTimeout(async () => {
        pending = null;
        const b = framedBounds();
        if (!b)
            return;
        const n = ++serial;
        measured.set(null);
        trouble.set(null);
        try {
            const m = await measure(b, AREA_MAXZOOM);
            if (n === serial)
                measured.set(m);
        }
        catch (e) {
            if (n === serial)
                trouble.set(e instanceof Error ? e.message : String(e));
        }
    }, 250);
}
/** The foot's sentence for what is measured. */
export function sizeLine(m, why) {
    if (why)
        return `the gateway's regions are out of reach (${why})`;
    if (!m)
        return "measuring…";
    if (!m.regions.length)
        return "this area is outside every region this gateway offers";
    return `Download will use up to ${bytes(m.bytes)}${m.partly ? " — part of this area is outside the regions this gateway offers" : ""}`;
}
/** The name a download of the framed area gets: the region it mostly lies in, numbered when taken. */
const nameFor = (m) => {
    const main = [...m.regions].sort((a, b) => b.bytes - a.bytes)[0].region.name;
    return freeName(main.charAt(0).toUpperCase() + main.slice(1));
};
/** Put the frame up over the map. A second call only refits. */
export function enterSelectArea(opts = {}) {
    const map = theMap();
    if (!map)
        return;
    if (!el) {
        el = document.createElement("div");
        el.className = "area-sel";
        el.innerHTML = `
      <div class="area-head"><span>Download a map of this area?</span>
        <button type="button" class="area-x" title="close">✕</button></div>
      <div class="area-frame"></div>
      <div class="area-foot"><span class="area-size"></span>
        <button type="button" class="area-dl">Download</button></div>`;
        map.getContainer().appendChild(el);
        // whatever is pinned over the top of the page (the deployment's status
        // ribbon) is cleared by measuring it, not by knowing it
        const clearTop = () => {
            const over = [...document.querySelectorAll("body > [class*='banner']")]
                .reduce((h, b) => Math.max(h, b.getBoundingClientRect().bottom), 0);
            el.style.setProperty("--area-top", `${Math.max(0, over)}px`);
        };
        clearTop();
        window.addEventListener("resize", clearTop);
        el.querySelector(".area-x").onclick = leaveSelectArea;
        const onKey = (e) => { if (e.key === "Escape")
            leaveSelectArea(); };
        document.addEventListener("keydown", onKey);
        map.on("moveend", remeasure);
        const size = el.querySelector(".area-size");
        const dl = el.querySelector(".area-dl");
        const stop = effect(() => {
            const m = measured(), why = trouble(), busy = Object.values(landing())[0];
            size.textContent = busy ? `${Math.floor(100 * busy.done / Math.max(1, busy.total))}% of ${bytes(busy.total)}` : sizeLine(m, why);
            dl.disabled = !!busy || !m || !m.regions.length;
        });
        dl.onclick = () => {
            const m = measured(), b = framedBounds();
            if (!m || !b || !m.regions.length)
                return;
            const area = { name: nameFor(m), bounds: b, maxZoom: AREA_MAXZOOM };
            keep(area).then(() => { leaveSelectArea(); opts.onKept?.(area.name); }, e => trouble.set(e instanceof Error ? e.message : String(e)));
        };
        unbind = () => {
            document.removeEventListener("keydown", onKey);
            window.removeEventListener("resize", clearTop);
            map.off("moveend", remeasure);
            stop();
        };
    }
    selecting.set(true);
    if (opts.fit) {
        // the area fills the frame: pad the fit by the frame's inset from the container
        const c = map.getContainer().getBoundingClientRect(), f = el.querySelector(".area-frame").getBoundingClientRect();
        map.fitBounds([[opts.fit[0], opts.fit[1]], [opts.fit[2], opts.fit[3]]], { padding: Math.max(0, Math.min(f.left - c.left, f.top - c.top, c.right - f.right, c.bottom - f.bottom)), duration: 0 });
    }
    remeasure();
}
/** Take the frame down. Safe when it is not up; the map face's exit calls it too. */
export function leaveSelectArea() {
    if (!el)
        return;
    unbind?.();
    unbind = null;
    el.remove();
    el = null;
    if (pending) {
        clearTimeout(pending);
        pending = null;
    }
    serial++;
    measured.set(null);
    trouble.set(null);
    selecting.set(false);
}
