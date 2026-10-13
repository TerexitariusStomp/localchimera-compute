// app/passcode-held.ts — whether a passcode is on screen that has not been saved yet.
//
// A new identity's passcode is shown once; leaving before it is saved destroys
// the only key. While it is held, the page asks before it unloads and a waiting
// update waits too. This is a leaf, so app/update.ts can read it without
// pulling in the identity machinery.

import { signal } from './reactive.js';

export const passcodeUnsaved = signal(false);

/** Leaving the page with an unsaved passcode destroys the only key: the browser's one hook. */
const guard = (e: BeforeUnloadEvent): void => { e.preventDefault(); e.returnValue = ""; };

/** Hold (true) or release (false) the page around an unsaved passcode. */
export function holdPasscode(on: boolean): void {
  passcodeUnsaved.set(on);
  if (on) window.addEventListener("beforeunload", guard);
  else window.removeEventListener("beforeunload", guard);
}
