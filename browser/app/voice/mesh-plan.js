// app/voice/mesh-plan.ts — how much video one person sends into a room, and how
// big a room can be.
//
// A room is a full mesh: everyone sends their video to everyone else, so what a
// person uploads is one stream per peer. This leaf holds the ONE budget that
// bounds that upload and derives everything else from it:
//
//   VIDEO_BUDGET   the bits per second of video a person sends in all
//   MIN_VIDEO      the smallest stream still worth sending
//   maxPeers       how many peers fit: the budget divided by the smallest stream
//   videoPlan(n)   what each of N peers' streams may use
//
// The ceiling comes out of the same two numbers the plan uses, so a room never
// admits a peer the plan could not give MIN_VIDEO to: the sum of the streams
// stays within the budget at every size a room can reach. Audio costs a fraction
// of a stream and rides along.
//
// Pure, no imports: the page applies the plan (browser/day-boot.js) and the
// spine reads the ceiling (hoot/day-boot.scm), from this one file
// (tests/browser/mesh-plan-test.mjs).
/** Bits per second of video one person sends into a room, summed over its peers. */
export const VIDEO_BUDGET = 2_500_000;
/** The smallest video stream worth sending, bits per second (a small tile). */
export const MIN_VIDEO = 200_000;
/** The most one stream uses, however few the peers: a tile does not need more. */
export const MAX_VIDEO = 1_500_000;
/** Peers besides yourself: the room's size is this plus one. */
export const maxPeers = Math.floor(VIDEO_BUDGET / MIN_VIDEO) - 1;
/** What each video sender may use when you hold PEERS connections. */
export function videoPlan(peers) {
    const n = Math.max(1, Math.min(maxPeers, Math.floor(peers)));
    const rate = Math.max(MIN_VIDEO, Math.min(MAX_VIDEO, Math.floor(VIDEO_BUDGET / n)));
    const scaleDown = rate >= 1_000_000 ? 1 : rate >= 500_000 ? 1.5 : rate >= 300_000 ? 2 : 3;
    return { maxBitrate: rate, scaleDown };
}
