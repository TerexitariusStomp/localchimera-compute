// tests/browser/rns-identity-test.mjs — lib/rns-identity.js: the mesh key at rest.
//
// The claim: localStorage never holds the key's bytes. What it holds opens
// only with the origin's non-extractable seal key beside it, a key stored
// before sealing is sealed on first read, and a device that has lost its seal
// key mints a fresh identity (the anonymous one is replaceable; a crash here
// would cost the page its mesh).
//
// Real WebCrypto; tests/browser/fakes.mjs stands in for localStorage and IndexedDB.
//
// Run: node tests/browser/rns-identity-test.mjs

import { memStorage, fakeIndexedDB } from './fakes.mjs';

import { harness } from './assert.mjs';
const { ok, done } = harness();

const freshLs = () => memStorage();
const idb = globalThis.indexedDB = fakeIndexedDB();
globalThis.localStorage = freshLs();          // keystore.js's own door reads the global

const { keepMeshKey, loadMeshKey, meshIdentity } = await import('../../browser/lib/rns-identity.js');

// a stand-in for rns-wasm's Identity: 64 key bytes, minted or restored
let minted = 0;
const rns = { Identity: class {
  constructor(bytes) { this.k = bytes || (minted++, crypto.getRandomValues(new Uint8Array(64))); }
  static fromPrivateKey(b) { if (b.length !== 64) throw new Error('bad key'); return new rns.Identity(b); }
  privateKey() { return this.k; }
} };
const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
const KEY = 'pn.mesh.identity';

console.log('\n── a first visit ──');
let ls = freshLs();
const first = await meshIdentity(rns, ls);
const stored = ls.getItem(KEY);
ok('an identity is minted', minted === 1 && first.privateKey().length === 64);
ok('what is stored is marked sealed', stored.startsWith('sealed:v1:'));
ok('and carries none of the key’s bytes in the clear',
   !stored.includes(JSON.stringify(Array.from(first.privateKey())).slice(1, 40)));
ok('the seal key is in the keystore, non-extractable',
   idb.rows('playnet-keys', 'keypairs').get('local-seal').privateKey.extractable === false);

console.log('\n── a return visit ──');
const again = await meshIdentity(rns, ls);
ok('the same identity comes back', same(again.privateKey(), first.privateKey()) && minted === 1);

console.log('\n── a key stored before sealing ──');
ls = freshLs();
const legacy = crypto.getRandomValues(new Uint8Array(64));
ls.setItem(KEY, JSON.stringify(Array.from(legacy)));
const moved = await meshIdentity(rns, ls);
ok('it is read as it was', same(moved.privateKey(), legacy) && minted === 1);
ok('and is sealed in place', ls.getItem(KEY).startsWith('sealed:v1:'));
ok('the sealed form opens to the same key', same(await loadMeshKey(ls), legacy));

console.log('\n── the seal key is gone ──');
idb.wipe();                                      // IndexedDB cleared; localStorage kept
ok('the sealed value no longer opens', (await loadMeshKey(ls)) === null);
const fresh = await meshIdentity(rns, ls);
ok('a fresh identity is minted and kept', minted === 2 && same(await loadMeshKey(ls), fresh.privateKey()));

console.log('\n── a device that cannot seal ──');
idb.down = true;
ls = freshLs();
ok('keeping answers false', (await keepMeshKey(ls, legacy)) === false);
ok('and stores nothing', ls.getItem(KEY) === null);
const session = await meshIdentity(rns, ls);
ok('the page still gets an identity, for the session', session.privateKey().length === 64 && ls.getItem(KEY) === null);
ls.setItem(KEY, JSON.stringify(Array.from(legacy)));
ok('a pre-sealing key is still read', same((await meshIdentity(rns, ls)).privateKey(), legacy));
ok('and left as it was for the next visit', ls.getItem(KEY).startsWith('['));
idb.down = false;

console.log('\n── a store that throws ──');
const blocked = memStorage({ blocked: true });
ok('reads as no key', (await loadMeshKey(blocked)) === null);
ok('the page still gets an identity', (await meshIdentity(rns, blocked)).privateKey().length === 64);

done();
