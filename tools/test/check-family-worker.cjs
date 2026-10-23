#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-or-later
// check-family-worker.cjs — boot browser/family.wasm the way the page's worker does, and ask it a week.
//
//   node tools/test/check-family-worker.cjs        (make check-family-worker builds the wasm first)
//
// Runs browser/lib/family-boot.js — the module browser/family-worker.js boots
// through — under node, with browser/reflect.js as the Scheme runtime. The week
// is the planner's demo household: at a €250 purse the reference build spends
// 253.0 (the Pfand run's income rides on the purse) and at €400, 403.0, feasible
// both times, to the barrier's residue (a few thousandths). A different number here means the browser build and the reference
// build no longer solve the same program.
// Hoot 0.9 emits the standard wasm exception encoding (try_table / exnref); Node 22
// compiles it behind this V8 flag, which must be set before the first compile.
try { require('v8').setFlagsFromString('--experimental-wasm-exnref'); } catch {}
const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');
const browser = path.join(__dirname, '..', '..', 'browser');
const Scheme = new Function('require', fs.readFileSync(path.join(browser, 'reflect.js'), 'utf8') + '\n;return Scheme;')(require);

// the planner's own demo household (family.scm %family-demo-needs): person, what, cost, want, voice, kind
const needs = [
  ['all', 'treats', 4, 3, 10, 'des'], ['alice', 'medicine', 30, 1, 0, 'floor'], ['alice', 'physio', 25, 1, 464, 'held'],
  ['alice', 'newspaper', 1.5, 7, 5, 'des'], ['bob', 'schoolbooks', 25, 2, 464, 'held'], ['bob', 'transit-school', 30, 1, 464, 'held'],
  ['bob', 'phone-credit', 10, 1, 10, 'des'], ['bob', 'videogame', 50, 1, 1, 'des'], ['christine', 'transit-pass', 40, 1, 464, 'held'],
  ['christine', 'work-lunches', 5, 5, 22, 'des'], ['christine', 'coffee-beans', 9, 1, 5, 'des'], ['christine', 'concert', 35, 1, 2, 'des'],
  ['dennis', 'shoes', 45, 1, 215, 'held'], ['dennis', 'swimming', 15, 2, 100, 'des'], ['dennis', 'birthday-gift', 15, 1, 10, 'des'],
  ['dennis', 'videogame', 50, 1, 1, 'des'],
].map(([person, what, cost, want, voice, kind]) => ({ person, what, cost, want, voice, kind }));

let failed = 0;
const check = (ok, what, detail) => { console.log((ok ? '  ✓ ' : '  ✗ ') + what + (detail ? '   ' + detail : '')); if (!ok) failed++; };

(async () => {
  const { bootFamily } = await import(pathToFileURL(path.join(browser, 'lib', 'family-boot.js')).href);
  const t0 = performance.now();
  const fam = await bootFamily(Scheme, fs.readFileSync(path.join(browser, 'family.wasm')), { reflect_wasm_dir: browser });
  console.log('  booted in ' + Math.round(performance.now() - t0) + ' ms');

  for (const purse of [250, 400]) {
    const t = performance.now();
    const r = JSON.parse(await fam.split(JSON.stringify(needs), purse, 20, true, '[]', 40));
    const ms = Math.round(performance.now() - t);
    check(r.feasible === 'yes' && Math.abs(Number(r.spent) - (purse + 3)) < 0.05, `purse ${purse}: the split the reference build measures`, `spent ${Number(r.spent).toFixed(4)}, ${ms} ms`);
    check(Array.isArray(r.needs) && r.needs.length === needs.length, `purse ${purse}: a row per need`);
  }
  const b = JSON.parse(await fam.bills(JSON.stringify(needs), 100, 20, true, 15, '[]', 40));
  check(Array.isArray(b.tiers) && b.tiers.length === 3, 'bills: three tiers', b.tiers.map((x) => x.tier).join(' / '));
  const bad = await fam.split('not json', 100, 20, true, '[]', 40);
  check(typeof bad === 'string' && bad.startsWith('err:'), 'a malformed week is refused by name', bad.slice(0, 60));
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error('ERR', (e && e.stack) || e); process.exit(1); });
