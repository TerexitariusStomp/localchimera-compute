import { blankCaptionState, windowFor, applyTranscript } from './caption-window.js';
import type { CaptionState } from './caption-window.js';

import { seam } from '../seam.js';
import { toBase64 } from '../bytes.js';
import { workerRpc } from '../rpc.js';
// app/audio.ts — speech becomes text, off the main thread.
//
// The voice module: the wrapper around the on-device ASR worker
// (browser/lib/asr-worker.js — see below) plus WAV
// encoding and base64, and on top of them the two flows every speaking
// surface shares —
//
//   transcribePcm(pcm)   one clip → text: the gateway's whisper through the
//                        seam when it is up, the on-device worker otherwise
//   pressToSpeak(btn, …) the whole hold-to-speak dance: pointer capture,
//                        tap forgiveness, live caption while held, and the
//                        release pass that hands the final text back
//
// The orb (main.js) and the captain's log (tabs/log.js) are both
// pressToSpeak callers; what each DOES with the words stays its own.
// Dial state arrives only through the seam, read at call time, so this
// stays a leaf the way seam.ts is.

/** 16 kHz mono float samples — the shape both whisper doors expect. */
export type Pcm = Float32Array;

/** What the hold-to-speak button reports as it moves through the dance. */
export interface SpeakWords {
  idle: string;
  listening: string;
  tap: string;
  busy: string;
  nothing: string;
  refused: string;
}

export interface PressToSpeakOptions {
  /** The release pass's text — authoritative. */
  onText(text: string): void;
  /** Status line, in the caller's own vocabulary. */
  onState?(status: string): void;
  /** Interim transcript while held; null to skip live captioning entirely. */
  onLive?: ((text: string) => void) | null;
  /** Overrides for the status vocabulary. */
  words?: Partial<SpeakWords>;
}

/** What is in flight while the button is held. */
interface RecordingJob {
  rec: MediaRecorder;
  stream: MediaStream;
  liveTimer: ReturnType<typeof setInterval> | null;
}

/**
 * A thrown value is `unknown`, and the site wants what the old `err.message ||
 * err` produced: the message when there is one, the value itself otherwise.
 */
const errText = (err: unknown): string => {
  const m = (err as { message?: unknown } | null | undefined)?.message;
  return String(m || err);
};

// the local worker's first call downloads model weights from a CDN with no
// timeout of its own (verified: a stalled fetch — slow network, blocked
// host — hangs the awaiting promise forever, indistinguishable from a
// silently broken worker). Every whisper() call the release/live paths make
// is bounded by this so a stall surfaces as a real, visible error instead.
function withTimeout<T>(p: Promise<T>, ms: number, label: string): Promise<T> {
  return new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error(`${label} timed out`)), ms);
    p.then(v => { clearTimeout(t); res(v); }, e => { clearTimeout(t); rej(e); });
  });
}

// Local ASR, off the main thread: browser/lib/asr-worker.js, the one speech
// worker both pages spawn ({preload} / {transcribe, pcm} in, {ok, text} /
// {ok: false, error} out, and {progress} as the model's files arrive). It
// runs Moonshine tiny (onnx-community/moonshine-tiny-ONNX) on the vendored
// transformers.js runtime; the model, its dtype pair and where the runtime
// and the weights come from are that file's to say.
// The speech model's download, as a reader can watch it. The worker reports
// each file's bytes as its fetch begins, so the files announced so far are a
// small, growing total; the whole download is measured against the size the
// model's files are known to add up to (EXPECTED_BYTES: encoder fp32 + merged
// decoder q4 + tokenizer + configs, from the model repo's own listing), so the
// bar climbs steadily instead of leaping when the big files appear. Once those
// bytes are in, the runtime builds its sessions: stage "prepare", which has no
// fraction to show and says so.
export interface ModelState {
  phase: "idle" | "loading" | "ready";
  stage: "download" | "prepare";
  frac: number;          // of the download, 0–1
  loadedMb: number; totalMb: number;
  etaS: number | null;   // seconds left of the download, once the rate is steady
}
const EXPECTED_BYTES = 79_430_000;
const MODEL_IDLE: ModelState = { phase: "idle", stage: "download", frac: 0, loadedMb: 0, totalMb: EXPECTED_BYTES / 1e6, etaS: null };
let modelState: ModelState = MODEL_IDLE;
const modelListeners = new Set<(s: ModelState) => void>();
export const speechModel = (): ModelState => modelState;
export function onSpeechModel(cb: (s: ModelState) => void): () => void {
  modelListeners.add(cb); cb(modelState);
  return () => { modelListeners.delete(cb); };
}
function setModel(s: ModelState): void { modelState = s; modelListeners.forEach(cb => cb(s)); }
const modelFiles = new Map<string, { loaded: number; total: number }>();
let modelT0 = 0, rateT = 0, rateB = 0, rate = 0;   // bytes/s, smoothed over the last few seconds
function modelProgress(d: { status?: string; file?: string; loaded?: number; total?: number }): void {
  if (modelState.phase === "ready" || !d.file) return;
  if (d.status !== "progress" && d.status !== "done") return;
  const prior = modelFiles.get(d.file);
  const total = d.total || prior?.total || 0;
  modelFiles.set(d.file, { loaded: d.status === "done" ? total : (d.loaded || 0), total });
  let loaded = 0, seen = 0;
  modelFiles.forEach(f => { loaded += f.loaded; seen += f.total; });
  const whole = Math.max(EXPECTED_BYTES, seen);
  const now = performance.now();
  if (!modelT0) { modelT0 = rateT = now; rateB = loaded; }
  if (now - rateT >= 700) {
    const inst = (loaded - rateB) / ((now - rateT) / 1000);
    rate = rate ? rate * 0.6 + inst * 0.4 : inst;
    rateT = now; rateB = loaded;
  }
  const frac = Math.max(modelState.frac, Math.min(1, loaded / whole));
  const steady = (now - modelT0) > 3000 && frac > 0.03 && rate > 0;
  setModel({ phase: "loading", stage: frac >= 0.985 ? "prepare" : "download", frac,
             loadedMb: Math.min(loaded, whole) / 1e6, totalMb: whole / 1e6,
             etaS: steady ? Math.max(1, Math.round((whole - loaded) / rate)) : null });
}

// The speech worker: asked a question at a time, by id (app/rpc.ts). A worker
// that dies ends every open question with the reason, and the next question
// starts a fresh one.
interface WhisperReply { id: number; ok: boolean; text?: string; error?: string; }
const whisperRpc = workerRpc<{ type: string; pcm?: Pcm }, WhisperReply>({
  spawn: () => new Worker(new URL("../../lib/asr-worker.js", import.meta.url), { type: "module" }),
  other: data => {
    const d = data as { progress?: Parameters<typeof modelProgress>[0] } | null;
    if (d && d.progress) modelProgress(d.progress);
  },
});

// how many REAL calls are still pending inside the worker — not the same
// as a withTimeout() wrapper giving up: a wrapper rejecting after its own
// bound does NOT cancel the underlying worker job, which keeps running
// and still lands eventually. liveTick's own tick cadence (every ~1.4s)
// used to just retry when its wrapper timed out, stacking a new REAL
// worker call behind each still-running one — during the ~44s a cold
// model load takes, that piles up ~30 concurrent inference/pipeline-
// creation calls into the SAME worker before the model is even ready.
// Verified live: a real hold-to-speak session that started during a cold
// load never resolved even after minutes, while a single isolated
// preload-then-transcribe pair resolved in under a second once cached —
// the difference was exactly this pile-up, not the model or the network.
let whisperInFlight = 0;
export function whisperBusy(): boolean { return whisperInFlight > 0; }

const whisper = (type: string, pcm?: Pcm): Promise<string> => {
  whisperInFlight++;
  if (modelState.phase === "idle") setModel({ ...MODEL_IDLE, phase: "loading" });
  return whisperRpc.ask(pcm ? { type, pcm } : { type }, pcm ? [pcm.buffer as ArrayBuffer] : []).then(r => {
    if (!r.ok) throw new Error(r.error);
    return r.text || "";
  }).then(
    text => { whisperInFlight--; markModelLoaded(); return text; },
    err => { whisperInFlight--; if (modelState.phase === "loading") setModel(MODEL_IDLE); throw err; },
  );
};

// the FIRST call in a session downloads ~75MB of model weights (verified
// live: onnx-community/moonshine-tiny-ONNX's encoder+decoder, over HF's
// xet-bridge) plus the ONNX Runtime WASM binary itself — genuinely over a
// minute even on a fast connection, not a hang. env.useBrowserCache keeps
// it in Cache Storage, so every call after the first in this browser reads
// from disk instead — a short bound is correct THEN, but wrong for the
// first call, which a short bound would cut off before it can ever finish.
let modelLoaded = false;
function whisperTimeoutMs(): number { return modelLoaded ? 20000 : 180000; }
function markModelLoaded(): void { modelLoaded = true; setModel({ ...modelState, phase: "ready", stage: "download", frac: 1, etaS: 0 }); }

// 16 kHz mono float → 16-bit WAV, base64 — the wire shape the gateway's
// 'transcribe expects (browser/repl.js does the same dance)
function encodeWav(pcm: Pcm, rate: number): ArrayBuffer {
  const buf = new ArrayBuffer(44 + pcm.length * 2), v = new DataView(buf);
  const str = (o: number, s: string) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
  str(0, "RIFF"); v.setUint32(4, 36 + pcm.length * 2, true); str(8, "WAVE");
  str(12, "fmt "); v.setUint32(16, 16, true); v.setUint16(20, 1, true);
  v.setUint16(22, 1, true); v.setUint32(24, rate, true);
  v.setUint32(28, rate * 2, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true);
  str(36, "data"); v.setUint32(40, pcm.length * 2, true);
  for (let i = 0; i < pcm.length; i++)
    v.setInt16(44 + i * 2, Math.max(-1, Math.min(1, pcm[i])) * 0x7fff, true);
  return buf;
}

const toB64 = (buf: ArrayBuffer): string => toBase64(new Uint8Array(buf));

// a recorded blob → 16 kHz mono PCM, the shape both whisper doors expect
async function decodeToPcm(blob: Blob): Promise<Pcm> {
  const ac = new AudioContext({ sampleRate: 16000 });
  const decoded = await ac.decodeAudioData(await blob.arrayBuffer());
  const pcm = decoded.getChannelData(0).slice();
  ac.close();
  return pcm;
}

// one clip → text: the on-device worker first — free, and the audio stays
// here — and the seam's gateway whisper (read at call time, so a standalone
// page simply skips it) for a clip the device heard nothing in. The gateway
// pass needs its own WAV, since the local pass transfers pcm.buffer.
async function transcribePcm(pcm: Pcm): Promise<string> {
  const h = seam.handlers;
  const wav = (h && h.transcribe) ? toB64(encodeWav(pcm, 16000)) : "";
  const local = ((await whisper("transcribe", pcm)) || "").trim();
  if (local || !wav) return local;
  // a real, upstream CapTP/WebSocket transport bug (deploy/UPSTREAM-ISSUES.md
  // #14): once a message larger than any prior one has been sent on this
  // connection, the reply never arrives — no error, no rejection, just an
  // unbounded hang. Any real clip beyond a couple seconds trips this on a
  // connection that's already carried smaller traffic. A short bound turns
  // that silent hang into an empty answer.
  try {
    return ((await withTimeout(h!.transcribe!(wav), 5000, "gateway transcribe")) || "").trim();
  } catch (_) {
    return "";
  }
}

// pressToSpeak(btn, { onText, onState, onLive, words }) — wire BTN to the
// hold-to-speak dance. Pointer capture keeps the release on the button
// wherever the finger drifts; a tap (<350 ms) is forgiven; while held, the
// growing clip is re-transcribed on-device every ~1.4 s and shown through
// onLive — bounded by caption-window.ts's commit ratchet, so a long hold's
// per-tick cost stays flat rather than growing with how long the mic has
// been open; the release pass over the FULL clip is authoritative and lands
// in onText. `words` overrides the status vocabulary (the log says "release
// to log" where the orb says "release to send"). The button carries class
// `rec` while hot.
function pressToSpeak(
  btn: HTMLElement,
  { onText, onState = () => {}, onLive = null, words = {} }: PressToSpeakOptions,
): void {
  const W: SpeakWords = { idle: "hold to speak",
              listening: "listening — release to send",
              tap: "press and KEEP holding to speak",
              busy: "transcribing…",
              nothing: "heard nothing — hold and speak",
              refused: "microphone refused", ...words };
  let state: "idle" | "recording" | "transcribing" = "idle";
  let job: RecordingJob | null = null, t0 = 0, liveBusy = false;
  // a hold must not become a scroll or a text selection on a phone: these
  // belong to the dance, not to any one mic's stylesheet
  btn.style.touchAction = "none";
  btn.style.userSelect = "none";
  (btn.style as CSSStyleDeclaration & { webkitUserSelect?: string }).webkitUserSelect = "none";

  async function finish(blob: Blob, stream: MediaStream): Promise<void> {
    stream.getTracks().forEach(t => t.stop());
    try {
      const pcm = await decodeToPcm(blob);
      const text = await withTimeout(transcribePcm(pcm), whisperTimeoutMs(), "transcription");
      state = "idle";
      if (!text) { onState(W.nothing); return; }
      onState(W.idle);
      onText(text);
    } catch (err) {
      state = "idle";
      onState(`transcription failed: ${errText(err)}`);
    }
  }

  // how long an unconfirmed block may grow before caption-window.ts commits
  // it and starts a fresh one — the bound on what whisper re-reads each tick
  const LIVE_BLOCK_SAMPLES = 8 * 16000;   // 8 s at whisper's 16 kHz

  // one live job at a time; interim best-effort — the release pass is the real one
  async function liveTick(chunks: Blob[], caption: CaptionState): Promise<CaptionState> {
    // whisperBusy() catches what liveBusy alone cannot: a PRIOR tick (or the
    // preload fired on press) whose own withTimeout gave up already, while
    // its real worker call is still running underneath — starting another
    // real call on top of that is exactly the pile-up that hangs a cold
    // model load (see whisper()'s own comment). Skipping the tick entirely
    // here is cheap; the release pass is still the authoritative read.
    if (liveBusy || whisperBusy() || state !== "recording" || !chunks.length || !onLive) return caption;
    liveBusy = true;
    let next = caption;
    try {
      // the FULL clip decodes every tick — decode is cheap, unlike inference,
      // so this is left ungrounded; only the WINDOW whisper reads is bounded
      const pcm = await decodeToPcm(new Blob(chunks));
      const [from, to] = windowFor(caption, pcm.length);
      const block = pcm.subarray(from, to);
      if (block.length >= 8000 && state === "recording") {     // ≥ ~0.5 s of audio
        const text = ((await withTimeout(whisper("transcribe", block), 12000, "live transcription")) || "").trim();
        if (state === "recording") {
          const step = applyTranscript(caption, text, block.length, LIVE_BLOCK_SAMPLES);
          next = step.state;
          if (step.caption) onLive(step.caption);
        }
      }
    } catch (_) { /* interim only — the release pass is the one that counts */ }
    liveBusy = false;
    return next;
  }

  btn.addEventListener("pointerdown", async e => {
    e.preventDefault();
    if (state !== "idle") return;
    try { btn.setPointerCapture(e.pointerId); } catch (_) { /* capture is a nicety */ }
    state = "recording"; t0 = performance.now();
    btn.classList.add("rec"); onState(W.listening);
    // first use downloads the model from a CDN — can take a while on a slow
    // connection, and with nothing shown here that reads exactly like a
    // stuck/broken worker. A one-shot hint after 3s (only if the model
    // still isn't ready) tells the citizen what's actually happening.
    let modelReady = false;
    const hint = setTimeout(() => {
      if (!modelReady && state === "recording") onState(`${W.listening} (downloading speech model, first use only…)`);
    }, 3000);
    withTimeout(whisper("preload"), whisperTimeoutMs(), "model preload")
      .then(() => { modelReady = true; clearTimeout(hint); if (state === "recording") onState(W.listening); })
      .catch(() => { modelReady = true; clearTimeout(hint); });
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      if (state !== "recording") {          // released before the mic opened
        stream.getTracks().forEach(t => t.stop());
        return;
      }
      const mime = window.MediaRecorder?.isTypeSupported?.("audio/webm;codecs=opus")
        ? "audio/webm;codecs=opus" : undefined;
      const rec = new MediaRecorder(stream, mime ? { mimeType: mime } : undefined);
      const chunks: Blob[] = [];
      let caption = blankCaptionState();    // this hold's own commit ratchet, fresh each press
      rec.ondataavailable = ev => { if (ev.data.size) chunks.push(ev.data); };
      rec.onstop = () => finish(new Blob(chunks), stream);
      rec.start(800);                       // emit chunks as we go → live caption
      const liveTimer = onLive ? setInterval(() => { liveTick(chunks, caption).then(c => { caption = c; }); }, 1400) : null;
      job = { rec, stream, liveTimer };
    } catch (_) {
      state = "idle"; btn.classList.remove("rec");
      onState(W.refused);
    }
  });

  function up(): void {
    if (state !== "recording") return;
    btn.classList.remove("rec");
    if (!job) { state = "idle"; onState(W.idle); return; }
    const { rec, stream, liveTimer } = job; job = null;
    if (liveTimer) clearInterval(liveTimer);
    if (performance.now() - t0 < 350) {     // a tap, not a hold
      rec.onstop = null;
      stream.getTracks().forEach(t => t.stop());
      try { rec.stop(); } catch (_) { /* already stopped */ }
      state = "idle"; onState(W.tap);
      return;
    }
    state = "transcribing"; onState(W.busy);
    rec.stop();                             // → finish → onText
  }
  btn.addEventListener("pointerup", up);
  btn.addEventListener("pointercancel", up);
  btn.addEventListener("contextmenu", e => e.preventDefault());
}

export { whisper, encodeWav, toB64, decodeToPcm, transcribePcm, pressToSpeak, withTimeout, whisperTimeoutMs };
