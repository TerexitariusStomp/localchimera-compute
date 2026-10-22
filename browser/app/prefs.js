// app/prefs.ts — small preferences about HOW the day is shown, kept per device.
//
// These are not facts about the commons and never cross the wire: they are the
// reader's own habits. Each is a signal, so a change in settings repaints every
// surface that reads it without anything having to remember to call a draw.
import { signal } from './reactive.js';
import { readJSON, writeJSON } from './store.js';
import { K } from "./keys.js";
const KEY = K.prefs;
// Unparseable or unreadable (private mode, disabled storage) starts from
// defaults rather than refusing to render — app/store.ts holds that guard.
const store = readJSON(KEY, {});
const save = () => { writeJSON(KEY, store); };
function pref(name, dflt) {
    // What came back from localStorage is whatever was written there last — the
    // cast is a claim about our own past self, and a reader with an older (or
    // hand-edited) store can hold anything. Falling back to dflt on `undefined`
    // is the only validation, which is why prefs stay small and scalar.
    const s = signal(store[name] === undefined ? dflt : store[name]);
    const set = (v) => { store[name] = v; save(); s.set(v); };
    return [s, set];
}
// 0 = Sunday, 1 = Monday. It governs BOTH week-shaped surfaces — the calendar
// rail's mini-month and the week grid's own window — so they can never disagree
// about which column a day belongs in.
export const [weekStart, setWeekStart] = pref("weekStart", 1);
// Feedback and ideas: anyone may point at a part of the interface (or of the
// protocol it shows) and say what they think; it goes to the developers. The
// 💬 in the share bar (app/feedback.ts) is the way in, and stays out of the way
// until this is on — the bar's row is the one place every face shares, and a
// visitor who never wants it never has to make room for it. It is one switch in
// the account sheet and in settings.
export const [feedbackMode, setFeedbackMode] = pref("feedbackMode", false);
// Dev mode: the maintainers' own tools (the map's layer inspector). Apart from
// feedback, which is for everyone: this one is for reading the map's layers.
export const [devMode, setDevMode] = pref("devMode", false);
// Which faces the nav strip NAMES. The strip starts small — the map, the
// calendar and the forum — and every other face is a toggle in settings: a
// reader who never opens the corpus never has to read past it. A face stays
// reachable by URL and by voice whether or not its tab shows; the face you are
// on is always named, so nothing you can stand on is ever nameless.
export const DEFAULT_TABS = ["map", "shop", "forum"];
export const [tabsOn, setTabsOn] = pref("tabsOn", DEFAULT_TABS);
// Where the page lands when the URL names no face. A setting of its own, apart
// from which tabs show: the home face is what you want FIRST, and the strip is
// what you want within reach — the calendar by default.
export const [homeFace, setHomeFace] = pref("homeFace", "map");
// The currency an hour of credit is read in (app/money.ts). Empty means "not
// chosen": the reader is then shown the currency the device's zone or locale
// implies, and the dollar when neither says. A pick is kept as the code.
export const [currency, setCurrency] = pref("currency", "");
