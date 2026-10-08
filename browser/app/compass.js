// app/compass.ts — the phone as a compass, and knowing where you are.
//
// In earth mode the dial's angular coordinate stops meaning the HOUR and starts
// meaning the BEARING. Turn the compass on and it means bearing *from where you
// are facing*: the satellite rotates under you, the place arcs swing to their
// true directions, and the dial becomes an instrument you hold rather than a
// picture you read.
//
// Two device capabilities, both optional and both asked for the same way — only
// where they can work, and only behind a gesture:
//
//   ORIENTATION  iOS demands the permission request ride a user gesture, which
//                is why toggleCompass is a click handler and not a boot step.
//                Two event names are bound because Safari and the rest disagree
//                about which one is absolute.
//   GEOLOCATION  asked ONCE, ever. The SF default was always a stand-in, and
//                arriving somewhere should read as arrival — so the camera
//                GLIDES rather than jumping, because a hard jump reads as a
//                teleport.
import { USER } from './core.js';
import { onEarth } from './stage.js';
let host;
/** Device heading, degrees clockwise from north. Zero when the compass is off. */
let heading = 0;
let compassOn = false;
let lastHeading = 0;
/** Where the device is pointing — the dial's angular origin in earth mode. */
export const deviceHeading = () => heading;
/** Whether the compass is live. */
export const compassLive = () => compassOn;
function onOrient(e) {
    const r = e;
    let h = null;
    if (typeof r.webkitCompassHeading === "number")
        h = r.webkitCompassHeading;
    else if (r.absolute && typeof r.alpha === "number")
        h = 360 - r.alpha;
    if (h == null)
        return;
    // A 2° deadband. Orientation fires far faster than the dial can repaint, and
    // without it the whole bearing chrome redraws on sensor noise.
    if (Math.abs(h - lastHeading) < 2)
        return;
    lastHeading = h;
    heading = h;
    if (!onEarth())
        return;
    host.setBearing(heading); // the satellite turns with you
    host.redrawBearings(); // arcs, threads, events and chrome follow
}
/**
 * Whether this device can give a heading: orientation events exist and the
 * device is a touch one (a desktop browser defines the events and never fires
 * them). The needle turns heading-up on only where this holds.
 */
export const compassCapable = () => typeof DeviceOrientationEvent !== "undefined"
    && typeof matchMedia === "function" && matchMedia("(pointer: coarse)").matches;
/** The needle control's own state: lit while the phone steers the map. */
export function syncCompassUi() {
    d3.selectAll(".mapbox-ctrl-compass").classed("live", compassOn);
}
/**
 * The needle was tapped. With a heading to give, it toggles heading-up (off
 * sets north up again, as the needle always did); true claims the tap. Without
 * one, false leaves the tap to the control's own back-to-north.
 */
export function needleTap() {
    if (!compassCapable())
        return false;
    void toggleCompass();
    return true;
}
async function toggleCompass() {
    if (!compassOn) {
        try {
            const gate = (typeof DeviceOrientationEvent !== "undefined"
                ? DeviceOrientationEvent : null);
            if (gate && gate.requestPermission) {
                if (await gate.requestPermission() !== "granted")
                    return;
            }
            // Both names: they disagree about which is absolute, and the reading
            // itself says which it is.
            window.addEventListener("deviceorientationabsolute", onOrient, true);
            window.addEventListener("deviceorientation", onOrient, true);
            compassOn = true;
        }
        catch {
            return;
        }
    }
    else {
        window.removeEventListener("deviceorientationabsolute", onOrient, true);
        window.removeEventListener("deviceorientation", onOrient, true);
        compassOn = false;
        heading = 0;
        host.setBearing(0);
        if (onEarth())
            host.redrawBearings();
    }
    syncCompassUi();
}
let geoAsked = false;
/**
 * You are the centre: ask for geolocation, ONCE ever, and move everything to
 * where you actually are.
 *
 * Asked lazily rather than at boot, because a permission prompt on first paint
 * is a prompt nobody has been given a reason for yet.
 */
export function askGeolocation() {
    if (geoAsked || !navigator.geolocation)
        return;
    geoAsked = true;
    navigator.geolocation.getCurrentPosition(pos => {
        USER.lat = pos.coords.latitude;
        USER.lng = pos.coords.longitude;
        host.arrived();
    }, () => { }, { timeout: 6000 });
}
/**
 * Leaving the earth: the heading stops meaning anything, so it goes back to
 * north. The compass itself stays on — you did not turn it off, and returning
 * to the map should find it as you left it.
 */
export const resetHeading = () => { heading = 0; };
/** Hand the compass its host: what turns when the heading does. */
export function initCompass(h) {
    host = h;
}
