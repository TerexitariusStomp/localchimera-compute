// app/arm.ts — an act that takes two taps, as a signal.
//
// A first tap arms the act: its control redraws as the question ("withdraw?"),
// and a second tap inside the window runs it; silence disarms. The armed act's
// key is a signal, so a view drawn from templates (template.ts) shows the
// armed state by reading it, the way slots/editors.ts armTwice does for a
// control built once.
import { signal } from './reactive.js';

export interface Armer {
  /** The key of the armed act, or null. A tracked read. */
  armed(): string | null;
  /** Arm KEY, or run it when it is the one armed. */
  arm(key: string, run: () => void): void;
}

/** A two-tap guard whose arming lapses after MS. */
export function armer(ms = 3000): Armer {
  const key = signal<string | null>(null);
  let timer = 0;
  return {
    armed: () => key(),
    arm(k, run) {
      clearTimeout(timer);
      if (key.peek() === k) { key.set(null); run(); return; }
      key.set(k);
      timer = window.setTimeout(() => key.set(null), ms);
    },
  };
}
