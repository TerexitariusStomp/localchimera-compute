// browser/scope-worker.js — a scope held on the device, off the page's thread.
//
// With no gateway the page still has books: the demo neighbourhood's. They are a
// real scope (scope.wasm, the planner's scope root, observer and door functions
// compiled for the browser), held here so a count lands and a schedule is read
// by the engine itself, with no gateway and without holding the page or the
// spine's vat.
//
//   page → worker   {id, door, args: […]}
//   worker → page   {id, reply}     reply = the door's JSON, or "err:…" ("err:unavailable: …" when the wasm could not run or the door is not taken here)
//
// scope.wasm boots on the first call and stays.

importScripts("reflect.js");

let ready = null;
const boot = () => ready || (ready = import("./lib/scope-boot.js")
  .then((m) => m.bootScope(Scheme, "scope.wasm")));

self.onmessage = async ({ data: { id, door, args } }) => {
  try {
    const scope = await boot();
    self.postMessage({ id, reply: await scope.ask(door, args) });
  } catch (e) {
    ready = null;                       // a failed boot is tried again on the next call
    self.postMessage({ id, reply: "err:unavailable: " + ((e && e.message) || e) });   // ui/app/scope-local.ts UNAVAILABLE
  }
};
