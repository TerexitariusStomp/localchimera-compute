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
            ws.addEventListener('message', (e) => {
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
              // Lazy-load Whisper pipeline on first use
              if (!window.__whisperPipeline) {
                console.log('[whisper] Loading model...');
                const { pipeline } = await import(
                  'https://cdn.jsdelivr.net/npm/@huggingface/transformers@3'
                );
                window.__whisperPipeline = await pipeline(
                  'automatic-speech-recognition',
                  'Xenova/whisper-tiny.en',
                  { dtype: 'q8' }
                );
                console.log('[whisper] Model ready.');
              }

              // Record audio from microphone at 16kHz mono
              const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
              const audioContext = new AudioContext({ sampleRate: 16000 });
              const source = audioContext.createMediaStreamSource(stream);
              const processor = audioContext.createScriptProcessor(4096, 1, 1);

              const chunks = [];
              let recording = true;

              processor.onaudioprocess = (e) => {
                if (recording) {
                  chunks.push(new Float32Array(e.inputBuffer.getChannelData(0)));
                }
              };

              source.connect(processor);
              processor.connect(audioContext.destination);

              window.__xorgRecording = {
                stream, audioContext, processor, source, chunks,
                stop: async () => {
                  recording = false;
                  processor.disconnect();
                  source.disconnect();
                  stream.getTracks().forEach(t => t.stop());
                  audioContext.close();

                  // Concatenate chunks
                  const totalLen = chunks.reduce((acc, c) => acc + c.length, 0);
                  const audio = new Float32Array(totalLen);
                  let offset = 0;
                  for (const chunk of chunks) {
                    audio.set(chunk, offset);
                    offset += chunk.length;
                  }

                  // Transcribe locally via Whisper WASM
                  console.log('[whisper] Transcribing', audio.length, 'samples...');
                  const result = await window.__whisperPipeline(audio);
                  console.log('[whisper] Result:', result.text);
                  onResult(result.text.trim());
                  onEnd();
                }
              };
            } catch (e) {
              console.error('[whisper] Error:', e);
              onEnd();
            }
          },
          stopListening() {
            if (window.__xorgRecording) {
              window.__xorgRecording.stop();
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
