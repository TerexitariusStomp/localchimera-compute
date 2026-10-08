// app/daterow.ts — the date above the clock: which window the dial is showing,
// named, and the picker that moves it.
//
// The dial's face is a PHASE — an angle within one turn — and a phase says
// nothing about which turn. This line is what makes the difference: read off
// turnAnchor(), so it follows present-forward and calendar anchoring exactly,
// it names the real day, range or period on screen. Without it, walking the
// hand across 0/τ would look like a re-loop of today rather than an arrival at
// tomorrow, which is the one thing the scrub is designed NOT to be.
//
// ── EACH SCALE IS NAMED IN ITS OWN UNITS ────────────────────────────────────
// An hour turn reads as a clock hour, a day as one real date, the rolling
// scales as a range, and the long ones by period name. The RELATIVE half
// follows the same rule: one step gets a word ("next week"), several count in
// the unit's own plural — and the 3-day turn counts in real days (+6 days)
// rather than in threes, because "+2 3-days" is not a thing anyone says.
//
// ── THE LABEL IS THE PICKER ─────────────────────────────────────────────────
// Tapping the date opens a native date input rather than a calendar of our
// own; ⟲ appears only once you are off "now" and walks back to the present.
// showPicker() is the modern door and is tried first, with focus+click as the
// fallback for a browser that has not got it — both are wrapped, because a
// browser may also HAVE the method and refuse the call.
import { S } from './state.js';
import { turnAnchor } from './events.js';
import { turnPos } from './turn.js';
import { drawHand, isScrubbing, stopScrub, homeHand as homeTurn } from './hand.js';
import { drawEvents } from './ribbons.js';
import { baseYear, dateOf, wd, dm, FULLMON, SEASONS, relTerm, relPeriod, two, isoDateUTC } from './timefmt.js';
// the date above the clock names the window the dial is showing — read off
// turnAnchor(), so it follows present-forward / calendar anchoring exactly.
function dateRowText() {
    const k = S.viewTurnOffset, A = turnAnchor(), d0 = Math.floor(A / 24);
    if (S.turnH < 1.5) { // hour: the clock hour
        const d = dateOf(d0), h = Math.floor((A % 24 + 24) % 24);
        return `${wd(d)} ${dm(d)} · ${two(h)}:00`;
    }
    if (Math.abs(S.turnH - 24) < 0.5) { // day: one real date
        const d = dateOf(d0);
        return `${wd(d)} ${dm(d)} · ${relTerm(k, "day")}`;
    }
    if (S.turnH < 720) { // 3-day / week / moon: a rolling range
        const a = dateOf(d0), b = dateOf(Math.floor((A + S.turnH - 1) / 24));
        const rng = a.getUTCMonth() === b.getUTCMonth()
            ? `${wd(a)} ${a.getUTCDate()} – ${wd(b)} ${dm(b)}`
            : `${wd(a)} ${dm(a)} – ${wd(b)} ${dm(b)}`;
        // one step gets a name; many steps count in the unit's own plural — the
        // 3-day in real days (+6 days), the week in weeks, the moon in moons
        const [one, per, many] = Math.abs(S.turnH - 72) < 1 ? ["3 days", 3, "days"]
            : Math.abs(S.turnH - 168) < 1 ? ["week", 1, "weeks"] : ["moon", 1, "moons"];
        const rel = k === 0 ? "now"
            : Math.abs(k) === 1 ? (k > 0 ? `next ${one}` : `last ${one}`)
                : `${k > 0 ? "+" : "−"}${Math.abs(k) * per} ${many}`;
        return `${rng} · ${rel}`;
    }
    const d = dateOf(d0); // month / season / year, by name
    if (S.turnH < 1500)
        return `${FULLMON[d.getUTCMonth()]} ${d.getUTCFullYear()} · ${relPeriod(k, "month")}`;
    if (S.turnH < 4000)
        return `${SEASONS[Math.floor(d.getUTCMonth() / 3)]} ${d.getUTCFullYear()} · ${relPeriod(k, "season")}`;
    return `${d.getUTCFullYear()} · ${relPeriod(k, "year")}`;
}
export const updateDateRow = () => {
    const el = document.getElementById("datelabel");
    if (el)
        el.textContent = dateRowText();
    const rb = document.getElementById("datereset");
    if (rb)
        rb.style.display = (S.viewTurnOffset !== 0 || isScrubbing()) ? "" : "none";
};
// jump the dial to the window that CONTAINS a chosen calendar day, at the
// current scale: the small scales count whole windows forward from today,
// the long scales count whole calendar months/seasons/years. No scrub — the
// full schedule shows, the hand sits at the present time projected onto it.
export function goToDate(y, m, da) {
    const targetDoy = Math.round((Date.UTC(y, m, da) - Date.UTC(baseYear, 0, 1)) / 86400000);
    const today = Math.floor(S.nowAbs / 24);
    stopScrub(); // this caller picks the turn itself; do not zero its offset
    if (S.turnH < 1.5)
        S.viewTurnOffset = (targetDoy - today) * 24; // hour: same hour, that day
    else if (S.turnH < 720)
        S.viewTurnOffset = Math.floor((targetDoy - today) / (S.turnH / 24));
    else {
        const nd = dateOf(today), nm = nd.getUTCMonth() + nd.getUTCFullYear() * 12;
        const tm = m + y * 12;
        if (S.turnH < 1500)
            S.viewTurnOffset = tm - nm; // months apart
        else if (S.turnH < 4000)
            S.viewTurnOffset = Math.floor(tm / 3) - Math.floor(nm / 3); // season-quarters apart
        else
            S.viewTurnOffset = y - nd.getUTCFullYear(); // years apart
    }
    drawHand(turnPos());
    drawEvents();
}
// the date label IS the picker; ⟲ now walks back to the present
(function wireDatePicker() {
    const label = document.getElementById("datelabel");
    const pick = document.getElementById("datepick");
    const reset = document.getElementById("datereset");
    if (!label || !pick || !reset)
        return;
    label.onclick = () => {
        const d = dateOf(Math.floor(turnAnchor() / 24)); // open on the viewed day
        pick.value = isoDateUTC(d); // a day-of-year has no zone; reading it back local shifts it
        if (pick.showPicker) {
            try {
                pick.showPicker();
                return;
            }
            catch (e) { }
        }
        pick.focus();
        pick.click();
    };
    pick.onchange = () => {
        if (!pick.value)
            return;
        const [y, m, da] = pick.value.split("-").map(Number);
        goToDate(y, m - 1, da);
    };
    reset.onclick = () => { homeTurn(); drawHand(turnPos()); drawEvents(); };
})();
