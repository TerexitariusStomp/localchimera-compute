// Who the universal mic speaks into.
//
// The footer mic is layout chrome — one button, on every face, described in
// share.ts as "the one spot that always records". A surface that wants spoken
// words therefore does not grow a mic of its own; it CLAIMS this one while it
// is open, and releases it when it closes. Two mics side by side in one bar
// would be two answers to "where do my words go", and the bar can only mean
// one of them.
//
// A single slot rather than a stack: at most one of these surfaces is open at
// a time, and a stack would only defer the question of which is on top.
// Release is identity-checked, so a late release from a surface that has
// already been superseded cannot take the microphone away from the one that
// has it now.
let current = null;
/**
 * Route the universal mic here until the returned release is called.
 * Claiming while another surface holds the mic supersedes it — the newly
 * opened surface is the one the speaker is looking at.
 */
export function claimVoice(sink) {
    current = sink;
    return () => { if (current === sink)
        current = null; };
}
/** The sink the mic should speak into, or null for the bar's own draft. */
export const voiceSink = () => current;
