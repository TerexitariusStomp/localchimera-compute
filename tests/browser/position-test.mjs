// tests/browser/position-test.mjs — where you are, from ONE source
// (browser/app/position.js, from ui/app/position.ts): a fix moves USER and
// reaches every observer, a watch runs only while someone listens (high-accuracy
// while anyone asks), and a rehearsed drive sets the device aside.
//
// Run: node tests/browser/position-test.mjs

import { installDomStub } from './dom-stub.mjs';
import { harness } from './assert.mjs';
const { check, section, done } = harness();
installDomStub();

// a device that records how it was asked, and can be made to report
let watches = [], cleared = [], once = [];
Object.defineProperty(globalThis, "navigator", { configurable: true, value: {
  geolocation: {
    watchPosition(ok, _err, o) { const id = watches.length + 1; watches.push({ id, ok, o }); return id; },
    clearWatch(id) { cleared.push(id); },
    getCurrentPosition(ok, err, o) { once.push({ ok, err, o }); },
  },
} });
const { USER } = await import("../../browser/app/core.js");
const P = await import("../../browser/app/position.js");

section("a reading");
{
  const f = P.fixOf({ latitude: 1, longitude: 2, heading: NaN, speed: null, accuracy: 5 }, 7);
  check("a reading becomes a fix", f.lat === 1 && f.lng === 2 && f.accuracy === 5 && f.t === 7);
  check("NaN and absent are unknown, not zero", f.heading === null && f.speed === null);
  check("a heading and a speed ride through", (g => g.heading === 90 && g.speed === 3)(P.fixOf({ latitude: 0, longitude: 0, heading: 90, speed: 3 })));
}

section("a fix moves you, and is heard");
{
  const heard = []; const stop = P.observeFixes(f => heard.push(f));
  P.feed({ lat: 10, lng: 20 });
  check("USER is where the fix says", USER.lat === 10 && USER.lng === 20);
  check("an observer hears it", heard.length === 1 && heard[0].lat === 10);
  check("an unnamed part of the reading is unknown", heard[0].heading === null && heard[0].speed === null);
  check("the last fix is kept", P.lastFix().lat === 10);
  check("an observer asks the device for nothing", watches.length === 0);
  P.feed({ lat: 11, lng: 21, heading: 45, speed: 2 });
  check("a fed heading and speed are heard", heard[1].heading === 45 && heard[1].speed === 2);
  stop(); P.feed({ lat: 12, lng: 22 });
  check("a stopped observer hears no more, but USER still moves", heard.length === 2 && USER.lat === 12);
}

section("where you are, as a point of your own");
{
  P.feed({ lat: 51, lng: 4 });
  const here = P.youAt();
  check("a point at USER", here.lat === 51 && here.lng === 4);
  P.feed({ lat: 52, lng: 5 });
  check("a copy: later fixes do not move it", here.lat === 51 && P.youAt().lat === 52);
}

section("the device watch follows its listeners");
{
  const a = [], b = [];
  const stopA = P.watchFixes(f => a.push(f));
  check("the first listener starts one watch", watches.length === 1);
  check("which is not high-accuracy while nobody asks", watches[0].o.enableHighAccuracy === false);
  const stopB = P.watchFixes(f => b.push(f), { highAccuracy: true });
  check("a listener asking for accuracy re-tunes it: the old watch is cleared, a high one begins",
        cleared.includes(1) && watches.length === 2 && watches[1].o.enableHighAccuracy === true);
  watches[1].ok({ coords: { latitude: 5, longitude: 6, heading: 10, speed: 1, accuracy: 3 }, timestamp: 99 });
  check("a device reading reaches every listener", a.length === 1 && b.length === 1 && a[0].lat === 5 && USER.lng === 6);
  stopB();
  check("when the accurate listener leaves, the watch relaxes", cleared.includes(2) && watches.length === 3 && watches[2].o.enableHighAccuracy === false);
  stopA();
  check("when the last listener leaves, the watch is cleared", cleared.includes(3));
  const before = watches.length;
  const stopC = P.watchFixes(() => {}), stopD = P.watchFixes(() => {});
  check("two listeners share one watch", watches.length === before + 1);
  stopC(); stopD();
}

section("a rehearsed drive sets the device aside");
{
  const n = watches.length, got = [];
  P.simulate(true);
  const stop = P.watchFixes(f => got.push(f));
  check("while simulating, no device watch starts", watches.length === n);
  P.feed({ lat: 30, lng: 40 });
  check("a fed fix still reaches the listener", got.length === 1 && USER.lat === 30);
  P.simulate(false);
  check("taking the device back starts the watch for the listener already there", watches.length === n + 1);
  stop();
}

section("one ask");
{
  P.simulate(true);
  const f = await P.locateOnce();
  check("while simulating, locateOnce answers the last fix and asks the device nothing", f && f.lat === 30 && once.length === 0);
  P.simulate(false);
  const p = P.locateOnce(1000);
  check("otherwise it asks the device once", once.length === 1 && once[0].o.timeout === 1000);
  once[0].ok({ coords: { latitude: 7, longitude: 8 }, timestamp: 1 });
  const g = await p;
  check("and resolves with the fix, which has moved USER", g.lat === 7 && USER.lat === 7);
  const q = P.locateOnce();
  once[1].err({});
  check("a refusal resolves null", (await q) === null);
}

done();
