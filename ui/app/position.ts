// app/position.ts — where you are: ONE source of the device's position.
//
// A fix arrives from a watch, a one-shot ask, the map's own locate button, or —
// in a test or a rehearsed drive — `feed`. All of them end in `report`, which
// does the two things a fix means: you ARE there (USER moves) and everything
// that draws you hears of it (the observers). So the you-marker, the wayfinder
// and a simulated drive read one stream, and no fix can reach the page by a
// side door.
//
//   report / feed     a fix has arrived
//   observeFixes      hear every fix, whoever took it — asks the device for nothing
//   watchFixes        hear every fix AND keep a device watch going while listening;
//                     the watch is high-accuracy while any listener asks for that
//   locateOnce        one ask, now
//   simulate          the device is set aside: only `feed` moves you (a rehearsed drive)
//
// A permission prompt is a request nobody has been given a reason for until a
// journey or a locate asks — so nothing here asks until a watcher or a locateOnce does.

import { USER } from './core.js';
import type { LatLng } from './geom.js';

/** One reading of where you are. Heading is degrees from north, speed metres per second; null when unknown. */
export interface Fix {
  lat: number;
  lng: number;
  heading: number | null;
  speed: number | null;
  /** Metres of doubt around the point. */
  accuracy: number | null;
  /** Epoch milliseconds. */
  t: number;
}

type Hear = (f: Fix) => void;

const observers = new Set<Hear>();
const watchers = new Map<Hear, boolean>();   // listener → asks for high accuracy
let watchId = -1, watchHigh = false, last: Fix | null = null, simulating = false;

/** A device reading as a fix. NaN and absent become null — a stationary phone reports no heading. */
export function fixOf(c: { latitude: number; longitude: number; heading?: number | null; speed?: number | null;
                           accuracy?: number | null }, t = Date.now()): Fix {
  const num = (v: number | null | undefined): number | null => typeof v === "number" && Number.isFinite(v) ? v : null;
  return { lat: c.latitude, lng: c.longitude, heading: num(c.heading), speed: num(c.speed), accuracy: num(c.accuracy), t };
}

/** Where you are, as a point of your own: a copy, that later fixes do not move. */
export const youAt = (): LatLng => ({ lat: USER.lat, lng: USER.lng });

/** The last fix taken, or null before any. */
export const lastFix = (): Fix | null => last;

/** A fix has arrived: you are there, and whoever draws you hears of it. */
export function report(f: Fix): void {
  last = f;
  USER.lat = f.lat; USER.lng = f.lng;
  for (const h of [...observers]) h(f);
  for (const h of [...watchers.keys()]) h(f);
}

/** Move you by hand — a test, or a rehearsed drive. Unnamed parts of the reading are unknown. */
export function feed(f: Partial<Fix> & { lat: number; lng: number }): void {
  report({ heading: null, speed: null, accuracy: null, t: Date.now(), ...f });
}

/** Hear every fix, from wherever it comes. Returns the way to stop hearing. */
export function observeFixes(fn: Hear): () => void {
  observers.add(fn);
  return () => { observers.delete(fn); };
}

/** Keep the device watch going while listening. Returns the way to stop. */
export function watchFixes(fn: Hear, o: { highAccuracy?: boolean } = {}): () => void {
  watchers.set(fn, !!o.highAccuracy);
  retune();
  return () => { watchers.delete(fn); retune(); };
}

/** Set the device aside (or take it back): while simulating, only `feed` moves you. */
export function simulate(on: boolean): void {
  simulating = on;
  retune();
}

/** One ask, now. Resolves with the fix, or null when refused, absent or too slow. */
export function locateOnce(timeoutMs = 6000): Promise<Fix | null> {
  return new Promise(resolve => {
    if (simulating || !navigator.geolocation) { resolve(last); return; }
    navigator.geolocation.getCurrentPosition(p => {
      const f = fixOf(p.coords, p.timestamp);
      report(f); resolve(f);
    }, () => resolve(null), { timeout: timeoutMs });
  });
}

/** Start, stop or re-tune the device watch to match who is listening. */
function retune(): void {
  const wanted = !simulating && watchers.size > 0;
  const high = [...watchers.values()].some(Boolean);
  if (watchId >= 0 && (!wanted || high !== watchHigh)) {
    navigator.geolocation?.clearWatch(watchId);
    watchId = -1;
  }
  if (wanted && watchId < 0 && navigator.geolocation) {
    watchHigh = high;
    watchId = navigator.geolocation.watchPosition(p => report(fixOf(p.coords, p.timestamp)), () => {},
      { enableHighAccuracy: high, maximumAge: high ? 3000 : 15000 });
  }
}
