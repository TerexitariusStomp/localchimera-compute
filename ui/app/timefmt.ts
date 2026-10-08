// app/timefmt.ts — pure calendar constants & time/date formatting.
//
// No mutable dial state: these are the stateless naming/formatting helpers
// (month & weekday tables, day-of-year → Date, duration/clock strings).
// The *stateful* time logic — turnAnchor / absUnits / dateRowText, which
// read turnH/nowAbs/viewTurnOffset — stays in main.js until Stage 4.

export const baseYear: number = (new Date()).getFullYear();
export const MON: string[] = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
/** The month as a narrow header spells it: dotted where cut, "Sept." not "Sep". */
export const MON_DOT: string[] = ["Jan.","Feb.","Mar.","Apr.","May","Jun.","Jul.","Aug.","Sept.","Oct.","Nov.","Dec."];
export const WD: string[] = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
export const FULLMON: string[] = ["January","February","March","April","May","June",
                        "July","August","September","October","November","December"];
export const SEASONS: string[] = ["winter","spring","summer","autumn"];   // by Jan-start quarter

// all calendar math is in UTC so a DST shift between two dates can never bend
// a day-count by an hour (which would floor a month-start onto the day before)
export const hoursToFirst = (y: number, m: number): number =>   // hours from Jan 1 baseYear to (y, m, 1)
  (Date.UTC(y, m, 1) - Date.UTC(baseYear, 0, 1)) / 3600000;

export const dateOf = (doy: number): Date => new Date(Date.UTC(baseYear, 0, 1 + doy)); // day-of-year → Date (UTC)
export const wd = (d: Date): string => WD[d.getUTCDay()];
export const dm = (d: Date): string => `${d.getUTCDate()} ${MON[d.getUTCMonth()]}`;    // "8 Jun"
export const relTerm = (k: number, unit: string): string => k === 0 ? "today"
  : Math.abs(k) === 1 ? (k > 0 ? "tomorrow" : "yesterday")
  : `${k > 0 ? "+" : "−"}${Math.abs(k)} ${unit}s`;
export const relPeriod = (k: number, unit: string): string => k === 0 ? "now"
  : Math.abs(k) === 1 ? (k > 0 ? `next ${unit}` : `last ${unit}`)
  : `${k > 0 ? "+" : "−"}${Math.abs(k)} ${unit}s`;

/**
 * Two digits, zero-padded — the atom every clock and ISO date below is built
 * from.
 *
 * Exported because it was being written out longhand in eight other files, and
 * a `padStart(2, "0")` in the middle of a template literal is the kind of thing
 * that reads as incidental until one of the eight forgets the pad.
 */
export const two = (n: number): string => String(n).padStart(2, "0");

/** An hour of the turn, possibly fractional, as a clock face. */
export const fmtClock = (t: number): string => {
  const h = Math.floor(t), m = Math.round((t - h) * 60);
  return `${two(h)}:${two(m)}`;
};

/** A moment as a clock face, in the reader's OWN zone — for what is happening now. */
export const clockOf = (d: Date): string => `${two(d.getHours())}:${two(d.getMinutes())}`;

/** `YYYY-MM-DD` in the reader's own zone — what a date input carries. */
export const isoDate = (d: Date): string =>
  `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())}`;

/**
 * `YYYY-MM-DD` in UTC — for a day-of-year, which is a position in the turn and
 * has no zone of its own. Reading one back with the local getters shifts the
 * date by a day for anyone west of Greenwich.
 */
export const isoDateUTC = (d: Date): string =>
  `${d.getUTCFullYear()}-${two(d.getUTCMonth() + 1)}-${two(d.getUTCDate())}`;
export const fmtTau = (t: number): string => `${(t / 24).toFixed(2)}τ`;
export const fmtDur = (t0: number, t1: number): string => {
  const d = t1 - t0, h = Math.floor(d), m = Math.round((d - h) * 60);
  return (h ? `${h} h ` : "") + (m ? `${m} m` : "").trim() || `${h} h`;
};
export const fmtSpan = (h: number): string =>
  h < 2 ? `${Math.round(h * 60)} min`
  : h < 48 ? `${+h.toFixed(1)} h`
  : h < 336 ? `${+(h / 24).toFixed(1)} days`
  : h < 4000 ? `${+(h / 168).toFixed(1)} weeks`
  : `${+(h / 730.5).toFixed(1)} months`;
