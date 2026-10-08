// tests/browser/dom-stub.mjs — enough browser for a dial module to LOAD.
//
// The dial's modules are written for a browser and node has none. Four unit
// suites needed the same handful of globals, and were carrying four copies that
// had already begun to differ — so it lives here, and a fifth suite gets it
// right by importing rather than by remembering.
//
// WHAT THIS IS NOT: a DOM. Nothing here renders, measures or lays anything out,
// and no test should assert against it. Its entire job is to let an import
// SUCCEED, because the modules under test reach the browser at module scope —
// theme.js mounts a <style> and reads the page's CSS tokens the moment it loads,
// toast.js mounts its container, core.js pulls in both. The logic being tested
// is pure; this is the cost of that logic living in a file a browser also runs.
//
// If a test starts wanting more from this than "the import worked", the thing to
// do is move the logic out of the module that needs a DOM, not to grow a
// half-DOM here until it can be believed.

/** An element only as far as import-time code reaches. */
const el = () => ({
  style: { setProperty() {}, getPropertyValue: () => "", removeProperty() {} },
  dataset: {}, children: [], className: "", innerHTML: "", textContent: "", title: "",
  classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
  setAttribute() {}, removeAttribute() {}, getAttribute: () => null,
  appendChild(c) { this.children.push(c); return c; },
  append() {}, remove() {}, replaceChildren() {},
  addEventListener() {}, removeEventListener() {},
  querySelector: () => null, querySelectorAll: () => [],
  getBoundingClientRect: () => ({ x: 0, y: 0, width: 0, height: 0, top: 0, left: 0 }),
});

/** A d3 that answers every chained call with itself, and never draws. */
const d3Stub = () => {
  const sel = () => new Proxy(() => {}, { get: () => () => sel() });
  const scale = () => { const s = () => "#000";
                        s.domain = () => s; s.range = () => s;
                        s.interpolate = () => s; s.clamp = () => s; return s; };
  return {
    select: sel, selectAll: sel,
    scaleLinear: scale,
    interpolateLab: () => () => "#000",
    interpolateRgb: () => () => "#000",
    rgb: () => ({ r: 0, g: 0, b: 0 }),
    color: () => ({ rgb: () => ({ r: 0, g: 0, b: 0 }), darker: () => ({}), brighter: () => ({}),
                    formatHex: () => "#000", toString: () => "#000" }),
    // theme.js patches these two prototypes on import; they must exist.
    selection: { prototype: {} },
    transition: { prototype: {} },
  };
};

/**
 * Install the globals. Call before importing anything under `browser/app/`.
 * `fetch` rejects by default: a unit test that reaches the network is a unit
 * test that has stopped being one, and the modules all have an offline path.
 */
export function installDomStub() {
  const head = el(), body = el();
  globalThis.window = {
    d3: {}, addEventListener() {}, removeEventListener() {},
    matchMedia: () => ({ matches: false, addEventListener() {}, addListener() {} }),
  };
  globalThis.location = { search: "", hash: "", href: "http://localhost/" };
  globalThis.localStorage = {
    _m: new Map(),
    getItem(k) { return this._m.has(k) ? this._m.get(k) : null; },
    setItem(k, v) { this._m.set(k, String(v)); },
    removeItem(k) { this._m.delete(k); },
  };
  globalThis.CustomEvent = class { constructor(type, init) { this.type = type;
                                    this.detail = init && init.detail; } };
  globalThis.document = {
    addEventListener() {}, removeEventListener() {}, dispatchEvent() { return true; },
    getElementById: () => null, querySelector: () => null, querySelectorAll: () => [],
    createElement: el, createElementNS: el,
    head, body, documentElement: el(),
    // theme.js walks these for the page's own tokens; there are none here.
    styleSheets: [],
  };
  globalThis.matchMedia = globalThis.window.matchMedia;
  globalThis.requestAnimationFrame = fn => setTimeout(fn, 0);
  globalThis.cancelAnimationFrame = id => clearTimeout(id);
  globalThis.d3 = d3Stub();
  globalThis.window.d3 = globalThis.d3;
  globalThis.fetch = () => Promise.reject(new Error("no network in a unit test"));
}

// the pass/fail harness is tests/browser/assert.mjs's; it is handed on from
// here for the suites that install the stub and assert in one import
export { harness } from "./assert.mjs";
