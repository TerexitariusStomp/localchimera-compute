// app/stage.ts — how the dial is ARRANGED right now.
//
// state.ts holds what the dial is SHOWING — the turn, the tree, σ. This holds
// how it is arranged to show it: which face owns the stage, whether the angle
// means an hour or a bearing, what the earth is lensed through, and where the
// hand stands. Same reason, same shape: a value written from one module and
// read from six cannot be an exported `let`, because an importer may not
// assign one.
//
// ── WHY THIS EXISTS, AND WHAT IT REPLACED ───────────────────────────────────
// Nine modules were being handed these four values through nine HOST
// interfaces, and main answered "am I on the earth?" identically in five of
// them. A host is the right shape for a question only the dial can answer about
// ITSELF — what to redraw, where to fly, what a tap means. It is the wrong
// shape for a fact, and these are facts. Every host member that just forwarded
// one of them is gone.
//
// Keep this small, on state.ts's own rule: a field belongs here only when it is
// genuinely written from one place and read from several.
export const stage = {
    mode: "dial",
    face: "time",
    leaf: null,
    leafK: -1,
    hand: 6.0,
    // `focus` is null only between this module's evaluation and the first
    // buildRoot — nothing reads the dial before there is a tree to read. Typed
    // non-null so that fact is stated once, here, rather than asserted at fifty
    // call sites.
    focus: null,
    cums: [],
    zooming: false,
};
/** Whether the earth is up — the angle means a bearing. */
export const onEarth = () => stage.mode === "earth";
/**
 * Whether the MAP face owns the stage.
 *
 * Distinct from onEarth, and the distinction is load-bearing: the map face is a
 * RECTANGLE with no disc geometry, while the earth reached by drilling a desire
 * band is a circular disc welded to the dial. Both are `mode === "earth"`; only
 * one of them has a dial around it.
 */
export const onMapFace = () => onFace("map");
/**
 * Whether `id` is the face that owns the stage.
 *
 * Ask the RECORD, not the paint. `setFace` writes `stage.face` and then dresses
 * the DOM to match — the `on` class on a rail, an overlay's `.on`, a layer's
 * `display` — so a module that reads its own `#…Secs.on` is reading the shadow
 * of this answer rather than the answer. Equivalent while they agree, and one
 * of them is the thing that decides.
 */
export const onFace = (id) => stage.face === id;
