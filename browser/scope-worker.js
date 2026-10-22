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

// scope.wasm outweighs the Pages per-file cap (~25MiB): where the static tier
// cannot carry it the gateway's own static server does (serve-static's
// work-dir is this same directory). Resolve the gateway origin from the
// baked discovery doc and fetch the bytes from there.
async function scopeBytes() {
  const res = await fetch("scope.wasm");
  if (res.ok) return res.arrayBuffer();
  const ep = await (await fetch("entry-points.json")).json();
  const link = ep && (ep.discoveryUrl || (ep.gateway && ep.gateway[0] && ep.gateway[0].url));
  if (!link) throw new Error("scope.wasm: HTTP " + res.status);
  const alt = await fetch(new URL("/scope.wasm", new URL(link, self.location.href).origin).href);
  if (!alt.ok) throw new Error("scope.wasm: HTTP " + alt.status);
  return alt.arrayBuffer();
}

let ready = null;
const boot = () => ready || (ready = import("./lib/scope-boot.js")
  .then(async (m) => m.bootScope(Scheme, await scopeBytes())));

self.onmessage = async ({ data: { id, door, args } }) => {
  try {
    const scope = await boot();
    self.postMessage({ id, reply: await scope.ask(door, args) });
  } catch (e) {
    ready = null;                       // a failed boot is tried again on the next call
    self.postMessage({ id, reply: "err:unavailable: " + ((e && e.message) || e) });   // ui/app/scope-local.ts UNAVAILABLE
  }
};
