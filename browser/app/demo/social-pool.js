// app/demo/social-pool.ts — the scope's pooled needs and means, offline.
//
// The match ring (match.ts) and the share bar (share.ts) read the scope's whole
// pool: every citizen's standing needs and every declared means, yours among
// them, in the shape the gateway's match-slots door answers in. Offline that pool
// is the demo world's one table of slots (demo/world.ts SLOTS), read here as the
// pool; the map reads the same table as what stands at a place (atlas.ts), so a
// need or an offer is one row wherever it is seen.
import { scopePool } from './world.js';
/** The demo world's slots as the scope's pool. */
export const SOCIAL_DEMO_POOL = scopePool();
