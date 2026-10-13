// app/route/drive-sim.ts — a rehearsed drive: the device set aside, fixes fed along a route.
//
// A desktop has no GPS and a test has no road. `startDrive` walks a route's own
// shape at a speed and feeds each step through the one position source
// (app/position.ts `feed`), so the wayfinder, the camera and the you-marker read
// a drive exactly as they read a real one. `?simdrive=<factor>` on the page's URL
// starts one when a journey sets out; `factor` is how many times the way's own pace.
import { feed, simulate } from '../position.js';
import { pointAt, shapeKm } from './facts.js';
/** A typical pace for a way of travelling, in metres per second. */
export const pace = (costing) => ({ pedestrian: 1.4, bicycle: 4.5, auto: 13, multimodal: 1.4 }[costing] ?? 1.4);
/** Begin a drive along `r`. */
export function startDrive(r, o = {}) {
    const factor = o.factor ?? 1, tickMs = o.tickMs ?? 500;
    const speed = pace(r.costing) * factor; // metres per second, as simulated
    const total = shapeKm(r);
    let km = 0, timer = 0, stopped = false, finish = () => { };
    const done = new Promise(res => { finish = res; });
    simulate(true);
    const step = () => {
        const p = pointAt(r, km);
        feed({ lat: p.lat, lng: p.lng, heading: p.heading, speed, accuracy: 5 });
        if (km >= total) {
            stop();
            return;
        }
        km = Math.min(total, km + speed * tickMs / 1000 / 1000);
    };
    const stop = () => {
        if (stopped)
            return;
        stopped = true;
        if (timer)
            clearInterval(timer);
        simulate(false);
        finish();
    };
    step();
    if (!stopped)
        timer = window.setInterval(step, tickMs);
    return { stop, done };
}
