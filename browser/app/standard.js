// The ratified standard, stated once for the browser (the twin of
// `ratified-standard` in module/playnet/knowledge/catalogues/subsistence.scm).
//
// A scope's ratified standard lifts the floors its people are held to above bare
// adequacy, in every catalogue that carries an L4 layer: nutrition, housing and
// rest. It has one rule: it only raises. Below 1, absent or not a number, it is 1.
export function ratifiedStandard(x) {
    return typeof x === "number" && x > 1 ? x : 1;
}
/** A lift raises a floor by `factor` as far as the floor's own ceiling allows and stops there; it never lowers one. */
export function liftToCeiling(floor, ceiling, factor) {
    const raised = floor * factor;
    return ceiling == null ? raised : Math.max(floor, Math.min(raised, ceiling));
}
/** A floor never stands above its own ceiling: a requirement through its own toxic limit is a plan no one can meet. */
export function underCeiling(floor, ceiling) {
    return ceiling != null && floor > ceiling ? ceiling : floor;
}
