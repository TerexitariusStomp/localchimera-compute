/**
 * weave.js — Hoot WASM host for the Weave browser client
 *
 * Provides user_imports for the compiled Scheme WASM module:
 *   - console bindings  (Scheme can write to the browser console)
 *   - Standard DOM bindings (matches browser/repl.js patterns)
 *   - Fetch API (bridged to synchronous callback for Scheme)
 *   - LiveKit SDK bindings
 *   - Weave callback registration
 *
 * ── Error boundary: the JS/WASM divide ───────────────────────────────────────
 * JS exceptions do NOT propagate into Scheme as Scheme exceptions.
 * Hoot's Scheme call stack and JS/Wasm exception systems are distinct.
 * Convention:
 *   • Synchronous FFI functions: return a sentinel on error ("ERR:..." or "").
 *     Scheme checks the return value; it must never assume success.
 *   • Async FFI functions (LiveKit connect, enable*): wrap in try/catch;
 *     call _callbacks.onError(source, message) so Scheme can handle the failure.
 *   • Never let an async throw escape — it shows as an uncaught rejection with
 *     a reflect.js stack trace that cannot be traced back to Scheme source.
 *
 * LiveKit SDK must be loaded before this script.
 * Import map or CDN script tag handles that — see weave.html.
 */

// ── LiveKit room state ────────────────────────────────────────────────────────
let _room = null;
let _callbacks = {
  onParticipantConnected:    null,
  onParticipantDisconnected: null,
  onConnectionQualityChanged: null,
  onDisconnected:             null,
  onDataReceived:             null,   // Sprint 2: room transfer messages
  onError:                    null,   // async error bridge → Scheme
};

// ── Global error safety net ───────────────────────────────────────────────────
// Unhandled promise rejections that escape try/catch blocks appear here.
// Surface them visibly so they don't silently fail during development.
window.addEventListener("unhandledrejection", (event) => {
  console.error("[weave] Unhandled async rejection:", event.reason);
  if (_callbacks.onError) {
    const msg = event.reason?.message || String(event.reason);
    try { _callbacks.onError("unhandled", msg); } catch (_) {}
  }
});

// ── Load and start WASM ───────────────────────────────────────────────────────
window.addEventListener("load", async () => {
  try {
  const { Scheme } = await import("./reflect.js");

  await Scheme.load_main("weave.wasm", {
    user_imports: {

      // ── Console (Scheme → browser console) ─────────────────────────────────
      // Scheme calls: (console-log "msg"), (console-warn "msg"), (console-error "msg")
      // All messages are prefixed with [weave] for easy filtering in DevTools.
      console: {
        log(msg)  { console.log("[weave]", msg); },
        warn(msg) { console.warn("[weave]", msg); },
        error(msg){ console.error("[weave]", msg); },
      },

      // ── Document ────────────────────────────────────────────────────────────
      document: {
        body()           { return document.body; },
        getElementById(id) { return document.getElementById(id); },
        createTextNode(t)  { return document.createTextNode(t); },
        createElement(tag) { return document.createElement(tag); },
        createElementNS(ns, tag) { return document.createElementNS(ns, tag); },
        createTreeWalker(root, what) { return document.createTreeWalker(root, what); },
      },

      // ── Events ──────────────────────────────────────────────────────────────
      event: {
        preventDefault(e)     { e.preventDefault(); },
        stopPropagation(e)    { e.stopPropagation(); },
        keyboardKey(e)        { return e.key; },
        keyboardShiftKey(e)   { return e.shiftKey ? 1 : 0; },
        keyboardCtrlKey(e)    { return e.ctrlKey ? 1 : 0; },
        keyboardMetaKey(e)    { return e.metaKey ? 1 : 0; },
      },

      // ── Element ─────────────────────────────────────────────────────────────
      element: {
        value(el)                       { return el.value; },
        setValue(el, v)                  { el.value = v; },
        checked(el)                      { return el.checked ? 1 : 0; },
        setChecked(el, v)               { el.checked = (v === 1); },
        scrollHeight(el)                 { return el.scrollHeight; },
        setScrollTop(el, v)             { el.scrollTop = v; },
        appendChild(parent, child)       { return parent.appendChild(child); },
        setAttribute(el, name, val)      { el.setAttribute(name, val); },
        removeAttribute(el, name)        { el.removeAttribute(name); },
        remove(el)                       { el.remove(); },
        replaceWith(old, next)           { old.replaceWith(next); },
        addEventListener(el, name, fn)   { el.addEventListener(name, fn); },
        removeEventListener(el, name, fn){ el.removeEventListener(name, fn); },
        setStyle(el, prop, val)          { el.style[prop] = val; },
        focus(el)                        { el.focus(); },
      },

      // ── TreeWalker ──────────────────────────────────────────────────────────
      treeWalker: {
        currentNode(w)          { return w.currentNode; },
        setCurrentNode(w, node) { w.currentNode = node; return node; },
        nextNode(w)             { return w.nextNode(); },
        firstChild(w)           { return w.firstChild(); },
        nextSibling(w)          { return w.nextSibling(); },
      },

      // ── URL params ──────────────────────────────────────────────────────────
      urlParams: {
        get(key) {
          return new URLSearchParams(window.location.search).get(key) || "";
        },
      },

      // ── Fetch (bridged to synchronous via XHR) ──────────────────────────────
      // Scheme calls %fetch-json(url, body) → string result.
      // For /api/rooms/.../token:  returns "token|livekit_url|identity"
      // For /api/meetings:         returns "meeting_id:<mid>|room_id:<rid>"
      //   (reads X-Weave-Encoded response header)
      //
      // Error sentinel convention (Scheme checks with string-prefix? "ERR:"):
      //   "ERR:HTTP-<status>"  — server returned non-200 (e.g. "ERR:HTTP-404")
      //   "ERR:NET"            — network/XHR exception (offline, CORS, etc.)
      //   "ERR:PARSE"          — response body could not be JSON-decoded
      fetch: {
        postJSON(url, body) {
          try {
            const xhr = new XMLHttpRequest();
            xhr.open("POST", url, false); // synchronous
            xhr.setRequestHeader("Content-Type", "application/json");
            xhr.send(body);
            if (xhr.status !== 200) {
              console.warn(`[weave] fetch.postJSON ${url} → HTTP ${xhr.status}`);
              return `ERR:HTTP-${xhr.status}`;
            }
            // If the server set X-Weave-Encoded, return that directly
            const encoded = xhr.getResponseHeader("X-Weave-Encoded");
            if (encoded) return encoded;
            // Otherwise assume token response
            try {
              const data = JSON.parse(xhr.responseText);
              return `${data.token}|${data.livekit_url}|${data.identity}`;
            } catch (parseErr) {
              console.error("[weave] fetch.postJSON parse error:", parseErr, xhr.responseText);
              return "ERR:PARSE";
            }
          } catch (e) {
            console.error("[weave] fetch.postJSON network error:", e);
            return "ERR:NET";
          }
        },
      },

      // ── LiveKit ─────────────────────────────────────────────────────────────
      // All async methods are wrapped in try/catch. JS exceptions thrown inside
      // async functions cannot be caught by Scheme — they would surface only as
      // unhandled rejections with reflect.js stack traces. Instead, errors are
      // caught here and forwarded to Scheme via _callbacks.onError(source, msg).
      livekit: {
        async connect(url, token, _callbackObj) {
          try {
            const { Room, RoomEvent, Track } = LivekitClient;
            _room = new Room({ adaptiveStream: true, dynacast: true });

            _room.on(RoomEvent.ParticipantConnected, (participant) => {
              if (_callbacks.onParticipantConnected) {
                _callbacks.onParticipantConnected(
                  participant.identity,
                  participant.name || participant.identity
                );
              }
            });

            _room.on(RoomEvent.ParticipantDisconnected, (participant) => {
              if (_callbacks.onParticipantDisconnected) {
                _callbacks.onParticipantDisconnected(participant.identity);
              }
            });

            _room.on(RoomEvent.Disconnected, () => {
              if (_callbacks.onDisconnected) _callbacks.onDisconnected();
            });

            _room.on(RoomEvent.TrackSubscribed, (track, _pub, participant) => {
              if (track.kind === Track.Kind.Video || track.kind === Track.Kind.Audio) {
                const tileId = `tile-${participant.identity}`;
                const element = track.attach();
                const container = document.getElementById(tileId);
                if (container) {
                  container.querySelectorAll("video, audio").forEach(el => el.remove());
                  container.appendChild(element);
                }
              }
            });

            _room.on(RoomEvent.TrackUnsubscribed, (track) => { track.detach(); });

            _room.on(RoomEvent.DataReceived, (payload, _participant) => {
              const msg = new TextDecoder().decode(payload);
              if (_callbacks.onDataReceived) _callbacks.onDataReceived(msg);
            });

            await _room.connect(url, token);
            console.log("[weave] livekit.connect: connected to", url);

          } catch (e) {
            console.error("[weave] livekit.connect error:", e);
            _room = null;
            if (_callbacks.onError) _callbacks.onError("livekit.connect", e.message || String(e));
          }
        },

        disconnect() {
          try {
            if (_room) { _room.disconnect(); _room = null; }
          } catch (e) {
            console.error("[weave] livekit.disconnect error:", e);
            _room = null;
          }
        },

        async enableCamera() {
          try {
            if (_room) await _room.localParticipant.setCameraEnabled(true);
          } catch (e) {
            console.warn("[weave] livekit.enableCamera error:", e);
            if (_callbacks.onError) _callbacks.onError("livekit.enableCamera", e.message || String(e));
          }
        },

        async disableCamera() {
          try {
            if (_room) await _room.localParticipant.setCameraEnabled(false);
          } catch (e) {
            console.warn("[weave] livekit.disableCamera error:", e);
          }
        },

        async enableMic() {
          try {
            if (_room) await _room.localParticipant.setMicrophoneEnabled(true);
          } catch (e) {
            console.warn("[weave] livekit.enableMic error:", e);
            if (_callbacks.onError) _callbacks.onError("livekit.enableMic", e.message || String(e));
          }
        },

        async disableMic() {
          try {
            if (_room) await _room.localParticipant.setMicrophoneEnabled(false);
          } catch (e) {
            console.warn("[weave] livekit.disableMic error:", e);
          }
        },

        async shareScreen() {
          try {
            if (_room) await _room.localParticipant.setScreenShareEnabled(true);
          } catch (e) {
            // User may have denied the screen share permission — not fatal
            console.warn("[weave] livekit.shareScreen error:", e);
            if (_callbacks.onError) _callbacks.onError("livekit.shareScreen", e.message || String(e));
          }
        },

        async stopScreenShare() {
          try {
            if (_room) await _room.localParticipant.setScreenShareEnabled(false);
          } catch (e) {
            console.warn("[weave] livekit.stopScreenShare error:", e);
          }
        },

        attachTrack(track, tileId) {
          try {
            const el = track.attach();
            const container = document.getElementById(tileId);
            if (container) container.appendChild(el);
            else console.warn("[weave] livekit.attachTrack: tile not found:", tileId);
          } catch (e) {
            console.error("[weave] livekit.attachTrack error:", e);
          }
        },

        detachTrack(track) {
          try { track.detach(); } catch (e) { console.warn("[weave] livekit.detachTrack:", e); }
        },
      },

      // ── Weave callbacks (Scheme registers; JS calls back into WASM) ─────────
      weave: {
        // 6 callbacks: joined, left, quality, disconnected, data, error
        registerCallbacks(onJoined, onLeft, onQuality, onDisconnect, onData, onError) {
          _callbacks.onParticipantConnected     = onJoined;
          _callbacks.onParticipantDisconnected  = onLeft;
          _callbacks.onConnectionQualityChanged = onQuality;
          _callbacks.onDisconnected             = onDisconnect;
          _callbacks.onDataReceived             = onData;
          _callbacks.onError                    = onError;
        },

        // Synchronous XHR helpers. Same error sentinel convention as fetch.postJSON:
        //   "ERR:HTTP-<status>" | "ERR:NET" on failure; raw JSON string on success.
        getJSON(url) {
          try {
            const xhr = new XMLHttpRequest();
            xhr.open("GET", url, false);
            xhr.send();
            if (xhr.status !== 200) {
              console.warn(`[weave] getJSON ${url} → HTTP ${xhr.status}`);
              return `ERR:HTTP-${xhr.status}`;
            }
            return xhr.responseText;
          } catch (e) {
            console.error("[weave] getJSON error:", e);
            return "ERR:NET";
          }
        },

        deleteJSON(url) {
          try {
            const xhr = new XMLHttpRequest();
            xhr.open("DELETE", url, false);
            xhr.setRequestHeader("Content-Type", "application/json");
            xhr.send();
            if (xhr.status !== 200) {
              console.warn(`[weave] deleteJSON ${url} → HTTP ${xhr.status}`);
              return `ERR:HTTP-${xhr.status}`;
            }
            return xhr.responseText;
          } catch (e) {
            console.error("[weave] deleteJSON error:", e);
            return "ERR:NET";
          }
        },
      },

    } // end user_imports
  }); // end load_main

  } catch (e) {
    // WASM failed to compile or initialise. Surface the error visibly.
    console.error("[weave] WASM load failed:", e);
    const el = document.getElementById("wasm-error");
    if (el) el.hidden = false;
  }
});
