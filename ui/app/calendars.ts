// app/calendars.ts — the CALENDARS: which of the day's sources are showing.
//
// Google's left rail lists one checkbox per calendar because a calendar there is
// a SOURCE of events. playnet's day already has eight, and they are not arbitrary
// containers — each is a different relation between you and a span of time:
//
//   plan    the committed day the planner solved for you (evs)
//   props   proposals directed at you, awaiting your yes (pending())
//   mine    your own events, the ones you wrote yourself (eventRing)
//   open    work-intents you are eligible for but nobody has assigned (eligible)
//   avail   the availability windows you painted, the offer of your time
//   sched   the solve's WHOLE production schedule, dated (sched)
//   needs   your declared needs, at their own standing rhythm (share's slots)
//   lived   the record of what actually happened — EconomicEvents (lived)
//
// So the checkbox is a real filter over real sources, not a folder toggle: turn
// `props` off and the proposals leave the dial's ribbons, the week grid, the map
// markers and the panel list together, because all four read through here.
//
// A commune-per-calendar split (Google's "Other calendars") is buildable now —
// ingest stamps `scope` on every wired event — and waits only on a face that
// wants it. The eight above are what the day actually holds.
//
// Visibility persists per device — it is a way of looking, not a fact about the
// commons, so it never leaves the browser.
//
// It rides the reactive spine (app/reactive.ts): `calOn` reads a signal, so any
// effect that asks about a calendar re-runs when one is toggled. That is what
// keeps the rail's checkboxes and the settings section in step with each other
// without either knowing the other exists — and it is why no caller has to
// remember to repaint. The dial's own hot paint stays imperative on purpose (see
// reactive.ts's note): main.js subscribes ONE effect that calls markDayChanged.

import { signal } from './reactive.js';
import { readJSON, writeJSON } from './store.js';
import { K } from "./keys.js";

/** The eight sources. A calendar id is closed: adding one means adding a source. */
export type CalendarId = "plan" | "props" | "mine" | "open" | "avail" | "sched" | "needs" | "lived";

/** A source as the rail and the settings section render it. */
export interface Calendar {
  id: CalendarId;
  name: string;
  /** The colour this source already wears elsewhere in the dial. */
  ink: string;
  hint: string;
}

const KEY = K.calendarsOff;

// Unreadable or unparseable — show everything rather than hide a source.
const off = new Set<string>(readJSON<string[]>(KEY, []));

// The inks are the ones these sources ALREADY wear elsewhere in the dial, so the
// rail reads as a legend of the same day rather than a second colour language:
// work-warm for the plan, the credit gold proposals wear while they await you,
// the commons green of an open shift, the availability arc's own blue.
export const CALENDARS: Calendar[] = [
  { id: "plan",  name: "social-plan",     ink: "#1581a8",
    hint: "the day the planner solved for you" },
  { id: "props", name: "proposals",    ink: "#e2a512",
    hint: "directed at you, awaiting your yes" },
  { id: "mine",  name: "my events",    ink: "#7a4bb0",
    hint: "the ones you wrote yourself" },
  { id: "open",  name: "open shifts",  ink: "#2f7a5a",
    hint: "work you are eligible for, unassigned" },
  { id: "avail", name: "availability", ink: "#7ab0d4",
    hint: "the windows you offered your time in" },
  { id: "sched", name: "schedule", ink: "#b0653a",
    hint: "the whole production schedule, every day on its own date" },
  { id: "needs", name: "my needs",     ink: "#5a8a52",
    hint: "your standing needs, at their own rhythm" },
  { id: "lived", name: "what happened", ink: "#767b6e",
    hint: "the lived record — economic events, beside the plan that asked" },
];

// the version signal: a notifier, the way main.js's `day` is one. The Set is
// deep-mutated (it is small and shared), so what changes identity is this.
const rev = signal(0);

// Reading a calendar's state SUBSCRIBES the reading effect — that is the whole
// mechanism: `calOn` inside an effect means "re-run me when this flips".
export const calOn = (id: CalendarId): boolean => { rev(); return !off.has(id); };

// `pick` is how every paint site reads a source: it returns the list or nothing,
// so a hidden calendar costs one branch and can never half-apply.
export const pick = <T>(id: CalendarId, list: T[]): T[] => (calOn(id) ? list : []);

// the notifier itself, for a reader that wants "any calendar changed" without
// naming one (main.js's repaint effect)
export const calsRev = (): number => rev();

export function setCalOn(id: CalendarId, on: boolean): void {
  if (on === !off.has(id)) return;              // no news, no repaint
  if (on) off.delete(id); else off.add(id);
  writeJSON(KEY, [...off]);   // a store that refuses loses the memory, not the toggle
  rev.set(rev.peek() + 1);
}

export const calCount = (): number => CALENDARS.filter(c => calOn(c.id)).length;
