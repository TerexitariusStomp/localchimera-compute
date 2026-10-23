// SPDX-License-Identifier: AGPL-3.0-or-later
// app/voice/mic.ts — the walkie's own outbound audio track, handed over.
//
// The live layer (day-boot.js) opens ONE mic track for push-to-talk and flips
// `enabled` on it; the transcript module reads that same track rather than
// asking getUserMedia itself, so a closed mic delivers silence there too —
// the privacy property the header promises. One provider, any reader.
let track = null;
/** The walkie's mic track, or null before the walkie opened one. */
export const micTrack = () => track;
/** Installed by the live layer when the mic opens; null when it closes. */
export function provideMic(t) { track = t; }
