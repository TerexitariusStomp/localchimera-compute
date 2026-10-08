// tests/browser/diag-redact-test.mjs — the diagnostic ring must never keep a
// secret.
//
// The feedback lane can attach what the page said about itself, and what the
// dial says while booting includes its OCapN sturdyref — a BEARER capability,
// where the swiss-num grants whatever it names to whoever holds it. That line
// is logged on every connect, so without a scrub the anonymous pool would
// collect live capabilities, and the person previewing their own report could
// not be expected to know which characters mattered.
//
// The scrub runs at capture, so the ring never holds the secret and no later
// reader of these entries can leak what was never kept.
//
// Run: node tests/browser/diag-redact-test.mjs

import { redact } from '../../browser/app/diag.js';

import { harness } from './assert.mjs';
const { check, done } = harness();

// The shape day-boot.js logs on every gateway connect. SYNTHETIC on purpose,
// and not the real sref with a character moved: a fixture is copied by the
// next person who needs one, and "start from the live capability and edit it"
// is the habit that eventually publishes a working one. The scrub keys on
// SHAPE, so filler holds the test exactly as well.
const SREF = 'gw: computed sref="ocapn://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.websocket'
  + '/s/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb?url=ws%3A%2F%2F127.0.0.1%3A40555%2Fws"';

{
  const out = redact(SREF);
  check('the swiss-num does not survive redaction',
        !out.includes('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'), out);
  check('…and neither does the node id it addresses',
        !out.includes('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'));
  check('what remains still reads as a sturdyref, so the line stays diagnostic',
        out.includes('ocapn://') && out.includes('redacted'), out);
}

// A KERI AID is the same shape of thing: long, base64url, and identifying.
check('an AID does not survive',
      !redact('signed by EKYSbYVFvVFxLPMlEHBmZ0IcJvBpTMOEJTVDPBDDhVOA')
        .includes('EKYSbYVFvVFxLPMlEHBmZ0IcJvBpTMOEJTVDPBDDhVOA'));

// Query parameters are the other road to the same secret.
for (const [k, v] of [['token', 'abc123'], ['bran', 'Awxy'], ['passcode', 'hunter2'],
                      ['key', 'k1'], ['secret', 's1'], ['sref', 'x']]) {
  const out = redact(`GET /x?${k}=${v}&ok=1`);
  check(`?${k}= is redacted`, !out.includes(`${k}=${v}`), out);
}

// What must SURVIVE — a scrub that eats the message is a scrub nobody keeps.
{
  const msg = "Uncaught TypeError: Cannot read properties of null (reading 'getBBox')";
  check('an ordinary error message is untouched', redact(msg) === msg, redact(msg));
}
{
  const msg = '[day-boot] rns ready | libs ready, loading wasm | status: connecting';
  check('ordinary boot breadcrumbs are untouched', redact(msg) === msg);
}
{
  const msg = 'at app/wheel.js:412:9 — frag layer redraw took 1840ms';
  check('a file:line and a timing survive', redact(msg) === msg);
}
{
  // 31 chars: under the bar, and legitimately a word rather than a key
  const msg = 'reticulum_transport_established';
  check('a long ordinary identifier under the threshold survives',
        redact(msg) === msg, redact(msg));
}

done();
