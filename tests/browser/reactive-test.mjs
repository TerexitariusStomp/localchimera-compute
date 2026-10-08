// tests/browser/reactive-test.mjs — signals and batched effects
// (browser/app/reactive.js, from ui/app/reactive.ts)
//
// Twenty-one modules import this and none of them could see it fail. The panels,
// the calendar filters and the theme picker all rest on three properties that are
// invisible when they hold and near-impossible to debug when they do not:
//
//   BATCHING      several writes in one tick wake an effect ONCE. Lose it and
//                 every filter toggle repaints per signal touched.
//   RE-TRACKING   an effect that reads a different signal on its second run must
//                 DROP the first. Lose it and a branch you left keeps waking you
//                 forever — the leak that looks like "the dial redraws randomly".
//   DEDUP         writing the value that is already there is not news.
//
// Pure functions over microtasks: node runs the real module, no DOM.
//
// Run: node tests/browser/reactive-test.mjs

const { signal, effect } = await import("../../browser/app/reactive.js");

import { harness } from './assert.mjs';
const { check, done } = harness();
// effects are batched to a microtask, so settle before asserting
const tick = () => new Promise(r => setTimeout(r, 0));

console.log("\n── a signal reads and writes ──");
{
  const s = signal(1);
  check("reads its initial value", s() === 1);
  s.set(2);
  check("reads what was written", s() === 2);
  s.update(v => v + 40);
  check("update sets from the old value", s() === 42);
  check("peek reads the same value", s.peek() === 42);
}

console.log("\n── an effect runs, then re-runs on change ──");
{
  const s = signal("a");
  let runs = 0, seen = null;
  effect(() => { runs++; seen = s(); });
  check("runs immediately", runs === 1 && seen === "a");

  s.set("b");
  check("the write does not re-run it synchronously", runs === 1);
  await tick();
  check("it re-runs on the microtask", runs === 2 && seen === "b");
}

console.log("\n── BATCHING: many writes, one wake ──");
{
  const a = signal(0), b = signal(0);
  let runs = 0;
  effect(() => { runs++; a(); b(); });
  runs = 0;

  a.set(1); a.set(2); a.set(3); b.set(1);
  await tick();
  check("four writes across two signals wake it exactly once", runs === 1, `  (runs=${runs})`);
}

console.log("\n── DEDUP: the same value is not news ──");
{
  const s = signal(7);
  let runs = 0;
  effect(() => { runs++; s(); });
  runs = 0;

  s.set(7);
  await tick();
  check("writing the value already there wakes nobody", runs === 0);

  const obj = { x: 1 };
  const o = signal(obj);
  let oruns = 0;
  effect(() => { oruns++; o(); });
  oruns = 0;
  o.set(obj);
  await tick();
  check("identity is the test, so the same object is not news", oruns === 0);
  o.set({ x: 1 });
  await tick();
  check("…but an equal-looking NEW object is", oruns === 1);
}

console.log("\n── RE-TRACKING: yesterday's dependency lets go ──");
{
  const useFirst = signal(true);
  const first = signal("1"), second = signal("2");
  let runs = 0;
  effect(() => { runs++; useFirst() ? first() : second(); });
  check("runs once to start", runs === 1);

  useFirst.set(false);            // now it reads `second` instead
  await tick();
  check("switching branch re-runs it", runs === 2);

  first.set("changed");           // the signal it no longer reads
  await tick();
  check("the ABANDONED signal no longer wakes it", runs === 2, `  (runs=${runs})`);

  second.set("changed");
  await tick();
  check("the newly-read signal does", runs === 3);
}

console.log("\n── peek reads without subscribing ──");
{
  const s = signal(0);
  let runs = 0;
  effect(() => { runs++; s.peek(); });
  runs = 0;
  s.set(1);
  await tick();
  check("an effect that only peeked is never woken", runs === 0);
}

console.log("\n── the disposer unsubscribes ──");
{
  const s = signal(0);
  let runs = 0;
  const stop = effect(() => { runs++; s(); });
  runs = 0;
  stop();
  s.set(1);
  await tick();
  check("a disposed effect stays asleep", runs === 0);
}

done();
