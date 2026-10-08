// app/voice/caption-window.ts — the live-caption state machine: how much of
// a growing recording to re-transcribe each tick, and when to freeze what
// has already been read as CONFIRMED, so the next tick's transcription
// doesn't keep growing with how long the mic has been held.
//
// Pulled out of audio.ts as its own module for the same reason app/utter.ts
// and app/fuzzy.ts are: the DECISION here — what to feed whisper, when a
// block is "done" — has nothing to do with AudioContext, MediaRecorder or a
// Worker, and is worth testing without any of them
// (tests/browser/caption-window-test.mjs, no DOM, no audio, no model).
//
// ── THE PROBLEM ──────────────────────────────────────────────────────────
// The live caption re-transcribes the WHOLE clip recorded so far, every
// ~1.4s, while the mic is held — so the tenth tick of a long hold re-reads
// everything the first nine already covered, and the per-tick whisper cost
// keeps climbing the longer someone speaks.
//
// ── THE FIX ──────────────────────────────────────────────────────────────
// A growing BLOCK of unconfirmed audio is re-transcribed each tick, same as
// before — but once a block reaches BLOCK_SAMPLES, its transcript is
// COMMITTED into a confirmed prefix and a fresh, empty block starts. The
// shown caption is always `confirmed + " " + the current block's own
// transcript`, so nothing a speaker said is ever dropped from view; only the
// SIZE of what whisper re-reads each tick is bounded — flat once a session
// runs long enough to commit at least once, rather than growing without
// limit.
//
// The commit is a one-way ratchet: once text is confirmed it is never
// re-read or revised by a later tick, even if a longer window would have
// transcribed those same words differently — a bounded, honest cost next to
// a real streaming model. Swapping the model itself for Moonshine tiny/base
// (`docs/planning/faces/voice-search-pipeline.md` §5.B) does not change this
// trade; only a genuinely incremental architecture — unavailable in-browser
// today, per that doc's research — would. The release-time pass
// (`transcribePcm`, over the FULL clip) is unaffected either way and stays
// the authoritative transcript.
//
// Decoding the whole growing clip every tick (audio.ts's `decodeToPcm`) is
// left alone: audio DECODE is cheap next to whisper INFERENCE, which is the
// actual, diagnosed cost — bounding decode too would solve a problem this
// clip length doesn't have.

export interface CaptionState {
  /** the sample index (into the whole recording) where the unconfirmed block begins */
  blockStart: number;
  /** everything already committed, joined by a single space; "" before the first commit */
  confirmed: string;
}

export const blankCaptionState = (): CaptionState => ({ blockStart: 0, confirmed: "" });

/**
 * The sample range the caller should feed whisper THIS tick, given TOTAL
 * samples decoded so far (the whole clip) — the unconfirmed block, never the
 * whole clip once at least one commit has happened.
 */
export function windowFor(state: CaptionState, total: number): [number, number] {
  return [state.blockStart, total];
}

/**
 * Given what whisper read out of that window (BLOCKTEXT) and how long the
 * window itself is (BLOCKLENGTH samples), the caption to show now and the
 * state to carry into the next tick — committed (a fresh, empty block from
 * this point on) once the block has grown to BLOCKSAMPLES, unchanged
 * otherwise. An empty BLOCKTEXT never commits: a long silence should not
 * freeze prematurely on nothing, and should keep being re-offered the chance
 * to read words once the speaker resumes.
 */
export function applyTranscript(
  state: CaptionState, blockText: string, blockLength: number, blockSamples: number,
): { caption: string; state: CaptionState } {
  const caption = [state.confirmed, blockText].filter(Boolean).join(" ");
  if (blockText && blockLength >= blockSamples)
    return { caption, state: { blockStart: state.blockStart + blockLength, confirmed: caption } };
  return { caption, state };
}
