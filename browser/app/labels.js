// app/labels.ts — a label, and the three prints a store lives by.
//
// A label is the code a thing is known by, printed (docs/observation/
// capture.md §6). The code is six characters, unique in its scope, silent about
// owner and contents; the QR symbol on the label carries that code and nothing
// more, so a label read by a stranger yields a code.
//
// Three prints, each a page a browser prints as it stands:
//
//   label sheet      the symbol and the code, one per thing: finding, scanning
//   name cards       the thing's name, large: a shelf read from across a room
//   count checklist  a container's lines with blanks: the paper form of a count
//
// The builders are pure, text in and a page out, so a unit test reads what a
// printer would. `print` is the one function that touches a window.
import { encode, svg } from "./qr.js";
import { LABEL_ALPHABET, LABEL_LENGTH, LABEL_SCHEME } from "./count-catalogue.js";
import { esc } from "./esc.js";
import { figure } from "./count.js";
/**
 * A code as the books hold it: upper case, a typed I or L read as 1 and an O
 * as 0, everything outside the alphabet dropped. The gateway reads a code the
 * same way (service.scm label-normal), so what is typed here is what is found
 * there.
 */
export function normalCode(text) {
    let out = "";
    for (const ch of String(text ?? "").toUpperCase()) {
        const c = ch === "I" || ch === "L" ? "1" : ch === "O" ? "0" : ch;
        if (LABEL_ALPHABET.includes(c))
            out += c;
    }
    return out;
}
/** What a label's symbol carries. */
export const labelText = (code) => LABEL_SCHEME + normalCode(code);
/**
 * The code in what a camera read or a person typed: a label's own text, a link
 * carrying `label=`, or the bare code. Null when what was read is no label of
 * this kind, so a scanned shop barcode or a web address reads as nothing.
 */
export function codeIn(read) {
    const s = String(read ?? "").trim();
    const whole = (c) => {
        const n = normalCode(c);
        return n.length === LABEL_LENGTH ? n : null;
    };
    if (s.toLowerCase().startsWith(LABEL_SCHEME))
        return whole(s.slice(LABEL_SCHEME.length));
    const link = /[?&]label=([^&#\s]+)/i.exec(s);
    if (link)
        return whole(decodeURIComponent(link[1]));
    // a bare code: what was typed is the code, with the spaces and dashes a
    // person puts in to read it aloud
    if (/^[\sA-Za-z0-9-]+$/.test(s) && s.replace(/[\s-]/g, "").length === LABEL_LENGTH)
        return whole(s);
    return null;
}
/** A code as it is printed and read aloud: two groups of three. */
export const spoken = (code) => {
    const c = normalCode(code);
    return c.length === LABEL_LENGTH ? `${c.slice(0, 3)} ${c.slice(3)}` : c;
};
const symbolOf = (code, px) => {
    const s = encode(labelText(code));
    return s ? svg(s, px) : "";
};
const PAGE = (title, style, body) => `<!doctype html><html><head><meta charset="utf-8"><title>${esc(title)}</title><style>`
    + `@page{margin:10mm}*{box-sizing:border-box}`
    + `body{margin:0;font-family:system-ui,-apple-system,"Segoe UI",sans-serif;color:#000;background:#fff}`
    + style + `</style></head><body>${body}</body></html>`;
/** The label sheet: the symbol and the code, one per thing, cut along the rules. */
export function labelSheet(things) {
    const cells = things.map(t => `<div class="l">${symbolOf(t.code, 132)}<div class="c">${esc(spoken(t.code))}</div></div>`).join("");
    return PAGE("labels", `.s{display:grid;grid-template-columns:repeat(4,1fr);gap:0}`
        + `.l{border:.3mm dashed #999;padding:3mm;text-align:center;break-inside:avoid}`
        + `.l svg{width:34mm;height:34mm}`
        + `.c{font:600 13pt ui-monospace,Menlo,Consolas,monospace;letter-spacing:.12em;margin-top:1mm}`, `<div class="s">${cells}</div>`);
}
/** The name cards: the thing's name, large, with its symbol small beside it. */
export function nameCards(things) {
    const cells = things.map(t => `<div class="n"><div class="t"><div class="e">${esc(t.emoji ?? "")}</div>`
        + `<div class="m">${esc(t.name)}</div>${t.where ? `<div class="w">${esc(t.where)}</div>` : ""}</div>`
        + `<div class="q">${symbolOf(t.code, 96)}<div class="c">${esc(spoken(t.code))}</div></div></div>`).join("");
    return PAGE("name cards", `.s{display:grid;grid-template-columns:repeat(2,1fr);gap:0}`
        + `.n{border:.3mm dashed #999;padding:5mm;display:flex;align-items:center;gap:4mm;break-inside:avoid;min-height:42mm}`
        + `.t{flex:1 1 auto;min-width:0}.e{font-size:20pt}`
        + `.m{font:700 24pt/1.1 system-ui,sans-serif;overflow-wrap:anywhere}`
        + `.w{font-size:10pt;color:#444;margin-top:1mm}`
        + `.q{flex:0 0 auto;text-align:center}.q svg{width:24mm;height:24mm}`
        + `.c{font:600 9pt ui-monospace,Menlo,Consolas,monospace;letter-spacing:.1em}`, `<div class="s">${cells}</div>`);
}
/**
 * The count checklist: the container at the head, a line for each thing in it
 * with a blank for the figure found, and a line for whoever counted to sign.
 */
export function checklist(container, lines, opts = {}) {
    const head = `<div class="h"><div class="q">${symbolOf(container.code, 96)}<div class="c">${esc(spoken(container.code))}</div></div>`
        + `<div class="t"><div class="m">${esc(container.emoji ?? "")} ${esc(container.name)}</div>`
        + `<div class="w">${[container.where, opts.day, opts.commitment ? `count ${opts.commitment}` : "",
            opts.blind ? "blind count" : ""].filter(Boolean).map(x => esc(x)).join(" · ")}</div></div></div>`;
    const rows = lines.map(l => {
        const date = l.expires ? `${l.expiresKind === "use-by" ? "use by" : l.expiresKind === "best-before" ? "best before" : "date"} ${l.expires.slice(0, 10)}` : "";
        return `<tr><td class="k">${esc(spoken(l.code))}</td><td>${esc(l.emoji ?? "")} ${esc(l.name)}`
            + `${date ? `<div class="d">${esc(date)}</div>` : ""}</td>`
            + (opts.blind ? "" : `<td class="r">${esc(figure(l.onhand))}</td>`)
            + `<td class="b"></td><td class="u">${esc(l.unit)}</td></tr>`;
    }).join("");
    const none = lines.length ? "" : `<tr><td colspan="${opts.blind ? 4 : 5}" class="d">the ledger holds nothing in this container; write in what is found</td></tr>`;
    const spare = Array.from({ length: 3 }, () => `<tr><td class="k"></td><td></td>${opts.blind ? "" : `<td class="r"></td>`}<td class="b"></td><td class="u"></td></tr>`).join("");
    return PAGE(`count · ${container.name}`, `.h{display:flex;align-items:center;gap:5mm;margin-bottom:5mm}`
        + `.q{text-align:center}.q svg{width:24mm;height:24mm}`
        + `.c,.k{font:600 9pt ui-monospace,Menlo,Consolas,monospace;letter-spacing:.1em}`
        + `.m{font:700 18pt system-ui,sans-serif}.w,.d{font-size:9pt;color:#444}`
        + `table{width:100%;border-collapse:collapse}th,td{border-bottom:.3mm solid #999;padding:2.5mm 2mm;text-align:left;vertical-align:top}`
        + `th{font-size:9pt;color:#444;font-weight:600}.r{text-align:right;white-space:nowrap}`
        + `.b{width:32mm;border-left:.3mm solid #999;border-right:.3mm solid #999}.u{white-space:nowrap}`
        + `.f{margin-top:9mm;display:flex;gap:8mm;font-size:10pt}.f div{flex:1;border-top:.3mm solid #000;padding-top:1mm}`, head
        + `<table><tr><th>code</th><th>what</th>${opts.blind ? "" : `<th class="r">ledger</th>`}<th>found</th><th>unit</th></tr>`
        + rows + none + spare + `</table>`
        + `<div class="f"><div>counted by</div><div>on</div><div>at</div></div>`);
}
/**
 * Hand a page to the printer: a frame out of sight holds it, and the browser's
 * own print sheet opens over the app. The frame leaves once the sheet closes.
 */
export function print(page) {
    const frame = document.createElement("iframe");
    frame.setAttribute("aria-hidden", "true");
    frame.style.cssText = "position:fixed;right:0;bottom:0;width:0;height:0;border:0";
    frame.srcdoc = page;
    frame.addEventListener("load", () => {
        const w = frame.contentWindow;
        if (!w) {
            frame.remove();
            return;
        }
        w.addEventListener("afterprint", () => frame.remove());
        w.focus();
        w.print();
    });
    document.body.append(frame);
}
