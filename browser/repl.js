window.addEventListener("load", async () => {
  try {
    // Pre-load key pairs from localStorage BEFORE WASM starts.
    // crypto.subtle.importKey is async, but we can await here in JS.
    // This makes keys available synchronously to Scheme via getPreloadedKeyPair.
    const preloadedKeyPairs = {};
    try {
      const orgNames = (localStorage.getItem("xorg-index") || "")
        .split(",").filter(Boolean);
      const fromHex = hex =>
        new Uint8Array(hex.match(/.{2}/g).map(b => parseInt(b, 16)));
      for (const name of orgNames) {
        const stored = localStorage.getItem("xorg-kp-" + name);
        if (stored) {
          const [pubHex, privHex] = stored.split(":");
          const publicKey = await crypto.subtle.importKey(
            "raw", fromHex(pubHex), { name: "Ed25519" }, true, ["verify"]);
          const privateKey = await crypto.subtle.importKey(
            "pkcs8", fromHex(privHex), { name: "Ed25519" }, true, ["sign"]);
          preloadedKeyPairs[name] = { publicKey, privateKey };
        }
      }
    } catch(e) { console.error("Key preload error:", e); }

    await Scheme.load_main("repl.wasm", {
      user_imports: {
        document: {
          body() { return document.body; },
          getElementById: Document.prototype.getElementById.bind(document),
          createTextNode: Document.prototype.createTextNode.bind(document),
          createElement: Document.prototype.createElement.bind(document),
          createTreeWalker: Document.prototype.createTreeWalker.bind(document)
        },
        event: {
          preventDefault(event) { event.preventDefault(); },
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
        treeWalker: {
          currentNode(walker) { return walker.currentNode; },
          setCurrentNode(walker, node) { walker.currentNode = node; },
          nextNode(walker) { return walker.nextNode(); },
          firstChild(walker) { return walker.firstChild(); },
          nextSibling(walker) { return walker.nextSibling(); }
        },
        ai: {
          chat(systemPrompt, userPrompt, apiKey, model) {
            const xhr = new XMLHttpRequest();
            xhr.open("POST", "https://openrouter.ai/api/v1/chat/completions", false);
            xhr.setRequestHeader("Content-Type", "application/json");
            xhr.setRequestHeader("Authorization", "Bearer " + apiKey);
            xhr.send(JSON.stringify({
              model: model,
              messages: [
                { role: "system", content: systemPrompt },
                { role: "user", content: userPrompt }
              ]
            }));
            if (xhr.status !== 200)
              throw new Error("AI request failed (" + xhr.status + "): " + xhr.responseText);
            const choices = JSON.parse(xhr.responseText).choices;
            if (!choices || !choices.length)
              throw new Error("AI returned no choices");
            return choices[0].message.content;
          }
        },
        uint8Array: {
          new(size) { return new Uint8Array(size); },
          fromArrayBuffer(buf) { return new Uint8Array(buf); },
          ref(arr, idx) { return arr[idx]; },
          set(arr, idx, val) { arr[idx] = val; },
          length(arr) { return arr.length; }
        },
        crypto: {
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
            return await crypto.subtle.generateKey(
              { name: "Ed25519" }, true, ["sign", "verify"]
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
          // Key pair persistence — save is fire-and-forget, load is pre-loaded
          saveKeyPair(name, keyPair) {
            const toHex = buf => [...new Uint8Array(buf)]
              .map(b => b.toString(16).padStart(2, '0')).join('');
            Promise.all([
              crypto.subtle.exportKey("raw", keyPair.publicKey),
              crypto.subtle.exportKey("pkcs8", keyPair.privateKey)
            ]).then(([pubBuf, privBuf]) => {
              localStorage.setItem("xorg-kp-" + name,
                toHex(pubBuf) + ":" + toHex(privBuf));
            }).catch(e => console.error("saveKeyPair error:", e));
          },
          getPreloadedKeyPair(name) {
            return preloadedKeyPairs[name] || null;
          },
          hasPreloadedKeyPair(name) {
            return name in preloadedKeyPairs ? 1 : 0;
          },
          deleteKeyPair(name) {
            localStorage.removeItem("xorg-kp-" + name);
            delete preloadedKeyPairs[name];
          }
        },
        webSocket: {
          new(url) { return new WebSocket(url); },
          close(ws) { ws.close(); },
          send(ws, data) { ws.send(data); },
          setOnOpen(ws, cb) { ws.addEventListener('open', () => cb()); },
          setOnError(ws, cb) { ws.addEventListener('error', () => cb()); },
          setOnMessage(ws, cb) {
            window.__xorgWs = ws;  // expose for speech transcription
            ws.addEventListener('message', (e) => {
              // Intercept presence updates before Scheme handler
              if (typeof e.data === 'string' && e.data.startsWith('(presence ')) {
                // Parse user list and store for Scheme to read
                try {
                  // Simple extraction: (presence ((name1 pk1) (name2 pk2) ...))
                  window.__onlineUsers = e.data;
                } catch(err) {}
                // Still pass to Scheme so it can update the UI
              }
              // Intercept transcribe responses before Scheme handler
              if (typeof e.data === 'string' && window.__pendingTranscribe) {
                if (e.data.startsWith('(transcribe-ok ')) {
                  const text = e.data.slice(16, -2);  // extract string from (transcribe-ok "...")
                  const { onResult, onEnd } = window.__pendingTranscribe;
                  window.__pendingTranscribe = null;
                  console.log('[speech] Relay transcript:', text);
                  onResult(text);
                  onEnd();
                  return;
                }
                if (e.data.startsWith('(transcribe-error ')) {
                  console.error('[speech] Relay error:', e.data);
                  const { onEnd } = window.__pendingTranscribe;
                  window.__pendingTranscribe = null;
                  onEnd();
                  return;
                }
              }
              if (e.data instanceof Blob) {
                e.data.arrayBuffer().then(buf => cb(new Uint8Array(buf)));
              } else if (e.data instanceof ArrayBuffer) {
                cb(new Uint8Array(e.data));
              } else {
                const enc = new TextEncoder();
                cb(enc.encode(e.data));
              }
            });
          },
          setOnClose(ws, cb) { ws.addEventListener('close', () => cb()); }
        },
        urlParams: {
          get(name) {
            return new URLSearchParams(window.location.search).get(name) || "";
          }
        },
        relay: {
          sendLater(ws, msg) {
            // Send asynchronously, outside any Scheme call stack
            setTimeout(() => { try { ws.send(msg); } catch(e) { console.error("relay send:", e); } }, 0);
          }
        },
        localStorage: {
          getItem(key) { return localStorage.getItem(key); },
          setItem(key, value) { localStorage.setItem(key, value); },
          removeItem(key) { localStorage.removeItem(key); }
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

                // Try relay transcription first (donated key-pool), fall back to local Whisper
                const ws = window.__xorgWs;
                if (ws && ws.readyState === WebSocket.OPEN) {
                  console.log('[speech] Sending to relay for transcription...');
                  const buf = await blob.arrayBuffer();
                  const b64 = btoa(String.fromCharCode(...new Uint8Array(buf)));

                  // Register one-time handler for transcribe response
                  window.__pendingTranscribe = { onResult, onEnd };
                  ws.send('(transcribe "' + b64 + '")');
                } else {
                  // Fallback: local Whisper WASM
                  console.log('[speech] No relay — falling back to local Whisper...');
                  try {
                    if (!window.__whisperPipeline) {
                      const { pipeline } = await import(
                        'https://cdn.jsdelivr.net/npm/@huggingface/transformers@3'
                      );
                      window.__whisperPipeline = await pipeline(
                        'automatic-speech-recognition', 'Xenova/whisper-tiny.en', { dtype: 'q8' }
                      );
                    }
                    // Decode webm to float32 PCM at 16kHz
                    const audioCtx = new AudioContext({ sampleRate: 16000 });
                    const decoded = await audioCtx.decodeAudioData(await blob.arrayBuffer());
                    const pcm = decoded.getChannelData(0);
                    audioCtx.close();
                    const result = await window.__whisperPipeline(pcm);
                    onResult(result.text.trim());
                  } catch (e) {
                    console.error('[speech] Local Whisper error:', e);
                  }
                  onEnd();
                }
              };

              recorder.start();
              window.__xorgRecording = { recorder, stream };
            } catch (e) {
              console.error('[speech] Mic error:', e);
              onEnd();
            }
          },
          stopListening() {
            if (window.__xorgRecording) {
              window.__xorgRecording.recorder.stop();
              window.__xorgRecording = null;
            }
          }
        }
      }
    });
  } catch(e) {
    console.error("WASM load error:", e);
    if(e instanceof WebAssembly.CompileError) {
      document.getElementById("wasm-error").hidden = false;
    }
  }
});
