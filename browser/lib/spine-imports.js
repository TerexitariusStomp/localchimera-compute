// SPDX-License-Identifier: AGPL-3.0-or-later
// browser/lib/spine-imports.js — the spine's thread-agnostic FFI groups
//
// The Hoot/Goblins spine (day-boot.wasm) talks to JS through named import
// groups. The ones here need nothing of the page — no DOM, no window, no
// WebAuthn, no media — so the same objects serve the spine whether it runs
// in a Web Worker (browser/spine-worker.js, the default) or on the page
// (day-boot.js with ?spine=main). What DOES need the page — the seam's
// sinks, WebRTC, the device key — stays in day-boot.js and is bridged.
//
// `pureImports(ctx)` returns the groups; `ctx` supplies what differs by
// thread: a storage door (`ls`), the page's origin/search/hash, the
// gateway sturdyref the page resolved, and a trace sink.

import { maxPeers } from "../app/voice/mesh-plan.js";
import { toHex as bytesToHex } from "../app/bytes.js";

// the gateway socket the spine opened last — the reconnect proof severs it
// from outside the spine (tests/reconnect-live-ux.mjs) and watches it recover
let lastWs = null;
/** Sever the spine's live gateway socket, as a network drop would. */
export function severGateway() { if (lastWs) lastWs.close(); }

/** The libraries the spine needs before the wasm loads: noble-backed KERI
 *  crypto, the IndexedDB keystore
 *  for org keypairs, and rns-wasm for the mesh identity. Each is optional —
 *  a failure is logged and the spine boots without that door. */
export async function loadLibs(ctx) {
  const out = { keri: null, keystore: null, preloadedKeyPairs: {}, rns: null, rnsIdentity: null };
  ctx.trace("importing keri-crypto");
  try {
    out.keri = (await import("./keri-crypto.js")).keri;
  } catch (e) { console.warn("[day-boot] keri-crypto.js failed to load:", e); }
  try {
    out.keystore = await import("./keystore.js");
    // the one-time move off localStorage runs where localStorage exists (the
    // page); a worker reads the IndexedDB store the page already migrated
    if (typeof localStorage !== "undefined") await out.keystore.migrateLegacy();
    out.preloadedKeyPairs = await out.keystore.getAll();
  } catch (e) { console.warn("[day-boot] keystore unavailable:", e && e.message); }
  // Reticulum mesh identity (rns-wasm) — anonymous from storage until
  // unlock/signup binds the persona-derived one
  ctx.trace("importing rns-wasm");
  try {
    const rns = await import("../rns_wasm.js");
    ctx.trace("rns imported, init");
    await rns.default();
    ctx.trace("rns ready");
    out.rns = rns;
    // held sealed at rest (lib/rns-identity.js)
    const { meshIdentity } = await import("./rns-identity.js");
    out.rnsIdentity = await meshIdentity(rns, ctx.ls);
  } catch (e) {
    console.warn("[day-boot] rns-wasm unavailable — no mesh identity:", e && e.message);
  }
  return out;
}

/** Normalize the gateway sturdyref the page discovered into the one string
 *  the spine parses, or "" to stand alone. Pure: runs on the page, and the
 *  result travels to wherever the spine runs. */
export function normalizeGatewaySref(g, trace) {
  let s = "";
  if (!g.ws && g.sref) s = g.sref;
  else if (g.sref) s = `${g.sref}?url=${encodeURIComponent(g.ws)}`;
  // a URL never legitimately contains raw whitespace; strip any that a
  // copy/line-wrap injected (e.g. a giant ?gateway= param split mid-escape
  // into "%3  A"), which would otherwise mangle the ws url.
  s = s.replace(/\s+/g, "");
  // normalize: the on-disk sref may carry a RAW inner ws URL (…?url=ws://…)
  // which the ocapn id parser cannot read — re-encode it the way
  // entry-points + repl.js always have. A dev gateway also records its BIND
  // address; browsers cannot connect to 0.0.0.0, so rewrite it to loopback.
  const m = s.match(/^(.*?\?url=)(.*)$/);
  if (m && /:\/\//.test(m[2])) s = m[1] + encodeURIComponent(m[2]);
  // an sref with NO routable ws anywhere (a stale ?gateway= param, a 503'd
  // entry-points) would crash uri->ocapn-peer inside the wasm (string-length
  // of #f) — refuse it here and let the dial stand alone rather than take
  // the spine down with it.
  if (!/\?url=/.test(s)) {
    if (s) trace("gw: sref has no ws url — staying standalone");
    return "";
  }
  s = s.replace(/0\.0\.0\.0/g, "127.0.0.1");
  trace("gw: computed sref=" + JSON.stringify(s));
  return s;
}

/** The import groups. CTX: { ls, trace, search, origin, getHash, setHash,
 *  gatewaySref, libs } where LIBS is loadLibs' result. */
export function pureImports(ctx) {
  const { ls, trace, libs } = ctx;
  let rnsIdentity = libs.rnsIdentity;
  const preloadedKeyPairs = libs.preloadedKeyPairs;
  const keystore = libs.keystore;
  return {
    // the KEL: the controller's own log, kept by the browser that wrote it
    // (K.idKel, ordered JSON) — the vat reads and writes it through
    // these three doors
    // `ls` is the page's guarded store (app/store.ts pageStore) or, in the
    // spine worker, its mirror of it; neither throws
    localStorage: {
      getItem(k) { return ls.getItem(k); },
      setItem(k, v) { ls.setItem(k, v); },
      removeItem(k) { ls.removeItem(k); },
    },
    urlParams: {
      get(name) { return new URLSearchParams(ctx.search).get(name) || ""; },
      gatewaySref() { return ctx.gatewaySref; },
    },
    location: {
      getOrigin() { return ctx.origin; },
      getHash() { return ctx.getHash(); },
      setHash(h) { ctx.setHash(h); },
    },
    // how many peers a room's mesh may hold: the page's video budget names it
    // (app/voice/mesh-plan.ts), the spine only reads it
    mesh: {
      maxPeers() { return maxPeers; },
    },
    reticulum: {
      hasIdentity() { return rnsIdentity !== null ? 1 : 0; },
      destHashHex() { return rnsIdentity ? rnsIdentity.destHashHex() : ""; },
      publicKeyHex() {
        const pk = rnsIdentity && rnsIdentity.publicKey();
        return pk ? bytesToHex(pk) : "";
      },
      lxmfDestHashHex() {
        try { return rnsIdentity ? rnsIdentity.lxmfDestHashHex() : ""; }
        catch (_) { return ""; }
      },
      // seal TEXT to another identity's 64-byte public bundle (hex): only its
      // holder opens it. "" when the crate or the key is not to hand.
      sealTextFor(destPubHex, text) {
        try {
          const rns = libs.rns;
          if (!(rns && rns.Identity && rns.Identity.sealFor)) return "";
          const pub = Uint8Array.from(destPubHex.match(/.{2}/g) || [], h => parseInt(h, 16));
          return bytesToHex(rns.Identity.sealFor(pub, new TextEncoder().encode(text)));
        } catch (e) { console.warn("[day-boot] sealTextFor:", e); return ""; }
      },
      // open what was sealed to THIS identity, as text; "" when it does not open
      openText(hex) {
        try {
          if (!rnsIdentity) return "";
          const ct = Uint8Array.from(hex.match(/.{2}/g) || [], h => parseInt(h, 16));
          return new TextDecoder().decode(rnsIdentity.decrypt(ct));
        } catch (_) { return ""; }
      },
      loadFromSeed(seed) {
        try {
          const rns = libs.rns;
          if (!rns) return 0;
          const arr = seed instanceof Uint8Array ? seed : new Uint8Array(seed);
          if (arr.length !== 64) return 0;
          rnsIdentity = rns.Identity.fromPrivateKey(arr);
          console.log("[day-boot] mesh identity bound:", rnsIdentity.destHashHex());
          return 1;
        } catch (e) { console.warn("[day-boot] loadFromSeed:", e); return 0; }
      },
    },
    keri: libs.keri || {},
    webSocket: {
      new(url) {
        trace("ws: new(" + JSON.stringify(url) + ")");
        const ws = new WebSocket(url);
        lastWs = ws;
        return ws;
      },
      close(ws) { trace("ws: close() by the spine"); ws.close(); },
      send(ws, data) { ws.send(data); },
      setOnOpen(ws, cb) { ws.addEventListener("open", () => cb()); },
      setOnError(ws, cb) {
        ws.addEventListener("error", () =>
          console.warn("[day-boot] gateway websocket error"));
      },
      setOnMessage(ws, cb) {
        ws.binaryType = "arraybuffer";
        ws.addEventListener("message", (e) => {
          if (e.data instanceof ArrayBuffer) cb(e.data);
          else if (e.data instanceof Blob) e.data.arrayBuffer().then(cb);
          else cb(new TextEncoder().encode(e.data).buffer);
        });
      },
      setOnClose(ws, cb) {
        ws.addEventListener("close", (e) => {
          trace("ws: closed code=" + e.code + (e.reason ? " reason=" + e.reason : "") + (e.wasClean ? " clean" : " unclean"));
          cb(e.code, e.reason || "");
        });
      },
    },
    time: {
      now() { return Date.now(); },
      isoNow() { return new Date().toISOString().replace("Z", "000+00:00"); },
      epochSeconds() { return String(Math.floor(Date.now() / 1000)); },
    },
    crypto: {
      // full WebCrypto group — the CapTP session layer needs Ed25519
      randomUUID() { return crypto.randomUUID(); },
      randomValues(size) {
        const a = new Uint8Array(size); crypto.getRandomValues(a); return a;
      },
      async digest(algo, data) {
        const buf = await crypto.subtle.digest(algo, data);
        return new Uint8Array(buf);
      },
      async generateEd25519KeyPair() {
        // extractable:false — the private half can be USED to sign but never
        // exported to bytes, so an XSS cannot steal the identity. WebCrypto
        // always marks the public half extractable regardless, which is what
        // the exportKey path below relies on.
        return await crypto.subtle.generateKey(
          { name: "Ed25519" }, false, ["sign", "verify"]);
      },
      keyPairPublicKey(pair) { return pair.publicKey; },
      keyPairPrivateKey(pair) { return pair.privateKey; },
      async exportKey(key) {
        const buf = await crypto.subtle.exportKey("raw", key);
        return new Uint8Array(buf);
      },
      async verifyEd25519(sig, data, key) {
        return await crypto.subtle.verify({ name: "Ed25519" }, key, sig, data);
      },
      async importPublicKey(data) {
        return await crypto.subtle.importKey(
          "raw", data, { name: "Ed25519" }, true, ["verify"]);
      },
      async signEd25519(data, key) {
        const buf = await crypto.subtle.sign({ name: "Ed25519" }, key, data);
        return new Uint8Array(buf);
      },
      // Persist the CryptoKeyPair itself (structured-cloned into IndexedDB).
      // Nothing is ever exported, so a non-extractable private key survives a
      // reload without becoming bytes.
      saveKeyPair(name, keyPair) {
        if (!keyPair || !keyPair.publicKey || !keyPair.privateKey) return;
        preloadedKeyPairs[name] = keyPair;
        if (keystore) keystore.put(name, keyPair).catch(() => {});
      },
      getPreloadedKeyPair(name) { return preloadedKeyPairs[name] || null; },
      hasPreloadedKeyPair(name) { return name in preloadedKeyPairs ? 1 : 0; },
      deleteKeyPair(name) {
        delete preloadedKeyPairs[name];
        if (keystore) keystore.del(name).catch(() => {});
      },
    },
    uint8Array: {
      new(size) { return new Uint8Array(size); },
      fromArrayBuffer(buf) { return new Uint8Array(buf); },
      ref(arr, i) { return arr[i]; },
      set(arr, i, v) { arr[i] = v; },
      length(arr) { return arr.length; },
    },
  };
}

/** The seam sinks the spine pushes into, by name — the bridge forwards these
 *  from the worker to the page's implementations. From the protocol seam table. */
export { SEAM_SINKS } from "../app/seam-wire.js";

/** The WebRTC doors, by name — every one bridged to the page; `newPc` is the
 *  only one that answers a value (an opaque handle). */
export const RTC_DOORS = [
  "setIce", "newPc", "micGet", "micEnabled", "addMic", "camGet", "camStop", "addCam",
  "screenGet", "screenStop", "replaceVideo", "peerVideo", "onRemoteMedia", "dropMedia",
  "dropAllMedia", "onIce", "addIce", "offer", "answer", "setRemote", "closePc",
];
