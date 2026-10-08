// app/relocation.ts — a relocation is two rows of one run.
//
// A plan carries stock between places as a Process of its own (a run): a `pickup` at the
// origin is its input and a `dropoff` at the destination its output, both naming the run
// as `proc` (docs/planning/books/valueflows-native-inventory.md F1). The one place the two rows
// are paired, for the map's journey arcs and the plan board's haul lines.
/** The index among ROWS of the dropoff that completes pickup M: the same run, the same cargo; -1 when none. */
export function dropoffIndex(rows, m) {
    return rows.findIndex(x => x.action === "dropoff" && x.proc === m.proc && x.spec === m.spec);
}
