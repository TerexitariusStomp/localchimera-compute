// tests/browser/assert.mjs — the unit tests' one way of saying what held.
//
// A unit test here is a plain node script: it states a claim, says whether it
// held, and exits non-zero when any did not. This is the counter, the line
// format and the exit, once:
//
//   import { harness } from './assert.mjs';
//   const { check, section, done } = harness();
//   section('the gateway’s measure');
//   check('plain text: its bytes and the two quotes', wireBytes('abc') === 5);
//   check('what is kept measures within the cap', n <= cap, `${n} ≤ ${cap}`);
//   done();
//
//   ✓ label — detail          a claim that held (the detail is optional)
//   ✗ label — detail          one that did not
//   N passed, M failed        and the exit code is 1 when M > 0
//
// `ok` is `check` under the name some suites call it by.

export function harness() {
  let pass = 0, fail = 0;
  const check = (label, held, detail = "") => {
    held ? pass++ : fail++;
    // a detail reads after a dash; a caller that wrote its own is taken as written
    const d = String(detail ?? "").replace(/^\s*—\s*/, "").trim();
    console.log(`  ${held ? "✓" : "✗"} ${label}${d ? " — " + d : ""}`);
  };
  return {
    check,
    ok: check,
    section(title) { console.log(`\n── ${title} ──`); },
    done() {
      console.log(`\n${pass} passed, ${fail} failed`);
      process.exit(fail ? 1 : 0);
    },
  };
}
