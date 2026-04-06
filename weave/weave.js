/**
 * weave.js — Hoot WASM host for the Weave browser client
 *
 * Provides user_imports for the compiled Scheme WASM module:
 *   - Standard DOM bindings (matches browser/repl.js patterns)
 *   - Fetch API (bridged to synchronous callback for Scheme)
 *   - LiveKit SDK bindings
 *   - Weave callback registration
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
};

// ── Load and start WASM ───────────────────────────────────────────────────────
window.addEventListener("load", async () => {
  const { Scheme } = await import("./reflect.js");

  await Scheme.load_main("weave.wasm", {
    user_imports: {

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
      // Returns "" on failure.
      fetch: {
        postJSON(url, body) {
          try {
            const xhr = new XMLHttpRequest();
            xhr.open("POST", url, false); // synchronous
            xhr.setRequestHeader("Content-Type", "application/json");
            xhr.send(body);
            if (xhr.status !== 200) return "";
            // If the server set X-Weave-Encoded, return that directly
            const encoded = xhr.getResponseHeader("X-Weave-Encoded");
            if (encoded) return encoded;
            // Otherwise assume token response
            const data = JSON.parse(xhr.responseText);
            return `${data.token}|${data.livekit_url}|${data.identity}`;
          } catch (e) {
            console.error("fetch.postJSON error:", e);
            return "";
          }
        },
      },

      // ── LiveKit ─────────────────────────────────────────────────────────────
      livekit: {
        async connect(url, token, _callbackObj) {
          const { Room, RoomEvent, Track } = LivekitClient;
          _room = new Room({
            adaptiveStream: true,
            dynacast: true,
          });

          // Forward LiveKit events to Scheme callbacks
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
            if (_callbacks.onDisconnected) {
              _callbacks.onDisconnected();
            }
          });

          _room.on(RoomEvent.TrackSubscribed, (track, _pub, participant) => {
            // Attach the track to the tile placeholder div
            if (track.kind === Track.Kind.Video || track.kind === Track.Kind.Audio) {
              const tileId = `tile-${participant.identity}`;
              const element = track.attach();
              const container = document.getElementById(tileId);
              if (container) {
                // Remove old media elements and attach new one
                container.querySelectorAll("video, audio").forEach(el => el.remove());
                container.appendChild(element);
              }
            }
          });

          _room.on(RoomEvent.TrackUnsubscribed, (track) => {
            track.detach();
          });

          // Sprint 2: room transfer messages from host via LiveKit data channel
          _room.on(RoomEvent.DataReceived, (payload, _participant) => {
            const msg = new TextDecoder().decode(payload);
            if (_callbacks.onDataReceived) {
              _callbacks.onDataReceived(msg);
            }
          });

          await _room.connect(url, token);
        },

        disconnect() {
          if (_room) {
            _room.disconnect();
            _room = null;
          }
        },

        async enableCamera() {
          if (_room) await _room.localParticipant.setCameraEnabled(true);
        },

        async disableCamera() {
          if (_room) await _room.localParticipant.setCameraEnabled(false);
        },

        async enableMic() {
          if (_room) await _room.localParticipant.setMicrophoneEnabled(true);
        },

        async disableMic() {
          if (_room) await _room.localParticipant.setMicrophoneEnabled(false);
        },

        async shareScreen() {
          if (_room) await _room.localParticipant.setScreenShareEnabled(true);
        },

        async stopScreenShare() {
          if (_room) await _room.localParticipant.setScreenShareEnabled(false);
        },

        attachTrack(track, tileId) {
          const el = track.attach();
          const container = document.getElementById(tileId);
          if (container) container.appendChild(el);
        },

        detachTrack(track) {
          track.detach();
        },
      },

      // ── Weave callbacks (Scheme registers; JS calls back into WASM) ─────────
      weave: {
        registerCallbacks(onJoined, onLeft, onQuality, onDisconnect, onData) {
          _callbacks.onParticipantConnected    = onJoined;
          _callbacks.onParticipantDisconnected = onLeft;
          _callbacks.onConnectionQualityChanged = onQuality;
          _callbacks.onDisconnected             = onDisconnect;
          _callbacks.onDataReceived             = onData;
        },

        // Synchronous XHR helper for non-token API calls (returns JSON string)
        getJSON(url) {
          try {
            const xhr = new XMLHttpRequest();
            xhr.open("GET", url, false);
            xhr.send();
            return xhr.status === 200 ? xhr.responseText : "";
          } catch (e) {
            console.error("weave.getJSON error:", e);
            return "";
          }
        },

        deleteJSON(url) {
          try {
            const xhr = new XMLHttpRequest();
            xhr.open("DELETE", url, false);
            xhr.setRequestHeader("Content-Type", "application/json");
            xhr.send();
            return xhr.status === 200 ? xhr.responseText : "";
          } catch (e) {
            console.error("weave.deleteJSON error:", e);
            return "";
          }
        },
      },

    } // end user_imports
  }); // end load_main
});
