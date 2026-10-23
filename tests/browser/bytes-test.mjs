// SPDX-License-Identifier: AGPL-3.0-or-later
// tests/browser/bytes-test.mjs — app/bytes.ts: bytes as text and back.
//
// Every form round-trips every byte value, base64url uses the URL alphabet
// with no padding, and hex refuses what is not hex (a malformed legacy key
// must fail its import, never become a shorter key).
//
// Run: node tests/browser/bytes-test.mjs

import { toBase64, fromBase64, toBase64Url, fromBase64Url, toHex, fromHex, base64Length } from '../../browser/app/bytes.js';

import { harness } from './assert.mjs';
const { ok, done } = harness();
const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
const throws = (f) => { try { f(); return false; } catch { return true; } };

const all = Uint8Array.from({ length: 256 }, (_, i) => i);
const big = Uint8Array.from({ length: 200_000 }, (_, i) => (i * 7) & 255);   // past the chunk size

ok('base64 round-trips every byte', same(fromBase64(toBase64(all)), all));
ok('base64 agrees with the platform', toBase64(all) === Buffer.from(all).toString('base64'));
ok('base64 of a large buffer round-trips', same(fromBase64(toBase64(big)), big));
ok('base64url round-trips every byte', same(fromBase64Url(toBase64Url(all)), all));
ok('base64url uses the URL alphabet, unpadded', !/[+/=]/.test(toBase64Url(all)) && toBase64Url(all) === Buffer.from(all).toString('base64url'));
ok('hex round-trips every byte', same(fromHex(toHex(all)), all));
ok('hex is lowercase, two digits a byte', toHex(Uint8Array.of(0, 10, 255)) === '000aff');
ok('hex reads uppercase', same(fromHex('0AFF'), Uint8Array.of(10, 255)));
ok('an odd-length hex string is refused', throws(() => fromHex('abc')));
ok('a non-hex digit is refused', throws(() => fromHex('zz')));
ok('empty in, empty out', toBase64(new Uint8Array(0)) === '' && fromHex('').length === 0);
ok('base64Length is the encoded length', [0, 1, 2, 3, 4, 300_000].every(n => base64Length(n) === toBase64(new Uint8Array(n)).length));

done();
