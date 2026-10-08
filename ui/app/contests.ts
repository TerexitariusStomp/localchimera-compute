// app/contests.ts — the contests open, as the faces read them.
//
// A contest is a member's word that a count (or work) was not done
// (docs/observation/capture.md §8). Three places read the contests open in the
// scope: the capture sheet's counts screen, the store face's desk, and the stock
// rows that tell a counter their count is contested. They read one state, here:
// every contest open as it stands to this person, and the ones they may attach a
// picture to, by the stock each is of. One writer sets both, so they cannot
// disagree, and a contest opened from the sheet shows on the face at once.

import { HANDLERS } from "./core.js";
import { signal } from "./reactive.js";
import { readContests, contestedBy, type ContestEntry } from "./contest.js";

/** Every contest open in the scope, as it stands to this person. */
export const openContests = signal<ContestEntry[]>([]);

/** The contests of this person's own counts, by the stock each is of. */
export const contested = signal(new Map<string, ContestEntry>());

let asked = false;

/** Ask the contests door and set both states; resolves to the contests (none when the door fails). */
export async function refreshContests(): Promise<ContestEntry[]> {
  try {
    const entries = readContests(await HANDLERS.contests?.());
    openContests.set(entries);
    contested.set(contestedBy(entries));
    asked = true;
    return entries;
  } catch {
    return [];
  }
}

/** Ask once until the next push of the stock; the faces call it while they draw. */
export function ensureContests(): void {
  if (!asked) { asked = true; void refreshContests().then(() => undefined); }
}

/** The stock moved: the contests are asked again the next time a face wants them. */
export function forgetContests(): void { asked = false; }
