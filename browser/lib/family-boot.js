// browser/lib/family-boot.js — boot the household solve (family.wasm) and give it a promise face.
//
//   const fam = await bootFamily(Scheme, "family.wasm");
//   const json = await fam.split(needsJson, purse, labourH, weighted, membersJson, perCitizenHours);
//   const json = await fam.bills(needsJson, purse, labourH, weighted, eurPerHour, membersJson, perCitizenHours);
//
// Each reply is the solve's JSON, or "err:…". Booted through lib/wasm-boot.js,
// the one way a planner build for the page is booted.
//
// One module for the page's worker (browser/family-worker.js) and for the node
// check (tools/test/check-family-worker.cjs): both boot the same way.

import { bootHandlers } from "./wasm-boot.js";

export async function bootFamily(Scheme, source, opts = {}) {
  const { call } = await bootHandlers(Scheme, source, { ...opts, module: "family", what: "the household solve" });
  return { split: (...args) => call("split", 6, ...args), bills: (...args) => call("bills", 7, ...args) };
}
