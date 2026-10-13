// tests/browser/awake-test.mjs — keeping the screen on (browser/app/awake.js, from ui/app/awake.ts): the lock
// is asked for, given back, taken again when the page returns from being hidden, and a browser with no lock or
// one that refuses leaves the screen to its own timeout without a fault.
//
// Run: node tests/browser/awake-test.mjs

import { harness } from './assert.mjs';
const { check, section, done } = harness();

const listeners = new Map();
globalThis.document = {
  visibilityState: "visible",
  addEventListener(t, f) { (listeners.get(t) ?? listeners.set(t, new Set()).get(t)).add(f); },
  removeEventListener(t, f) { listeners.get(t)?.delete(f); },
};
const fire = t => [...(listeners.get(t) ?? [])].forEach(f => f());
const tick = () => new Promise(r => setTimeout(r, 5));

let requests = 0, locks = [];
const wakeLock = { request: async () => { requests++; const l = { released: false, release: async () => { l.released = true; } }; locks.push(l); return l; } };
Object.defineProperty(globalThis, "navigator", { configurable: true, value: { wakeLock } });
const { keepAwake } = await import("../../browser/app/awake.js");

section("holding the screen");
{
  const stop = keepAwake(); await tick();
  check("the lock is asked for", requests === 1 && !locks[0].released);
  check("and a listener waits for the page to come back", listeners.get("visibilitychange")?.size === 1);
  document.visibilityState = "hidden"; locks[0].released = true;       // the browser drops it when hidden
  fire("visibilitychange"); await tick();
  check("hidden: nothing is asked for", requests === 1);
  document.visibilityState = "visible"; fire("visibilitychange"); await tick();
  check("back in view: the lock is taken again", requests === 2 && !locks[1].released);
  fire("visibilitychange"); await tick();
  check("a lock still held is not asked for twice", requests === 2);
  stop(); await tick();
  check("letting go gives the lock back and stops listening", locks[1].released && listeners.get("visibilitychange").size === 0);
  document.visibilityState = "visible"; fire("visibilitychange"); await tick();
  check("a released hold asks for nothing more", requests === 2);
}

section("letting go before the lock came");
{
  requests = 0; locks = [];
  let grant; const slow = new Promise(r => { grant = r; });
  wakeLock.request = async () => { requests++; await slow; const l = { released: false, release: async () => { l.released = true; } }; locks.push(l); return l; };
  const stop = keepAwake(); stop(); grant(); await tick(); await tick();
  check("a lock that arrives after the hold was given up is let go at once", locks.length === 1 && locks[0].released);
}

section("no lock, or a refusal");
{
  Object.defineProperty(globalThis, "navigator", { configurable: true, value: {} });
  let ok = true; try { const stop = keepAwake(); await tick(); stop(); } catch { ok = false; }
  check("a browser with no wake lock is no fault", ok);
  Object.defineProperty(globalThis, "navigator", { configurable: true, value: { wakeLock: { request: async () => { throw new Error("not allowed"); } } } });
  ok = true; try { const stop = keepAwake(); await tick(); stop(); } catch { ok = false; }
  check("one that refuses is no fault", ok);
}

done();
