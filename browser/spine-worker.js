// SPDX-License-Identifier: AGPL-3.0-or-later
// browser/spine-worker.js — the spine off the page's thread
//
// The Hoot/Goblins vat decodes every gateway frame byte by byte (Goblins'
// Hoot netlayer copies a frame with one FFI call per byte, and its syrup
// reader walks it per byte again): a solve round's snapshot costs the
// thread a second or more, and on the page that second is a tap that waits.
// Here the vat runs in a dedicated Worker; the page keeps the DOM, WebRTC,
// WebAuthn and the device key, and a small typed bridge joins them:
//
//   page → worker   {t:"init", …}           what the page resolved (sref, storage, origin)
//                   {t:"call", id, name, args}   a HANDLERS call → schemeHandlers[name]
//                   {t:"cb", id, args}      a bridged callback fired on the page
//                   {t:"devret", id, value} a device-key door answered
//                   {t:"hash", h}           the page's hash moved
//   worker → page   {t:"trace", s}          a boot trace line
//                   {t:"handler", name}     the spine registered a handler
//                   {t:"ret", id, value}    a call's reply
//                   {t:"seam", fn, args}    a push into the seam (status, data, …)
//                   {t:"ls", op, k, v}      storage write-through
//                   {t:"rtc", fn, args, pcId} a WebRTC door (handles by id)
//                   {t:"device", id, fn, args} a device-key door
//                   {t:"hash", h}           the spine set the hash
//
// Storage is MIRRORED: the vat reads localStorage synchronously (the KEL at
// init, the device wire at unlock), so the page hands a snapshot of it in
// `init` and every write goes back through `ls`.

importScripts("reflect.js");

const post = (m) => self.postMessage(m);
const trace = (s) => post({ t: "trace", s });
const schemeHandlers = {};
const pending = new Map();          // page-issued callback id → externalized Scheme proc
const devPending = new Map();       // device door id → cb
let nextId = 1;
let devicePub = new Uint8Array(0);
let cfg = null;
let mirror = new Map();
let severGateway = () => {};        // the reconnect proof's door, once the libs load

function bridgedCb(fn) {            // an externalized Scheme procedure, callable from the page
  const id = nextId++;
  pending.set(id, fn);
  return { cb: id };
}

async function boot(init) {
  cfg = init;
  mirror = new Map(Object.entries(init.ls || {}));
  const ls = {
    getItem(k) { return mirror.has(k) ? mirror.get(k) : null; },
    setItem(k, v) { mirror.set(k, String(v)); post({ t: "ls", op: "set", k, v: String(v) }); },
    removeItem(k) { mirror.delete(k); post({ t: "ls", op: "remove", k }); },
  };
  const imports = await import("./lib/spine-imports.js");
  const { loadLibs, pureImports, SEAM_SINKS, RTC_DOORS } = imports;
  severGateway = imports.severGateway;
  const libs = await loadLibs({ trace, ls });
  trace("libs ready, loading wasm (worker)");
  const pure = pureImports({
    ls, trace, libs,
    search: init.search, origin: init.origin, gatewaySref: init.gatewaySref,
    getHash: () => cfg.hash, setHash: (h) => { cfg.hash = h; post({ t: "hash", h }); },
  });

  // the seam's sinks: every push crosses to the page by name
  const seam = {
    setHandler(name, fn) { schemeHandlers[name] = fn; post({ t: "handler", name }); },
    callCallback(cb, s) { cb(s); },
  };
  for (const fn of SEAM_SINKS) seam[fn] = (...args) => post({ t: "seam", fn, args });

  // WebRTC: peer connections live on the page; here they are handles
  let nextPc = 1;
  const webRTC = {};
  for (const fn of RTC_DOORS) {
    webRTC[fn] = (...args) => {
      const wire = args.map(a =>
        typeof a === "function" ? bridgedCb(a)
        : (a && typeof a === "object" && "pc" in a) ? a
        : a);
      if (fn === "newPc") { const pcId = nextPc++; post({ t: "rtc", fn, args: [], pcId }); return { pc: pcId }; }
      post({ t: "rtc", fn, args: wire });
    };
  }

  // the device key: WebAuthn and the keystore door stay on the page
  const devCall = (fn, args, cb) => { const id = nextId++; devPending.set(id, cb); post({ t: "device", id, fn, args }); };
  const device = {
    load(cb) { devCall("load", [], (v) => { if (v && v.pub) devicePub = v.pub; cb(v && v.status ? v.status : "err:device unavailable"); }); },
    pub() { return devicePub; },
    sign(bytes, cb) { devCall("sign", [bytes], (v) => cb(v instanceof Uint8Array ? v : new Uint8Array(0))); },
    seal(bytes, cb) { devCall("seal", [bytes], (v) => cb(typeof v === "string" ? v : "")); },
    open(blob, cb) { devCall("open", [blob], (v) => cb(v instanceof Uint8Array ? v : new Uint8Array(0))); },
  };

  await Scheme.load_main("day-boot.wasm", { user_imports: { ...pure, seam, webRTC, device } });
  post({ t: "loaded" });
}

self.onmessage = (e) => {
  const m = e.data;
  switch (m.t) {
    case "init": boot(m).catch(err => { console.warn("[spine-worker] boot failed:", err); trace("boot failed: " + (err && err.message || err)); post({ t: "failed", err: String(err && err.message || err) }); }); break;
    case "call": {
      const fn = schemeHandlers[m.name];
      if (!fn) { post({ t: "ret", id: m.id, value: "err:offline" }); break; }
      try { fn(...m.args, (value) => post({ t: "ret", id: m.id, value })); }
      catch (err) { post({ t: "ret", id: m.id, value: "err:" + (err && err.message || err) }); }
      break;
    }
    case "cb": { const fn = pending.get(m.id); if (fn) fn(...m.args); break; }
    case "devret": { const cb = devPending.get(m.id); devPending.delete(m.id); if (cb) cb(m.value); break; }
    case "hash": if (cfg) cfg.hash = m.h; break;
    case "devpub": devicePub = m.pub instanceof Uint8Array ? m.pub : new Uint8Array(m.pub || 0); break;
    case "debug": if (m.op === "closeWs") severGateway(); break;
  }
};
