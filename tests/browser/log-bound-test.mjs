// tests/browser/log-bound-test.mjs — app/tabs/social/log-bound.ts: the newest
// entries that fit a store's budget.
//
// The gateway rejects a synced document over its cap WHOLE, so a log one entry
// too long backs up nothing. The claim under test is the one that prevents
// that: whatever fitNewest returns measures within the budget, by the
// gateway's own measure, and it is the longest newest-first prefix that does.
//
// Run: node tests/browser/log-bound-test.mjs

import { fitNewest, wireBytes, SYNC_MAX_BYTES, SYNC_MAX_ENTRIES, LOCAL_MAX_BYTES }
  from '../../browser/app/tabs/social/log-bound.js';

import { harness } from './assert.mjs';
const { ok, done } = harness();

console.log('\n── the gateway’s measure ──');
ok('plain text: its bytes and the two quotes', wireBytes('abc') === 5);
ok('a quote and a backslash each cost one more', wireBytes('a"b\\c') === 5 + 2 + 2);
ok('a non-ASCII character counts its UTF-8 bytes', wireBytes('é') === 2 + 2);
ok('the sync cap is the gateway’s own figure', SYNC_MAX_BYTES === (await import('../../browser/app/limits-catalogue.js')).USER_DATA_MAX_BYTES);
ok('the device budget sits inside localStorage’s 5 MB', LOCAL_MAX_BYTES < 5 * 1024 * 1024 / 2 + 1);

console.log('\n── the prefix that fits ──');
const entry = (i, n) => ({ id: 'e' + i, t: 1e6 - i, text: 'x'.repeat(n) });
const small = Array.from({ length: 10 }, (_, i) => entry(i, 20));
ok('everything, when it fits', fitNewest(small, 400, 1e6).length === 10);
ok('the row cap holds', fitNewest(small, 3, 1e6).map(e => e.id).join() === 'e0,e1,e2');
ok('an empty log is an empty document', fitNewest([], 400, 10).length === 0);

const big = Array.from({ length: 600 }, (_, i) => entry(i, 2000));     // ~1.2 MB of log
const kept = fitNewest(big, SYNC_MAX_ENTRIES, SYNC_MAX_BYTES);
const doc = JSON.stringify(kept);
ok('a log past the cap is cut', kept.length > 0 && kept.length < SYNC_MAX_ENTRIES, `${kept.length} of ${big.length}`);
ok('what is kept measures within the cap', wireBytes(doc) <= SYNC_MAX_BYTES, `${wireBytes(doc)} ≤ ${SYNC_MAX_BYTES}`);
ok('and it is the newest, in order', kept.every((e, i) => e === big[i]));
ok('one more entry would not fit', wireBytes(JSON.stringify(big.slice(0, kept.length + 1))) > SYNC_MAX_BYTES);

const quoted = Array.from({ length: 400 }, (_, i) => ({ id: 'q' + i, text: '"'.repeat(1500) }));
const qk = fitNewest(quoted, SYNC_MAX_ENTRIES, SYNC_MAX_BYTES);
ok('text full of quotes is measured as the gateway writes it',
   wireBytes(JSON.stringify(qk)) <= SYNC_MAX_BYTES && qk.length < quoted.length, `${qk.length} kept`);
ok('an entry larger than the budget leaves an empty document', fitNewest([entry(0, 5000)], 400, 1000).length === 0);

done();
