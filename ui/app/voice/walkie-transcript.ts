// app/walkie-transcript.ts — the room transcribes itself, at the edge.
//
// docs/planning/faces/meeting-station.md, Layer 2 (step 3). While you are live in a
// room, YOUR OWN microphone is transcribed on THIS device by the same local
// the on-device ASR model the orb uses (app/audio.js → a Web Worker), and each segment is
// posted to the room's chat topic as kind:"transcript". Audio never leaves the
// machine; only the words do, and they arrive already attributed — the chat
// registry stamps the author's AID and their stratum server-side
// (doors/service/chat.scm), so a transcript is a stream of authored lines rather
// than one blob with names in it.
//
// WHY EACH PEER TRANSCRIBES ITSELF, rather than one machine transcribing the
// mix: attribution comes free and correct (you can only ever post as yourself),
// nobody needs a server-side model, and the work scales with the room instead
// of piling onto one host. It is also the only version that can become the
// per-author ACDC of step 6 without being re-plumbed.
//
// WHAT GETS TRANSCRIBED IS WHAT YOU BROADCAST. The walkie is push-to-talk, and
// PTT is a `track.enabled` flip — a disabled track delivers SILENCE to every
// consumer, this tap included. So the room's record is what was actually said
// INTO the room, and holding the mic closed is genuinely off the record. That
// is a privacy property worth keeping: this must never grow a path that taps
// getUserMedia directly instead of the walkie's own track.

import { whisper } from './audio.js';

import { seam } from '../seam.js';

import { micTrack } from './mic.js';
/** A line that lands, for the UI. */
export type PostedLine = (text: string) => void;

// ── what counts as SPOKEN ───────────────────────────────────────────────────
// One definition, three readers: the chat face's spoken/typed filter, the line
// marker beside a message, and the wake's marker on a room's current
// utterance. Step 6 promotes transcript segments to per-speaker credentials
// (meeting-station.md §4); when it does, the new kind is added here and every
// reader follows — rather than being a grep across three files.
export const SPOKEN_KINDS = new Set<string>(["note", "transcript"]);
// `kind` is ABSENT on a typed message, which is the common case and already
// the answer both of these give — no kind is not spoken, and marks nothing.
export const isSpoken = (kind?: string): boolean => SPOKEN_KINDS.has(kind!);
export const spokenMark = (kind?: string): string =>
  kind === "transcript" ? "🎙 " : kind === "note" ? "📝 " : "";

// ── segmenter tuning ────────────────────────────────────────────────────────
// A segment is a run of speech ended by a short pause, capped so one long
// monologue still lands in readable pieces.
const RATE        = 16000;
const BLOCK       = 4096;                    // ~256 ms at 16 kHz
const RMS_SPEECH  = 0.012;                   // above this a block counts as voice
const SIL_BLOCKS  = 3;                       // ~0.77 s of quiet closes a segment
const MIN_VOICED  = 4;                       // ~1.0 s of voice before it is worth sending
const MAX_BLOCKS  = 47;                      // ~12 s hard cut

// whisper-tiny — the model this list was tuned against — hallucinates a
// small fixed vocabulary on near-silence. These are what IT invents when it
// hears nothing; dropping them keeps the record honest rather than
// sprinkling a meeting with phantom "thank you"s.
//
// app/audio.ts now runs Moonshine tiny underneath the same worker
// (voice-search-pipeline.md §5.B). This list and ANNOTATION below are
// UNVERIFIED against it — carried over rather than dropped, since a stale
// filter is at worst a no-op if Moonshine's phantom vocabulary differs, while
// removing it would silently let whisper-tiny's own hallucinations back in
// wherever the gateway's transcribe (still whisper-based) answers instead
// (transcribePcm tries the gateway before the local worker). Revisit once a
// real meeting's transcript surfaces what, if anything, Moonshine invents on
// silence — nothing here has been checked against real recorded speech.
const PHANTOM = new Set<string>([
  "you", "thank you.", "thank you", "thanks for watching!", "bye.", "bye",
  ".", "!", "?", "...", "so.", "so",
]);

// Whisper emits NON-SPEECH ANNOTATIONS — "[Music]", "[BLANK_AUDIO]",
// "(applause)" — describing what it heard rather than reporting words. A
// meeting's record should carry what people said, so a line that is nothing
// but an annotation is dropped. (Observed: a test tone transcribes as
// "[Music]", which would otherwise be posted as if someone had spoken it.)
// Whether Moonshine emits the same style of annotation is unverified.
const ANNOTATION = /^[\[(][^\])]*[\])][.!?]?$/;

let ctx: AudioContext | null = null, node: ScriptProcessorNode | null = null, src: MediaStreamAudioSourceNode | null = null;
// One buffer for the longest segment we will ever cut, filled in place. The
// alternative — a Float32Array per block plus a concat on flush — allocates
// ~16 KB four times a second and up to 770 KB per segment, on the main thread,
// during a call.
let pcm: Float32Array | null = null, used = 0, voiced = 0, quiet = 0, running = false;
let topic: string | null = null, busy = false, onPosted: PostedLine | null = null;

function reset(): void { used = 0; voiced = 0; quiet = 0; }

// One segment at a time: a 12 s clip is not instant, and a
// backlog of overlapping jobs would reorder the transcript. Dropping a segment
// while busy is the right trade — a meeting keeps talking.
async function flush(clip: Float32Array): Promise<void> {
  busy = true;
  try {
    const text = ((await whisper("transcribe", clip)) || "").trim();
    const bare = text.toLowerCase().replace(/\s+/g, " ").trim();
    if (text && !PHANTOM.has(bare) && !ANNOTATION.test(bare) && bare.length > 1) {
      const H = seam.handlers;
      // `topic` is re-read AFTER the await, and stopRoomTranscript() clears it —
      // so a segment whose transcription outlived its room used to post to a null
      // topic. Leaving the room takes its words with it, which is the same
      // promise the header makes about a closed mic.
      if (H && H.chat && topic) {
        const r = await H.chat("post", topic, text, "transcript");
        if (typeof r === "string" && !r.startsWith("err:") && onPosted) onPosted(text);
      }
    }
  } catch (_) { /* a dropped segment is a gap, never a broken call */ }
  busy = false;
}

function onBlock(e: AudioProcessingEvent): void {
  if (!running) return;
  const inBuf = e.inputBuffer.getChannelData(0);
  let sum = 0;
  for (let i = 0; i < inBuf.length; i++) sum += inBuf[i] * inBuf[i];
  const rms = Math.sqrt(sum / inBuf.length);

  if (rms > RMS_SPEECH) { voiced++; quiet = 0; }
  else if (voiced) { quiet++; }        // keep the tail of a phrase
  else return;                         // pure silence: nothing to hold
  // `running` is only ever set after start() allocated pcm, and onBlock returns
  // above unless running — so the buffer is here.
  const buf = pcm!;
  buf.set(inBuf, used); used += inBuf.length;

  const done = (quiet >= SIL_BLOCKS) || (used + BLOCK > buf.length);
  if (!done) return;

  // The busy check belongs HERE, not inside flush: a segment arriving while
  // whisper is still working is dropped, and dropping it before the work is
  // the difference between a gap and a wasted copy of up to twelve seconds
  // of audio — which is exactly when it happens, mid-monologue.
  // `slice`, not `subarray`: app/audio.js posts the clip to the worker with
  // its buffer in the TRANSFER list, which would detach the shared buffer and
  // leave every later segment writing into nothing. One copy per segment is
  // the price of that hand-off — still far below a copy per block.
  if (voiced >= MIN_VOICED && !busy && topic) flush(buf.slice(0, used));
  reset();
}

/// Begin transcribing our own mic into TOPIC. Safe to call repeatedly; a call
/// with a different topic re-points the stream. POSTED is an optional callback
/// run with each line that lands, for the UI.
export function startRoomTranscript(nextTopic: string | null | undefined, posted?: PostedLine | null): boolean {
  topic = nextTopic || null;
  onPosted = posted || null;
  if (running || !topic) return running;
  const track = micTrack();                  // the walkie's own track, never a fresh getUserMedia
  if (!track) return false;
  try {
    pcm = pcm || new Float32Array(MAX_BLOCKS * BLOCK);
    ctx = new AudioContext({ sampleRate: RATE });
    src = ctx.createMediaStreamSource(new MediaStream([track]));
    // ScriptProcessor is deprecated in favour of AudioWorklet, which needs a
    // separate module URL; for a 16 kHz mono VAD this is the smaller honest
    // thing, and it runs everywhere the walkie runs.
    node = ctx.createScriptProcessor(BLOCK, 1, 1);
    node.onaudioprocess = onBlock;
    src.connect(node);
    // A ScriptProcessor only pulls while connected to a sink. Route it into a
    // muted gain so nothing is ever played back — connecting to the
    // destination directly would echo your own voice into the room.
    const mute = ctx.createGain();
    mute.gain.value = 0;
    node.connect(mute); mute.connect(ctx.destination);
    running = true;
    reset();
  } catch (_) { running = false; }
  return running;
}

export function stopRoomTranscript(): void {
  running = false; topic = null; onPosted = null;
  reset();
  try { if (node) node.disconnect(); } catch (_) {}
  try { if (src) src.disconnect(); } catch (_) {}
  try { if (ctx) ctx.close(); } catch (_) {}
  ctx = node = src = null;
}

export function roomTranscriptRunning(): boolean { return running; }
