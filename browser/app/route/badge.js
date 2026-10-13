// app/route/badge.ts — a transit line as its badge: the line's short name on the colours its agency gave it.
//
// One builder for the preview's summary and leg strip, the step list's ride rows and anywhere else a line is
// named, so a line reads the same wherever it appears. The colours are the engine's own ("#rrggbb" or empty);
// a line with none wears the sheet's.
import { mk } from '../dom.js';
export function lineBadge(l) {
    const b = mk("span", "line-badge", l.line);
    if (l.color) {
        b.style.background = l.color;
        b.style.color = l.textColor || "#fff";
    }
    return b;
}
