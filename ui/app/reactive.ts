// SPDX-License-Identifier: AGPL-3.0-or-later
// app/reactive.ts — a tiny (~40-line) reactive core: signals + batched effects.
//
// The elegant half of what a framework like Svelte would give us, with no build
// step and no dependency: read a signal inside an effect and the effect
// re-runs — batched to a microtask — whenever that signal changes. Replaces the
// codebase's manual "mutate a `let`, then remember to call the right drawX()"
// pattern for EVENT-DRIVEN panel/filter state.
//
// NOT for the dial's hot animation fields (S.turnH/morphU/…): those are mutated
// many times per rAF frame by tuned morph/scrub loops that already draw in a
// precise order — reactive auto-redraw there would double-paint and fight them.
// Keep those imperative; use signals for panel state that changes on user/seam
// events (filters, the contacts book, view toggles).

/**
 * A signal is callable AND carries its writers, so reading is `s()` at every
 * call site rather than `s.get()`. The type says both halves at once.
 */
export interface Signal<T> {
  /** Read, subscribing the active effect if one is running. */
  (): T;
  /** Write. A value equal by Object.is is not a change and wakes nobody. */
  set(value: T): void;
  /** Write from the current value. */
  update(fn: (previous: T) => T): void;
  /** Read WITHOUT subscribing — for code that wants the value, not the edge. */
  peek(): T;
}

/** Unsubscribes an effect from every signal it currently reads. */
export type Dispose = () => void;

/**
 * A live effect. `deps` holds the subscriber sets it sits in, so a re-run can
 * remove itself from all of them before tracking afresh — that is what lets an
 * effect's dependencies change between runs (a branch reading a different
 * signal) without leaking the old ones.
 */
interface Effect {
  deps: Set<Set<Effect>>;
  run(): void;
}

let activeEffect: Effect | null = null;
const queued = new Set<Effect>();
let flushing = false;

function flush(): void {
  flushing = false;
  const run = [...queued]; queued.clear();
  for (const e of run) e.run();
}
function enqueue(e: Effect): void {
  queued.add(e);
  if (!flushing) { flushing = true; queueMicrotask(flush); }
}

// signal(v) → a getter function; s() reads (and subscribes the active effect),
// s.set(v) writes, s.peek() reads untracked, s.update(fn) sets from the old value.
export function signal<T>(value: T): Signal<T> {
  const subs = new Set<Effect>();
  // Built as a bare reader, then given its writers. The assertion is what lets
  // the three properties land on a function; every one of them is installed
  // before this returns.
  const s = (() => {
    // Reading inside an effect is what subscribes it: the edge is recorded on
    // both ends, so either side can tear it down.
    if (activeEffect) {
      subs.add(activeEffect);
      activeEffect.deps.add(subs);
    }
    return value;
  }) as Signal<T>;

  s.set = (v) => {
    if (Object.is(v, value)) return;
    value = v;
    // Copied before iterating: an effect re-running may subscribe or drop
    // during the walk, and mutating `subs` mid-iteration would skip a reader.
    for (const e of [...subs]) enqueue(e);
  };
  s.update = (fn) => s.set(fn(value));
  s.peek = () => value;
  return s;
}

// effect(fn) → runs fn now, tracks the signals it reads, re-runs (batched) when
// any of them change. Returns a disposer that unsubscribes it.
export function effect(fn: () => void): Dispose {
  const e: Effect = {
    deps: new Set(),
    run() {
      for (const d of e.deps) d.delete(e);
      e.deps.clear();
      const prev = activeEffect; activeEffect = e;
      try { fn(); } finally { activeEffect = prev; }
    },
  };
  e.run();
  return () => {
    for (const d of e.deps) d.delete(e);
    e.deps.clear();
  };
}
