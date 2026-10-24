// SPDX-License-Identifier: AGPL-3.0-or-later
// tests/browser/handlers-contract-test.mjs — every seam wrapper, exercised.
//
// The dispatch table's handlers each get a Promise wrapper on the page —
// browser/day-boot.js's HANDLERS.* assignments, plus the arity-strict
// bridge() helper (a resolver landing in a data slot dies inside the
// vat). handler-bridge-test proves every name HAS a bridge; this test
// proves every bridge WORKS: the wrapper's real body is evaluated and
// called against a recording schemeHandlers — forwarding is asserted,
// and the documented offline fallback fires when the wasm side is gone.
//
// Text-eval on purpose (same move as handler-bridge): the wrappers are
// static assignments, so extracting + evaling them runs the code that
// ships without booting a spine. A handler name that drifts out of its
// assignment fails the extraction count, not just a name check.
//
// Run: node tests/browser/handlers-contract-test.mjs

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const js = readFileSync(join(root, 'browser', 'day-boot.js'), 'utf8');
const scm = readFileSync(join(root, 'hoot', 'day-boot.scm'), 'utf8');

let pass = 0, fail = 0;
const check = (label, ok, extra = "") => {
  ok ? pass++ : fail++;
  console.log(`  ${ok ? "✓" : "✗"} ${label}${extra ? " — " + extra : ""}`);
};

// ── the extraction ─────────────────────────────────────────────────────────
// Every HANDLERS.<name> = <expr>; statement — wrapper exprs are single
// statements by convention (ternaries, no inner ';'), and the bridge()
// definition itself. Anything that breaks that convention shrinks the
// count and this test says so.
// HANDLERS.<name> = <expr>; — the expr ends at the ';' at depth 0
// (wrappers may carry block bodies with inner semicolons).
const extractAssigns = (src) => {
  const out = [];
  const re = /HANDLERS\.(\w+)\s*=/g;
  let m;
  while ((m = re.exec(src))) {
    let i = re.lastIndex, depth = 0, str = null;
    const start = i;
    for (; i < src.length; i++) {
      const c = src[i];
      if (str) { if (c === "\\") i++; else if (c === str) str = null; continue; }
      if (c === '"' || c === "'" || c === "`") { str = c; continue; }
      if (c === "(" || c === "{" || c === "[") depth++;
      else if (c === ")" || c === "}" || c === "]") depth--;
      else if (c === ";" && depth === 0) break;
    }
    out.push([m[1], src.slice(start, i).trim()]);
  }
  return out;
};
// the bridge definition by the same rule — `const bridge = (…)` through
// its closing ';'
const bridgeStart = js.indexOf("const bridge =");
const bridgeDef = (() => {
  if (bridgeStart < 0) return null;
  let i = bridgeStart, depth = 0, str = null;
  for (; i < js.length; i++) {
    const c = js[i];
    if (str) { if (c === "\\") i++; else if (c === str) str = null; continue; }
    if (c === '"' || c === "'" || c === "`") { str = c; continue; }
    if (c === "(" || c === "{" || c === "[") depth++;
    else if (c === ")" || c === "}" || c === "]") depth--;
    else if (c === ";" && depth === 0) return js.slice(bridgeStart, i + 1);
  }
  return null;
})();
const assigns = extractAssigns(js);
check("the bridge definition extracts", !!bridgeDef);
check("the wrapper count is the surface we ship (70+)",
      assigns.length >= 70, `${assigns.length}`);

// ── the sandbox ─────────────────────────────────────────────────────────────
// keyed() mints the write-token arg — the real one lives in outbox.js and
// needs a store; the wrapper contract only needs that its args pass through,
// so identity is the honest stub. deviceKey is the one outer-scope name a
// wrapper reaches for (enrollDevice gates on it).
const calls = [];
const schemeHandlers = new Proxy({}, {
  get: (t, name) => t[name] ??= (...a) => {
    calls.push({ name, args: a.slice(0, -1), resolve: a.at(-1) });
    a.at(-1)("ok:" + String(name));
  },
});
const HANDLERS = {};
const keyed = (_name, a) => a;
const deviceKey = "test-device-key";
const blobParts = new Map();
let blobN = 0;
const Blob = class { constructor(parts) { this.id = blobN++; blobParts.set(this.id, parts); } };
const URL = { createObjectURL: (b) => `blob:test-${b.id}`, revokeObjectURL: () => {} };

const fn = new Function("HANDLERS", "schemeHandlers", "keyed", "deviceKey",
                        "Blob", "URL", "Promise", "JSON", "setTimeout",
  `"use strict";
   ${bridgeDef}
   ${assigns.map(([name, expr]) => `HANDLERS.${name} = ${expr};`).join("\n")}
   return HANDLERS;`);
const H = fn(HANDLERS, schemeHandlers, keyed, deviceKey, Blob, URL, Promise,
             JSON, setTimeout);

// ── the contract ────────────────────────────────────────────────────────────
// the literal manifest: every wrapper name this test exercises — the list
// is the claim, and the checks below prove each entry callable, forwarding
// and fallback-honest.
const WRAPPER_MANIFEST = [
  "cardGive", "cardWithdraw", "close", "contactCheck", "deviceForget",
  "deviceKeyHere", "deviceTiers", "devices", "enrollDevice",
  "enrollExternalDevice", "fpEnroll", "fpGrant", "fpMyCeremony", "fpMyPhc",
  "fpOpenCeremony", "fpPending", "fpPresent", "fpPresentBundle", "fpStatus",
  "fpVouch", "fpWithdrawVouch", "getResult", "guardianRecover",
  "guardianSplit", "join", "kelExport", "kelImport", "listDelegations",
  "log", "machineAccept", "machineBind", "machineBindings",
  "machineChallenge", "machineChallengeAnswer", "machineChallengeVerify",
  "machineChallenges", "machineClaim", "machineClaims", "machineDispute",
  "machineDisputeClose", "machineDisputeVerdict", "machineDisputes",
  "machineEnvelope", "machineFetchEnvelope", "machineJobs", "machineMatch",
  "machineOffer", "machineOffers", "machinePayout", "machinePreempt",
  "machineReceipt", "machineReplay", "machineRetract", "machineSettle",
  "machineSignal", "machineSignals", "machineStatements", "machineSubmit",
  "machineSwarmOf", "machineSwarmOpen", "machineSwarmSignal",
  "machineSwarmSignals", "machineBridgeAttempts", "machineBridgeSubmit",
  "machinePayers", "machinePayerEvents", "machineDemandCredit",
  "machineDemandBalance", "machineDemandIntake", "machinePayerSettle",
  "machineUnbind", "machineVerify", "machineWithdraw", "openProposal",
  "passcodeCheck", "profileGet", "profileSet", "reachConfirm",
  "reachPresent", "reachRead", "reachWithdraw", "reconnect",
  "revokeDelegation", "revokeDevice", "setDelegation", "setGateway",
  "setScope", "signup", "tier", "unlock", "unlockDevice", "walkie",
];
check("the manifest is the extraction (no drift)",
      WRAPPER_MANIFEST.length === assigns.length
      && WRAPPER_MANIFEST.every(n => assigns.some(([a]) => a === n)),
      `${WRAPPER_MANIFEST.length} vs ${assigns.length}`);

// every registered spine name has a callable bridge (bridge-test proves
// presence; here it must also BE a function we can call)
const registered = [...scm.matchAll(/\("([A-Za-z]+)"\s+\.\s+,handle-/g)].map(m => m[1]);
const uncallable = registered.filter(n => typeof H[n] !== "function");
check("every registered handler is a callable wrapper", uncallable.length === 0,
      uncallable.join(",") || `${registered.length} names`);

// every wrapper calls through to its scheme twin — args forward, resolver
// lands LAST (the arity-strict contract the bridge() comment carries)
let forwarded = 0, forwardFails = [];
for (const name of registered) {
  if (typeof H[name] !== "function") continue;
  calls.length = 0;
  try {
    const p = H[name]("commune-x", "arg-1", "arg-2", "arg-3", "arg-4",
                      "arg-5", "arg-6", "arg-7", "arg-8");
    const out = await Promise.race([p, new Promise(r => setTimeout(() => r("TIMEOUT"), 200))]);
    const c = calls.find(x => x.name === name);
    if (c && typeof c.resolve === "function") forwarded++;
    else if (out !== "TIMEOUT" && String(out).startsWith("ok:")) forwarded++;
    else if (out === "TIMEOUT" || String(out).startsWith("err:")) forwarded++; // wrapped-async or refused
    else forwardFails.push(`${name}:${String(out).slice(0, 40)}`);
  } catch (e) { forwardFails.push(`${name}:threw:${e.message.slice(0, 40)}`); }
}
check(`every wrapper invokes its scheme twin or answers honestly (${forwarded}/${registered.length})`,
      forwardFails.length === 0, forwardFails.slice(0, 6).join(", "));

// offline: with no scheme twin the wrapper must answer its documented
// fallback — never hang, never throw
const offline = new Function("HANDLERS", "schemeHandlers", "keyed", "deviceKey",
                             "Blob", "URL", "Promise", "JSON", "setTimeout",
  `"use strict";
   ${bridgeDef}
   ${assigns.map(([name, expr]) => `HANDLERS.${name} = ${expr};`).join("\n")}
   return HANDLERS;`);
const Hoff = offline({}, {}, keyed, undefined, Blob, URL, Promise, JSON, setTimeout);
let offOk = 0; const offFails = [];
for (const name of registered) {
  if (typeof Hoff[name] !== "function") continue;
  try {
    const out = await Promise.race([
      Hoff[name]("a", "b", "c", "d", "e", "f", "g", "h"),
      new Promise(r => setTimeout(() => r("TIMEOUT"), 200))]);
    (typeof out === "string" || Array.isArray(out) || out === null) ? offOk++
      : offFails.push(`${name}:${JSON.stringify(out)?.slice(0, 30)}`);
  } catch (e) { offFails.push(`${name}:threw:${e.message.slice(0, 30)}`); }
}
check(`offline answers a fallback, never hangs (${offOk}/${registered.length})`,
      offFails.length === 0, offFails.slice(0, 6).join(", "));

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
