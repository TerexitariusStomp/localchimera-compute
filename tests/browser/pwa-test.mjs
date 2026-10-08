// tests/browser/pwa-test.mjs — app/pwa.ts: which origins are live-editing, and
// which caches the worker owns.
//
// Both answers decide what gets deleted. isDev() tears the worker and its
// caches down on every load; ownsCache() bounds what that teardown (and the
// worker's own activate) may remove. The Capacitor shell serves the dial from
// https://localhost, so "loopback" alone reads the installed app as a dev box.
//
// Run: node tests/browser/pwa-test.mjs

import { isDev, ownsCache } from '../../browser/app/pwa.js';

import { harness } from './assert.mjs';
const { ok, done } = harness();
const at = (href) => { const u = new URL(href); return { search: u.search, hostname: u.hostname, protocol: u.protocol }; };

console.log('\n── live-editing origins ──');
ok('make serve on localhost is dev', isDev(at('http://localhost:8080/app.html')));
ok('make serve on 127.0.0.1 is dev', isDev(at('http://127.0.0.1:8080/app.html?face=time')));
ok('?dev on any host is dev', isDev(at('https://playnet.earth/app.html?face=time&dev=1')));
ok('?nosw on any host is dev', isDev(at('http://abc.onion/app.html?nosw')));

console.log('\n── production origins ──');
ok('the published site is production', !isDev(at('https://playnet.earth/app.html')));
ok('an onion is production', !isDev(at('http://abc.onion/app.html?face=time')));
ok('the Capacitor shell (https://localhost) is production', !isDev(at('https://localhost/app.html')));
ok('a parameter that only starts with dev is production', !isDev(at('https://playnet.earth/app.html?device=1')));
ok('?dev=0 is production', !isDev(at('https://playnet.earth/app.html?dev=0')));
ok('make serve on ::1 is dev', isDev(at('http://[::1]:8080/app.html')));

console.log('\n── cache ownership ──');
ok('a build cache is the worker’s', ownsCache('playnet-4fdcc59b5019'));
ok('the unstamped cache is the worker’s', ownsCache('playnet-v23-dev'));
ok('the speech model’s cache belongs to its writer', !ownsCache('transformers-cache'));

done();
