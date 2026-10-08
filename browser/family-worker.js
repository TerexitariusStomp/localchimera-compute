// browser/family-worker.js — the household's solve, off the page's thread and on the device.
//
// The family face's week is a solve over the household's own ledger. It runs
// here (family.wasm, the planner compiled for the browser) so the ledger never
// leaves the device and a solve — a few hundred milliseconds — never holds the
// page or the spine's vat.
//
//   page → worker   {id, door: "split" | "bills", args: […]}
//   worker → page   {id, reply}     reply = the solve's JSON, or "err:…" ("err:unavailable: …" when the wasm could not run)
//
// family.wasm boots on the first call and stays.

importScripts("reflect.js");

let ready = null;
const boot = () => ready || (ready = import("./lib/family-boot.js")
  .then((m) => m.bootFamily(Scheme, "family.wasm")));

self.onmessage = async ({ data: { id, door, args } }) => {
  try {
    const fam = await boot();
    self.postMessage({ id, reply: await fam[door](...args) });
  } catch (e) {
    ready = null;                       // a failed boot is tried again on the next call
    self.postMessage({ id, reply: "err:unavailable: " + ((e && e.message) || e) });   // ui/app/family-local.ts UNAVAILABLE
  }
};
