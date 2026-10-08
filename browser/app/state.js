// app/state.ts — the dial's shared MUTABLE state.
//
// These values are reassigned across many render functions. ES module import
// bindings are read-only for the importer, so a plain `export let turnH` could
// not be written from another module. Instead they live as fields on this one
// object that every module reads and MUTATES in place (S.turnH = …) — the same
// pattern the seam uses for its data bag. Keep this list small: only add a
// field here when a value genuinely has to be written from more than one module.
export const S = {
    turnH: 24,
    nowAbs: 155 * 24 + 6.0,
    viewTurnOffset: 0,
    VE: 4.0,
    sigma: 0,
    morphFrom: null,
    morphU: 1,
    root: null,
    desc: null,
};
