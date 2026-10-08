// app/partition.ts — a household as a set, its members and groups as blocks.
//
// The family face keys rows per WHO: an individual (thierry), a group of them
// (thierry+jolly — a couple sharing a cost once), or the household entire
// (all). Every one of those is a BLOCK of the set of individuals, and a block
// has a picture: the individuals stand on a circle, and the block is the
// rounded shape through its members — a dot for one, a capsule for two, a
// polygon for three or more (Jason Davies' set-partitions figure, 2012). The
// picture says at a glance whose row it is and how far it reaches.
//
// Sorting the rows is sorting blocks: the whole first, then the singletons,
// then the groups between — or any of the other orders a reader may want.
// Pure; tests/browser/partition-test.mjs pins it.

/** Which individuals a WHO names. `all` is everyone; "a+b" is those two;
 *  a name in GROUPS is that group; any other name is itself. */
export function membersOf(who: string, individuals: string[], groups: Record<string, string[]> = {}): string[] {
  const key = who.trim().toLowerCase();
  if (key === "all") return individuals.slice();
  if (key in groups) return groups[key].map(g => g.trim().toLowerCase()).filter(g => individuals.includes(g));
  if (key.includes("+")) return key.split("+").map(s => s.trim()).filter(s => individuals.includes(s));
  return individuals.includes(key) ? [key] : [];
}

/** The individuals of a ledger, in first-appearance order: every WHO that is
 *  neither `all`, a "+"-group, nor a named group — plus the members those
 *  groups name, so a couple's block has vertices to stand on even where no
 *  row is either spouse's own. */
export function individualsOf(whos: string[], groups: Record<string, string[]> = {}): string[] {
  const out: string[] = [];
  const add = (key: string) => { if (key && !out.includes(key)) out.push(key); };
  for (const raw of whos) {
    const key = raw.trim().toLowerCase();
    if (key === "all") continue;
    if (key in groups) { groups[key].forEach(m => add(m.trim().toLowerCase())); continue; }
    if (key.includes("+")) { key.split("+").forEach(m => add(m.trim())); continue; }
    add(key);
  }
  return out;
}

export type SortOrder = "all-individuals-groups" | "individuals-groups-all" | "groups-individuals-all" | "smallest-first" | "largest-first";
export const SORT_ORDERS: { id: SortOrder; label: string }[] = [
  { id: "all-individuals-groups", label: "all · individuals · groups" },
  { id: "individuals-groups-all", label: "individuals · groups · all" },
  { id: "groups-individuals-all", label: "groups · individuals · all" },
  { id: "smallest-first", label: "smallest block first" },
  { id: "largest-first", label: "largest block first" },
];

/** A rank for a block of SIZE members among N individuals under ORDER; ties
 *  keep their ledger order (a stable sort). */
export function blockRank(size: number, n: number, order: SortOrder): number {
  const kind = size >= n && n > 0 ? 0 : size <= 1 ? 1 : 2;   // whole, singleton, group
  switch (order) {
    case "all-individuals-groups": return [0, 1, 2][kind] * n + (kind === 2 ? -size : 0);
    case "individuals-groups-all": return [2, 0, 1][kind] * n + (kind === 2 ? size : 0);
    case "groups-individuals-all": return [2, 1, 0][kind] * n + (kind === 2 ? -size : 0);
    case "smallest-first": return size;
    case "largest-first": return -size;
  }
}

/** The vertices: N individuals on a circle of radius R about (0,0), the first at the top. */
export function vertices(n: number, r: number): [number, number][] {
  return Array.from({ length: n }, (_, i) => {
    const a = -Math.PI / 2 + (2 * Math.PI * i) / Math.max(1, n);
    return [r * Math.cos(a), r * Math.sin(a)];
  });
}

/** The block's shape as an SVG path through the vertices at INDICES (in
 *  circle order, so the polygon is convex). One vertex is a point, two a
 *  segment, three or more a closed polygon; drawn with a wide round stroke
 *  the three read as dot, capsule and rounded polygon. */
export function blockPath(indices: number[], n: number, r: number): string {
  const vs = vertices(n, r);
  const pts = indices.filter(i => i >= 0 && i < n).sort((a, b) => a - b).map(i => vs[i]);
  if (pts.length === 0) return "";
  const p = (v: [number, number]) => `${v[0].toFixed(2)},${v[1].toFixed(2)}`;
  if (pts.length === 1) return `M${p(pts[0])}l0,0`;
  return `M${pts.map(p).join("L")}${pts.length > 2 ? "Z" : ""}`;
}
