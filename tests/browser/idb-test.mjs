// tests/browser/idb-test.mjs — app/idb.ts: the IndexedDB door.
//
// Three claims, each the reason the door exists:
//   • an operation resolves when its TRANSACTION completes, never before — a
//     write that resolved on the request and then aborted would report a key
//     as kept that the device dropped;
//   • an abort (how a quota refusal arrives) and an error both REJECT;
//   • `upgrade` hears the version the device holds, so a schema can migrate.
//
// node has no IndexedDB; tests/browser/fakes.mjs stands in, and lets a test
// hold a transaction open, abort it, and reopen at a higher version.
//
// Run: node tests/browser/idb-test.mjs

import { table } from '../../browser/app/idb.js';
import { fakeIndexedDB } from './fakes.mjs';

import { harness } from './assert.mjs';
const { ok, done } = harness();

const idb = globalThis.indexedDB = fakeIndexedDB();

const seen = [];
const v1 = { name: 'db', version: 1, upgrade(db, from) { seen.push(from); if (from < 1) db.createObjectStore('rows', { keyPath: 'id' }); } };
const rows = table(v1, 'rows');

console.log('\n── a round trip ──');
await rows.put({ id: 'a', n: 1 });
await rows.put({ id: 'b', n: 2 });
ok('a first open upgrades from 0', seen.join() === '0');
ok('get reads a row back', (await rows.get('a'))?.n === 1);
ok('a missing key is undefined', (await rows.get('zz')) === undefined);
ok('all reads every row', (await rows.all()).length === 2);
ok('entries pairs each key with its row', (await rows.entries()).map(([k, v]) => k + v.n).join() === 'a1,b2');
await rows.del('a');
ok('del removes one', (await rows.all()).map(r => r.id).join() === 'b');
ok('every call closed its database', idb.closed === 8, `closed ${idb.closed}`);

console.log('\n── out-of-line keys ──');
const kv = table({ name: 'kv', version: 1, upgrade(db) { if (!db.objectStoreNames.contains('s')) db.createObjectStore('s'); } }, 's');
await kv.put({ x: 1 }, 'name');
ok('a row is kept under the key it was given', (await kv.entries())[0][0] === 'name');

console.log('\n── durability ──');
idb.fate = 'hold';
let landed = false;
const p = rows.put({ id: 'c', n: 3 }).then(() => { landed = true; });
await new Promise(r => setTimeout(r, 20));
ok('a put is pending while its transaction is open', landed === false);
idb.settle('complete'); await p;
ok('and resolves when the transaction completes', landed === true);
idb.fate = 'complete';
ok('the row is there afterwards', (await rows.get('c'))?.n === 3);

console.log('\n── refusals ──');
idb.fate = 'abort';
const aborted = await rows.put({ id: 'd', n: 4 }).then(() => null, e => e);
ok('an aborted write rejects', aborted != null, aborted?.name);
idb.fate = 'error';
ok('an errored write rejects', (await rows.put({ id: 'e', n: 5 }).then(() => null, e => e)) != null);
idb.fate = 'complete';
ok('neither left a row behind', (await rows.all()).every(r => r.id !== 'd' && r.id !== 'e'));
idb.blocked = true;
ok('an open blocked by another tab rejects', (await rows.all().then(() => null, e => e)) != null);
idb.blocked = false;

console.log('\n── a schema change ──');
seen.length = 0;
const v2 = { name: 'db', version: 2, upgrade(db, from) { seen.push(from); if (from < 2) db.createObjectStore('extra'); } };
await table(v2, 'extra').put({ y: 1 }, 'k');
ok('upgrade hears the version the device held', seen.join() === '1');
ok('the old store kept its rows', (await table(v2, 'rows').all()).length === 2);

done();
