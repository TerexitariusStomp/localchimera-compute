// tests/browser/attention-test.mjs — app/attention.ts: what is waiting on this device.
//
// The list is read off two signals, so it holds exactly what is true now: a
// waiting build (with its remedy), a refused write (said with its time and
// key), both, or nothing.
//
// Run: node tests/browser/attention-test.mjs

import { harness } from './assert.mjs';
import { memStorage } from './fakes.mjs';
const { check, section, done } = harness();

globalThis.localStorage = memStorage();
const { matters, updateReady } = await import('../../browser/app/attention.js');
const { writeStr } = await import('../../browser/app/store.js');

section('nothing waiting');
check('the list is empty', matters().length === 0);

section('a build waiting');
updateReady.set(true);
check('it is listed', matters().length === 1 && matters()[0].id === 'update');
check('with its remedy', typeof matters()[0].act?.run === 'function' && /reload/.test(matters()[0].act.label));

section('a refused write');
globalThis.localStorage = memStorage({ full: true });
writeStr('some-key', 'v');
const both = matters();
check('it is listed after the build', both.length === 2 && both[1].id === 'storage');
check('it names the key the device refused', both[1].says.includes('some-key'));
check('the page has no remedy to offer for it', both[1].act === undefined);

section('the build applied');
updateReady.set(false);
check('only the refusal stands', matters().length === 1 && matters()[0].id === 'storage');

done();
