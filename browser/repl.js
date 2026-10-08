// ── WAV encoding / base64 helpers (used by the speech pipeline) ─────────
// Encode a Float32Array of mono PCM samples as a 16-bit PCM WAV ArrayBuffer.
function encodeWav(pcm, sampleRate) {
  const numFrames = pcm.length;
  const bytesPerSample = 2;
  const blockAlign = bytesPerSample;       // mono
  const byteRate = sampleRate * blockAlign;
  const dataSize = numFrames * bytesPerSample;
  const buffer = new ArrayBuffer(44 + dataSize);
  const view = new DataView(buffer);
  const writeStr = (off, s) => { for (let i = 0; i < s.length; i++) view.setUint8(off + i, s.charCodeAt(i)); };
  writeStr(0, 'RIFF');
  view.setUint32(4, 36 + dataSize, true);
  writeStr(8, 'WAVE');
  writeStr(12, 'fmt ');
  view.setUint32(16, 16, true);            // PCM chunk size
  view.setUint16(20, 1, true);             // format = PCM
  view.setUint16(22, 1, true);             // channels
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, byteRate, true);
  view.setUint16(32, blockAlign, true);
  view.setUint16(34, 16, true);            // bits per sample
  writeStr(36, 'data');
  view.setUint32(40, dataSize, true);
  let off = 44;
  for (let i = 0; i < numFrames; i++) {
    let s = Math.max(-1, Math.min(1, pcm[i]));
    view.setInt16(off, s < 0 ? s * 0x8000 : s * 0x7fff, true);
    off += 2;
  }
  return buffer;
}

function bufferToBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

// ── Hex ↔ bytes (used throughout the reticulum FFI namespace) ───────────
// FFI namespace methods are invoked as bare functions (no `this`), so
// shared helpers live at file scope — same pattern as the routing
// internals below.
function hexToBytes(hex) {
  return new Uint8Array(hex.match(/.{2}/g).map(b => parseInt(b, 16)));
}
function bytesToHex(bytes) {
  return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
}

// ── Entry point discovery ──────────────────────────────────────────────
// Discovers the gateway sturdyref and best reachable WebSocket URL.
// Returns { sref, ws } — the Scheme side reads the combined sturdyref.
//
// Sources (in priority order):
//   1. ?gateway= URL param (full sturdyref override)
//   2. /entry-points.json (sref + list of WS endpoints to probe)
//   3. Hardcoded fallback
async function discoverGateway() {
  // 1. URL param override — full sturdyref, skip discovery
  const param = new URLSearchParams(window.location.search).get("gateway");
  if (param) return { sref: param, ws: "" };

  // 2. Fetch entry-points.json and probe WebSocket endpoints
  let sref = "";
  try {
    const resp = await fetch("/entry-points.json");
    if (resp.ok) {
      const data = await resp.json();
      sref = data.sref || "";

      // Prepend a "self" entry derived from the page's own origin: nginx
      // on the playnet server proxies /ws to the gateway, so any client
      // (Tor Browser on the onion, clearnet via the CDN, file:// dev, …)
      // gets a working WebSocket URL without per-host config in
      // entry-points.json. Only useful when we're loaded over http(s).
      const eps = (data.gateway || []).slice();
      if (window.location.protocol === "http:" ||
          window.location.protocol === "https:") {
        const wsProto = (window.location.protocol === "https:") ? "wss:" : "ws:";
        const selfWs = `${wsProto}//${window.location.host}/ws`;
        eps.unshift({ name: "self", kind: "origin", ws: selfWs });
      }
      // Pick the first entry — no probe. Probing by opening + closing a
      // real WebSocket sends zero bytes of CapTP/Syrup to the gateway,
      // which then errors with `syrup-decode #<eof>` and tears down its
      // session. The actual Hoot/wasm netlayer below opens its own WS
      // and either succeeds or fails on its own merits; nothing here
      // can change that outcome, so the probe was pure noise.
      if (eps.length > 0) {
        const ep = eps[0];
        console.log(`[gateway] Selected entry: ${ep.name} → ${ep.ws}`);
        return { sref, ws: ep.ws };
      }
    }
  } catch (_) { /* entry-points.json not available */ }

  // 3. No entry points configured
  console.log("[gateway] No entry points configured");
  return { sref, ws: "" };
}

// Gateway discovery result — read by Scheme via FFI
window.__playnetGateway = { sref: "", ws: "" };

// Universal Commune identity — read by Scheme via FFI to seed the
// contacts tab. Fetched on page load from /universal-commune.json
// (served by serve-static.scm when the gateway has provisioned a UC).
// Shape: { name: "universal-commune", aid: "E…", oobi: "/oobi/E…",
// did: "did:keri:E…" } or null when the endpoint returns 404.
window.__playnetUcIdentity = null;
async function discoverUcIdentity() {
  try {
    const resp = await fetch("/universal-commune.json");
    if (resp.ok) {
      window.__playnetUcIdentity = await resp.json();
    }
  } catch (_) {
    // Endpoint may be 404 on dev/file: deployments — silently no-op.
  }
}

// Local speech-to-text lives in a dedicated Web Worker (browser/lib/asr-worker.js,
// the one the dial spawns too) so model download, ONNX init, and inference
// never touch the main thread. Its runtime is vendored same-origin.
let whisperWorker = null;
let whisperReady  = false;
let nextWhisperId = 1;
const pendingWhisper = new Map();

function getWhisperWorker() {
  if (whisperWorker) return whisperWorker;
  whisperWorker = new Worker('/lib/asr-worker.js', { type: 'module' });
  whisperWorker.onmessage = (e) => {
    const { id, ok, text, error } = e.data;
    const cb = pendingWhisper.get(id);
    if (!cb) return;
    pendingWhisper.delete(id);
    if (ok) cb.resolve(text);
    else cb.reject(new Error(error));
  };
  whisperWorker.onerror = (e) => {
    console.error('[speech] Whisper worker error:', e.message || e);
  };
  return whisperWorker;
}

function whisperSend(message, transfer) {
  return new Promise((resolve, reject) => {
    const id = nextWhisperId++;
    pendingWhisper.set(id, { resolve, reject });
    getWhisperWorker().postMessage({ id, ...message }, transfer || []);
  });
}

function preloadWhisper() {
  if (whisperReady) return Promise.resolve(true);
  console.log('[speech] Pre-warming local Whisper in worker...');
  return whisperSend({ type: 'preload' })
    .then(() => {
      whisperReady = true;
      console.log('[speech] Local Whisper ready');
      return true;
    })
    .catch((e) => {
      console.error('[speech] Whisper preload failed (will retry on first use):', e);
      return false;
    });
}

function transcribeWithWhisper(pcm) {
  // Transfer the underlying buffer to the worker (zero-copy).
  // Caller must not reuse pcm after this call.
  return whisperSend({ type: 'transcribe', pcm }, [pcm.buffer]);
}

// ── Routing internals (used by the "routing" FFI namespace) ─────────────
// Hoot's reflect.js invokes FFI imports as BARE functions, detached from
// their namespace object — `this` is undefined inside them. So everything
// shared lives here at file scope, and the namespace methods stay thin.

// UI words → Valhalla costing — THE one vocabulary boundary, where the
// words are born; the wire and the server speak costing names natively.
function routeCosting(profile) {
  return { foot: "pedestrian", bike: "bicycle", car: "auto",
           scooter: "motor_scooter", transit: "multimodal",
           bus: "bus" }[profile] || profile || "pedestrian";
}

// Decode a Valhalla/Google encoded polyline (precision 6 ⇒ 1e6) into
// [[lng,lat],…] (GeoJSON axis order).
function routeDecode(str, factor) {
  const out = []; let i = 0, lat = 0, lng = 0;
  const n = str.length;
  const val = () => {
    let shift = 0, result = 0, b;
    do { b = str.charCodeAt(i++) - 63;
         result |= (b & 0x1f) << shift; shift += 5;
    } while (b >= 0x20);
    return (result & 1) ? ~(result >> 1) : (result >> 1);
  };
  while (i < n) {
    lat += val(); lng += val();
    out.push([lng / factor, lat / factor]);
  }
  return out;
}

// Valhalla trip → the one normalized contract Scheme pipes around:
// { engine, profile, coordinates, segments, distance_km, time_s, maneuvers }
function routeFlatten(vresp, profile) {
  const trip = vresp && vresp.trip;
  const legs = (trip && trip.legs) || [];
  if (!legs.length) return null;
  let coords = [], maneuvers = [], base = 0;
  for (const leg of legs) {
    const pts = leg.shape ? routeDecode(leg.shape, 1e6) : [];
    for (const m of (leg.maneuvers || [])) {
      maneuvers.push({
        instruction: m.instruction || "",
        type: m.type || 0,
        distance_km: m.length || 0,
        time_s: m.time || 0,
        travel_mode: m.travel_mode || "",
        begin: base + (m.begin_shape_index || 0),
        end: base + (m.end_shape_index || 0)
      });
    }
    coords = coords.concat(pts);
    base += pts.length;
  }
  // Contiguous same-mode runs → per-mode segments, so multimodal trips
  // (walk → bus → walk) can be drawn with per-mode styling.
  const segments = [];
  for (const m of maneuvers) {
    const last = segments[segments.length - 1];
    if (last && last.mode === m.travel_mode) last.end = m.end;
    else segments.push({ mode: m.travel_mode, begin: m.begin, end: m.end });
  }
  const segs = segments.map(s => ({
    mode: s.mode,
    coordinates: coords.slice(s.begin, s.end + 1)
  })).filter(s => s.coordinates.length > 1);
  const s = (trip && trip.summary) || {};
  return { engine: "valhalla", profile: profile || "foot",
           coordinates: coords, segments: segs,
           distance_km: s.length || 0,
           time_s: s.time || 0, maneuvers };
}

function routeStraight(waypoints, profile) {
  // waypoints: [[lat,lng],…] → straight [[lng,lat],…], with the honest
  // great-circle distance (the crow's km — what "straight line" means).
  const R = 6371, rad = Math.PI / 180;
  let km = 0;
  for (let i = 1; i < waypoints.length; i++) {
    const [la1, lo1] = waypoints[i - 1], [la2, lo2] = waypoints[i];
    const dla = (la2 - la1) * rad, dlo = (lo2 - lo1) * rad;
    const h = Math.sin(dla / 2) ** 2 +
              Math.cos(la1 * rad) * Math.cos(la2 * rad) * Math.sin(dlo / 2) ** 2;
    km += 2 * R * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
  }
  return JSON.stringify({
    engine: "straight-line", profile: profile || "foot",
    coordinates: waypoints.map(w => [w[1], w[0]]),
    distance_km: km, time_s: 0, maneuvers: []
  });
}

// Trace state: the journey as actually walked/ridden (geolocation watch),
// map-matched on arrival via the same-origin /trace relay.
let routeTrace = null, routeTraceWatch = -1, routeTraceT0 = 0;

// Defer Whisper warm-up until the browser is idle. Otherwise the
// worker's ~22 MB of JS+WASM downloads compete with the page's own
// fetches (the static server is single-threaded), and the REPL appears
// to wait on Whisper. Idle = page has rendered, network is quiet.
function scheduleWhisperPreload() {
  const start = () => preloadWhisper();
  if ('requestIdleCallback' in window) {
    requestIdleCallback(start, { timeout: 5000 });
  } else {
    setTimeout(start, 2000);
  }
}

window.addEventListener("load", async () => {
  try {
    // Discover gateway (runs in parallel with key preload)
    const gatewayPromise = discoverGateway();
    // Discover UC identity in parallel — fire-and-forget; Scheme
    // checks the global on contacts-tab init.
    discoverUcIdentity();

    // The storage door first: importing it moves any value kept under a
    // former key name to its present one (app/keys.ts), and the Scheme below
    // reads the present names.
    try { await import('./app/store.js'); } catch (e) { console.warn('[repl] storage door unavailable:', e.message); }

    // Pre-load key pairs from the IndexedDB keystore BEFORE WASM starts,
    // so they're available synchronously to Scheme via getPreloadedKeyPair.
    // Private halves are non-extractable CryptoKeys — usable for signing,
    // never exportable to bytes (browser/lib/keystore.js).
    let keystore = null;
    let preloadedKeyPairs = {};
    try {
      keystore = await import('./lib/keystore.js');
      await keystore.migrateLegacy();     // one-time move off localStorage
      preloadedKeyPairs = await keystore.getAll();
    } catch(e) { console.error("Key preload error:", e); }

    // Pre-load synchronous KERI crypto primitives (Blake3, Ed25519,
    // HMAC-SHA256). Must finish BEFORE Scheme.load_main so the
    // crypto-primitives-browser backend has its FFI targets ready
    // when (playnet keri signify-portable) gets imported.
    let keriCrypto = null;
    try {
      keriCrypto = (await import('./lib/keri-crypto.js')).keri;
    } catch (e) {
      console.error('[keri] crypto shim failed to load:', e);
    }

    // At-rest blob crypto for the credential backup. Must also be ready
    // before Scheme.load_main, since the `vault` FFI group closes over it.
    let vaultMod = null;
    try {
      vaultMod = await import('./lib/vault.js');
    } catch (e) {
      console.error('[vault] failed to load:', e);
    }

    // Load Reticulum WASM module (identity + channel framing).
    // Provides each browser with a real Reticulum destination hash.
    let rnsIdentity = null;
    let anonymousRns = null;
    try {
      const rns = await import('./rns_wasm.js');
      await rns.default();  // init WASM
      window.__rnsModule = rns;

      // This browser's Reticulum identity, held sealed at rest
      // (lib/rns-identity.js). The anonymous one is kept in hand so signing
      // out can return to it.
      const { meshIdentity } = await import('./lib/rns-identity.js');
      rnsIdentity = anonymousRns = await meshIdentity(rns, localStorage);
      console.log('[reticulum] identity:', rnsIdentity.destHashHex());
    } catch (e) {
      console.warn('[reticulum] WASM not available, running without mesh identity:', e.message);
    }

    // Resolve gateway (was started in parallel with key preload)
    window.__playnetGateway = await gatewayPromise;
    console.log("[gateway] sref:", window.__playnetGateway.sref || "(not configured)");
    console.log("[gateway] ws:", window.__playnetGateway.ws);

    await Scheme.load_main("repl.wasm", {
      user_imports: {
        document: {
          body() { return document.body; },
          getElementById: Document.prototype.getElementById.bind(document),
          createTextNode: Document.prototype.createTextNode.bind(document),
          createElement: Document.prototype.createElement.bind(document),
          createElementNS(ns, tag) { return document.createElementNS(ns, tag); },
          createTreeWalker(root, whatToShow) { return document.createTreeWalker(root, whatToShow); }
        },
        event: {
          preventDefault(event) { event.preventDefault(); },
          stopPropagation(event) { event.stopPropagation(); },
          keyboardKey(event) { return event.key; },
          keyboardShiftKey(event) { return event.shiftKey; },
          keyboardCtrlKey(event) { return event.ctrlKey; },
          keyboardMetaKey(event) { return event.metaKey; }
        },
        element: {
          value(elem) { return elem.value; },
          setValue(elem, value) { elem.value = value; },
          checked(elem) { return elem.checked; },
          setChecked(elem, checked) { elem.checked = (checked == 1); },
          scrollHeight(elem) { return elem.scrollHeight; },
          clientWidth(elem) { return elem.clientWidth; },
          clientHeight(elem) { return elem.clientHeight; },
          setScrollTop(elem, value) { elem.scrollTop = value; },
          appendChild(parent, child) { return parent.appendChild(child); },
          setAttribute(elem, name, value) { elem.setAttribute(name, value); },
          removeAttribute(elem, name) { elem.removeAttribute(name); },
          remove(elem) { elem.remove(); },
          replaceWith(oldElem, newElem) { oldElem.replaceWith(newElem); },
          addEventListener(elem, name, f) { elem.addEventListener(name, f); },
          removeEventListener(elem, name, f) { elem.removeEventListener(name, f); },
          setStyle(elem, prop, value) { elem.style[prop] = value; },
          focus(elem) { elem.focus(); }
        },
        time: {
          now() { return Date.now(); },
          // ISO-8601 with microsecond precision + explicit offset, the
          // KERI `dt` shape (used for OKEA endpoint-reply timestamps).
          isoNow() {
            return new Date().toISOString().replace('Z', '000+00:00');
          }
        },
        file: {
          download(content, filename, mimeType) {
            const blob = new Blob([content], { type: mimeType });
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url; a.download = filename;
            document.body.appendChild(a); a.click();
            document.body.removeChild(a);
            URL.revokeObjectURL(url);
          }
        },
        treeWalker: {
          currentNode(walker) { return walker.currentNode; },
          setCurrentNode(walker, node) { walker.currentNode = node; },
          nextNode(walker) { return walker.nextNode(); },
          firstChild(walker) { return walker.firstChild(); },
          nextSibling(walker) { return walker.nextSibling(); }
        },
        // (The "ai"/"chat" import — a direct OpenRouter XHR with a client-held
        // key — was removed. AI now flows through the gateway lobby over OCapN
        // from the Scheme side: the evaluator suspends at (ai …) and the resumer
        // fulfils it via lobby 'ai-complete → key-pool → nano-gpt/TEE.)
        // Live-location sharing → planner. The callback gets (lat, lon); the
        // WASM coarsens to the nearest named place before anything is stored.
        geolocation: {
          getCurrent(cb) {
            if (!navigator.geolocation) return;
            navigator.geolocation.getCurrentPosition(
              (p) => cb(p.coords.latitude, p.coords.longitude),
              (err) => console.warn("[geo] error:", err && err.message),
              { enableHighAccuracy: false, maximumAge: 30000, timeout: 15000 });
          },
          watchStart(cb) {
            if (!navigator.geolocation) return -1;
            return navigator.geolocation.watchPosition(
              (p) => cb(p.coords.latitude, p.coords.longitude),
              (err) => console.warn("[geo] watch error:", err && err.message),
              { enableHighAccuracy: false, maximumAge: 30000, timeout: 30000 });
          },
          watchStop(id) {
            if (navigator.geolocation && id >= 0) navigator.geolocation.clearWatch(id);
          },
        },
        uint8Array: {
          new(size) { return new Uint8Array(size); },
          fromArrayBuffer(buf) { return new Uint8Array(buf); },
          ref(arr, idx) { return arr[idx]; },
          set(arr, idx, val) { arr[idx] = val; },
          length(arr) { return arr.length; }
        },
        array: {
          length(arr) { return arr.length; },
          ref(arr, idx) { return arr[idx]; },
          refString(arr, idx) { return String(arr[idx]); },
          refF64(arr, idx) { return Number(arr[idx]); }
        },
        h3: {
          latLngToCell(lat, lng, res) {
            return h3.latLngToCell(lat, lng, res);
          },
          getResolution(cell) {
            return h3.getResolution(cell);
          },
          gridDisk(cell, k) {
            return h3.gridDisk(cell, k);
          },
          cellToParent(cell, res) {
            return h3.cellToParent(cell, res);
          },
          cellToLatLng(cell) {
            return h3.cellToLatLng(cell);
          },
          gridDistance(a, b) {
            try { return h3.gridDistance(a, b); }
            catch (_) { return -1; }
          }
        },
        crypto: {
          randomUUID() { return crypto.randomUUID(); },
          randomValues(size) {
            const arr = new Uint8Array(size);
            crypto.getRandomValues(arr);
            return arr;
          },
          async digest(algo, data) {
            const buf = await crypto.subtle.digest(algo, data);
            return new Uint8Array(buf);
          },
          async generateEd25519KeyPair() {
            // extractable:false — see browser/lib/keystore.js. The private half
            // can sign but never becomes bytes; the public half stays
            // extractable (WebCrypto forces that) for the exportKey path.
            return await crypto.subtle.generateKey(
              { name: "Ed25519" }, false, ["sign", "verify"]
            );
          },
          keyPairPublicKey(pair) { return pair.publicKey; },
          keyPairPrivateKey(pair) { return pair.privateKey; },
          async exportKey(key) {
            const buf = await crypto.subtle.exportKey("raw", key);
            return new Uint8Array(buf);
          },
          async verifyEd25519(sig, data, key) {
            return await crypto.subtle.verify(
              { name: "Ed25519" }, key, sig, data
            );
          },
          async importPublicKey(data) {
            return await crypto.subtle.importKey(
              "raw", data, { name: "Ed25519" }, true, ["verify"]
            );
          },
          async signEd25519(data, key) {
            const buf = await crypto.subtle.sign(
              { name: "Ed25519" }, key, data
            );
            return new Uint8Array(buf);
          },
          // Key pair persistence — save is fire-and-forget, load is pre-loaded.
          // The CryptoKeyPair is structured-cloned straight into IndexedDB;
          // nothing is exported, so non-extractable private keys persist
          // across reloads without ever existing as bytes.
          saveKeyPair(name, keyPair) {
            if (!keyPair || typeof keyPair !== 'object') {
              console.warn("saveKeyPair: invalid keyPair for", name);
              return;
            }
            if (!keyPair.publicKey || !keyPair.privateKey) {
              console.warn("saveKeyPair: missing publicKey/privateKey for", name);
              return;
            }
            preloadedKeyPairs[name] = keyPair;
            if (keystore)
              keystore.put(name, keyPair)
                .catch(e => console.warn("saveKeyPair: store failed for", name, e.message));
          },
          getPreloadedKeyPair(name) {
            return preloadedKeyPairs[name] || null;
          },
          hasPreloadedKeyPair(name) {
            return name in preloadedKeyPairs ? 1 : 0;
          },
          deleteKeyPair(name) {
            delete preloadedKeyPairs[name];
            if (keystore) keystore.del(name).catch(() => {});
          }
        },
        // ── KERI sync crypto primitives (browser-resident Signify) ──
        // Backed by browser/lib/keri-crypto.js (noble libs). All sync —
        // Hoot's FFI cannot await Promises, and AID derivation must
        // happen synchronously inside (bran->signing-keypair).
        keri: keriCrypto || {
          // Stubs that error visibly if keri-crypto.js failed to load.
          blake3_256(_) { throw new Error('keri-crypto.js not loaded'); },
          sha256(_) { throw new Error('keri-crypto.js not loaded'); },
          hmac_sha256(_, __) { throw new Error('keri-crypto.js not loaded'); },
          ed25519_from_seed(_) { throw new Error('keri-crypto.js not loaded'); },
          ed25519_sign(_, __) { throw new Error('keri-crypto.js not loaded'); },
          ed25519_verify(_, __, ___) { throw new Error('keri-crypto.js not loaded'); },
          random_bytes(_) { throw new Error('keri-crypto.js not loaded'); },
          u8_length(_) { return 0; },
          u8_ref(_, __) { return 0; },
          kp_pub(_) { throw new Error('keri-crypto.js not loaded'); },
          kp_seed(_) { throw new Error('keri-crypto.js not loaded'); },
        },
        // ── vault: authenticated encryption for at-rest blobs ──────────
        //
        // The crypto lives in browser/lib/vault.js (promise-based, unit-tested
        // in tests/browser/vault-test.mjs). This group only adapts it to
        // the callback shape Hoot's FFI needs — Hoot cannot await, so the
        // await happens here and the result returns through a Scheme
        // callback, the same shape as the WebSocket callbacks below.
        // An empty result means "do not proceed" on both sides, so a
        // failed module load degrades to skipping the backup rather than
        // throwing into Scheme.
        vault: {
          seal(keyBytes, plaintext, cb) {
            if (!vaultMod) { cb(new Uint8Array(0)); return; }
            vaultMod.seal(keyBytes, plaintext).then(cb);
          },
          open(keyBytes, blob, cb) {
            if (!vaultMod) { cb(new Uint8Array(0)); return; }
            vaultMod.open(keyBytes, blob).then(cb);
          },
        },
        webSocket: {
          // OCapN-compatible WebSocket FFI — binary frames (Syrup/CapTP)
          new(url) { return new WebSocket(url); },
          close(ws) { ws.close(); },
          send(ws, data) { ws.send(data); },  // data is Uint8Array from Hoot
          setOnOpen(ws, cb) { ws.addEventListener('open', () => cb()); },
          setOnError(ws, cb) {
            ws.addEventListener('error', () => {
              // Don't call cb() — the WASM bad-cast propagation crashes the runtime.
              // The Scheme-side enliven #:catch handler won't fire, but that's
              // preferable to a cascading RuntimeError when the gateway is down.
              console.warn('OCapN: gateway unreachable');
            });
          },
          setOnMessage(ws, cb) {
            ws.binaryType = 'arraybuffer';
            ws.addEventListener('message', (e) => {
              if (e.data instanceof ArrayBuffer) {
                cb(e.data);
              } else if (e.data instanceof Blob) {
                e.data.arrayBuffer().then(buf => cb(buf));
              } else {
                // Text frame — encode to ArrayBuffer for CapTP
                cb(new TextEncoder().encode(e.data).buffer);
              }
            });
          },
          setOnClose(ws, cb) {
            ws.addEventListener('close', (e) => cb(e.code, e.reason || ""));
          }
        },
        webRTC: {
          // WebRTC FFI — peer-to-peer DataChannel connections between browsers
          createPeerConnection(config) {
            return new RTCPeerConnection(JSON.parse(config));
          },
          createDataChannel(pc, label) {
            return pc.createDataChannel(label, {ordered: true, protocol: 'ocapn'});
          },
          createOffer(pc, cb) {
            pc.createOffer()
              .then(o => pc.setLocalDescription(o).then(() => cb(JSON.stringify(o))));
          },
          createAnswer(pc, cb) {
            pc.createAnswer()
              .then(a => pc.setLocalDescription(a).then(() => cb(JSON.stringify(a))));
          },
          setRemoteDescription(pc, sdp) {
            pc.setRemoteDescription(JSON.parse(sdp));
          },
          addIceCandidate(pc, candidate) {
            pc.addIceCandidate(JSON.parse(candidate));
          },
          onIceCandidate(pc, cb) {
            pc.onicecandidate = e => { if (e.candidate) cb(JSON.stringify(e.candidate)); };
          },
          onDataChannel(pc, cb) {
            pc.ondatachannel = e => cb(e.channel);
          },
          onOpen(dc, cb) { dc.onopen = () => cb(); },
          onMessage(dc, cb) {
            dc.binaryType = 'arraybuffer';
            dc.onmessage = e => cb(e.data);
          },
          onClose(dc, cb) { dc.onclose = () => cb(); },
          send(dc, data) { dc.send(data); },
          close(dc) { dc.close(); },
          closePc(pc) { pc.close(); },
          // ── live PTT audio (the walkie's co-present layer) ────────────
          // One shared mic track, added to each peer's connection; PTT just
          // toggles its `enabled` flag (connection stays up, glare-free).
          // Remote tracks play through one <audio> sink per peer.
          micGet(cb) {           // → 1 on success (track cached), 0 on deny
            navigator.mediaDevices.getUserMedia({ audio: true })
              .then(stream => {
                window.__walkieMic = stream.getAudioTracks()[0];
                window.__walkieMic.enabled = false;   // PTT: silent until held
                cb(1);
              })
              .catch(() => cb(0));
          },
          micEnabled(on) {       // hold-to-talk: open/close the live mic
            if (window.__walkieMic) window.__walkieMic.enabled = !!on;
          },
          addMic(pc) {           // attach the shared mic — idempotent
            const t = window.__walkieMic;
            if (t && !pc.getSenders().some(snd => snd.track === t)) pc.addTrack(t);
          },
          onRemoteAudio(pc, peerId) {   // play whatever the peer sends
            pc.ontrack = e => {
              let el = document.getElementById("walkie-audio-" + peerId);
              if (!el) {
                el = document.createElement("audio");
                el.id = "walkie-audio-" + peerId;
                el.autoplay = true;
                document.body.appendChild(el);
              }
              el.srcObject = e.streams[0];
            };
          },
          dropAudio(peerId) {
            const el = document.getElementById("walkie-audio-" + peerId);
            if (el) el.remove();
          }
        },
        reticulum: {
          // Reticulum identity (from rns-wasm WASM module).
          // Anonymous by default (random from localStorage).
          // loadFromSeed switches to a persona-bound deterministic identity.
          hasIdentity() { return rnsIdentity !== null; },
          destHashHex() { return rnsIdentity ? rnsIdentity.destHashHex() : ""; },
          destHash() { return rnsIdentity ? rnsIdentity.destHash() : new Uint8Array(0); },
          publicKey() { return rnsIdentity ? rnsIdentity.publicKey() : new Uint8Array(0); },
          publicKeyHex() { const pk = rnsIdentity?.publicKey(); return pk ? bytesToHex(pk) : ""; },
          // Build + sign a full announce packet for the bound identity's
          // goblins.ocapn destination, as hex. The gateway verifies it
          // against the persona's KEL-anchored pubkey and relay-announces
          // it on the mesh (browsers can't transmit announces themselves).
          packAnnounceHex() {
            try {
              if (!rnsIdentity) return "";
              const now = BigInt(Math.floor(Date.now() / 1000));
              return bytesToHex(rnsIdentity.packAnnounce(now, undefined));
            } catch (e) {
              console.warn('[reticulum] packAnnounce failed:', e);
              return "";
            }
          },
          // Announce an arbitrary (app, aspect) destination on the bound
          // identity — e.g. ("lxmf", "delivery") for store-and-forward mail.
          packAnnounceHexFor(app, aspect) {
            try {
              if (!rnsIdentity) return "";
              const now = BigInt(Math.floor(Date.now() / 1000));
              return bytesToHex(rnsIdentity.packAnnounceFor(app, aspect, now, undefined));
            } catch (e) {
              console.warn('[reticulum] packAnnounceFor failed:', e);
              return "";
            }
          },
          // The lxmf.delivery destination hash (mail address), hex.
          lxmfDestHashHex() {
            try { return rnsIdentity ? rnsIdentity.lxmfDestHashHex() : ""; }
            catch (_) { return ""; }
          },
          // Decrypt a mesh delivery (hex ciphertext → hex plaintext, ""
          // on failure). Mailbox payloads are encrypted to this identity;
          // only the browser can open them.
          decryptHex(hex) {
            try {
              if (!rnsIdentity || !hex) return "";
              return bytesToHex(rnsIdentity.decrypt(hexToBytes(hex)));
            } catch (e) {
              console.warn('[reticulum] decrypt failed:', e);
              return "";
            }
          },
          // One field of a decrypted LXMF message (source / timestamp /
          // title / content) — parse happens in rns-wasm, JSON here.
          lxmfField(plainHex, name) {
            try {
              if (!rnsIdentity || !plainHex) return "";
              const v = JSON.parse(rnsIdentity.parseLxmf(hexToBytes(plainHex)))[name];
              return v === undefined ? "" : String(v);
            } catch (e) {
              console.warn('[lxmf] parse failed:', e);
              return "";
            }
          },
          // Verify a decrypted LXMF message under the claimed source's
          // 64-byte pubkey (hex) — the binding-verified contact pub.
          lxmfVerifyHex(plainHex, pubHex) {
            try {
              if (!rnsIdentity || !plainHex || !pubHex) return 0;
              return rnsIdentity.verifyLxmf(hexToBytes(plainHex),
                                            hexToBytes(pubHex)) ? 1 : 0;
            } catch (_) { return 0; }
          },
          // Compose an LXMF message to a contact (64-byte pub, hex) and
          // return the complete raw DATA packet, hex — signed and
          // encrypted HERE; the gateway only relays ciphertext.
          lxmfPackPacketHex(destPubHex, title, content) {
            try {
              if (!rnsIdentity || !destPubHex) return "";
              return bytesToHex(rnsIdentity.packLxmfPacket(
                hexToBytes(destPubHex), title, content, Date.now() / 1000));
            } catch (e) {
              console.warn('[lxmf] pack failed:', e);
              return "";
            }
          },
          sign(message) { return rnsIdentity ? rnsIdentity.sign(message) : new Uint8Array(0); },
          verify(signature, message) { return rnsIdentity ? rnsIdentity.verify(signature, message) : false; },
          // (identity encrypt/decrypt intentionally absent — see the note
          // above ret-load-from-seed in repl.scm. decryptHex above is the
          // live path, for inbound mesh messages.)
          loadFromSeed(seed) {
            try {
              const rns = window.__rnsModule;
              if (!rns) { console.warn('[reticulum] rns module not loaded'); return 0; }
              const arr = seed instanceof Uint8Array ? seed : new Uint8Array(seed);
              if (arr.length !== 64) { console.warn('[reticulum] seed must be 64 bytes, got', arr.length); return 0; }
              rnsIdentity = rns.Identity.fromPrivateKey(arr);
              console.log('[reticulum] Bound persona identity:', rnsIdentity.destHashHex());
              return 1;
            } catch (e) { console.error('[reticulum] loadFromSeed failed:', e); return 0; }
          },
          revertToAnonymous() {
            if (anonymousRns) {
              rnsIdentity = anonymousRns;
              console.log('[reticulum] Reverted to anonymous identity:', rnsIdentity.destHashHex());
            }
          },
        },
        map: {
          // MapLibre GL JS bridge. Loaded from CDN in index.html.
          create(container, styleUrl, lng, lat, zoom, globe) {
            if (!window.maplibregl) {
              console.error("[map] maplibre-gl not loaded"); return null;
            }
            const m = new maplibregl.Map({
              container,
              style: styleUrl || "https://basemaps.cartocdn.com/gl/voyager-gl-style/style.json",
              center: [lng, lat], zoom,
              minZoom: 1, maxPitch: 85, attributionControl: false,
              projection: { type: globe ? "globe" : "mercator" }
            });
            m.addControl(new maplibregl.NavigationControl({ visualizePitch: true }), "top-right");
            m.addControl(new maplibregl.FullscreenControl(), "top-right");
            const geo = new maplibregl.GeolocateControl({
              positionOptions: { enableHighAccuracy: true },
              trackUserLocation: true
            });
            m.addControl(geo, "bottom-right");
            // If geolocation is ALREADY granted, find the user without a
            // click — the button stays the consent moment when the state is
            // still "prompt" (auto-prompting on map open would be rude).
            if (navigator.permissions && navigator.permissions.query) {
              navigator.permissions.query({ name: "geolocation" })
                .then(st => {
                  if (st.state !== "granted") return;
                  const go = () => { try { geo.trigger(); } catch (_) {} };
                  if (m.isStyleLoaded && m.isStyleLoaded()) go();
                  else m.once("load", go);
                })
                .catch(() => {});
            }
            // Resize once the style is fully loaded — covers the race
            // where the container is laid out after the constructor runs.
            m.once('load', () => { try { m.resize(); } catch (_) {} });
            return m;
          },
          remove(m) { if (m) m.remove(); },
          resize(m) { if (m) m.resize(); },
          setCenter(m, lng, lat) { m.setCenter([lng, lat]); },
          setZoom(m, z) { m.setZoom(z); },
          setPitch(m, p) { m.setPitch(p); },
          setProjection(m, name) {
            if (!m || typeof m.setProjection !== "function") return;
            const apply = () => {
              try { m.setProjection({ type: name }); } catch (_) {}
            };
            if (m.isStyleLoaded && m.isStyleLoaded()) apply();
            else m.once("load", apply);
          },
          // Markers: caller passes a DOM element built on the Scheme side
          // (via sxml->dom). Returns the marker handle for later removal.
          makeMarker(m, el, lng, lat) {
            return new maplibregl.Marker({ element: el, anchor: 'bottom' })
              .setLngLat([lng, lat]).addTo(m);
          },
          markerRemove(mk) { if (mk) mk.remove(); },
          markerSetLngLat(mk, lng, lat) { mk.setLngLat([lng, lat]); },
          on(m, evt, cb) { if (m) m.on(evt, cb); },
          getZoom(m) { return m ? m.getZoom() : 0; },
          getCenter(m) {
            if (!m) return "";
            const c = m.getCenter(); return c.lat + "," + c.lng;
          },
          fitBounds(m, w, s, e, n, padding) {
            m.fitBounds([[w, s], [e, n]], { padding: padding || 60, duration: 0 });
          },
          // Draw (or replace) a route. `json` is either a bare coords array
          // "[[lng,lat],…]" or a full routing result object — so Scheme can
          // pipe the fetch result straight through without parsing it.
          //
          // Multimodal trips (≥2 travel modes in result.segments) render as
          // a FeatureCollection with per-mode styling: walking legs dashed,
          // transit legs solid in a warm accent — one source, data-driven
          // paint, so mode switches are a setData away. Single-mode trips
          // stay one solid line. Layers are keyed by `id` and reused.
          drawRoute(m, id, json, color, width) {
            if (!m) return;
            let parsed;
            try { parsed = JSON.parse(json); } catch (_) { return; }
            const coords = Array.isArray(parsed) ? parsed : (parsed && parsed.coordinates);
            if (!coords || !coords.length) return;
            const segs = (!Array.isArray(parsed) && parsed.segments) || [];
            const multi = new Set(segs.map(s => s.mode)).size > 1;
            const data = multi
              ? { type: "FeatureCollection",
                  features: segs.map(s => ({
                    type: "Feature", properties: { mode: s.mode },
                    geometry: { type: "LineString", coordinates: s.coordinates } })) }
              : { type: "Feature", properties: { mode: "all" },
                  geometry: { type: "LineString", coordinates: coords } };
            const srcId = "route-" + id;
            const modeColor = ["match", ["get", "mode"],
                               "transit", "#ffb454",
                               color || "#4ea1ff"];
            const draw = () => {
              const src = m.getSource(srcId);
              if (src) { src.setData(data); return; }
              m.addSource(srcId, { type: "geojson", data });
              // casing underneath for contrast on any basemap
              m.addLayer({ id: "route-casing-" + id, type: "line", source: srcId,
                layout: { "line-cap": "round", "line-join": "round" },
                paint: { "line-color": "#0b0f14",
                         "line-width": (width || 5) + 3, "line-opacity": 0.5 } });
              // solid: every mode except walking-within-a-multimodal-trip
              m.addLayer({ id: "route-line-" + id, type: "line", source: srcId,
                filter: ["!=", ["get", "mode"], "pedestrian"],
                layout: { "line-cap": "round", "line-join": "round" },
                paint: { "line-color": modeColor, "line-width": width || 5 } });
              // dashed: the walking stitches of a multimodal trip
              m.addLayer({ id: "route-walk-" + id, type: "line", source: srcId,
                filter: ["==", ["get", "mode"], "pedestrian"],
                layout: { "line-join": "round" },
                paint: { "line-color": color || "#4ea1ff",
                         "line-width": width || 5,
                         "line-dasharray": [0.5, 1.5] } });
            };
            if (m.isStyleLoaded && m.isStyleLoaded()) draw();
            else m.once("load", draw);
          },
          clearRoute(m, id) {
            if (!m) return;
            const ids = ["route-line-" + id, "route-walk-" + id, "route-casing-" + id];
            for (const l of ids) if (m.getLayer(l)) m.removeLayer(l);
            const srcId = "route-" + id;
            if (m.getSource(srcId)) m.removeSource(srcId);
          }
        },
        // Same-origin routing (serve-static /route → local Valhalla). The
        // ── OOBI body fetch (contacts mesh-endpoint resolution) ─────
        // GET url as text; cb(text) on 2xx, cb("") on any failure.
        // Callback-shaped because Hoot's FFI cannot await Promises —
        // same pattern as routing.fetch below.
        oobiFetch: {
          fetchText(url, cb) {
            window.fetch(url)
              .then(r => (r.ok ? r.text() : ""))
              .then(t => cb(t))
              .catch(() => cb(""));
          },
        },
        // server is a thin relay of Valhalla's raw JSON; we parse + decode
        // here (native JSON.parse) and normalise to one stable contract:
        //   { engine, profile, coordinates:[[lng,lat]…],
        //     distance_km, time_s, maneuvers:[{instruction,type,…,begin}] }
        // handed back to Scheme as a JSON string. Offline-safe: if Valhalla
        // returns no trip (or the request fails) we synthesise a straight
        // line through the requested waypoints, so the map always draws.
        routing: {
          // NOTE: reflect.js calls these DETACHED (no `this`) — all shared
          // logic lives at file scope (routeCosting/routeDecode/routeFlatten/
          // routeStraight + the routeTrace* state).
          //
          // "2.3 km · 28 min · walking" (or "straight line" when offline).
          summaryLine(json) {
            let r; try { r = JSON.parse(json); } catch (_) { return ""; }
            if (!r) return "";
            const km = (r.distance_km || 0), s = (r.time_s || 0);
            const dist = km >= 1 ? km.toFixed(1) + " km"
                                 : Math.round(km * 1000) + " m";
            const mins = Math.round(s / 60);
            const time = s ? (mins >= 60 ? Math.floor(mins/60)+" h "+(mins%60)+" min"
                                         : mins + " min") : "";
            const mode = { pedestrian: "walking", bicycle: "cycling", auto: "driving",
                           bus: "bus", multimodal: "transit",
                           foot: "walking", bike: "cycling", car: "driving" }[r.profile]
                         || r.profile || "";
            // a straight line is the crow's path, and says so — the engine
            // has no road data between these points
            if (r.engine === "straight-line")
              return dist + " as the crow flies · no route data here";
            return [dist, time, mode].filter(Boolean).join(" · ");
          },
          // Newline-joined turn list for a directions drawer. On multimodal
          // trips each turn is prefixed with its mode, so the walk→ride→walk
          // rhythm reads at a glance.
          maneuversText(json) {
            let r; try { r = JSON.parse(json); } catch (_) { return ""; }
            if (!r || !r.maneuvers || !r.maneuvers.length) return "";
            const modes = new Set(r.maneuvers.map(m => m.travel_mode));
            const icon = { pedestrian: "🚶", bicycle: "🚲", drive: "🚗", transit: "🚌" };
            return r.maneuvers.map(m => {
              const km = m.distance_km || 0;
              const d = km >= 1 ? "  (" + km.toFixed(1) + " km)"
                      : km > 0 ? "  (" + Math.round(km*1000) + " m)" : "";
              const pre = modes.size > 1 ? (icon[m.travel_mode] || "·") + " " : "";
              return pre + (m.instruction || "") + d;
            }).join("\n");
          },
          // "w,s,e,n" bbox of the route (for fitBounds), or "" if empty.
          bounds(json) {
            let r; try { r = JSON.parse(json); } catch (_) { return ""; }
            const c = r && (Array.isArray(r) ? r : r.coordinates);
            if (!c || !c.length) return "";
            let w=180,s=90,e=-180,n=-90;
            for (const p of c) { if(p[0]<w)w=p[0]; if(p[0]>e)e=p[0];
                                 if(p[1]<s)s=p[1]; if(p[1]>n)n=p[1]; }
            return [w,s,e,n].join(",");
          },
          // Locate the user for a journey origin: cb("lat,lng") on a fix,
          // cb("") on denial/timeout — the caller falls back to map center.
          locate(cb) {
            console.debug("[routing] locate: asked");
            if (!navigator.geolocation) { cb(""); return; }
            navigator.geolocation.getCurrentPosition(
              p => { console.debug("[routing] locate fix:",
                                   p.coords.latitude, p.coords.longitude);
                     cb(p.coords.latitude + "," + p.coords.longitude); },
              e => { console.warn("[routing] locate error:", e && e.message);
                     cb(""); },
              { enableHighAccuracy: false, maximumAge: 60000, timeout: 5000 });
          },
          costingOf(profile) { return routeCosting(profile); },
          // ── trace: how the journey ACTUALLY went ─────────────────────
          // Collected from geolocation during an active journey, matched to
          // the network via the same-origin /trace relay (Valhalla
          // trace_route) on arrival. The matched result uses the SAME
          // normalized contract as fetch — Scheme pipes it to drawRoute.
          traceStart() {
            routeTrace = []; routeTraceT0 = Date.now();
            if (navigator.geolocation)
              routeTraceWatch = navigator.geolocation.watchPosition(
                p => routeTrace && routeTrace.push(
                  { lat: p.coords.latitude, lon: p.coords.longitude }),
                _ => {}, { enableHighAccuracy: true, maximumAge: 5000 });
          },
          traceStop() {
            if (navigator.geolocation && routeTraceWatch >= 0)
              navigator.geolocation.clearWatch(routeTraceWatch);
            routeTraceWatch = -1;
          },
          // minutes since traceStart — the journey's ACTUAL wall-clock
          traceElapsedMin() {
            return routeTraceT0 ? (Date.now() - routeTraceT0) / 60000 : 0;
          },
          traceMatch(profile, cb) {
            const pts = routeTrace || [];
            if (navigator.geolocation && routeTraceWatch >= 0)
              navigator.geolocation.clearWatch(routeTraceWatch);
            routeTraceWatch = -1;
            if (pts.length < 2) { cb(""); return; }
            window.fetch("/trace", {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ shape: pts,
                                     costing: routeCosting(profile),
                                     shape_match: "map_snap",
                                     directions_options: { units: "kilometers" } })
            })
              .then(r => r.ok ? r.text() : Promise.reject(r.status))
              .then(text => {
                let res = null;
                try { res = routeFlatten(JSON.parse(text), profile); } catch (_) {}
                cb(res ? JSON.stringify(res) : "");
              })
              .catch(_ => { cb(""); });
          },
          fetch(fromLat, fromLng, toLat, toLng, profile, via, cb) {
            const q = new URLSearchParams({
              from: fromLat + "," + fromLng,
              to: toLat + "," + toLng,
              profile: routeCosting(profile)
            });
            const wps = [[fromLat, fromLng]];
            if (via) { for (const p of via.split(";")) {
              const [a, b] = p.split(",").map(Number);
              if (!isNaN(a) && !isNaN(b)) wps.push([a, b]);
            } q.set("via", via); }
            wps.push([toLat, toLng]);
            const fallback = () => { console.debug("[routing] straight-line fallback"); cb(routeStraight(wps, profile)); };
            window.fetch("/route?" + q.toString())
              .then(r => r.ok ? r.text() : Promise.reject(r.status))
              .then(text => {
                let result = null;
                try { result = routeFlatten(JSON.parse(text), profile); } catch (_) {}
                console.debug("[routing] /route answered:", result ? "trip" : "no trip");
                if (result) cb(JSON.stringify(result));
                else fallback();
              })
              .catch(err => { console.error("[routing] /route failed", err); fallback(); });
          }
        },
        window: {
          setTimeout(cb, delay) { return setTimeout(cb, delay); },
          setInterval(cb, delay) { return setInterval(cb, delay); },
          clearTimeout(id) { clearTimeout(id); },
          clearInterval(id) { clearInterval(id); },
          // Install a single debounced resize listener; later calls just swap
          // the callback (so re-installs across renders don't stack listeners).
          onResize(cb) {
            const fresh = !window.__playnetResizeCb;
            window.__playnetResizeCb = cb;
            if (!fresh) return;
            let t = null;
            window.addEventListener("resize", () => {
              clearTimeout(t);
              t = setTimeout(() => {
                if (window.__playnetResizeCb) window.__playnetResizeCb();
              }, 120);
            });
          }
        },
        urlParams: {
          get(name) {
            return new URLSearchParams(window.location.search).get(name) || "";
          },
          gatewaySref() {
            // Returns the full sturdyref with the discovered WS URL baked in.
            // If sref is a full override (?gateway= param), return as-is.
            // Otherwise, combine sref + ws from entry-points.json.
            const g = window.__playnetGateway;
            if (!g.ws && g.sref) return g.sref; // ?gateway= override
            if (!g.sref) return "";              // gateway not configured
            const encoded = encodeURIComponent(g.ws);
            return `${g.sref}?url=${encoded}`;
          },
          ucAid() {
            // Returns the Universal Commune AID discovered at page
            // load (from /universal-commune.json), or "" when the
            // endpoint returned 404 / hasn't loaded yet. The Scheme
            // side checks for "" and skips the seed in that case.
            const uc = window.__playnetUcIdentity;
            return (uc && uc.aid) || "";
          },
          ucOobi() {
            const uc = window.__playnetUcIdentity;
            return (uc && uc.oobi) || "";
          }
        },
        location: {
          // Gateway origin — the public base URL the browser reached us at;
          // used as the /loc/scheme endpoint URL for browser-created AIDs.
          getOrigin() { return window.location.origin || ""; },
          getHash() { return window.location.hash || ""; },
          setHash(h) {
            // Avoid triggering hashchange when value is already set.
            if (window.location.hash !== h) {
              try { history.replaceState(null, "", h || window.location.pathname); }
              catch (_) { window.location.hash = h; }
            }
          }
        },
        events: {
          // Read e.target.value (e.g. for <select> change handlers).
          targetValue(e) {
            const t = e && e.target;
            return (t && typeof t.value === "string") ? t.value : "";
          },
          // clientY in viewport coords — used by calendar availability drag.
          clientY(e) { return (e && typeof e.clientY === "number") ? e.clientY : 0; },
          clientX(e) { return (e && typeof e.clientX === "number") ? e.clientX : 0; },
          // PointerEvent id — used by the clock dial to track pinch fingers.
          pointerId(e) { return (e && typeof e.pointerId === "number") ? e.pointerId : 0; },
          // WheelEvent deltaY — clock dial zoom on desktop.
          deltaY(e) { return (e && typeof e.deltaY === "number") ? e.deltaY : 0; }
        },
        ocapn: {
          // OCapN bridge: Scheme registers callbacks here for JS-initiated actions.
          // Speech/transcription flow: JS records audio → calls transcribeCallback → Scheme OCapN → result
          setTranscribeCallback(cb) { window.__playnetTranscribe = cb; },
          setExpressCallback(cb) { window.__playnetExpress = cb; },
          callCallback(cb, str) { if (typeof cb === 'function') cb(str); }
        },
        localStorage: {
          // a blocked or full store reads as empty and keeps the write for the session
          getItem(key) { try { return localStorage.getItem(key); } catch (_) { return null; } },
          setItem(key, value) { try { localStorage.setItem(key, value); } catch (_) {} },
          removeItem(key) { try { localStorage.removeItem(key); } catch (_) {} }
        },
        notifications: {
          requestPermission() {
            if (!('Notification' in window)) return 'denied';
            Notification.requestPermission();
            return Notification.permission;
          },
          hasPermission() {
            return ('Notification' in window) ? Notification.permission : 'denied';
          },
          show(title, body, tag, url) {
            if (!('Notification' in window) || Notification.permission !== 'granted') return;
            const n = new Notification(title, {
              body, icon: '/icon-192.png', tag: tag || undefined
            });
            n.onclick = () => {
              window.focus();
              if (url) window.location.hash = url;
              n.close();
            };
          },
          isPageVisible() {
            return document.visibilityState === 'visible' ? 1 : 0;
          },
          subscribePush(vapidPublicKeyB64, onResult) {
            (async () => {
              try {
                const reg = await navigator.serviceWorker.ready;
                const key = Uint8Array.from(
                  atob(vapidPublicKeyB64.replace(/-/g,'+').replace(/_/g,'/')),
                  c => c.charCodeAt(0));
                const sub = await reg.pushManager.subscribe({
                  userVisibleOnly: true, applicationServerKey: key
                });
                onResult(JSON.stringify(sub.toJSON()));
              } catch (e) { console.error('[push]', e); onResult(''); }
            })();
          },
          getSubscription(onResult) {
            (async () => {
              try {
                const reg = await navigator.serviceWorker.ready;
                const sub = await reg.pushManager.getSubscription();
                onResult(sub ? JSON.stringify(sub.toJSON()) : '');
              } catch (e) { onResult(''); }
            })();
          }
        },
        visibility: {
          onVisibilityChange(cb) {
            document.addEventListener('visibilitychange', () => {
              cb(document.visibilityState === 'visible' ? 1 : 0);
            });
          },
          onOnline(cb) {
            window.addEventListener('online', () => cb());
          }
        },
        clipboard: {
          writeText(text) {
            try {
              if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text);
              } else {
                // Fallback: temporary textarea + execCommand.
                const ta = document.createElement('textarea');
                ta.value = text;
                ta.style.position = 'fixed'; ta.style.opacity = '0';
                document.body.appendChild(ta);
                ta.select();
                try { document.execCommand('copy'); } catch (_) {}
                document.body.removeChild(ta);
              }
            } catch (e) { console.warn('[clipboard]', e); }
          }
        },
        terminal: {
          create(container) {
            if (typeof Terminal === 'undefined') {
              console.error('[term] xterm.js not loaded');
              return null;
            }
            const term = new Terminal({
              theme: { background: '#110e13', foreground: '#e0ceed',
                       cursor: '#a8e6cf', selectionBackground: '#2a2230' },
              fontFamily: 'monospace', fontSize: 13,
              cursorBlink: true
            });
            const fit = new FitAddon.FitAddon();
            term.loadAddon(fit);
            term.open(container);
            fit.fit();
            return { term, fit };
          },
          onData(termObj, callback) {
            if (termObj) termObj.term.onData(data => callback(data));
          },
          write(termObj, data) {
            if (termObj) termObj.term.write(data);
          },
          getCols(termObj) { return termObj ? termObj.term.cols : 80; },
          getRows(termObj) { return termObj ? termObj.term.rows : 24; },
          dispose(termObj) { if (termObj) termObj.term.dispose(); },
          fit(termObj) { if (termObj) termObj.fit.fit(); }
        },
        speech: {
          isSupported() { return 1; },
          async startListening(onResult, onEnd) {
            try {
              const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
              const recorder = new MediaRecorder(stream, { mimeType: 'audio/webm;codecs=opus' });
              const chunks = [];

              recorder.ondataavailable = (e) => { if (e.data.size > 0) chunks.push(e.data); };
              recorder.onstop = async () => {
                stream.getTracks().forEach(t => t.stop());
                const blob = new Blob(chunks, { type: 'audio/webm' });

                // Decode webm → 16 kHz mono PCM once. We may use it for both
                // OCapN (re-encoded as WAV) and the local Whisper fallback.
                let pcm = null;
                try {
                  const audioCtx = new AudioContext({ sampleRate: 16000 });
                  const decoded = await audioCtx.decodeAudioData(await blob.arrayBuffer());
                  pcm = decoded.getChannelData(0).slice();
                  audioCtx.close();
                } catch (e) {
                  console.error('[speech] decode error:', e);
                  onEnd();
                  return;
                }

                let finished = false;
                const finish = (text) => {
                  if (finished) return;
                  finished = true;
                  onResult(text || '');
                  onEnd();
                };

                const runLocalWhisper = async () => {
                  try {
                    // Send a copy so we keep `pcm` available locally
                    // (the worker call transfers the underlying buffer).
                    const text = await transcribeWithWhisper(pcm.slice());
                    return text || '';
                  } catch (e) {
                    console.error('[speech] Local Whisper error:', e);
                    return '';
                  }
                };

                const handleTranscript = async (transcript) => {
                  let text = (transcript || '').trim();
                  if (!text) {
                    console.log('[speech] OCapN returned empty — falling back to local Whisper');
                    text = await runLocalWhisper();
                  }
                  if (window.__speechExpressMode) {
                    const expressFn = window.__playnetExpress;
                    if (expressFn && text) {
                      expressFn(text, (expr) => finish(expr || text));
                    } else {
                      finish(text);
                    }
                  } else {
                    finish(text);
                  }
                };

                const transcribeFn = window.__playnetTranscribe;
                if (transcribeFn) {
                  console.log('[speech] Sending WAV to OCapN gateway for transcription...');
                  const wavBuf = encodeWav(pcm, 16000);
                  const wavB64 = bufferToBase64(wavBuf);
                  // Safety net: if Scheme never calls back, fall back after 30s.
                  const watchdog = setTimeout(async () => {
                    if (!finished) {
                      console.warn('[speech] OCapN timeout — local Whisper fallback');
                      await handleTranscript('');
                    }
                  }, 30000);
                  try {
                    transcribeFn(wavB64, (result) => {
                      clearTimeout(watchdog);
                      handleTranscript(result);
                    });
                  } catch (e) {
                    clearTimeout(watchdog);
                    console.error('[speech] OCapN call threw:', e);
                    handleTranscript('');
                  }
                } else {
                  console.log('[speech] No OCapN gateway — local Whisper');
                  handleTranscript('');
                }
              };

              recorder.start();
              window.__playnetRecording = { recorder, stream };
            } catch (e) {
              console.error('[speech] Mic error:', e);
              onEnd();
            }
          },
          stopListening() {
            if (window.__playnetRecording) {
              window.__playnetRecording.recorder.stop();
              window.__playnetRecording = null;
            }
          },
          setExpressMode(mode) {
            window.__speechExpressMode = (mode === 1);
          },
          // Express natural language → Scheme via OCapN callback
          expressNL(text, onResult) {
            const expressFn = window.__playnetExpress;
            if (expressFn) {
              expressFn(text, (expr) => { onResult(expr || ""); });
            } else {
              onResult("");
            }
          }
        }
      }
    });

    // Page is now interactive — warm up Whisper in the background.
    scheduleWhisperPreload();
  } catch(e) {
    console.error("WASM load error:", e);
    if (e && e.tag !== undefined) {
      console.error("  trap tag:", e.tag);
      console.error("  trap data:", e.data);
      try { console.error("  data json:", JSON.stringify(e.data)); } catch(_) {}
    }
    if(e instanceof WebAssembly.CompileError) {
      document.getElementById("wasm-error").hidden = false;
    }
  }
});
