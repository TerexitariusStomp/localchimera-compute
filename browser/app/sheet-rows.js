// app/sheet-rows.ts — the rows a sheet is made of.
//
// A menu of rows (an icon, a label, a line beneath), some that enter a page of their own
// (a chevron, a ← back), grouped in rounded cards: the account sheet's vocabulary, and the
// journey drawer's too. One builder, so the two read and behave alike. The classes are
// `acct-*` for the history of it; the settings room and the onboarding list wear them as well.
import { mk } from './dom.js';
/**
 * A row. A tap runs `r.go` after `close` (the row leaves the sheet), unless it is not `wire`d;
 * with `enter` it is a door to a page instead — a chevron, and `enter` runs.
 */
export function row(r, close, wire = true, enter) {
    const b = mk("button", "acct-row" + (r.tone ? " " + r.tone : ""));
    b.type = "button";
    const ic = mk("span", "acct-ic", r.icon);
    if (r.live)
        ic.classList.add("live");
    const text = mk("span", "acct-tx");
    text.append(mk("span", "acct-l", r.label));
    if (r.sub)
        text.append(mk("span", "acct-s", r.sub));
    b.append(ic, text);
    if (enter) {
        b.append(mk("span", "acct-chev", "›"));
        b.addEventListener("click", enter);
    }
    else if (wire)
        b.addEventListener("click", () => { close(); r.go(); });
    return b;
}
/** Rows in one rounded card. */
export function group(...rows) {
    const g = mk("div", "acct-group");
    g.append(...rows);
    return g;
}
/** The ← that steps back out of a page. */
export function backButton(onBack) {
    const back = mk("button", "acct-back", "←");
    back.type = "button";
    back.title = "back";
    back.setAttribute("aria-label", "back");
    back.addEventListener("click", onBack);
    return back;
}
/** The ✕ that puts the sheet away. */
export function closeButton(onClose, label = "close") {
    const x = mk("button", "acct-x", "✕");
    x.type = "button";
    x.title = label;
    x.setAttribute("aria-label", label);
    x.addEventListener("click", onClose);
    return x;
}
