// app/signs.ts — the small signs a row wears, in one place.
//
// Two faces mark a row with a glyph whose words wait behind it: the store face
// marks a stock with what asks for attention (store-view.ts), and a photo read
// marks a row with how its figure stands (look.ts markOf). The two vocabularies
// say different things, and they are kept side by side here so no sign is used
// for two meanings.
/** What asks for attention on a stock: the glyph, and whether it is a warning. Keyed by the badge's words (store-view.ts badges). */
export const STOCK_GLYPHS = {
    "your count is contested": ["⚠", true],
    "count due": ["⏱", false],
    "perishes": ["🍂", false],
};
/** How a row's figure stands before it lands: the glyph, and the words behind it. */
export const MARK_GLYPHS = {
    agrees: ["✓", "as the ledger reads"], within: ["≈", "inside what the plan expects"],
    under: ["▼", "under what was to be there"], over: ["▲", "over what was to be there"],
    new: ["＋", "a first sighting"], unsure: ["?", "counted in another unit"],
};
