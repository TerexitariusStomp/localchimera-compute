// app/store-tree.ts — a store as it is arranged: places inside places, things
// inside things.
//
// Two trees, kept apart by whether a thing moves (docs/observation/capture.md
// §6): a shelf is a place, a bin on the shelf is a container and is carried to
// another shelf with what is in it. This module reads both off flat lists, the
// way the wire carries them, each entry naming what it is inside. Pure, so the
// inventory face, the capture sheet and a unit test read the same arrangement.

/** A place, as far as its path needs it. */
export interface PlaceRow {
  id: string;
  name?: string;
  /** The id of the place this one is inside. */
  containedIn?: string | null;
}

/** A thing, as far as nesting needs it. */
export interface Nestable {
  id?: string;
  /** The id of the thing this one is inside. */
  containedIn?: string | null;
}

/** A thing with how deep it sits and whether anything sits in it. */
export interface Nested<T> {
  row: T;
  depth: number;
  holds: number;
}

const SEPARATOR = " › ";

/**
 * A place's path from the outermost place inward: "Mill House › Pantry ›
 * Shelf 1". An id the table does not hold reads as itself, and a table that
 * names a place inside itself is walked once.
 */
export function placePath(id: string | null | undefined, places: PlaceRow[]): string {
  if (!id) return "";
  const by = new Map(places.map(p => [p.id, p]));
  const names: string[] = [];
  const seen = new Set<string>();
  for (let at: string | null | undefined = id; at && !seen.has(at); at = by.get(at)?.containedIn) {
    seen.add(at);
    const p = by.get(at);
    names.unshift(p?.name || at);
    if (!p) break;
  }
  return names.join(SEPARATOR);
}

/**
 * Things in the order a store is read: each container, then what is in it, a
 * level deeper. A thing inside something the list does not hold stands at the
 * top, and the order given is kept among siblings.
 */
export function nest<T extends Nestable>(rows: T[]): Nested<T>[] {
  const ids = new Set(rows.map(r => r.id).filter((x): x is string => !!x));
  const kids = new Map<string, T[]>();
  const tops: T[] = [];
  for (const r of rows) {
    const p = r.containedIn;
    if (p && p !== r.id && ids.has(p)) kids.set(p, [...(kids.get(p) ?? []), r]);
    else tops.push(r);
  }
  const out: Nested<T>[] = [];
  const seen = new Set<T>();
  const walk = (r: T, depth: number): void => {
    if (seen.has(r)) return;
    seen.add(r);
    const mine = (r.id && kids.get(r.id)) || [];
    out.push({ row: r, depth, holds: mine.length });
    mine.forEach(k => walk(k, depth + 1));
  };
  tops.forEach(r => walk(r, 0));
  // a ring of things each inside the next has no top; they are read flat
  rows.forEach(r => walk(r, 0));
  return out;
}
