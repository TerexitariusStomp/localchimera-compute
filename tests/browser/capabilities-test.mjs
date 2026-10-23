// SPDX-License-Identifier: AGPL-3.0-or-later
// tests/browser/capabilities-test.mjs — lib/capabilities.js: does this engine run the wasm?
//
// The probes are bytes of wasm that use one engine feature each. Two things have to
// hold for the check to mean anything: the answer follows the ENGINE (here a real
// one — Node's V8 — with a feature switched on and off), and the words stay
// generic, so a browser that gains support passes with nothing to edit.
//
// Run: node tests/browser/capabilities-test.mjs

import v8 from 'node:v8';
import { check, describe, showNotice, PROBES } from '../../browser/lib/capabilities.js';

import { harness } from './assert.mjs';
const { ok, done } = harness();

console.log('\n── the probes against a real engine ──');
// A module of garbage is refused, so a probe that validates is the engine's own yes.
ok('a malformed module is rejected', WebAssembly.validate(new Uint8Array([1, 2, 3])) === false);
const byId = Object.fromEntries(PROBES.map((p) => [p.id, p]));
ok('the garbage-collected-data probe validates here', WebAssembly.validate(byId.gc.bytes));
ok('the tail-call probe validates here', WebAssembly.validate(byId['tail-calls'].bytes));

// V8 gates the standard exception encoding behind a flag (off by default in Node 22,
// on by default in Node 25): forcing it off and then on, the same engine answering
// both ways shows the probe reads the feature and nothing else.
v8.setFlagsFromString('--no-experimental-wasm-exnref');
const off = WebAssembly.validate(byId.exceptions.bytes);
v8.setFlagsFromString('--experimental-wasm-exnref');
const on = WebAssembly.validate(byId.exceptions.bytes);
ok('the exception probe follows the engine flag', off === false && on === true, `off=${off} on=${on}`);

console.log('\n── the report ──');
const yes = () => true;
ok('every probe accepted: ok, nothing missing', (() => { const r = check({ validate: yes }); return r.ok && r.missing.length === 0; })());
const onlyNo = (id) => (bytes) => bytes !== byId[id].bytes;
const r1 = check({ validate: onlyNo('exceptions') });
ok('one probe refused: not ok, and it is the one named', !r1.ok && r1.missing.length === 1 && r1.missing[0].id === 'exceptions');
const r2 = check({ validate: () => false });
ok('every probe refused: all listed, in table order', r2.missing.map((m) => m.id).join() === PROBES.map((p) => p.id).join());
const r3 = check({ validate: () => { throw new Error('boom'); } });
ok('an engine that throws counts as lacking the feature', !r3.ok && r3.missing.length === PROBES.length);
const r4 = check({ validate: yes, probes: [] });
ok('a table with no probes asks for nothing', r4.ok);

console.log('\n── the words ──');
const missingWords = describe(r1);
ok('names what is missing', missingWords.detail.includes(byId.exceptions.label), missingWords.detail);
ok('says the demo day is what shows', /demo day/.test(missingWords.detail));
ok('names no browser version, so it stays true as support grows',
   !/\b\d{2,}\b/.test(missingWords.title + ' ' + missingWords.detail));
const failedWords = describe({ failed: 'WebAssembly.instantiate(): Import #3 "x" "y": function import requires a callable' });
ok('a failure the probes did not foresee is shown, trimmed', failedWords.detail.includes('requires a callable'));
ok('...and still says the demo day shows', /demo day/.test(failedWords.detail));
ok('a failure with no message still reads whole', describe({ failed: '' }).detail.endsWith('may help.'));

console.log('\n── the banner, on a stand-in page ──');
// just enough of a DOM for showNotice: it builds, appends and removes elements
function fakeDoc() {
  const mk = (tag) => {
    const el = {
      tag, children: [], style: {}, dataset: {}, attrs: {}, listeners: {}, textContent: '',
      setAttribute(k, v) { this.attrs[k] = v; },
      append(...c) { this.children.push(...c); },
      appendChild(c) { this.children.push(c); return c; },
      addEventListener(t, f) { this.listeners[t] = f; },
      remove() { doc.removed.push(this.id || tag); if (doc.bar === this) doc.bar = null; },
    };
    return el;
  };
  const doc = { removed: [], bar: null, body: null,
    createElement: mk,
    getElementById: (id) => (doc.bar && doc.bar.id === id ? doc.bar : null) };
  doc.body = { appendChild(el) { if (el.id === 'capNotice') doc.bar = el; return el; } };
  return doc;
}
const store = () => { const m = new Map(); return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, v), m }; };
{
  const doc = fakeDoc(), storage = store();
  const bar = showNotice(r1, { document: doc, storage });
  ok('a missing feature puts a status banner on the page', bar && doc.bar === bar && bar.attrs.role === 'status');
  ok('the banner names its reason', bar.dataset.reason === 'missing:exceptions');
  bar.children[1].listeners.click();
  ok('dismissing removes it and remembers the reason', doc.bar === null && storage.m.get('pn.capNotice.dismissed') === 'missing:exceptions');
  ok('a dismissed reason does not come back', showNotice(r1, { document: doc, storage }) === null);
  ok('a different reason is not suppressed by it', showNotice(check({ validate: () => false }), { document: doc, storage }) !== null);
}
ok('nothing missing and nothing failed: no banner', showNotice({ missing: [] }, { document: fakeDoc(), storage: store() }) === null);
ok('a page without a body: no banner, no throw', showNotice(r1, { document: { body: null }, storage: store() }) === null);
{
  const hostile = { getItem() { throw new Error('storage blocked'); }, setItem() { throw new Error('storage blocked'); } };
  const doc = fakeDoc();
  const bar = showNotice(r1, { document: doc, storage: hostile });
  ok('blocked storage still shows the banner', !!bar);
  let threw = false; try { bar.children[1].listeners.click(); } catch (_) { threw = true; }
  ok('...and dismissing it does not throw', !threw && doc.bar === null);
}

done();
