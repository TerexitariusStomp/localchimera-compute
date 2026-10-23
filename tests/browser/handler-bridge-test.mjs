// SPDX-License-Identifier: AGPL-3.0-or-later
// tests/browser/handler-bridge-test.mjs — the seam between the spine's handler
// registry and the page's promise bridges is a CHECKED CLAIM, not a hand-kept
// mirror.
//
// The wasm registers handlers by name (hoot/day-boot.scm's one for-each over
// dial-set-handler!), and the page exposes each to the faces as a wrapper on
// __seam.handlers (browser/day-boot.js). Every face guards on the wrapper's
// PRESENCE and treats absence as "offline" — so a registered-but-unbridged
// handler is a silent no-op against a live gateway. Eight of them (the
// confirmation mile, the witness doors, availability, claim, invites) sat in
// exactly that state until the live first-citizen probe surfaced it. This test
// makes the parity a fact the suite holds: a name in the spine's registry MUST
// have a bridge, at commit time, forever.
//
// Text-level on purpose: the registry is a static literal table and the
// bridges are static assignments, so reading the two sources is exact, needs
// no wasm runtime, and costs milliseconds in test-fast.
//
// Run: node tests/browser/handler-bridge-test.mjs

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const scm = readFileSync(join(root, 'hoot', 'day-boot.scm'), 'utf8');
const js  = readFileSync(join(root, 'browser', 'day-boot.js'), 'utf8');

// the spine's registry: every ("name" . ,handle-…) row of the one for-each
const registered = [...scm.matchAll(/\("([A-Za-z]+)"\s+\.\s+,handle-/g)]
  .map(m => m[1]);
// the page's bridges: every HANDLERS.<name> = assignment
const bridged = new Set(
  [...js.matchAll(/HANDLERS\.([A-Za-z]+)\s*=/g)].map(m => m[1]));

import { harness } from './assert.mjs';
const { check, done } = harness();

check('the spine registers a plausible number of handlers (sanity)',
      registered.length >= 40);

const missing = registered.filter(n => !bridged.has(n));
check(`every spine-registered handler has a page bridge (${registered.length} names)`,
      missing.length === 0);
if (missing.length)
  console.log('    unbridged (silent no-ops live): ' + missing.join(', '));

done();
