window.addEventListener("load", async () => {
  try {
    // Pre-load key pairs from localStorage BEFORE WASM starts.
    // crypto.subtle.importKey is async, but we can await here in JS.
    // This makes keys available synchronously to Scheme via getPreloadedKeyPair.
    const preloadedKeyPairs = {};
    try {
      const orgNames = (localStorage.getItem("playnet-index") || "")
        .split(",").filter(Boolean);
      const fromHex = hex =>
        new Uint8Array(hex.match(/.{2}/g).map(b => parseInt(b, 16)));
      for (const name of orgNames) {
        const stored = localStorage.getItem("playnet-kp-" + name);
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
          now() { return Date.now(); }
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
            if (!keyPair || typeof keyPair !== 'object') {
              console.warn("saveKeyPair: invalid keyPair for", name);
              return;
            }
            const pub = keyPair.publicKey;
            const priv = keyPair.privateKey;
            if (!pub || !priv) {
              console.warn("saveKeyPair: missing publicKey/privateKey for", name);
              return;
            }
            const toHex = buf => [...new Uint8Array(buf)]
              .map(b => b.toString(16).padStart(2, '0')).join('');
            Promise.all([
              crypto.subtle.exportKey("raw", pub),
              crypto.subtle.exportKey("pkcs8", priv)
            ]).then(([pubBuf, privBuf]) => {
              localStorage.setItem("playnet-kp-" + name,
                toHex(pubBuf) + ":" + toHex(privBuf));
            }).catch(e => console.warn("saveKeyPair: export failed for", name, e.message));
          },
          getPreloadedKeyPair(name) {
            return preloadedKeyPairs[name] || null;
          },
          hasPreloadedKeyPair(name) {
            return name in preloadedKeyPairs ? 1 : 0;
          },
          deleteKeyPair(name) {
            localStorage.removeItem("playnet-kp-" + name);
            delete preloadedKeyPairs[name];
          }
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
          closePc(pc) { pc.close(); }
        },
        window: {
          setTimeout(cb, delay) { return setTimeout(cb, delay); },
          setInterval(cb, delay) { return setInterval(cb, delay); },
          clearTimeout(id) { clearTimeout(id); },
          clearInterval(id) { clearInterval(id); }
        },
        urlParams: {
          get(name) {
            return new URLSearchParams(window.location.search).get(name) || "";
          }
        },
        ocapn: {
          // OCapN bridge: Scheme registers callbacks here for JS-initiated actions.
          // Speech/transcription flow: JS records audio → calls transcribeCallback → Scheme OCapN → result
          setTranscribeCallback(cb) { window.__playnetTranscribe = cb; },
          setExpressCallback(cb) { window.__playnetExpress = cb; }
        },
        localStorage: {
          getItem(key) { return localStorage.getItem(key); },
          setItem(key, value) { localStorage.setItem(key, value); },
          removeItem(key) { localStorage.removeItem(key); }
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

                // Try OCapN transcription (via Scheme callback), fall back to local Whisper
                const transcribeFn = window.__playnetTranscribe;
                if (transcribeFn) {
                  console.log('[speech] Sending to OCapN gateway for transcription...');
                  const buf = await blob.arrayBuffer();
                  const b64 = btoa(String.fromCharCode(...new Uint8Array(buf)));

                  if (window.__speechExpressMode) {
                    // Express mode: transcribe, then convert NL → Scheme
                    transcribeFn(b64, (transcript) => {
                      console.log('[express] Transcript:', transcript);
                      const expressFn = window.__playnetExpress;
                      if (expressFn) {
                        expressFn(transcript, (expr) => {
                          onResult(expr || transcript);
                          onEnd();
                        });
                      } else {
                        onResult(transcript);
                        onEnd();
                      }
                    });
                  } else {
                    transcribeFn(b64, (result) => {
                      onResult(result);
                      onEnd();
                    });
                  }
                } else {
                  // Fallback: local Whisper WASM
                  console.log('[speech] No OCapN gateway — falling back to local Whisper...');
                  try {
                    if (!window.__whisperPipeline) {
                      const { pipeline } = await import(
                        'https://cdn.jsdelivr.net/npm/@huggingface/transformers@3'
                      );
                      window.__whisperPipeline = await pipeline(
                        'automatic-speech-recognition', 'Xenova/whisper-tiny.en', { dtype: 'q8' }
                      );
                    }
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
  } catch(e) {
    console.error("WASM load error:", e);
    if(e instanceof WebAssembly.CompileError) {
      document.getElementById("wasm-error").hidden = false;
    }
  }
});
