// app/route/follow.ts — the navigating camera: heading-up, tipped, and with you low in the frame.
//
// While a journey is under way the map turns so the way ahead is up, tips toward the
// horizon, and keeps you in the lower third with the road in front of you. Each fix eases the
// camera on; a hand on the map lets go of it, and it comes back by itself after a pause (or on
// the recentre button). The overview button zooms out to what is left of the way, then returns.
//
// The camera math is pure and exported — zoom by pace, padding that seats you low, the short way
// round to a new bearing, which heading to trust — so it is stated in a test without a map.
// `startFollow` is the stateful half and owns the map's camera, the you-arrow and the two buttons.
import { boundsOf } from './facts.js';
/** How far the camera is tipped toward the horizon, in degrees. */
export const FOLLOW_PITCH = 55;
/** Where in the frame you sit, as a share of its height from the top. */
export const SEAT = 0.68;
/** How long a hand's last touch holds the camera loose before it returns, in milliseconds. */
export const RETURN_MS = 10_000;
/**
 * The zoom for a pace: closer when slow, wider when fast. Walking and riding stay near;
 * driving pulls back as the speed rises.
 */
export function followZoom(speed, costing) {
    const drive = costing === "auto";
    const base = drive ? 17 : costing === "bicycle" || costing === "multimodal" ? 17.5 : 18;
    const share = Math.max(0, Math.min(1, (speed ?? 0) / (drive ? 25 : 12)));
    return base - share * (drive ? 1.6 : 0.6);
}
/**
 * The camera's padding that seats you at SEAT of the frame's height: more room above than below,
 * the sheet's height kept free at the foot and the banner's at the top.
 */
export function followPadding(h, sheetH, bannerH) {
    const bottom = Math.max(0, sheetH);
    const seatTop = 2 * SEAT * h - h + bottom; // the centre of the padded area is where you sit
    const top = Math.max(bannerH + 16, Math.min(seatTop, h - bottom - 120));
    return { top: Math.max(0, top), bottom, left: 0, right: 0 };
}
/**
 * The bearing to ease to, reached the short way round. `current` may already be past a full turn
 * (the camera keeps counting), and the answer stays near it, so the map never spins the long way.
 */
export function turnTo(current, target) {
    const d = ((target - current) % 360 + 540) % 360 - 180;
    return current + d;
}
/**
 * Which way is "up": the course the device is moving on when it is moving; else the compass, when the
 * phone is giving one; else the way the route is heading.
 */
export function chooseHeading(f, device, course) {
    if (f.heading !== null && (f.speed ?? 0) >= 1)
        return f.heading;
    return device !== null ? device : course;
}
/** Take the map's camera for a journey of `costing`. */
export function startFollow(host, costing, container) {
    const map = host.map();
    let on = true, last = null, course = 0, timer = 0;
    let stopped = false;
    const arrow = () => document.querySelector(".user-marker");
    const paintArrow = () => {
        const a = arrow();
        if (!a || !map)
            return;
        const heading = last ? chooseHeading(last, host.deviceHeading(), course) : course;
        a.classList.add("nav");
        a.style.setProperty("--hdg", `${on ? 0 : heading - map.getBearing()}deg`); // heading-up: the map turned, the arrow is straight
    };
    const ease = (duration) => {
        if (!map || !last || !on)
            return;
        const heading = chooseHeading(last, host.deviceHeading(), course);
        map.easeTo({
            center: [last.lng, last.lat], bearing: turnTo(map.getBearing(), heading), pitch: FOLLOW_PITCH,
            zoom: followZoom(last.speed, costing),
            padding: followPadding(container.clientHeight, host.sheetHeight(), host.bannerHeight()), duration,
        });
    };
    const later = (ms) => {
        clearTimeout(timer);
        timer = window.setTimeout(() => recentre(), ms);
    };
    const recentre = () => { if (stopped)
        return; clearTimeout(timer); on = true; paintArrow(); syncButtons(); ease(600); };
    // a hand on the map lets go of the camera; it comes back after a pause
    const hand = (e) => {
        if (stopped || !e.originalEvent)
            return;
        on = false;
        paintArrow();
        syncButtons();
        later(RETURN_MS);
    };
    const events = ["dragstart", "rotatestart", "pitchstart", "zoomstart"];
    if (map)
        for (const t of events)
            map.on(t, hand);
    const onRotate = () => paintArrow();
    map?.on("rotate", onRotate);
    // the two buttons, at the map's right edge
    const bar = document.createElement("div");
    bar.id = "navbtns";
    bar.innerHTML =
        `<button type="button" class="nbtn nb-recentre" title="Recentre on you" aria-label="Recentre on you">🧭</button>` +
            `<button type="button" class="nbtn nb-overview" title="Show the rest of the way" aria-label="Show the rest of the way">🗺️</button>`;
    container.appendChild(bar);
    const syncButtons = () => { bar.querySelector(".nb-recentre")?.classList.toggle("loose", !on); };
    bar.querySelector(".nb-recentre").onclick = recentre;
    bar.querySelector(".nb-overview").onclick = () => overview();
    function overview() {
        const r = host.remaining(), b = r && boundsOf([r]);
        if (!map || !b)
            return;
        on = false;
        paintArrow();
        syncButtons();
        map.setPadding({ top: 0, bottom: 0, left: 0, right: 0 });
        map.fitBounds(b, { duration: 700, maxZoom: 17, bearing: 0, pitch: 0,
            padding: { top: host.bannerHeight() + 40, bottom: host.sheetHeight() + 40, left: 40, right: 40 } });
        later(6000);
    }
    return {
        onFix(f, c) { last = f; course = c; paintArrow(); ease(900); },
        overview, recentre,
        following: () => on,
        stop() {
            stopped = true;
            clearTimeout(timer);
            if (map) {
                for (const t of events)
                    map.off(t, hand);
                map.off("rotate", onRotate);
                map.setPadding({ top: 0, bottom: 0, left: 0, right: 0 });
                map.easeTo({ bearing: 0, pitch: 0, duration: 600 });
            }
            const a = arrow();
            if (a) {
                a.classList.remove("nav");
                a.style.removeProperty("--hdg");
            }
            bar.remove();
        },
    };
}
