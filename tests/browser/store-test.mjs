// SPDX-License-Identifier: AGPL-3.0-or-later
// tests/browser/store-test.mjs — app/store.ts: the localStorage door, and what
// it says when the device refuses.
//
// A read that cannot land is the default. A write that cannot land answers
// false AND raises a fault — the one signal the person-facing notice and the
// settings readout hang off. Run against a store that works, one that is full,
// and one whose every access throws (private mode, storage blocked).
//
// Run: node tests/browser/store-test.mjs

import { memStorage } from './fakes.mjs';

import { harness } from './assert.mjs';
const { ok, done } = harness();

const working = () => memStorage(), full = () => memStorage({ full: true }), blocked = () => memStorage({ blocked: true });

globalThis.localStorage = working();
const { readStr, writeStr, readJSON, writeJSON, forget, onFault } = await import('../../browser/app/store.js');
const faults = [];
const stop = onFault((f) => faults.push(f));

console.log('\n── a store that works ──');
ok('a write answers true', writeStr('k', 'v') === true);
ok('and reads back', readStr('k') === 'v');
ok('JSON round-trips', writeJSON('j', { a: [1, 2] }) === true && readJSON('j', null).a[1] === 2);
ok('forget removes', (forget('k'), readStr('k') === null));
ok('an unparseable value reads as the fallback', (writeStr('bad', '{'), readJSON('bad', 7) === 7));
ok('no fault was raised', faults.length === 0);

console.log('\n── a store that is full ──');
globalThis.localStorage = full();
ok('a write answers false', writeStr('k', 'v') === false);
ok('and raises one fault naming the door and the key',
   faults.length === 1 && faults[0].door === 'local' && faults[0].what === 'k' && typeof faults[0].at === 'number');
ok('writeJSON answers and faults the same way', writeJSON('j', {}) === false && faults.length === 2);

console.log('\n── a store that is blocked ──');
globalThis.localStorage = blocked();
ok('a read is null', readStr('k') === null);
ok('a JSON read is the fallback', readJSON('k', 'dflt') === 'dflt');
ok('forget does not throw', (forget('k'), true));
ok('a write answers false and faults', writeStr('k', 'v') === false && faults.length === 3);

console.log('\n── listeners ──');
onFault(() => { throw new Error('a listener that fails'); });
ok('a failing listener leaves the write answering', writeStr('k', 'v') === false && faults.length === 4);
stop();
ok('a listener that stopped hears nothing more', (writeStr('k', 'v'), faults.length === 4));

done();
