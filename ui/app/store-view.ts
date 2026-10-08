// app/store-view.ts — the store as it is arranged, for the face that shows it.
//
// The store face reads what is held as a tree: places outermost first, what is
// held at each, and a container with what is in it a step in (docs/observation/
// capture.md §6, §10). This module is that arrangement and the questions the
// face asks of it: which stock a filter keeps, what to badge a row with, how to
// say the ledger in a line, in what order the counts due are listed. Pure over
// the rows the face already holds, so a unit test reads each answer.

import { nest, placePath, type PlaceRow } from "./store-tree.js";
import { cadence, type CountRow } from "./count.js";
import { STOCK_GLYPHS } from "./signs.js";
import type { ContestEntry } from "./contest.js";

/** What the tree needs of a stock. */
export interface Stockish {
  id?: string;
  name: string;
  /** The id of the place it is at, when the books name one. */
  location?: string;
  /** The id of the thing it sits in. */
  containedIn?: string;
  /** The rail it is held on. */
  rail?: string;
  /** A lot with a use-by date. */
  perishable?: boolean;
}

/** One line of the tree: a place heading, or a stock. */
export interface TreeNode<S extends Stockish = Stockish> {
  kind: "place" | "stock";
  /** The place's id (empty for the heading of what is held nowhere stated), or the stock's. */
  id: string;
  /** A place's path from the outermost; a stock's name. */
  name: string;
  /** How far in it sits: a place by what it is inside, a stock by place and container. */
  depth: number;
  /** What a place holds, counting what is in what it holds; what a container holds, for a stock. */
  holds: number;
  row?: S;
}

/** What held nowhere stated is gathered under. */
export const UNSTATED = "somewhere unstated";

/**
 * The tree of STOCKS over PLACES. A place shows when it holds stock or holds a
 * place that does, outermost first and each level in name order; stock that
 * names no place, or one the table does not hold, gathers at the end. A stock
 * inside another that the list holds follows it, a step in.
 */
export function storeTree<S extends Stockish>(stocks: S[], places: PlaceRow[]): TreeNode<S>[] {
  const known = new Set(places.map(p => p.id));
  const held = nest(stocks);                     // the stocks, containers first, with their depth
  const byPlace = new Map<string, typeof held>();
  for (const n of held) {
    // a stock inside another is read where its container is: it is in the same group
    const loc = n.row.location && known.has(n.row.location) ? n.row.location : "";
    const key = n.depth === 0 ? loc : "";
    if (n.depth > 0) continue;                    // placed below, under its container
    byPlace.set(key, [...(byPlace.get(key) ?? []), n]);
  }
  // each top-level stock brings its contents: the nodes after it of greater depth
  const withContents = (tops: typeof held): typeof held => {
    const out: typeof held = [];
    for (const t of tops) {
      const i = held.indexOf(t);
      out.push(t);
      for (let j = i + 1; j < held.length && held[j].depth > 0; j++) out.push(held[j]);
    }
    return out;
  };
  const kids = new Map<string, PlaceRow[]>();
  for (const p of places) {
    const parent = p.containedIn && known.has(p.containedIn) ? p.containedIn : "";
    kids.set(parent, [...(kids.get(parent) ?? []), p]);
  }
  const holdsIn = (id: string): number =>
    (byPlace.get(id)?.length ?? 0) + (kids.get(id) ?? []).reduce((n, k) => n + holdsIn(k.id), 0);

  const out: TreeNode<S>[] = [];
  const walk = (parent: string, depth: number, seen: Set<string>): void => {
    const here = (kids.get(parent) ?? []).slice().sort((a, b) => (a.name ?? a.id).localeCompare(b.name ?? b.id));
    for (const p of here) {
      if (seen.has(p.id) || holdsIn(p.id) === 0) continue;
      const own = byPlace.get(p.id) ?? [];
      out.push({ kind: "place", id: p.id, name: placePath(p.id, places), depth, holds: holdsIn(p.id) });
      for (const n of withContents(own))
        out.push({ kind: "stock", id: n.row.id ?? n.row.name, name: n.row.name, depth: depth + 1 + n.depth,
                   holds: n.holds, row: n.row });
      walk(p.id, depth + 1, new Set([...seen, p.id]));
    }
  };
  walk("", 0, new Set());
  const loose = byPlace.get("") ?? [];
  if (loose.length) {
    out.push({ kind: "place", id: "", name: UNSTATED, depth: 0, holds: loose.length });
    for (const n of withContents(loose))
      out.push({ kind: "stock", id: n.row.id ?? n.row.name, name: n.row.name, depth: 1 + n.depth,
                 holds: n.holds, row: n.row });
  }
  return out;
}

/** What a filter keeps; every field left out keeps everything. */
export interface StoreFilter {
  rail?: string;
  due?: boolean;
  contested?: boolean;
  perishable?: boolean;
  /** Words of a name: a stock keeps when its name holds them all. */
  q?: string;
}

/** Whether a stock stays under FILTER. */
export function keeps(row: Stockish, f: StoreFilter, schedule: Map<string, CountRow>,
                      contested: Map<string, ContestEntry>): boolean {
  if (f.rail && row.rail !== f.rail) return false;
  if (f.due && !(row.id && schedule.get(row.id)?.overdue)) return false;
  if (f.contested && !(row.id && contested.has(row.id))) return false;
  if (f.perishable && !row.perishable) return false;
  if (f.q && !named(row.name, f.q)) return false;
  return true;
}

/** Whether NAME holds every word of QUERY, in any order and any case. */
export function named(name: string, query: string): boolean {
  const n = name.toLowerCase();
  return query.toLowerCase().split(/\s+/).filter(Boolean).every(w => n.includes(w));
}

/** Whether FILTER keeps everything. */
export const unfiltered = (f: StoreFilter): boolean => !f.rail && !f.due && !f.contested && !f.perishable && !f.q?.trim();

/**
 * The tree under FILTER: the stock it keeps, and the place headings above them.
 * A container that fails the filter stays while something in it passes, so what
 * is kept is never shown out of its place.
 */
export function filterTree<S extends Stockish>(nodes: TreeNode<S>[], f: StoreFilter,
                                               schedule: Map<string, CountRow>,
                                               contested: Map<string, ContestEntry>): TreeNode<S>[] {
  if (unfiltered(f)) return nodes;
  const kept = nodes.map(n => n.kind === "stock" && !!n.row && keeps(n.row, f, schedule, contested));
  const keep = nodes.map((n, i) => {
    if (kept[i]) return true;
    // a heading or a container stays while anything after it, a step deeper, is kept
    for (let j = i + 1; j < nodes.length && nodes[j].depth > n.depth; j++) if (kept[j]) return true;
    return false;
  });
  return nodes.filter((_, i) => keep[i]);
}

/**
 * Whether a stock keeps for days at most: a lot with a use-by date, or a stock
 * whose stated keeping reads fresh or same day. The one rule, set on a row
 * where the row is built, so every view that counts what perishes counts the
 * same stock.
 */
export const perishable = (keeps: string | undefined, expiresKind?: string): boolean =>
  expiresKind === "use-by" || /fresh|same day/i.test(keeps || "");

/** How many of ROWS have an overdue count on SCHEDULE. */
export function dueCount(rows: Stockish[], schedule: Map<string, CountRow>): number {
  return rows.filter(s => s.id && schedule.get(s.id)?.overdue).length;
}

/** The rails ROWS sit on, in ORDER, each with how many rows are on it; a rail with none is left out. */
export function railCounts(rows: Stockish[], order: readonly string[]): { rail: string; n: number }[] {
  return order.map(rail => ({ rail, n: rows.filter(r => (r.rail || "own") === rail).length })).filter(c => c.n > 0);
}

/** The words a row is badged with, in the order a person weighs them. */
export function badges(row: Stockish, schedule: Map<string, CountRow>,
                       contested: Map<string, ContestEntry>): string[] {
  const out: string[] = [];
  if (row.id && contested.has(row.id)) out.push("your count is contested");
  if (row.id && schedule.get(row.id)?.overdue) out.push("count due");
  if (row.perishable) out.push("perishes");
  return out;
}

/** A badge as a row wears it: one glyph, the words behind it, and whether it asks for attention. */
export interface Glyph {
  glyph: string;
  word: string;
  warn: boolean;
}

/** The badges of ROW as glyphs, in the order a person weighs them: the row stays one line, the words wait behind the glyph. */
export function glyphs(row: Stockish, schedule: Map<string, CountRow>,
                       contested: Map<string, ContestEntry>): Glyph[] {
  return badges(row, schedule, contested).map(word => ({ glyph: STOCK_GLYPHS[word]?.[0] ?? "•", word, warn: STOCK_GLYPHS[word]?.[1] ?? false }));
}

/** One top-level place with everything in it: the unit the face lays out in columns. */
export interface Card<S extends Stockish = Stockish> {
  /** The place's id (empty for what is held nowhere stated). */
  id: string;
  name: string;
  /** What it holds, counting what is in what it holds. */
  holds: number;
  /** What follows its heading: the places inside it and the stock at each, in tree order. */
  nodes: TreeNode<S>[];
}

/** The tree cut at its outermost places, one card each, so a face can set them side by side. */
export function cards<S extends Stockish>(nodes: TreeNode<S>[]): Card<S>[] {
  const out: Card<S>[] = [];
  for (const n of nodes) {
    if (n.kind === "place" && n.depth === 0) out.push({ id: n.id, name: n.name, holds: n.holds, nodes: [] });
    else out[out.length - 1]?.nodes.push(n);
  }
  return out;
}

/** The ledger in a line: what is held, what is due, what is contested. */
export function ledgerLine(stocks: Stockish[], schedule: Map<string, CountRow>,
                           contested: Map<string, ContestEntry>): string {
  const n = stocks.length;
  const due = dueCount(stocks, schedule);
  const doubted = stocks.filter(s => s.id && contested.has(s.id)).length;
  const parts = [`${n} kind${n === 1 ? "" : "s"} held`];
  if (due) parts.push(`${due} count${due === 1 ? "" : "s"} due`);
  if (doubted) parts.push(`${doubted} contested`);
  return parts.join(" · ");
}

/** The schedule in the order it is worked: what is overdue first, then by when it falls due. */
export function dueOrder(rows: CountRow[]): CountRow[] {
  return rows.slice().sort((a, b) =>
    (a.overdue === b.overdue ? 0 : a.overdue ? -1 : 1) || a.due.localeCompare(b.due) || a.name.localeCompare(b.name));
}

/** When a count falls due, counted in days from NOW: "overdue 3 days", "due today", "due in 9 days". Empty with no date. */
export function dueWords(due: string, overdue: boolean, now: number): string {
  const at = Date.parse(due);
  if (!due || Number.isNaN(at)) return overdue ? "overdue" : "";
  const days = Math.round(Math.abs(at - now) / 86400000);
  const span = `${days} day${days === 1 ? "" : "s"}`;
  if (overdue) return days === 0 ? "overdue today" : `overdue ${span}`;
  return days === 0 ? "due today" : days === 1 ? "due tomorrow" : `due in ${span}`;
}

/** One schedule row in a sentence: how often, when it falls due, how long it takes. */
export function dueLine(r: CountRow, now: number = Date.now()): string {
  const when = dueWords(r.due, r.overdue, now);
  const hours = r.hours > 0 ? `${Math.round(r.hours * 60)} min` : "";
  return [cadence(r.interval) ? `counted ${cadence(r.interval)}` : "", when, hours].filter(Boolean).join(" · ");
}
