// browser/day-boot.js — boots the app's capability spine (day-boot.wasm)
//
// app.html is the shell; this script gives it the vat: gateway CapTP,
// KERI unlock/authenticate, lobby transcribe + ai-complete. It fills the
// seam's handlers (app/seam.js, imported — the same object the app holds)
// and adds a small sign-in chip to the header. An ES module, so it runs
// after reflect.js (a classic script, which defines the Scheme global) and
// after the app's own modules; standalone, with no reflect.js, the app
// keeps its local fallbacks — by design.

import { seam, seamSinks } from "./app/seam.js";
import { on } from "./app/bus.js";
import { keyed } from "./app/outbox.js";
import { readStr, writeStr, forget, pageStore } from "./app/store.js";
import { K } from "./app/keys.js";
import { provideMic } from "./app/voice/mic.js";
import { videoPlan } from "./app/voice/mesh-plan.js";
import { check as checkCapabilities, showNotice } from "./lib/capabilities.js";

// ── the page's probes: what a headless test reaches by importing this module ──
// The walkie's media door (built in boot, below): getUserMedia, replaceTrack
// and the tile grid are unreachable from the page otherwise, and they are
// exactly the parts no Scheme test can reach (tests/walkie-ux.mjs).
export let walkieRTC = null;
// The reconnect proof (tests/reconnect-live-ux.mjs) severs the gateway
// socket from outside the spine and watches it recover.
export const probe = { closeWs() {} };

function boot() {
  if (typeof Scheme === "undefined") {
    console.log("[day-boot] reflect.js not present — standalone mode");
    return;
  }

  // A browser whose engine lacks a feature the wasm needs cannot compile it.
  // Say so (lib/capabilities.js asks the engine, so the answer follows the
  // browser) and leave the page on the demo day, which is what the app does
  // without a spine.
  const caps = checkCapabilities();
  if (!caps.ok) {
    console.warn("[day-boot] engine lacks:", caps.missing.map(m => m.id).join(", "));
    showNotice({ missing: caps.missing });
    return;
  }

  // breadcrumbs for headless debugging: every status/error lands in a
  // hidden trace element (visible to --dump-dom) as well as the console
  const trace = (() => {
    const el = document.createElement("div");
    el.id = "bootTrace"; el.style.display = "none";
    document.body.appendChild(el);
    return (s) => { el.textContent += s + " | "; console.log("[day-boot]", s); };
  })();
  window.addEventListener("error", e => trace("JS-ERROR: " + e.message));
  window.addEventListener("unhandledrejection",
    e => trace("REJECTION: " + (e.reason && e.reason.message || e.reason)));

  // ── the seam: mutate (never replace) the imported object ──
  const HANDLERS = seam.handlers;
  const schemeHandlers = {};   // name → externalized Scheme procedure

  // ── the call stage: a floating, draggable video surface ───────────
  // Parented to <body> ON PURPOSE, never to a face.
  //
  // The chat panel rewrites its own innerHTML on every render
  // (app/tabs/chat.js), and joining flips the walkie signals — which
  // triggers exactly that render. A tile grid parented inside the panel was
  // therefore destroyed the instant after it was created: you joined, the
  // camera light came on, and no video ever appeared. Switching faces would
  // have torn it down too.
  //
  // On <body> the stage outlives every re-render and every face switch, and
  // minimise/maximise are CLASSES, never an unmount — so the tracks keep
  // flowing and the call survives whatever the rest of the app is doing.
  let stageDrag = null;

  function walkieStage() {
    let st = document.getElementById("dial-stage");
    if (st) return st;
    st = document.createElement("div");
    st.id = "dial-stage";
    st.innerHTML =
      '<div class="stagebar">'
      + '<span class="stagetitle">◉ live</span>'
      + '<span class="stagebtns">'
      + '<span class="stagebtn" data-act="min" title="minimise — the call keeps running">–</span>'
      + '<span class="stagebtn" data-act="max" title="fill the view">⛶</span>'
      + '</span></div>'
      + '<div id="dial-tiles"></div>';
    document.body.appendChild(st);

    const bar = st.querySelector(".stagebar");

    // One delegated handler for the bar: a button flips its own state, and a
    // click anywhere else on a minimised bar brings the call back. Minimise
    // and maximise are pure CLASS flips — nothing unmounts, so no track is
    // ever renegotiated to change how big the box is.
    bar.onclick = (e) => {
      const act = e.target.closest(".stagebtn")?.dataset.act;
      if (!act) { st.classList.remove("min"); return; }
      st.classList.toggle(act === "min" ? "min" : "max");
      st.classList.remove(act === "min" ? "max" : "min");
      // a maximised box drops any dragged offset so it lands where its CSS
      // says, rather than half off-screen
      if (st.classList.contains("max")) { st.style.left = ""; st.style.top = ""; }
    };

    // drag by the bar, clamped to the viewport so it can never be lost
    bar.addEventListener("pointerdown", (e) => {
      if (e.target.classList.contains("stagebtn")) return;
      if (st.classList.contains("max")) return;
      const r = st.getBoundingClientRect();
      stageDrag = { dx: e.clientX - r.left, dy: e.clientY - r.top };
      st.classList.add("dragging");
      bar.setPointerCapture(e.pointerId);
    });
    bar.addEventListener("pointermove", (e) => {
      if (!stageDrag) return;
      const w = st.offsetWidth, h = st.offsetHeight;
      const x = Math.max(0, Math.min(innerWidth - w, e.clientX - stageDrag.dx));
      const y = Math.max(0, Math.min(innerHeight - h, e.clientY - stageDrag.dy));
      st.style.left = x + "px"; st.style.top = y + "px";
      st.style.right = "auto"; st.style.bottom = "auto";
    });
    const endDrag = (e) => {
      if (!stageDrag) return;
      stageDrag = null; st.classList.remove("dragging");
      try { bar.releasePointerCapture(e.pointerId); } catch (_) {}
    };
    bar.addEventListener("pointerup", endDrag);
    bar.addEventListener("pointercancel", endDrag);
    return st;
  }

  // how many are on the stage, shown in the bar (and readable when minimised)
  function walkieStageCount() {
    const st = document.getElementById("dial-stage");
    if (!st) return;
    const n = st.querySelectorAll(".wktile").length;
    if (!n) { st.remove(); return; }       // no video on the call: no floating box either
    const t = st.querySelector(".stagetitle");
    if (t) t.textContent = "◉ live · " + n;
  }

  // One tile per participant. Created on demand by whichever side arrives
  // first: the local camera, or a remote track. Self is always first.
  function walkieTile(peerId, label) {
    const grid = walkieStage().querySelector("#dial-tiles");
    let vid = document.getElementById("dial-tile-" + peerId);
    if (!vid) {
      const cell = document.createElement("div");
      cell.className = "wktile";
      cell.id = "dial-cell-" + peerId;
      vid = document.createElement("video");
      vid.id = "dial-tile-" + peerId;
      vid.autoplay = true; vid.playsInline = true;
      const tag = document.createElement("span");
      tag.className = "wktag"; tag.textContent = label || peerId;
      cell.appendChild(vid); cell.appendChild(tag);
      if (peerId === "self") grid.prepend(cell); else grid.appendChild(cell);
      walkieStageCount();
    }
    return vid;
  }

  function walkieDropTile(peerId) {
    const t = document.getElementById("dial-tile-" + peerId);
    if (t && t.parentNode) t.parentNode.remove();
    walkieStageCount();
  }

  // What WE show of ourselves: the screen while sharing, else the camera, else
  // nothing. The tile exists exactly while there is something in it.
  function walkieSelf(track) {
    if (!track) { walkieDropTile("self"); return; }
    const self = walkieTile("self", "you");
    self.srcObject = new MediaStream([track]);
    self.muted = true;                      // never hear yourself
  }

  // A peer's tile exists while it says it is sending video AND its stream has
  // arrived — whichever lands first waits for the other. The peer's own word
  // decides (the walkie-cam signal), because a receiver's mute events do not
  // say dependably when a sender goes quiet.
  const peerStreams = new Map();      // peerId → the remote video stream
  const peerVideoOn = new Map();      // peerId → the peer says it is sending video
  function walkieShowPeer(peerId) {
    const stream = peerStreams.get(peerId);
    if (peerVideoOn.get(peerId) && stream)
      walkieTile(peerId, peerId.slice(0, 8)).srcObject = stream;
    else walkieDropTile(peerId);
  }

  // ── dominant speaker ──────────────────────────────────────────────
  // Purely local: a Web Audio analyser per remote stream, polled on a slow
  // interval, marks the loudest tile. Nothing is sent, nothing renegotiates
  // — with a mesh at its ≤6 ceiling every stream is already arriving, so
  // this is a display decision, not a bandwidth one.
  // ONE AudioContext for the whole room, an analyser node per peer. Browsers
  // cap concurrent contexts at around six, and the mesh ceiling is five peers
  // plus the transcriber's own — a context each would sit exactly on that
  // limit rather than under it.
  const walkieLevels = new Map();     // peerId → {node, analyser, buf}
  let walkieLevelCtx = null, walkieLevelTimer = null, walkieLoud = null;

  function walkieWatchLevel(peerId, stream) {
    try {
      const Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx) return;
      walkieUnwatchLevel(peerId);       // a re-offer must not orphan the old node
      walkieLevelCtx = walkieLevelCtx || new Ctx();
      const analyser = walkieLevelCtx.createAnalyser();
      analyser.fftSize = 256;
      const node = walkieLevelCtx.createMediaStreamSource(stream);
      node.connect(analyser);
      walkieLevels.set(peerId,
        { node, analyser, buf: new Uint8Array(analyser.frequencyBinCount) });
      if (!walkieLevelTimer) walkieLevelTimer = setInterval(walkieMarkLoudest, 400);
    } catch (_) { /* no analyser → no highlight, everything else still works */ }
  }

  function walkieMarkLoudest() {
    let best = null, bestLevel = 8;        // a floor, so silence highlights nobody
    walkieLevels.forEach((l, peerId) => {
      l.analyser.getByteFrequencyData(l.buf);
      let sum = 0;
      for (let i = 0; i < l.buf.length; i++) sum += l.buf[i];
      const avg = sum / l.buf.length;
      if (avg > bestLevel) { bestLevel = avg; best = peerId; }
    });
    if (best === walkieLoud) return;       // the common case: nobody swapped
    const prev = document.getElementById("dial-cell-" + walkieLoud);
    if (prev) prev.classList.remove("loud");
    const cell = best && document.getElementById("dial-cell-" + best);
    if (cell) cell.classList.add("loud");
    walkieLoud = best;
  }

  function walkieUnwatchLevel(peerId) {
    const l = walkieLevels.get(peerId);
    if (!l) return;
    try { l.node.disconnect(); } catch (_) {}
    walkieLevels.delete(peerId);
    if (walkieLoud === peerId) walkieLoud = null;
    if (!walkieLevels.size) walkieStopLevels();
  }

  function walkieStopLevels() {
    if (walkieLevelTimer) { clearInterval(walkieLevelTimer); walkieLevelTimer = null; }
    if (walkieLevelCtx) { try { walkieLevelCtx.close(); } catch (_) {} walkieLevelCtx = null; }
    walkieLoud = null;
  }

  function walkieUnwatchAll() {
    walkieLevels.forEach(l => { try { l.node.disconnect(); } catch (_) {} });
    walkieLevels.clear();
    walkieStopLevels();
  }

  // ── gateway discovery (same sources as repl.js, no probing) ──
  // tries the page's own directory FIRST so app.html works wherever
  // browser/ is mounted (repo root via Live Server, deployed at /, …)
  async function discoverGateway() {
    const param = new URLSearchParams(window.location.search).get("gateway");
    if (param) { trace("gw: raw param=" + JSON.stringify(param)); return { sref: param, ws: "" }; }
    for (const url of ["entry-points.json", "/entry-points.json"]) {
      try {
        const resp = await fetch(url);
        // 503 is serve-static's "sref not yet written": a gateway exists here
        // and is booting (it drops the previous process's address at start
        // and writes its own at the end, ~3 minutes in). That is an address
        // to come back for — the reconnect path re-asks — where a 404 is a
        // page served with no gateway at all.
        if (resp.status === 503) return { sref: "", ws: "", booting: true };
        if (!resp.ok) continue;
        const data = await resp.json();
        const sref = data.sref || "";
        const eps = (data.gateway || []).slice();
        // The server may name the ws outright. It does that when this page was
        // served on loopback — local dev, where nothing proxies /ws on the
        // page's own origin, so the "self" guess below would be wrong. The
        // address comes from the sref the gateway itself just wrote, so it is
        // current by construction: `make dev` needs no ?gateway= splice.
        if (typeof data.directWs === "string" && data.directWs) {
          trace("gw: server named the ws directly: " + data.directWs);
          return { sref, ws: data.directWs };
        }
        if (/^https?:$/.test(window.location.protocol)) {
          const wsProto = window.location.protocol === "https:" ? "wss:" : "ws:";
          eps.unshift({ name: "self", ws: `${wsProto}//${window.location.host}/ws` });
        }
        if (sref && eps.length) return { sref, ws: eps[0].ws };
        return { sref, ws: "" };
      } catch (_) { /* try the next location */ }
    }
    return { sref: "", ws: "" };
  }

  // ── the sign-in chip, injected into the header ──
  // ONLY for shells that carry no identity row of their own. A page with
  // #idrow owns the identity UX (app/tabs/id.js: the settings sheet, the
  // location chip beside it, sign-out), and this fallback must never appear
  // there — it used to be created on the first frame and removed only once
  // the spine reported `status`, so a spine that never booted left an
  // unwired chip sitting in the header where the real one belongs.
  const pageOwnsIdentity = () => !!document.getElementById("idrow");
  function chip() {
    let el = document.getElementById("whoami");
    if (!el && !pageOwnsIdentity()) {
      el = document.createElement("span");
      el.id = "whoami";
      el.style.cssText =
        "font-family: Inter, system-ui, sans-serif; font-size: 11.5px;" +
        "color: #2c4a6e; border: 1px solid #c9d2dd; border-radius: 12px;" +
        "padding: 2px 10px; cursor: pointer; white-space: nowrap;";
      const top = document.getElementById("top");
      if (top) top.appendChild(el);
    }
    return el;
  }
  function hintParts() {
    const hint = readStr(K.idHint);
    if (!hint) return null;
    const [aid, name, email, k0] = hint.split("|");
    return { aid, name, email, k0: k0 || "" };
  }
  let authed = false;
  let deviceAutoTried = false;
  let reconnectTimer = null, reconnectDelay = 0;
  let connectWatchdog = null;   // "connecting" with no answer → unreachable (status handler)
  function renderChip(state) {
    const el = chip(), h = hintParts();
    if (!el) return;                       // the page owns identity — nothing to render
    if (!h) {
      el.textContent = state === "offline" ? "offline" : "○ create your identity";
      el.style.opacity = state === "offline" ? 0.6 : 1;
      return;
    }
    el.style.opacity = 1;
    el.textContent =
      state === "authed"   ? `● ${h.name}` :
      state === "busy"     ? `… ${h.name}` :
      state === "offline"  ? `${h.name} (offline)` :
                             `○ ${h.name} — sign in`;
  }
  function wireChip() {
    const c = chip();
    if (!c) return;
    c.onclick = async () => {
      if (authed) return;
      const h = hintParts();
      if (h) {                                  // unlock
        if (!schemeHandlers.unlock) return;
        const bran = prompt(`passcode for ${h.name} (21+ characters):`);
        if (!bran) return;
        renderChip("busy");
        const result = await new Promise(res =>
          schemeHandlers.unlock(bran, h.aid, h.k0, res));
        if (result.startsWith("ok:")) { authed = true; renderChip("authed"); }
        else if (result.startsWith("local:")) { renderChip("offline"); }
        else if (result.startsWith("unregistered:")) { renderChip("idle"); }
        else { renderChip("idle"); alert(result.replace(/^err:/, "")); }
      } else {                                  // signup
        if (!schemeHandlers.signup) return;
        const name = prompt("choose a name:"); if (!name) return;
        const email = prompt("email:"); if (!email) return;
        const bran = prompt("choose a passcode (21+ characters — it IS the key; lose it, lose the identity):");
        if (!bran) return;
        renderChip("busy");
        const result = await new Promise(res =>
          schemeHandlers.signup(name, email, bran, res));
        if (result.startsWith("ok:")) {
          const [aid, k0] = result.slice(3).split("|");
          writeStr(K.idHint, `${aid}|${name}|${email}|${k0}`);
          authed = true; renderChip("authed");
        } else { renderChip("idle"); alert(result.replace(/^err:/, "")); }
      }
    };
  }

  // ── boot ──
  async function main() {
    trace("main");
    renderChip("offline");                    // visible from the first frame
    const gw = await discoverGateway();
    trace("gw: " + (gw.sref ? "sref ok, ws=" + (gw.ws || "(in sref)") : "none"));
    if (!gw.sref && !gw.booting) {
      // no commune to reach — the spine boots all the same: an identity is
      // made and unlocked against the log this device keeps, with no gateway
      // in the loop (the service worker serves the cached day with the
      // network gone), and takes its seat at a commune when one appears
      console.log("[day-boot] no gateway configured — the app stands alone; identity is local");
      const c = chip();
      if (c) c.title = "no gateway here — serve browser/ (make serve) or open the deployed /app.html";
    }

    // ── the page's side of the spine ──────────────────────────────────
    // What the vat needs of the PAGE: the seam's sinks, WebRTC, the device
    // key (WebAuthn + the keystore door). Everything else it needs — the
    // websocket, WebCrypto, noble, rns-wasm, storage, the clock — is thread-
    // agnostic and lives in lib/spine-imports.js. By default the vat runs in
    // a Worker (spine-worker.js) and these three are bridged; ?spine=main
    // runs it on the page with the same objects passed straight in.
    // the device's own signing key (browser/lib/device-key.js) — the hot
    // key a cold passcode authorizes once; docs/planning/device-keys.md.
    // `deviceLoaded` is the key in hand after device.load; the vat signs
    // through it and never sees its bytes.
    let deviceKey = null, deviceLoaded = null;
    // in worker mode the vat's copy of the device's public key is filled here
    // (a key made on the page must reach the vat before enrolDevice asks for it)
    let announceDevicePub = null;
    try { deviceKey = await import("./lib/device-key.js"); }
    catch (e) { console.warn("[day-boot] device-key unavailable:", e.message); }
    const { loadLibs, pureImports, normalizeGatewaySref, severGateway } = await import("./lib/spine-imports.js");
    const gatewaySref = normalizeGatewaySref(gw, trace);
    // the address the vat is currently on: a reconnect compares the one it
    // re-reads against this and hands a changed one to the vat (setGateway)
    let currentSref = gatewaySref;
    const WORKER = new URLSearchParams(window.location.search).get("spine") !== "main"
                   && typeof Worker !== "undefined";

    // the seam's sinks: what the wasm calls, by the names it imports. The
    // wired ones come built from the protocol seam table (app/seam.js: parse,
    // keep under seam.data, raise the push); the page adds its plumbing and
    // the side effects the status sink carries here.
    // A sturdyref is a gateway PROCESS's: its swiss-num is minted when that
    // process registers and dies with it. So before every reconnect the
    // address is read again from the same source as at load — a gateway
    // restarted since then (every deploy) has a new one, and a page loaded
    // while it was booting had none. A changed address goes to the vat as
    // setGateway (it re-enlivens on it); an unchanged one is a reconnect.
    async function reconnectWithFreshAddress() {
      let next = currentSref;
      try { next = normalizeGatewaySref(await discoverGateway(), trace); } catch (_) {}
      if (next && next !== currentSref && schemeHandlers.setGateway) {
        currentSref = next;
        trace("gw: address changed — enlivening on the new one");
        schemeHandlers.setGateway(next, r => trace("setGateway → " + r));
      } else if (schemeHandlers.reconnect) {
        schemeHandlers.reconnect(r => trace("reconnect → " + r));
      }
    }
    // loaded while the gateway was booting: keep asking, with the same
    // backoff a lost connection gets, until it has an address to give
    if (!gatewaySref && gw.booting) {
      let wait = 0;
      const ask = async () => {
        if (currentSref) return;
        wait = Math.min(30000, wait ? wait * 2 : 2000);
        try { currentSref = normalizeGatewaySref(await discoverGateway(), trace); } catch (_) {}
        if (currentSref && schemeHandlers.setGateway) {
          trace("gw: the gateway finished booting — enlivening");
          schemeHandlers.setGateway(currentSref, r => trace("setGateway → " + r));
        } else setTimeout(ask, wait);
      };
      trace("gw: gateway is booting — asking again in a moment");
      setTimeout(ask, 2000);
    }

    const pageSinks = {
      ...seamSinks,

      // A DIAGNOSTIC from the spine: it lands in the trace and nowhere
      // else. `status` below is the DOOR — every string on it is read by
      // the page's identity state machine (app/tabs/social/id.ts) as a
      // door state, and anything it does not recognise means "shut". A
      // progress note such as "seat:roster 7" on that channel showed
      // "the commune is unreachable" over a seat that had just been
      // taken (found live), which is why the two are separate sinks.
      trace(s) { trace(s); },

      setScope(sid) { seam.scope = sid; },

      status(s) {
        trace("status: " + s);
        // "connecting" that nothing answers: a socket that fails to OPEN
        // (the gateway's first seconds after a restart, nothing listening
        // yet) closes with no lobby ref to sever, so the spine's enliven
        // stays pending and no status ever follows — the page sat on
        // "connecting" for good (restart-heal probe, 2026-09-23). The
        // watchdog turns that silence into the unreachable status, which
        // takes the same backoff-and-re-read path as any other failure.
        if (connectWatchdog) { clearTimeout(connectWatchdog); connectWatchdog = null; }
        if (s === "connecting") {
          connectWatchdog = setTimeout(() => {
            connectWatchdog = null;
            trace("connecting: no answer in 20s — treating as unreachable");
            pageSinks.status("error:gateway unreachable");
          }, 20000);
        }
        // the connection went, or never came: ask the spine again, with
        // backoff; a seat follows the enliven on its own
        if (s === "connected") { reconnectDelay = 0; if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; } }
        else if (/^error:gateway (disconnected|unreachable)/.test(s) && !reconnectTimer) {
          reconnectDelay = Math.min(30000, reconnectDelay ? reconnectDelay * 2 : 2000);
          trace("reconnect in " + reconnectDelay + "ms");
          reconnectTimer = setTimeout(async () => {
            reconnectTimer = null;
            await reconnectWithFreshAddress();
          }, reconnectDelay);
        }
        seamSinks.status(s);
        // the page owns the identity UX when it provides #idrow — the chip
        // is only the fallback for older shells, retired when it does
        const pageOwns = !!document.getElementById("idrow");
        if (pageOwns) { const c = document.getElementById("whoami"); if (c) c.remove(); }
        if (s === "connected") {
          if (!pageOwns) { renderChip("idle"); wireChip(); }
          // a device key here signs in on its own: the passcode stays
          // cold. The page hears the outcome through deviceUnlock (a
          // refusal is its call — a revoked device forgets its key).
          if (!deviceAutoTried && deviceKey && deviceKey.hasRecord()
              && readStr(K.deviceWire) && schemeHandlers.unlockDevice) {
            deviceAutoTried = true;
            trace("device unlock");
            schemeHandlers.unlockDevice(r => {
              trace("device unlock → " + r);
              seam.deviceUnlock(r);
            });
          }
          // headless end-to-end proof: ?autotest=name:email:bran runs
          // the full signup → auth → snapshot chain and traces it
          const at = new URLSearchParams(window.location.search).get("autotest");
          if (at && schemeHandlers.signup) {
            const [n, e, b] = at.split(":");
            trace("autotest signup " + n);
            schemeHandlers.signup(n, e, b, r => trace("signup → " + r));
          }
        }
        else if (!pageOwns && (s === "no-gateway" || s.startsWith("error:")))
          renderChip("offline");
      },
    };
    // breadcrumbs for the two big pushes, where a headless run reads them
    on("ingest", (snap) => trace("snapshot: " + ((snap && snap.commitments) || []).length + " commitments, "
                                 + ((snap && snap.intents) || []).length + " intents"));
    on("contacts", (cs) => trace("contacts: " + (cs || []).length));

    // WebRTC for the app's live walkie — see the notes on each door below.
        // peer connections negotiated over the lobby signal relay, with the
        // local tracks added at pc-creation so nothing ever renegotiates.
        //
        // That no-renegotiation rule shapes the whole media model:
        //   • every pc gets a mic sender AND a video sender before its first
        //     offer, whether or not a camera is on — the sender is what lets
        //     the camera come and go, and lets an audio-only joiner see the
        //     room;
        //   • muting is `track.enabled`;
        //   • the camera goes off by STOPPING its track (the light goes out)
        //     and the sender is emptied with replaceTrack(null); on again is
        //     a fresh capture replaceTrack'd back in;
        //   • screen share is `sender.replaceTrack` onto the same sender,
        //     which by spec needs no new offer as long as the kind matches.
        // Exported above as walkieRTC for the headless media test.
    let micTrack = null, camTrack = null, screenTrack = null;
    // The servers a call finds its peers through. The gateway's `ice-servers` door
    // is the one place that names them; the spine reads it when a room is joined and
    // hands it here (setIce) before any peer connection exists.
    let iceServers = [];
    // The peer connections of the room we are in. Each carries a video sender, so
    // their count is how many copies of our video go out; the plan (mesh-plan.ts)
    // says what each may use, and every change of the count or of a sender
    // reshapes them all to it.
    const live = new Set();
    const shape = (pc) => {
      const tr = pc.getTransceivers().find(x => x.receiver.track.kind === "video");
      if (!tr) return;
      const plan = videoPlan(live.size);
      const p = tr.sender.getParameters();
      if (!p.encodings || !p.encodings.length) p.encodings = [{}];
      p.encodings[0].maxBitrate = plan.maxBitrate;
      p.encodings[0].scaleResolutionDownBy = plan.scaleDown;
      // a sender not yet negotiated refuses; it is shaped again when it is
      tr.sender.setParameters(p).catch(() => {});
    };
    const reshape = () => { for (const pc of live) shape(pc); };
    walkieRTC = {
      /** The local tracks in hand, for the test's eyes. */
      tracks() { return { mic: micTrack, cam: camTrack, screen: screenTrack }; },
      /** The gateway's list of ICE servers, as the JSON array its door replies. */
      setIce(json) {
        try { const l = JSON.parse(json); iceServers = Array.isArray(l) ? l : []; }
        catch (_) { iceServers = []; }
      },
      newPc() {
        const pc = new RTCPeerConnection({ iceServers });
        live.add(pc);
        reshape();
        return pc;
      },
      micGet(cb) {
        navigator.mediaDevices.getUserMedia({ audio: true })
          .then(st => { micTrack = st.getAudioTracks()[0];
                        micTrack.enabled = false; provideMic(micTrack); cb(1); })
          .catch(() => cb(0));
      },
      micEnabled(on) { if (micTrack) micTrack.enabled = !!on; },
      addMic(pc) {
        const t = micTrack;
        if (t && !pc.getSenders().some(s => s.track === t)) pc.addTrack(t);
      },

      // ── camera ──────────────────────────────────────────────────
      // Acquired at join when the caller asked for video, so it rides
      // the initial offer. Starts enabled: you joined with a camera.
      camGet(cb) {
        navigator.mediaDevices.getUserMedia(
          { video: { width: { ideal: 640 }, height: { ideal: 360 } } })
          .then(st => {
            camTrack = st.getVideoTracks()[0];
            walkieSelf(screenTrack || camTrack);
            cb(1);
          })
          .catch(() => cb(0));
      },
      // Off is a real stop: the capture ends and the light goes out. The
      // caller then points the senders at what is left (replaceVideo).
      camStop() {
        const t = camTrack;
        if (t) { try { t.stop(); } catch (_) {} camTrack = null; }
        walkieSelf(screenTrack);
      },
      hasCam() { return camTrack ? 1 : 0; },
      // The OFFERER's video sender, with the camera in it when one is on.
      // Present from the first offer, empty or not. The answerer adds nothing:
      // it adopts the offer's own video transceiver (setRemote, below) — a
      // second one added first would sit beside it, unnegotiated, and the
      // answerer's video would never reach the caller.
      addCam(pc) {
        if (pc.getTransceivers().some(x => x.receiver.track.kind === "video")) return;
        pc.addTransceiver(camTrack || "video", { direction: "sendrecv" });
        shape(pc);
      },

      // ── screen share, via replaceTrack (no renegotiation) ────────
      screenGet(cb) {
        if (!navigator.mediaDevices.getDisplayMedia) { cb(0); return; }
        navigator.mediaDevices.getDisplayMedia({ video: true })
          .then(st => {
            screenTrack = st.getVideoTracks()[0];
            // the user can stop the share from the browser's own chrome
            screenTrack.onended = () => {
              seam.screenEnded();
            };
            walkieSelf(screenTrack);
            cb(1);
          })
          .catch(() => cb(0));
      },
      screenStop() {
        const t = screenTrack;
        if (t) { try { t.stop(); } catch (_) {} screenTrack = null; }
        walkieSelf(camTrack);
      },
      // Point this pc's video sender at the screen track, or at the camera —
      // or at nothing when the camera is off. The sender stays either way, so
      // no new offer is needed.
      replaceVideo(pc, useScreen) {
        const want = (useScreen ? screenTrack : camTrack) || null;
        const tr = pc.getTransceivers().find(x => x.receiver.track.kind === "video");
        if (tr) { try { tr.sender.replaceTrack(want); } catch (_) {} }
      },
      // A peer's word on whether it is sending video (the walkie-cam signal).
      peerVideo(peerId, on) { peerVideoOn.set(peerId, !!on); walkieShowPeer(peerId); },

      // ── remote media ────────────────────────────────────────────
      // One element per peer per kind. Audio stays a bare <audio> off in
      // the corner; video lands in the tile grid the dial styles.
      onRemoteMedia(pc, peerId) {
        pc.ontrack = e => {
          // addTrack() is called WITHOUT a stream (walkie-equip! adds bare
          // tracks), so the remote event carries an empty `streams` array.
          // Wrapping the track is what actually gives the element
          // something to play — reading e.streams[0] alone yields
          // undefined and renders silence.
          const stream = e.streams[0] || new MediaStream([e.track]);
          if (e.track.kind === "audio") {
            let el = document.getElementById("dial-audio-" + peerId);
            if (!el) { el = document.createElement("audio");
              el.id = "dial-audio-" + peerId; el.autoplay = true;
              document.body.appendChild(el); }
            el.srcObject = stream;
            walkieWatchLevel(peerId, stream);
          } else {
            peerStreams.set(peerId, stream);
            walkieShowPeer(peerId);
          }
        };
      },
      dropMedia(peerId) {
        const a = document.getElementById("dial-audio-" + peerId);
        if (a) a.remove();
        peerStreams.delete(peerId); peerVideoOn.delete(peerId);
        walkieDropTile(peerId);
        walkieUnwatchLevel(peerId);
      },
      // Tear the whole media surface down on leave — the stage goes with
      // it, so leaving a room leaves no floating box behind.
      dropAllMedia() {
        document.querySelectorAll("[id^=dial-audio-]").forEach(e => e.remove());
        const st = document.getElementById("dial-stage");
        if (st) st.remove();
        walkieUnwatchAll();
        peerStreams.clear(); peerVideoOn.clear();
        for (const t of [camTrack, screenTrack]) if (t) { try { t.stop(); } catch (_) {} }
        camTrack = screenTrack = null;
      },
      onIce(pc, cb) {
        pc.onicecandidate = e => { if (e.candidate) cb(JSON.stringify(e.candidate)); };
      },
      addIce(pc, j) { try { pc.addIceCandidate(JSON.parse(j)); } catch (_) {} },
      offer(pc, cb) {
        pc.createOffer().then(o => pc.setLocalDescription(o)
          .then(() => { shape(pc); cb(JSON.stringify(o)); }));
      },
      answer(pc, cb) {
        // after the remote offer is applied and its video transceiver adopted
        (pc.remoteApplied || Promise.resolve())
          .then(() => pc.createAnswer())
          .then(a => pc.setLocalDescription(a).then(() => { shape(pc); cb(JSON.stringify(a)); }));
      },
      setRemote(pc, j) {
        const desc = JSON.parse(j);
        const applied = pc.setRemoteDescription(desc).then(() => {
          if (desc.type !== "offer") return;
          // take the offer's video transceiver as our own sender: we send
          // video too (the camera if one is on, else an empty sender that a
          // later camera fills)
          const tr = pc.getTransceivers().find(x => x.receiver.track.kind === "video");
          if (tr) { tr.direction = "sendrecv"; if (camTrack) tr.sender.replaceTrack(camTrack); shape(pc); }
        });
        pc.remoteApplied = applied;
        return applied;
      },
      closePc(pc) { try { pc.close(); } catch (_) {} live.delete(pc); reshape(); },
    };

    // the device key, for the vat: load (a touch on the hardware tier),
    // the public half as bytes, and sign-with-callback
    const deviceMain = {
      load(cb) {
        if (!deviceKey) return cb("err:no device-key module");
        deviceKey.load().then(k => { deviceLoaded = k; cb("ok:" + k.tier); },
                              e => cb("err:" + (e && e.message ? e.message : e)));
      },
      pub() { return deviceLoaded ? deviceLoaded.pub : new Uint8Array(0); },
      // a failure answers with an EMPTY value of the same kind (never
      // null): the vat reads lengths, and an extern-null test on what
      // Hoot hands over as a plain string or bytevector would throw
      sign(bytes, cb) {
        if (!deviceLoaded) return cb(new Uint8Array(0));
        deviceLoaded.sign(bytes).then(sig => cb(sig), () => cb(new Uint8Array(0)));
      },
      // small secrets the persona needs on this device, sealed under the
      // device's own seal key (the mesh identity seed)
      seal(bytes, cb) {
        if (!deviceLoaded) return cb("");
        deviceLoaded.seal(bytes).then(blob => cb(blob), () => cb(""));
      },
      open(blob, cb) {
        if (!deviceLoaded) return cb(new Uint8Array(0));
        deviceLoaded.open(blob).then(bytes => cb(bytes), () => cb(new Uint8Array(0)));
      },
    };

    if (WORKER) {
      // ── the vat in a Worker: a typed bridge, handles for what cannot cross ──
      const w = new Worker("spine-worker.js");
      w.onerror = (e) => {
        trace("spine worker error: " + (e && e.message || e) + " @" + (e && e.filename || "") + ":" + (e && e.lineno || ""));
        // a dead spine answers every open call at once, so nothing on the
        // page waits forever on a promise the worker can no longer keep
        for (const [, res] of replies) res("err:spine down");
        replies.clear();
        pageSinks.status("error:spine down");
      };
      const replies = new Map();       // call id → resolver
      const pcs = new Map();           // pc handle id → RTCPeerConnection
      let nextCall = 1;
      const unpack = (a) => {
        if (a && typeof a === "object" && "pc" in a) return pcs.get(a.pc);
        if (a && typeof a === "object" && "cb" in a) return (...args) => w.postMessage({ t: "cb", id: a.cb, args });
        return a;
      };
      w.onmessage = (e) => {
        const m = e.data;
        switch (m.t) {
          case "trace": trace(m.s); break;
          case "handler":
            schemeHandlers[m.name] = (...args) => {
              const res = args.pop();
              const id = nextCall++;
              replies.set(id, res);
              w.postMessage({ t: "call", id, name: m.name, args });
            };
            break;
          case "ret": { const r = replies.get(m.id); replies.delete(m.id); if (r) r(m.value); break; }
          case "seam": { const f = pageSinks[m.fn]; if (f) f(...m.args); break; }
          case "ls": if (m.op === "set") writeStr(m.k, m.v); else forget(m.k); break;
          case "hash": window.location.hash = m.h; break;
          case "rtc": {
            const door = walkieRTC[m.fn];
            if (!door) break;
            if (m.fn === "newPc") { pcs.set(m.pcId, door()); break; }
            if (m.fn === "closePc") { const pc = unpack(m.args[0]); if (pc) door(pc); for (const [k, v] of pcs) if (v === pc) pcs.delete(k); break; }
            door(...m.args.map(unpack));
            break;
          }
          case "device": {
            const reply = (value) => w.postMessage({ t: "devret", id: m.id, value });
            if (m.fn === "load") deviceMain.load((status) => reply({ status, pub: deviceLoaded ? deviceLoaded.pub : new Uint8Array(0) }));
            else deviceMain[m.fn](...m.args, reply);
            break;
          }
          case "loaded": trace("wasm loaded"); break;
          case "failed": trace("spine failed: " + m.err); showNotice({ failed: m.err }); break;
        }
      };
      window.addEventListener("hashchange", () => w.postMessage({ t: "hash", h: window.location.hash }));
      announceDevicePub = (pub) => w.postMessage({ t: "devpub", pub });
      probe.closeWs = () => w.postMessage({ t: "debug", op: "closeWs" });
      const ls = {};
      try { for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); ls[k] = localStorage.getItem(k); } } catch (_) {}
      w.postMessage({ t: "init", gatewaySref, search: window.location.search,
                      origin: window.location.origin, hash: window.location.hash, ls });
    } else {
      const libs = await loadLibs({ trace, ls: pageStore });
      trace("libs ready, loading wasm");
      const pure = pureImports({
        ls: pageStore, trace, libs, gatewaySref,
        search: window.location.search, origin: window.location.origin,
        getHash: () => window.location.hash, setHash: (h) => { window.location.hash = h; },
      });
      await Scheme.load_main("day-boot.wasm", {
        user_imports: {
          ...pure,
          seam: { ...pageSinks,
                  setHandler(name, fn) { schemeHandlers[name] = fn; },
                  callCallback(cb, s) { cb(s); } },
          webRTC: walkieRTC,
          device: deviceMain,
        },
      });
      trace("wasm loaded");
      probe.closeWs = severGateway;
    }

    // ── fill the seam: promise-shaped handlers over the Scheme spine ──
    //
    // `bridge` states a spine handler's ARITY once, here, and builds the
    // promise wrapper from it: the argument list is padded with "" and
    // truncated to N before the resolver goes on the end. Load-bearing —
    // procedure->external is arity-strict, so a caller that passes four
    // arguments to a nine-argument handler otherwise lands its resolver in a
    // data slot and the call dies inside the vat. Every handler whose spine
    // signature can grow (the slot and position families below) goes through
    // it. Handlers whose arguments need shaping (booleans, defaults) keep
    // their own wrapper and say so.
    const bridge = (name, arity, fallback = "err:offline") => (...args) =>
      new Promise(res => {
        const fn = schemeHandlers[name];
        if (!fn) return res(fallback);
        // the arguments as strings, padded and cut to the arity, and the act's token minted
        // once where the door is keyed (ui/app/keyed-doors.ts): the one place the page's
        // writes to the spine pass, so no face mints a token of its own
        const a = keyed(name, Array.from({ length: arity }, (_, i) => args[i])).slice(0, arity);
        fn(...a, res);
      });
    HANDLERS.transcribe = (wavB64) =>
      new Promise(res => schemeHandlers.transcribe
        ? schemeHandlers.transcribe(wavB64, res) : res(""));
    HANDLERS.ai = (system, user, model) =>
      new Promise(res => schemeHandlers.ai
        ? schemeHandlers.ai(system, user, model, res) : res(""));
    // the orb's exact-plan read: a wire-safe STRING summary of the current
    // plan (satisfaction, social ledger, loudest pulls, certificate). The orb
    // narrates it as ground truth instead of guessing over the snapshot.
    HANDLERS.solve = (overridesJson) =>
      new Promise(res => schemeHandlers.solve
        ? schemeHandlers.solve(overridesJson || "{}", res) : res(""));
    // the handshake outbound: accepting a proposal on the dial accepts
    // the Intent in the plan (acting-as = the signed-in AID); the
    // refreshed snapshot returns it as a commitment. Page calls these
    // positionally: (scope, intentId) → Promise<"ok" | "err:…">
    HANDLERS.commit = (scope, intentId) =>
      new Promise(res => schemeHandlers.commit
        ? schemeHandlers.commit(scope || "", intentId || "", res)
        : res("err:offline"));
    HANDLERS.decline = (scope, intentId) =>
      new Promise(res => schemeHandlers.decline
        ? schemeHandlers.decline(scope || "", intentId || "", res)
        : res("err:offline"));
    // a directed work offer's accept — the bounded rung's gated door
    // (accept-work-offer: the accepting worker is the PROVIDER)
    HANDLERS.acceptWorkOffer = (scope, proposalId) =>
      new Promise(res => schemeHandlers.acceptWorkOffer
        ? schemeHandlers.acceptWorkOffer(scope || "", proposalId || "", res)
        : res("err:offline"));
    // the offer-side opt-in: willing("yes") raises your hand for the
    // (skill, cell) — an option, not a bind; willing("no") withdraws /
    // declines the standing. Resolves "ok" | "err:…".
    HANDLERS.willing = (scope, spec, cell, willing) =>
      new Promise(res => schemeHandlers.willing
        ? schemeHandlers.willing(scope || "", spec || "", cell || "",
                                 willing ? "yes" : "no", res)
        : res("err:offline"));
    // leaving a thing in a shared container, and taking one out — the VF
    // pickup/dropoff pair (planner service `drop-event`). Resolves the id of
    // the resource touched, or "err:…". A fresh snapshot follows the write, so
    // the map redraws from the ledger rather than from the click.
    // …the last argument is the CLAIM: "mine" when the person leaving a new
    // thing holds the rights to it, "" when nobody does (the default — leaving
    // something is not how anyone comes to own it).
    HANDLERS.dropEvent = bridge("dropEvent", 7);
    // the captain's log — per-AID document sync, the same local-first +
    // server-backup shape as the contact book: log("sync", json) → "ok",
    // log("list", "") → the stored JSON string ("" when none).
    HANDLERS.log = bridge("log", 2);
    // the pin book — map lists: pins("sync", json) → "ok", pins("list", "")
    // → the stored JSON string; pins("ourLists", "") / pins("ourPins", id)
    // → the commune's shared lists / one list's members, as JSON
    HANDLERS.pins = bridge("pins", 2);
    // …and its observe path: a log suggestion becomes a self-scoped
    // EconomicEvent on the scope's observer (planner `log-observe`).
    // (action, spec, qty, unit, note, whenIso) → "ok:<event-id>" | "err:…"
    HANDLERS.logObserve = bridge("logObserve", 6);
    // a count of a stock the books hold: the difference from the ledger
    // lands on that stock (planner `count-stock`).
    // (resource, counted, unit, technique, place, whenIso, fulfills,
    //  evidence, note) → JSON {event, record, hours, delta, onhand} | "err:…"
    HANDLERS.countStock = bridge("countStock", 9);
    // the code a stock is known by, for its label, and what a code names
    // (resource) → JSON {code, id, name};  (code) → JSON {resource, contents}
    HANDLERS.labelStock = bridge("labelStock", 1);
    HANDLERS.countHistory = bridge("countHistory", 2);
    HANDLERS.scopeReplica = bridge("scopeReplica", 0, "");
    HANDLERS.contests = bridge("contests", 0, "");
    HANDLERS.attachEvidence = bridge("attachEvidence", 3);
    HANDLERS.contestEvidence = bridge("contestEvidence", 1, "");
    HANDLERS.readLabel = bridge("readLabel", 1);
    // the schedule of counts, and laying the due ones as offers
    // (regime) → JSON {rows};  (regime, counter, atMost) → JSON {laid, due, refused?}
    HANDLERS.countSchedule = bridge("countSchedule", 1);
    HANDLERS.planCounts = bridge("planCounts", 3);
    // a picture, read at the seat: one to four base64 JPEGs of one thing cross
    // joined by newlines, and the spine sends each on in parts
    // (images, system, user, fulfills) → the model's text | "" | "err:…"
    HANDLERS.see = (images, system, user, fulfills) =>
      new Promise(res => schemeHandlers.see
        ? schemeHandlers.see((images || []).join("\n"), system || "", user || "", fulfills || "", res)
        : res(""));
    // the week's unplanned photo reads → JSON {remaining, perWeek, opens, sees}
    HANDLERS.allotment = bridge("allotment", 0);
    // retag a contact (writes the rel into the synced contact book; the
    // gateway re-pushes the updated list to seam.data.contacts).
    // The tag is the person's own label; a vouch is its own act (fpVouch).
    HANDLERS.setContactRel = bridge("setContactRel", 2);
    HANDLERS.contactForget = bridge("contactForget", 1);
    HANDLERS.contactCheck = bridge("contactCheck", 1);
    // contact points told to this commune; the clock stamp is the credential's
    // issued-at (SAID material), since Hoot is clock-free
    HANDLERS.reachPresent = (kind, value) =>
      new Promise(res => schemeHandlers.reachPresent
        ? schemeHandlers.reachPresent(kind || "", value || "", new Date().toISOString(), res)
        : res("err:offline"));
    HANDLERS.reachConfirm = bridge("reachConfirm", 3);
    HANDLERS.reachWithdraw = bridge("reachWithdraw", 2);
    HANDLERS.reachRead = bridge("reachRead", 0);
    // this device's browser notifications (ui/app/push.ts)
    HANDLERS.pushKey = bridge("pushKey", 0);
    HANDLERS.pushRegister = bridge("pushRegister", 2);
    HANDLERS.pushUnregister = bridge("pushUnregister", 1);
    // a card for one contact: CONTENT is the JSON text sealed to them
    HANDLERS.cardGive = (aid, content) =>
      new Promise(res => schemeHandlers.cardGive
        ? schemeHandlers.cardGive(aid || "", content || "", new Date().toISOString(), res)
        : res("err:offline"));
    HANDLERS.cardWithdraw = bridge("cardWithdraw", 1);
    // the clock stamp is the book's added-at, since Hoot is clock-free
    HANDLERS.contactConnect = (aid, alias, oobi, myName) =>
      new Promise(res => schemeHandlers.contactConnect
        ? schemeHandlers.contactConnect(aid || "", alias || "", oobi || "", myName || "", String(Date.now()), res)
        : res("err:offline"));
    // read the book again; the answer arrives as the contacts push
    HANDLERS.contactsRefresh = bridge("contactsRefresh", 0);
    // publish the current spine as this AID's taxonomy cut (the edit-republish
    // arm of the loop). `wire` is the parser-free T/E flattening from main.js.
    HANDLERS.publishSpine = (wire) =>
      new Promise(res => schemeHandlers.publishSpine
        ? schemeHandlers.publishSpine(wire || "", res)
        : res("err:offline"));
    // swing the folksonomy lens: "social" → the commons/UC cut, "individual" →
    // your own (the dial's individual⇄social toggle; folksonomy.md Phase 4).
    HANDLERS.taxonomyLens = (name) =>
      new Promise(res => schemeHandlers.taxonomyLens
        ? schemeHandlers.taxonomyLens(name || "", res)
        : res("err:offline"));
    // adopt the currently-viewed cut as your own published taxonomy (the loop).
    HANDLERS.adoptCut = () =>
      new Promise(res => schemeHandlers.adoptCut
        ? schemeHandlers.adoptCut(res)
        : res("err:offline"));
    // the navcard's go/arrive → VF records: phase "begin" mints the
    // commitment + pickup event, "end" the fulfilling dropoff. Resolves
    // "ok:<commitment-id>" — the dial threads it back on arrival.
    HANDLERS.journey = (phase, from, to, mode, cid) =>
      new Promise(res => schemeHandlers.journey
        ? schemeHandlers.journey(phase || "begin", from || "", to || "",
                                 mode || "pedestrian", cid || "", res)
        : res("err:offline"));
    // topic chat: op "post" (body) | "history" (→ JSON array string).
    // Strata are stamped server-side; the dial filters read-side.
    HANDLERS.chat = (op, topic, body, kind) =>
      new Promise(res => schemeHandlers.chat
        ? schemeHandlers.chat(op || "history", topic || "", body || "",
                              kind || "", res)
        : res("err:offline"));
    // the wake: every live room + who is in it + the last thing said there,
    // as one JSON array. Cheap enough to poll (text and counts, no media).
    HANDLERS.wake = bridge("wake", 0);
    // live walkie: op "join" | "leave" | "talk" (arg "on"/"off")
    HANDLERS.walkie = (op, arg) =>
      new Promise(res => schemeHandlers.walkie
        ? schemeHandlers.walkie(op || "join", arg || "", res)
        : res("err:offline"));
    // identity, for the page-owned sign-in (the bran passes through to
    // the vat and is never stored anywhere)
    HANDLERS.unlock = (bran, aid, k0) =>
      new Promise(res => schemeHandlers.unlock
        ? schemeHandlers.unlock(bran, aid, k0 || "", res)
        : res("err:offline"));
    HANDLERS.signup = (name, email, bran) =>
      new Promise(res => schemeHandlers.signup
        ? schemeHandlers.signup(name, email, bran, res)
        : res("err:offline"));
    // the log in hand takes a seat at a commune that never saw it
    HANDLERS.join = (name, email) =>
      new Promise(res => schemeHandlers.join
        ? schemeHandlers.join(name || "", email || "", res)
        : res("err:offline"));
    // recovery friends: split the passcode among people, and put it together
    HANDLERS.guardianSplit = (k, n) =>
      new Promise(res => schemeHandlers.guardianSplit
        ? schemeHandlers.guardianSplit(String(k), String(n), res)
        : res("err:offline"));
    // the passcode, changed: two rotations as one act. passcodeCheck is
    // asked first, so a new passcode is shown only to its holder.
    HANDLERS.passcodeCheck  = bridge("passcodeCheck", 1);    // passcode → "ok" | "err:…"
    HANDLERS.changePasscode = bridge("changePasscode", 2);   // current new → "ok:<aid>|<first key>"
    // forget me: the passcode again, and "retire" to close the key log for good
    HANDLERS.forgetMe       = bridge("forgetMe", 2);         // passcode retire → receipt JSON | "err:…"
    HANDLERS.guardianRecover = (linesJson) =>
      new Promise(res => schemeHandlers.guardianRecover
        ? schemeHandlers.guardianRecover(linesJson, res)
        : res("err:offline"));
    // ── the device key: stay signed in without the passcode ──────────
    // enrollDevice makes the key at TIER here, then the vat builds the
    // root-signed authorization over its public half and records it.
    HANDLERS.enrollDevice = async (label, tier) => {
      if (!deviceKey) return "err:no device-key module";
      try { deviceLoaded = await deviceKey.create(tier); }
      catch (e) { return "err:" + (e && e.message ? e.message : e); }
      if (announceDevicePub) announceDevicePub(deviceLoaded.pub);
      const r = await bridge("enrollDevice", 2)(label, tier);
      if (typeof r === "string" && !r.startsWith("ok")) await deviceKey.forget();
      return r;
    };
    HANDLERS.unlockDevice = bridge("unlockDevice", 0);
    HANDLERS.reconnect    = bridge("reconnect", 0);
    HANDLERS.setGateway   = bridge("setGateway", 1);
    HANDLERS.tier         = bridge("tier", 0, "");
    HANDLERS.devices      = bridge("devices", 0, "[]");
    HANDLERS.revokeDevice = bridge("revokeDevice", 1);
    // where this person is reached on the map: declared at the home, read back
    HANDLERS.setLocationSharing = bridge("setLocationSharing", 1);   // mode → mode | "err:…"
    HANDLERS.locationSharing    = bridge("locationSharing", 0);      // → mode | "undeclared"
    // an OUTSIDE interface enrolled as a device: its own AID, a label, its doors
    HANDLERS.enrollExternalDevice = bridge("enrollExternalDevice", 3);
    // browser-side facts and the local wipe (the authorization's revocation
    // is revokeDevice's — the gateway is the authority on it)
    HANDLERS.deviceTiers  = () => deviceKey ? deviceKey.tiers() : Promise.resolve({ hardware: false, software: false });
    HANDLERS.deviceKeyHere = () => !!(deviceKey && deviceKey.hasRecord());
    HANDLERS.deviceForget = async () => { if (deviceKey) await deviceKey.forget(); };
    // the KEL out (recovery file) and in (a recovery file on a new device)
    HANDLERS.kelExport = bridge("kelExport", 0, "");
    HANDLERS.kelImport = (json) =>
      new Promise(res => schemeHandlers.kelImport
        ? schemeHandlers.kelImport(json, res)
        : res("err:offline"));
    // profile (settings): read/write the signed-in AID's display-name + email
    HANDLERS.profileGet = () =>
      new Promise(res => schemeHandlers.profileGet
        ? schemeHandlers.profileGet(res) : res("err:offline"));
    HANDLERS.profileSet = (name, email) =>
      new Promise(res => schemeHandlers.profileSet
        ? schemeHandlers.profileSet(name || "", email || "", res) : res("err:offline"));
    // First-Person: personhood status, vouch, enrollment, governance grant
    HANDLERS.fpStatus = () =>
      new Promise(res => schemeHandlers.fpStatus ? schemeHandlers.fpStatus(res) : res("err:offline"));
    // client-signed when the session can sign (the clock stamp is SAID material)
    HANDLERS.fpVouch = (aid, rel) =>
      new Promise(res => schemeHandlers.fpVouch
        ? schemeHandlers.fpVouch(aid || "", rel || "", String(Date.now()), res) : res("err:offline"));
    HANDLERS.fpWithdrawVouch = bridge("fpWithdrawVouch", 1);
    HANDLERS.fpEnroll = () =>
      new Promise(res => schemeHandlers.fpEnroll ? schemeHandlers.fpEnroll(res) : res("err:offline"));
    // the caller's own ask, read from the ceremony: {state, count, quorum,
    // witnesses, vouchers} — the same on every device
    HANDLERS.fpMyCeremony = () =>
      new Promise(res => schemeHandlers.fpMyCeremony ? schemeHandlers.fpMyCeremony(res) : res("err:offline"));
    HANDLERS.fpPending = () =>
      new Promise(res => schemeHandlers.fpPending ? schemeHandlers.fpPending(res) : res("err:offline"));
    HANDLERS.fpGrant = (aid) =>
      new Promise(res => schemeHandlers.fpGrant ? schemeHandlers.fpGrant(aid || "", res) : res("err:offline"));
    // the witnessed alternative to fpGrant: open a k-of-n enrollment
    // ceremony — the ask lands in every PHC-holder's witness inbox and
    // the credential issues at quorum, carrying each vouch as an edge
    HANDLERS.fpOpenCeremony = (aid, k) =>
      new Promise(res => schemeHandlers.fpOpenCeremony
        ? schemeHandlers.fpOpenCeremony(aid || "", (typeof k === "number" && k >= 1) ? k : 1, res)
        : res("err:offline"));
    HANDLERS.fpMyPhc = () =>
      new Promise(res => schemeHandlers.fpMyPhc ? schemeHandlers.fpMyPhc(res) : res("err:offline"));
    // ── slots: the share face's two rails, one wire ──────────────────────
    // A CAPACITY slot is an owned <economic-resource> (declareMeans, and the
    // ownership a socialization grant projects from); a NEED slot a standing
    // <intent> (declareNeed). Both carry quantity, unit, place, the recurring
    // arcs, note and emoji; a need adds its [from, until] bounds. mySlots
    // reads both back, retireNeed withdraws a standing order.
    HANDLERS.declareMeans = bridge("declareMeans", 10);  // spec qty unit loc arcs note emoji name catsJson criteriaJson
    HANDLERS.declareNeed  = bridge("declareNeed", 14);   // spec qty unit loc arcs note emoji from until name catsJson criteriaJson tension voice
    HANDLERS.retireNeed   = bridge("retireNeed", 1);     // spec
    HANDLERS.retireMeans   = bridge("retireMeans", 1);   // spec — the offer side's own withdrawal
    // the declaration-time price (the ⚖️ chip) and the burn-meter it feeds:
    // the scope's moved-distribution over its kept solves
    HANDLERS.needDisplacement = bridge("needDisplacement", 2); // spec qty → JSON {read, perUnit, moved, lately?}
    HANDLERS.externalityHistory = bridge("externalityHistory", 0); // → JSON {solves, meanTotal, specs}
    // the constitution's gate: a kind beyond a want is the scope's statement
    HANDLERS.ratifyKind = bridge("ratifyKind", 2);       // spec kind ("floor"|"held"; "des" withdraws)
    HANDLERS.ratifiedKinds = bridge("ratifiedKinds", 0); // → JSON [{spec, kind, by, at}]
    HANDLERS.auditKinds = bridge("auditKinds", 0);       // stage 3: → JSON {examined, padded, findings[]}
    HANDLERS.audits = bridge("audits", 0);               // → JSON [{spec, who, kind, declared, observed, verdict, rate, by, at}]
    // ── the citizen's own skills: self-declared labour-power ─────────────
    HANDLERS.declareSkill  = bridge("declareSkill", 1);   // skill-spec-id
    HANDLERS.revokeSkill   = bridge("revokeSkill", 1);    // skill-spec-id
    HANDLERS.mySkills      = bridge("mySkills", 0, "");   // → newline-joined skill-spec-ids
    HANDLERS.mySkillStanding = bridge("mySkillStanding", 0);   // → JSON rows: claim beside its validation; "err:…" leaves the demo standing
    HANDLERS.contestWork   = bridge("contestWork", 3);      // scope, event-id, reason → ballot id
    HANDLERS.mySlots      = bridge("mySlots", 0, "");    // → {needs:[…], means:[…]} JSON
    // corpus search (docs/planning/corpus-guile-native.md phase 4): domain
    // "" searches every built domain, merged by fusion score — the
    // federation corpus tab's own call; a real domain slug scopes to one
    // (the recipes face's call). → {hits:[…]} or {hits:[],error} JSON
    HANDLERS.corpusSearch  = bridge("corpusSearch", 3, '{"hits":[],"error":"offline"}');
    HANDLERS.lintRecords   = bridge("lintRecords", 2, "err:offline");
    HANDLERS.corpusDomains = bridge("corpusDomains", 0, '{"domains":[]}');
    // the fold at the scope you stand in — Our Needs / Our Offers as summed
    // cells, your own share joined as `mine`; no one else's name travels
    HANDLERS.ourSlots     = bridge("ourSlots", 0, "");   // → {needs:[cells], means:[cells]} JSON
    // payouts: "send N XMR of my claim to ⟨address⟩" — the commons' wallet
    // sends it under policy; the member holds a record, never a key
    HANDLERS.requestPayout = bridge("requestPayout", 4);  // address xmr due note
    HANDLERS.myPayouts     = bridge("myPayouts", 0, "");  // → {available, payouts:[…], owed:[…]} JSON
    HANDLERS.myClaims      = bridge("myClaims", 0, "");   // → {rows:[ClaimRow…]} JSON: asked, held, taken
    HANDLERS.myCreditHistory = bridge("myCreditHistory", 0, "");   // → {rows:[CreditHistoryRow…]} JSON: earned, waiting, drawn, voided, newest first
    // what every source says of a spec, and the history behind it: the reading
    // fold's rows and drift, then one row per reading between two instants
    // (spec) → {rows, drift, latest};  (spec, fromIso, untilIso) → {rows, fold}
    HANDLERS.scopeReadings = bridge("scopeReadings", 1);
    HANDLERS.readingsBetween = bridge("readingsBetween", 3);
    // the three scope declarations: a stock held at a place until a time, a
    // hosting ceiling for a spec, and a recipe's tail regime for a process
    // (scope, resourceId, place, until);  (scope, spec, ceiling, until);
    // (scope, recipe, tails, process, until) → the planner's reply | "err:…"
    HANDLERS.declareSpan = bridge("declareSpan", 4);
    HANDLERS.declareHosting = bridge("declareHosting", 4);
    HANDLERS.claimRegime = bridge("claimRegime", 5);
    HANDLERS.retirePayout  = bridge("retirePayout", 1);   // id
    // "I bought this for the commons": the good is raised into the commons;
    // what you advanced becomes a debt the commons owes you once accepted —
    // read back via myPayouts' `owed` (governance/debts.scm)
    HANDLERS.recordPurchase = (spec, qty, unit, moneySpec, cost, where, note, receipt, donation) =>
      new Promise(res => schemeHandlers.recordPurchase
        ? schemeHandlers.recordPurchase(spec || "", String(qty ?? 1), unit || "each", moneySpec || "spec-eur",
                                        String(cost ?? 0), where || "", note || "", receipt || "",
                                        donation ? "yes" : "no", res)
        : res("err:offline"));
    HANDLERS.slotsAt      = bridge("slotsAt", 0, "");    // → the scope's pool: {needs:[…]+who, means:[…]+owner}
    // the match ring's one read: needs + declared means with their folksonomy
    // terms, and every scored need↔means pairing (classification affinity ×
    // time × quantity, geometric mean — planner match-slots)
    HANDLERS.matchSlots   = bridge("matchSlots", 0, ""); // → {needs, means, matches:[{need, hits:[…]}]}
    // ── availability, invites, the confirmation mile, the witness doors ──
    // The spine registers these; the faces guard on their presence and treat
    // absence as offline — so each one MUST be bridged here to work live.
    HANDLERS.setAvailability = bridge("setAvailability", 1);  // arcs JSON
    HANDLERS.invite          = bridge("invite", 4);           // aid label t0-iso t1-iso
    HANDLERS.acceptInvite    = bridge("acceptInvite", 2);     // scope, proposal-id
    HANDLERS.recordEffort    = bridge("recordEffort", 5);     // scope cid qty unit tap
    HANDLERS.recordFlow      = bridge("recordFlow", 11);      // scope action spec qty total place when proc note rowId tap
    HANDLERS.witnessOpen     = bridge("witnessOpen", 2);      // scope event-id
    HANDLERS.witnessInbox    = bridge("witnessInbox", 0, ""); // → [{said,kind,worker,sponsor,skill,hours,count,quorum}…] JSON
    HANDLERS.witnessAttest   = bridge("witnessAttest", 1);    // said
    // its own wrapper: qty crosses as a NUMBER (the spine checks number?),
    // and shop.ts speaks callback here rather than promise.
    HANDLERS.claim = (rid, qty, where, when, cb) =>
      schemeHandlers.claim
        ? schemeHandlers.claim(rid || "", qty, where || "", when || "", cb)
        : cb("err:offline");
    // the family face: a purse split across stated needs by harmony. Callback
    // style like claim (the face wants the reply as soon as it lands, not a
    // Promise it has to unwrap) — weighted crosses as a string, like every
    // other boolean on this FFI edge (arg-num/arg-str's own doc, above).
    // who you are: the profile tags the reproduction floors and the diet read,
    // written onto your own agent record (a JSON array of "key:value" strings)
    HANDLERS.setProfile = (tagsJson, cb) =>
      schemeHandlers.setProfile
        ? schemeHandlers.setProfile(tagsJson || "[]", cb)
        : cb("err:offline");
    // membersJson: the household's own consumer voice (playnet.typ §The
    // credit identity) — {person,capacity,hours} rows; "[]" (the face's
    // default) reads every owner as an equal citizen.
    HANDLERS.familySplit = (needsJson, purse, labourH, weighted, membersJson, perCitizenHours, cb) =>
      schemeHandlers.familySplit
        ? schemeHandlers.familySplit(needsJson || "", purse, labourH, weighted ? "true" : "false",
                                      membersJson || "[]", perCitizenHours, cb)
        : cb("err:offline");
    // the same week asked backwards: the three bills (euros and hours beyond
    // the purse for rights, then needs, then wants), a euro priced in hours.
    HANDLERS.familyBills = (needsJson, purse, labourH, weighted, eurPerHour, membersJson, perCitizenHours, cb) =>
      schemeHandlers.familyBills
        ? schemeHandlers.familyBills(needsJson || "", purse, labourH, weighted ? "true" : "false", eurPerHour,
                                      membersJson || "[]", perCitizenHours, cb)
        : cb("err:offline");
    // ── live / expected position ─────────────────────────────────────────
    // Where you ARE at a period (0 = now): the commute origin for your labour
    // and the cell your reproduction floors sit in. setPositionHere hands raw
    // coordinates to the spine, which snaps them to the scope's nearest known
    // place — a place id is all that is ever stored. setPosition names a place
    // directly, which is how a FUTURE period gets declared ("the park, Saturday
    // afternoon"). An empty place clears that period back to your home.
    HANDLERS.setPosition     = bridge("setPosition", 2);       // period place
    HANDLERS.setPositionHere = bridge("setPositionHere", 3);   // period lat lon
    // your registered home: a known place id, or "" with coordinates for your own place
    HANDLERS.setHome = bridge("setHome", 3);                   // place lat lng
    HANDLERS.declareDwelling = bridge("declareDwelling", 10);  // place areaM2 rooms warmthWinterDegC warmthSummerDegC beds attestsJson certified rentEurNight tenure
    // a new place by name (+ optional lat lon) → its id, for a slot's WHERE
    HANDLERS.declarePlace = bridge("declarePlace", 5);         // name lat lon address parent
    // its own wrapper: `movable` crosses as the spine's "yes"/"no" string;
    // `kind` is "use" (lend the service) or "consume" (lend a quantity to
    // spend — a purse), absent = use.
    // `ref` uniquifies the grant's SAID so recall-then-relend with the same
    // terms mints a fresh credential instead of colliding with the revoked
    // one; auto-filled with a timestamp when the caller passes none.
    // `eligible` is the owner's steward rule — the slot criteria JSON ("" =
    // anyone) — bounding who may be assigned to work drawing on the grant.
    HANDLERS.socialize = (commune, spec, qty, until, movable, returnTo, floor, resource, kind, ref, eligible) =>
      new Promise(res => schemeHandlers.socialize
        ? schemeHandlers.socialize(commune || "", spec || "", String(qty ?? ""), until || "",
                                   movable ? "yes" : "no", returnTo || "", floor || "", resource || "",
                                   kind === "consume" ? "consume" : "use",
                                   ref || String(Date.now()), eligible || "", res)
        : res("err:offline"));
    HANDLERS.recall = (said) =>
      new Promise(res => schemeHandlers.recall ? schemeHandlers.recall(said || "", res) : res("err:offline"));
    // "I gave the commons this" — the reimbursement primary, client-signed
    // like socialize above. Replies the claim's own SAID, not just "ok" —
    // whoever calls acceptReimbursement needs it.
    HANDLERS.purchaseClaim = bridge("purchaseClaim", 8); // commune spec qty unit due resource ref trig(purchase-event id)
    // accepting a grant or a reimbursement — the commune's own word, no new
    // signature (the session's own identity is the proof). See
    // doors/governance.scm's own doc: no governor-role gate exists live
    // anywhere yet, so this is open to any authenticated member — only
    // self-accepting one's own reimbursement is actually refused.
    HANDLERS.acceptSocialization = bridge("acceptSocialization", 2); // commune grantSaid
    HANDLERS.acceptReimbursement = bridge("acceptReimbursement", 2); // commune claimSaid
    HANDLERS.setScope = (id) =>
      new Promise(res => schemeHandlers.setScope ? schemeHandlers.setScope(id || "", res) : res("err:offline"));
    HANDLERS.fpPresent = (wireJson) =>
      new Promise(res => schemeHandlers.fpPresent ? schemeHandlers.fpPresent(wireJson || "", res) : res("err:offline"));
    // the bundle you carry between gateways (vouches + personhoods + key
    // logs), and presenting one here — "ok:<newly imported>" | "err:…"
    HANDLERS.fpMyVouches = () =>
      new Promise(res => schemeHandlers.fpMyVouches ? schemeHandlers.fpMyVouches(res) : res("err:offline"));
    HANDLERS.fpPresentBundle = (json) =>
      new Promise(res => schemeHandlers.fpPresentBundle ? schemeHandlers.fpPresentBundle(json || "", res) : res("err:offline"));

    // ── Compute seam ───────────────────────────────────────────────────────
    // the commons' machine book: offers and jobs name the commune, member
    // acts carry the session's AID server-side. Reads answer JSON arrays;
    // mutations "ok" or "ok:<id>"; verify/receipt/settle answer JSON.
    HANDLERS.computeOffer = (commune, lane, classes, headroom, repro, optsJson) =>
      new Promise(res => schemeHandlers.computeOffer
        ? schemeHandlers.computeOffer(commune || "", lane || "", classes || "", headroom || 0, repro || "none", optsJson || "", res)
        : res("err:offline"));
    HANDLERS.computeRetract    = bridge("computeRetract", 2);
    HANDLERS.computeOffers     = (commune) =>
      new Promise(res => schemeHandlers.computeOffers ? schemeHandlers.computeOffers(commune || "", res) : res("[]"));
    HANDLERS.computeSubmit     = (commune, taskClass, lane, repro, inputHash, optsJson) =>
      new Promise(res => schemeHandlers.computeSubmit
        ? schemeHandlers.computeSubmit(commune || "", taskClass || "", lane || "", repro || "none", inputHash || "", optsJson || "", res)
        : res("err:offline"));
    HANDLERS.computeWithdraw   = bridge("computeWithdraw", 2);
    HANDLERS.computeJobs       = (commune) =>
      new Promise(res => schemeHandlers.computeJobs ? schemeHandlers.computeJobs(commune || "", res) : res("[]"));
    HANDLERS.computeMatch      = (commune, jobId) =>
      new Promise(res => schemeHandlers.computeMatch ? schemeHandlers.computeMatch(commune || "", jobId || "", res) : res("[]"));
    HANDLERS.computeClaim      = (commune, jobId, offerId, optsJson) =>
      new Promise(res => schemeHandlers.computeClaim
        ? schemeHandlers.computeClaim(commune || "", jobId || "", offerId || "", optsJson || "", res)
        : res("err:offline"));
    HANDLERS.computeAccept     = bridge("computeAccept", 2);
    HANDLERS.computePreempt    = bridge("computePreempt", 2);
    HANDLERS.computeClaims     = (commune) =>
      new Promise(res => schemeHandlers.computeClaims ? schemeHandlers.computeClaims(commune || "", res) : res("[]"));
    HANDLERS.computeReceipt    = (commune, wireJson) =>
      new Promise(res => schemeHandlers.computeReceipt ? schemeHandlers.computeReceipt(commune || "", wireJson || "{}", res) : res("err:offline"));
    HANDLERS.computeVerify     = (wireJson) =>
      new Promise(res => schemeHandlers.computeVerify ? schemeHandlers.computeVerify(wireJson || "{}", res) : res("err:offline"));
    HANDLERS.computeSettle     = (commune, wireJson) =>
      new Promise(res => schemeHandlers.computeSettle ? schemeHandlers.computeSettle(commune || "", wireJson || "{}", res) : res("err:offline"));
    HANDLERS.computeStatements = (commune) =>
      new Promise(res => schemeHandlers.computeStatements ? schemeHandlers.computeStatements(commune || "", res) : res("[]"));
    HANDLERS.computeEnvelope   = (wireJson) =>
      new Promise(res => schemeHandlers.computeEnvelope ? schemeHandlers.computeEnvelope(wireJson || "{}", res) : res("err:offline"));

    // ── Governance seam ──────────────────────────────────────────────────
    // app/tabs/governance.js drives the decisions tab through these, and
    // handle-cast-signed is where the citizen's KERI key signs the stance ACDC.
    // They live in schemeHandlers (day-boot.scm's dispatch) but were never
    // surfaced here, so every `if (HANDLERS.cast)` guard in the tab was falsy —
    // the whole governance tab (cast / open / results) was inert. Wire them.
    HANDLERS.listProposals = () =>
      new Promise(res => schemeHandlers.listProposals ? schemeHandlers.listProposals(res) : res("[]"));
    HANDLERS.getResult = (id) =>
      new Promise(res => schemeHandlers.getResult ? schemeHandlers.getResult(id || "", res) : res(""));
    HANDLERS.cast = (id, stance) =>
      new Promise(res => schemeHandlers.cast ? schemeHandlers.cast(id || "", stance || "", res) : res("err:offline"));
    HANDLERS.openProposal = (kind, domain, id, description, franchise, subject) =>
      new Promise(res => schemeHandlers.openProposal
        ? schemeHandlers.openProposal(kind || "ballot", domain || "policy", id || "",
                                      description || "", franchise || "federation", subject || "", res)
        : res("err:offline"));
    HANDLERS.voiceIn = (sid) =>
      new Promise(res => schemeHandlers.voiceIn ? schemeHandlers.voiceIn(sid || "", res) : res(""));
    HANDLERS.close = (id) =>
      new Promise(res => schemeHandlers.close ? schemeHandlers.close(id || "", res) : res("err:offline"));
    HANDLERS.myVoice = () =>
      new Promise(res => schemeHandlers.myVoice ? schemeHandlers.myVoice(res) : res(""));
    HANDLERS.listDelegations = () =>
      new Promise(res => schemeHandlers.listDelegations ? schemeHandlers.listDelegations(res) : res("[]"));
    HANDLERS.listUcProposals = () =>
      new Promise(res => schemeHandlers.listUcProposals ? schemeHandlers.listUcProposals(res) : res("[]"));
    HANDLERS.setDelegation = (to, fraction) =>
      new Promise(res => schemeHandlers.setDelegation
        ? schemeHandlers.setDelegation(to || "", String(fraction ?? ""), res) : res("err:offline"));
    HANDLERS.revokeDelegation = (to) =>
      new Promise(res => schemeHandlers.revokeDelegation
        ? schemeHandlers.revokeDelegation(to || "", res) : res("err:offline"));
  }

  main().catch(e => { console.warn("[day-boot] boot failed:", e); showNotice({ failed: (e && e.message) || String(e) }); });
}
boot();
