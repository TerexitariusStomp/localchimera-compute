// tests/browser/inline-text-test.mjs — inlineText (app/slots/editors.ts): a
// blur commits a CHANGE, measured against what was LAST committed — so an edit
// back to the original value is a change too, and a blur with nothing new is
// not. Pure node: the element is a minimal stub carrying value + listeners.
//
// Run: node tests/browser/inline-text-test.mjs
class Stub {
  constructor() { this.h = {}; this.value = ""; this.className = ""; this.style = {}; }
  addEventListener(t, f) { (this.h[t] = this.h[t] || []).push(f); }
  fire(t) { for (const f of this.h[t] || []) f({ key: "" }); }
  append() {} appendChild() {} replaceChildren() {} querySelector() { return null; } querySelectorAll() { return []; }
  setAttribute() {} get classList() { return { add() {}, remove() {}, toggle() {}, contains: () => false }; }
}
globalThis.document = { createElement: () => new Stub(), createTextNode: () => new Stub(), activeElement: null };
globalThis.window = globalThis;
const { inlineText } = await import("../../browser/app/slots/editors.js");

import { harness } from './assert.mjs';
const { check, done } = harness();

const got = [];
const i = inlineText("a", { onCommit: v => got.push(v) });
i.fire("blur");
check("a blur with nothing changed commits nothing", got.length === 0);
i.value = "b"; i.fire("blur");
check("a change commits", got.join() === "b");
i.fire("blur");
check("…and blurring again without a change commits nothing more", got.join() === "b");
i.value = "a"; i.fire("blur");
check("an edit BACK to the original value is a change too", got.join() === "b,a", got.join());

done();
