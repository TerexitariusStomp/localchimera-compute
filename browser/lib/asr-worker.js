// browser/lib/asr-worker.js — the speech-to-text worker, for both pages.
//
// Owns the on-device pipeline: Moonshine tiny on transformers.js, on its own
// thread, so the model download, the ONNX runtime's start and each inference
// stay off the page's. The dial (ui/app/voice/audio.ts) and the REPL page
// (repl.js) both spawn this file.
//
//   page → worker   { id, type: "preload" }
//                   { id, type: "transcribe", pcm: Float32Array }   16 kHz mono
//   worker → page   { id, ok: true, text? }  |  { id, ok: false, error }
//                   { progress }             a model file's download, as it goes
//
// The runtime is this origin's own (browser/vendor/transformers/, see its
// fetch.sh): the transformers.js bundle and the ONNX Runtime binaries beside
// it. The service worker caches them, so after one online use the runtime
// needs no network. The model's weights come from huggingface.co on first use
// and are kept in the `transformers-cache` cache.

import { pipeline, env } from "../vendor/transformers/transformers.min.js";

const VENDOR = new URL("../vendor/transformers/", import.meta.url).href;

// Safari runs the plain threaded build and every other engine the asyncify
// one — the choice transformers.js makes for its CDN default, made here for
// the vendored pair.
const safari = (() => {
  const ua = navigator.userAgent;
  return (navigator.vendor || "").includes("Apple")
    && !/CriOS|FxiOS|EdgiOS|OPiOS|mercury|brave/i.test(ua)
    && !ua.includes("Chrome") && !ua.includes("Android");
})();
const build = safari ? "ort-wasm-simd-threaded" : "ort-wasm-simd-threaded.asyncify";
env.backends.onnx.wasm.wasmPaths = { mjs: `${VENDOR}${build}.mjs`, wasm: `${VENDOR}${build}.wasm` };

env.allowLocalModels = false;   // the weights are huggingface.co's
env.useBrowserCache = true;     // …kept in Cache Storage after the first use
env.useWasmCache = false;       // the runtime is same-origin; the service worker keeps it

let p = null;
const ensure = () => p ||= pipeline("automatic-speech-recognition",
  "onnx-community/moonshine-tiny-ONNX",
  // this dtype pair is the one that loads: the merged decoder's q8 and int8
  // forms fail session creation in ONNX Runtime Web
  { dtype: { encoder_model: "fp32", decoder_model_merged: "q4" },
    progress_callback: (d) => self.postMessage({ progress: d }) });

self.onmessage = async (e) => {
  const { id, type, pcm } = e.data;
  try {
    if (type === "preload") { await ensure(); self.postMessage({ id, ok: true }); }
    else if (type === "transcribe") {
      const r = await (await ensure())(pcm);
      self.postMessage({ id, ok: true, text: (r?.text || "").trim() });
    } else self.postMessage({ id, ok: false, error: "unknown message type: " + type });
  } catch (err) {
    p = null;                    // a failed load is tried again on the next ask
    self.postMessage({ id, ok: false, error: String(err?.message || err) });
  }
};
