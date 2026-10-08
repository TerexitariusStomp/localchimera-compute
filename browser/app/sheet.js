// app/sheet.ts — the capture sheet's state: a short stack of screens.
//
// Every screen of the sheet (the figure, a container, the camera, the scenes
// waiting, a product's barcode, the counts of a stock) is one member of `Screen`;
// the sheet is the stack of them with the line under the screen and whether a
// door is being waited on; the helpers here are how a screen moves it. The
// screens are drawn by their own modules (capture-stock.ts, capture-look.ts,
// capture-contest.ts) and capture.ts draws whichever is on top.
import { signal } from "./reactive.js";
import { html } from "./template.js";
export const sheet = signal(null);
/** The element the sheet is drawn in; set once it exists. */
export const host = { el: null };
export const q = (sel) => host.el?.querySelector(sel) ?? null;
export const qa = (sel) => [...(host.el?.querySelectorAll(sel) ?? [])];
export const top = (s) => (s && s.stack.length ? s.stack[s.stack.length - 1] : null);
export const say = (says) => { const s = sheet.peek(); if (s)
    sheet.set({ ...s, says }); };
// a step ends: the line says what happened and the buttons are free again
export const settle = (says) => { const s = sheet.peek(); if (s)
    sheet.set({ ...s, busy: false, says }); };
// a door that never answers leaves the sheet where it stands, ready to ask again
export const unanswered = () => settle("the gateway did not answer");
// the screen on top, when it is of KIND
export const topOf = (kind) => {
    const t = top(sheet.peek());
    return t && t.kind === kind ? t : null;
};
export function push(screen) {
    const s = sheet.peek();
    sheet.set({ stack: [...(s?.stack ?? []), screen], says: "", busy: false });
}
export function replaceTop(screen, says = "") {
    const s = sheet.peek();
    if (!s)
        return;
    sheet.set({ stack: [...s.stack.slice(0, -1), screen], says, busy: false });
}
// what must let go when the sheet closes (the camera, the mic)
const closers = [];
export const onClose = (f) => { closers.push(f); };
export function close() {
    for (const f of closers)
        f();
    sheet.set(null);
}
export function back() {
    const s = sheet.peek();
    if (!s || s.stack.length <= 1) {
        close();
        return;
    }
    sheet.set({ stack: s.stack.slice(0, -1), says: "", busy: false });
}
// the inline children of a row carry no whitespace between them: a template's
// indentation between inline nodes renders as a gap
export const head = (emoji, name, deep) => html `
  <div class="cap-head">${deep ? html `<button class="cap-back" title="back" onclick=${back}>‹</button>` : ""}<span class="cap-emoji">${emoji}</span><span class="cap-name">${name}</span><button class="cap-x" title="close" onclick=${close}>✕</button></div>`;
