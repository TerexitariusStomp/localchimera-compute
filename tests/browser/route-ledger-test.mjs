// tests/browser/route-ledger-test.mjs — a journey as a fact of the ledger (browser/app/route/ledger.js, from
// ui/app/route/ledger.ts): begin names where from and to and by what; end names where it ended, once, with the
// commitment begin minted; a refused begin is told to the person and recorded as nothing; no door, no record.
//
// Run: node tests/browser/route-ledger-test.mjs

import { installDomStub } from './dom-stub.mjs';
import { harness } from './assert.mjs';
const { check, section, done } = harness();
installDomStub();

const { HANDLERS } = await import("../../browser/app/core.js");
const { beginJourney } = await import("../../browser/app/route/ledger.js");
const tick = () => new Promise(r => setTimeout(r, 5));

const A = { lat: 37.7749, lng: -122.4194 }, B = { lat: 37.7849, lng: -122.4094 };

section("begin and end");
{
  const calls = [];
  HANDLERS.journey = async (...a) => { calls.push(a); return a[0] === "begin" ? "ok:cid-1" : "ok"; };
  const led = beginJourney(A, B, "Oak Cafe", "bicycle"); await tick();
  check("begin names from, to and the way it is travelled", calls.length === 1 && calls[0][0] === "begin" &&
        calls[0][1] === "geo:37.77490,-122.41940" && calls[0][2] === "geo:37.78490,-122.40940" && calls[0][3] === "bicycle" && calls[0][4] === "");
  led.end({ lat: 37.7801, lng: -122.41 });
  check("end names where it ended, and the commitment begin minted", calls.length === 2 && calls[1][0] === "end" &&
        calls[1][1] === "geo:37.78010,-122.41000" && calls[1][3] === "bicycle" && calls[1][4] === "cid-1");
  led.end(B);
  check("a journey ends once", calls.length === 2);
}

section("end before begin answered");
{
  const calls = []; let answer;
  HANDLERS.journey = (...a) => { calls.push(a); return new Promise(r => { answer = r; }); };
  const led = beginJourney(A, B, "x", "auto");
  led.end(B);
  check("ending before the ledger has answered records no end: there is no commitment to fulfil", calls.length === 1);
  answer("ok:late");
}

section("a refusal, and no door");
{
  HANDLERS.journey = async () => "err:provisional";
  const told = [];
  const led = beginJourney(A, B, "x", "auto", r => told.push(r)); await tick();
  check("a refusal is handed on, to tell the person", told.join() === "err:provisional");
  let calls = 0; HANDLERS.journey = async () => { calls++; return "ok"; };
  led.end(B); await tick();
  check("a refused begin leaves nothing to end", calls === 0);
  HANDLERS.journey = undefined;
  let fine = true; try { beginJourney(A, B, "x", "auto").end(B); } catch { fine = false; }
  check("with no door the journey is simply not recorded", fine);
}

done();
