// browser/lib/scope-boot.js — boot the device's scope (scope.wasm) and give its doors a promise face.
//
//   const scope = await bootScope(Scheme, "scope.wasm");
//   const reply = await scope.ask("countHistory", ["demo:tea", ""]);
//   await scope.ask("hold", [scopeId, me, replicaText]);     // a copy of a gateway's scope
//
// Each reply is what a gateway's planner answers of the door: its JSON, or
// "err:…" ("err:unavailable: …" for a door the scope does not take). The scope
// holds what it was last told to: a replica (`hold`), or the demo neighbourhood
// (`open`, with a unix second for today). A door asked before either stands the
// neighbourhood as of the present.
// Booted through lib/wasm-boot.js.
//
// One module for the page's worker (browser/scope-worker.js) and for the node
// check (tools/check-scope-worker.cjs): both boot the same way.

import { bootHandlers } from "./wasm-boot.js";

const OPENERS = new Set(["open", "hold"]);

export async function bootScope(Scheme, source, opts = {}) {
  const { call } = await bootHandlers(Scheme, source, { ...opts, module: "scope", what: "the device scope" });
  // every argument goes as a string; the scope reads one left out as ""
  const door = (name, args) => call("door", 2, name, JSON.stringify(args.map((a) => a == null ? "" : String(a))));
  let held = false;
  const one = async (name, args) => {
    if (OPENERS.has(name)) held = true;
    else if (!held) { held = true; await door("open", [Math.floor(Date.now() / 1000)]); }
    return door(name, args);
  };
  // One door at a time: a door may yield to the vat before it answers, and a
  // second door entered meanwhile would read the scope half stood. Each ask
  // waits for the one before it to end, whichever way it ended.
  let last = Promise.resolve();
  return {
    ask(name, args = []) {
      const mine = last.then(() => one(name, args));
      last = mine.catch(() => undefined);
      return mine;
    },
  };
}
