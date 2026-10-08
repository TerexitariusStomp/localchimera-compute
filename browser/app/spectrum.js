// app/spectrum.ts — the time-view as a spectrum, for whoever wants to hear it.
//
// The hand reading the band-shares at this instant IS a distribution over
// needs, and the rim's marks (D∕2, D∕3, D∕4 …) are the overtone series. The
// ambient engine (browser/lib/ambient.js) turns that into the partials of one
// tone: the day's needs become its harmonics. main.ts provides the reading,
// since only it holds the stage's layout; the engine imports it from here, so
// neither knows the other.
let reader = () => null;
/** The time-view now, or null before the stage has laid out. */
export const spectrum = () => reader();
/** Installed once by main.ts. */
export function provideSpectrum(fn) { reader = fn; }
