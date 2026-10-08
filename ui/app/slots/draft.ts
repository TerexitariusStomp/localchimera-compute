// app/slots/draft.ts — the expanded draft panel: what the creation pill sets
// BEFORE the ➕. (The mic's words do not land here: they land in the Express
// input itself, and the bar's readings row is what says what they are.)
//
// free-association's ToolBar keeps one slide-down region under its draft pill
// whose content swaps per tab (`showExpandedDraft` + `expandedDraftTab`); this
// is that region on our pill. Each tab is one row of TABS — its label and its
// renderer — and every renderer writes into one of two places: the pill's
// FIELDS (name · emoji · qty · unit, reached through the accessor the pill
// hands over) or the DRAFT (arcs · where · cats · spec, the closure the pill
// owns). None of them declares: the ➕ stays the only commit, so the panel
// carries no store and dies with the pill's next submit.
//
//   type      the folksonomy spine as an emoji+label grid grouped by parent,
//             sifted by the name input (the name doubles as the type search);
//             a pick fills name/emoji, seeds cats with the term's chain and
//             the spec when the term is a known one
//   when      the card's own arcsEditor, on the draft
//   where     the card's own whereEditor, on the draft
//   unit      UNITS as a tappable grid, with the reading below
//   emoji     the glyphs the plan and inventory already carry, plus a floor

import { S } from '../state.js';
import { EXT, PLAN } from '../core.js';
import { termChain, indexDescendants } from '../spine.js';
import { runPass, aiAvailable } from '../day/extract.js';
import { arcsEditor, whereEditor } from './editors.js';
import { UNITS, knownSpecRows, knownEmoji, locationOptions, blankDraft }
  from './model.js';
import type { Draft, SlotKind, Arc, LocationOption, SpecRow, UnitOption } from './model.js';
import type { DesireNode } from '../desire.js';
import { mk as el } from '../dom.js';

/** The pill's four inputs, as one value. */
export interface PillFields { name: string; emoji: string; qty: number; unit: string }

/** How the panel reaches the pill: read the fields, write some, move focus. */
export interface PillAccess {
  get(): PillFields;
  set(patch: Partial<PillFields>): void;
  focus(which: "name" | "qty"): void;
}

export type DraftTab = "type" | "when" | "where" | "unit" | "emoji";

export interface DraftPanelConfig {
  pill: PillAccess;
  kind(): SlotKind;
  setKind(k: SlotKind): void;
  here(): string | null;
  /** The draft or the open tab moved: the pill re-lights its toggles. */
  onChange(): void;
  /** Make a place from a name (+ optional coordinates); resolves to its id. */
  onNewPlace?(name: string, lat: number, lon: number, address: string): Promise<string | null>;
  /** False where the type picker only narrows a search — no ➕ to declare the
   *  unmatched word as a new term (e.g. Resources browsing the same spine). */
  canDeclare?(): boolean;
  /** True while the top-level terms are shown as a row above the bar, so the picker's own top row is not drawn again. */
  topIsBar?(): boolean;
}

export interface DraftPanel {
  el: HTMLElement;
  draft: Draft;
  tab(): DraftTab | null;
  /** Open this tab (idempotent). */
  show(t: DraftTab): void;
  /** Open the type drill one level down, at this top-level term. */
  openAt(n: DesireNode): void;
  /** Open this tab, or close the panel when it is the one already open. */
  toggle(t: DraftTab): void;
  close(): void;
  /** Redraw the open tab — the pill's fields moved under it (the name sifts the type picker). */
  refresh(): void;
  /** Empty the draft (a declare happened). */
  reset(): void;
}


// one card grammar for the grids — free-association's type-grid-item: the
// glyph on top, the label under it; terms, units and emoji all read the same
const card = (glyph: string | HTMLElement, label: string, on: boolean, pick: () => void): HTMLElement => {
  const b = el("a", "sp-item" + (on ? " on" : ""));
  b.appendChild(typeof glyph === "string" ? el("span", "sp-glyph", glyph) : glyph);
  if (label) b.appendChild(el("span", "sp-label", label));
  b.addEventListener("click", pick);
  return b;
};

// ── reading a sentence into a slot ─────────────────────────────────────────
// The AI's slot pass when the door is open; the floor when it is not — the
// words become the name, and the classify pass fills cats after the ➕.
export interface SlotReading {
  fields: Partial<PillFields>;
  draft: Partial<Draft>;
  /** True when the pass read a slot out of the words (false = the floor). */
  read: boolean;
}
export async function readSlot(text: string, kind: SlotKind, locs: LocationOption[]): Promise<SlotReading> {
  const got = aiAvailable()
    ? await runPass("slot", { text, kind, places: locs.map(l => l.name) }) : null;
  const s = got && got.slot;
  if (!s) return { fields: { name: text.slice(0, 40) }, draft: {}, read: false };
  const place = locs.find(l => l.name.toLowerCase() === s.where.toLowerCase());
  return {
    fields: { name: s.name, emoji: s.emoji, qty: s.qty, unit: s.unit },
    draft: { spec: s.known ? s.spec : null, arcs: s.arcs as Arc[],
             where: place ? place.id : s.where },
    read: true,
  };
}

// ── the panel ──────────────────────────────────────────────────────────────
export function draftPanel(cfg: DraftPanelConfig): DraftPanel {
  const draft = blankDraft();
  let cur: DraftTab | null = null;

  // no header bar: the toolbar control that opened the tab already shows
  // which one is live (the lit toggle, the pill's own focus) — a second
  // label above the body just repeated it while eating the height a
  // cramped-feeling toolbar needed. The close affordance is a small corner
  // mark over the body instead of a whole row.
  const root = el("div", "share-panel");
  const x = el("a", "sp-close", "✕");
  x.title = "close";
  x.addEventListener("click", () => close());
  const body = el("div", "sp-body");
  root.append(x, body);

  const render = (): void => {
    body.replaceChildren();
    root.classList.toggle("on", cur !== null);
    // "type" alone wears its own layout (sp-wide): the taxonomy drill lays
    // one full-width bar per level, sharing it among however many siblings
    // a level holds — real room a fixed small popover cannot give it. Every
    // other tab (unit, emoji, where) is a short list or a grid and
    // stays in the compact popover family.
    root.classList.toggle("sp-wide", cur === "type");
    if (cur) { body.title = TABS[cur].title; TABS[cur].render(); }
    cfg.onChange();
  };
  const show = (t: DraftTab): void => { if (cur !== t) { cur = t; render(); } };
  const close = (): void => { if (cur !== null) { cur = null; typePath = []; unitBase = null; render(); } };
  const setDraft = (patch: Partial<Draft>): void => { Object.assign(draft, patch); render(); };

  // ── type: pick a real spec, grouped by where the spine files it ──────────
  // A branch's cells are the SPECS classified under it (an inventory spec's
  // own categories, or a plan need — whose id in this taxonomy IS a term-id)
  // — the citizen names a real, declarable thing, not a category. A leaf with
  // nothing catalogued yet falls back to the bare term, so the picker still
  // seeds a new spec's cats and never goes empty.
  const pickSpec = (name: string, emoji: string, spec: string | null, cats: string[]): void => {
    cfg.pill.set({ name, ...(emoji ? { emoji } : {}) });
    draft.spec = spec;
    draft.cats = cats;
    close();
    cfg.pill.focus("qty");
  };
  // the specs filed AT a node — exactly that node, not its ancestors or its
  // siblings' branches; indexDescendants makes a leaf's own set just {itself}
  const specsAt = (rows: SpecRow[], desc: Map<string, Set<string>>, k: DesireNode): SpecRow[] => {
    const under = desc.get(k.id) || new Set([k.id]);
    return rows.filter(r => r.cats.some(c => under.has(c)));
  };
  // does q match somewhere in k's own subtree — its name, a descendant
  // term's name, or a spec filed anywhere under it? The one predicate a
  // query filters EVERY level's segments through, so typing narrows the
  // SAME bars rather than swapping to a different view.
  const nameMatches = (n: DesireNode, q: string): boolean =>
    String(n.name || n.id).toLowerCase().includes(q)
    || (n.children || []).some(c => nameMatches(c, q));
  const subtreeMatches = (n: DesireNode, q: string, rows: SpecRow[], desc: Map<string, Set<string>>): boolean =>
    nameMatches(n, q) || specsAt(rows, desc, n).some(r => r.name.toLowerCase().includes(q));

  // ── type: drill down the spine, one block per level ──────────────────────
  // Each level is a group of segments — every sibling as wide as its words
  // need, wrapping to further lines, tinted by the term's own colour (the same palette the
  // wheel already reads off S.root) — dim until picked, solid once it is. One
  // tap drills to that term's children as the row below; the row above stays,
  // so the whole path down reads as a stack, not a single swap. At a leaf
  // (nothing further to drill into) the next row is either the real specs
  // filed there, or — filed with nothing yet — one line that commits the
  // bare term itself.
  //
  // A level is a GROUP of siblings, and its label is never cut: the segments
  // wrap onto as many lines as the words need, each keeping its own width, so
  // the whole group stays one tinted block. A child level sits indented under
  // its parent with a rail in the parent's colour (`sp-child`, --row-col), so
  // "one of these siblings, and what is inside it" reads at a glance.
  //
  // A QUERY filters this SAME structure rather than replacing it: a segment
  // shows only when it (or something in its own subtree — a descendant
  // term's name, or a spec filed anywhere under it) matches. A manual drill
  // (typePath) is NOT reset by typing, so narrowing while already three
  // levels deep re-filters all three bars in place. With no manual drill yet,
  // a query auto-opens the path down through each level's SOLE match — the
  // classification "opens up below" as you type instead of sitting closed
  // until tapped — and stops auto-descending the moment a level has more
  // than one match, handing the choice back to a tap.
  let typePath: DesireNode[] = [];
  const autoPath = (spine: DesireNode, q: string, rows: SpecRow[], desc: Map<string, Set<string>>): DesireNode[] => {
    const path: DesireNode[] = [];
    let cur = spine;
    for (;;) {
      const kids = (cur.children || []).filter(n => subtreeMatches(n, q, rows, desc));
      if (kids.length !== 1) break;
      path.push(kids[0]); cur = kids[0];
    }
    return path;
  };
  const renderTypeDrill = (q: string): void => {
    const spine = S.root!;
    const em = knownEmoji(EXT, PLAN);
    const desc = indexDescendants(spine);
    const rows = knownSpecRows(EXT, PLAN);
    const path = typePath.length ? typePath : (q ? autoPath(spine, q, rows, desc) : []);
    let shown = 0;
    // a row of siblings, under PARENT (none at the top): indented and railed
    // in the parent's colour when it is a child level
    const groupOf = (row: HTMLElement, depth: number, parent?: DesireNode): void => {
      row.style.setProperty("--depth", String(Math.min(depth, 4)));
      if (parent) { row.classList.add("sp-child"); row.style.setProperty("--row-col", parent.col || "#9a9384"); }
    };
    const segRow = (all: DesireNode[], depth: number, parent?: DesireNode): void => {
      const items = q ? all.filter(n => subtreeMatches(n, q, rows, desc)) : all;
      if (!items.length) return;
      const row = el("div", "sp-segrow");
      groupOf(row, depth, parent);
      for (const n of items) {
        const active = path[depth] === n;
        const seg = el("a", "sp-seg" + (active ? " on" : ""), n.name || n.id);
        seg.style.setProperty("--seg-col", n.col || "#9a9384");
        seg.addEventListener("click", () => {
          typePath = active ? path.slice(0, depth) : path.slice(0, depth).concat(n);
          renderBody();
        });
        row.appendChild(seg); shown++;
      }
      body.appendChild(row);
    };
    // the top level is drawn once: by the row above the bar while it shows, and
    // by this picker's own row otherwise (until a term is chosen there)
    if (!cfg.topIsBar?.() && (!path.length || q)) segRow(spine.children || [], 0);
    path.forEach((n, i) => segRow(n.children || [], i + 1, n));
    const deepest = path[path.length - 1];
    if (deepest && !(deepest.children && deepest.children.length)) {
      const specs = specsAt(rows, desc, deepest).filter(r => !q || r.name.toLowerCase().includes(q));
      if (specs.length) {
        const row = el("div", "sp-segrow sp-segrow-specs");
        groupOf(row, path.length, deepest);
        for (const r of specs) {
          const e = r.emoji || em.get(r.id) || em.get(r.name.toLowerCase()) || "";
          const seg = el("a", "sp-seg sp-seg-spec", (e ? e + " " : "") + r.name);
          seg.addEventListener("click", () => pickSpec(r.name, e, r.id, r.cats));
          row.appendChild(seg); shown++;
        }
        body.appendChild(row);
      } else if (!q) {
        const ghost = el("div", "sp-ghost", `nothing filed under “${deepest.name || deepest.id}” yet — `);
        const commit = el("a", "sp-seg-commit", `use it as a new spec`);
        commit.addEventListener("click", () =>
          pickSpec(deepest.name || deepest.id, em.get(deepest.id) || "", null, termChain(deepest)));
        ghost.appendChild(commit);
        body.appendChild(ghost);
        shown++;
      }
    }
    if (!shown) body.appendChild(el("div", "sp-ghost", cfg.canDeclare && !cfg.canDeclare()
      ? "nothing in the taxonomy says this"
      : "nothing in the taxonomy says this — ➕ declares it as a new term"));
  };
  // re-render just the type body without touching the panel's open/closed
  // state or the other tabs — a drill click (or a keystroke) never leaves it
  const renderBody = (): void => { body.replaceChildren(); renderType(); };
  const renderType = (): void => {
    const q = cfg.pill.get().name.trim().toLowerCase();
    const spine = S.root;
    if (!spine || !(spine.children || []).length) {
      body.appendChild(el("div", "sp-ghost", "no taxonomy yet — the name you type declares as-is"));
      return;
    }
    renderTypeDrill(q);
  };

  // ── unit / emoji: grids over the lists the pill already offers ──
  // Units group by what they measure (count, mass, volume, time, energy)
  // rather than sitting as one flat row. A BASE that carries rate siblings
  // (kg ↔ kg/day ↔ kg/week; hours ↔ hours/day ↔ hours/week) shows once at
  // this level; tapping it swaps the SAME box to those siblings alone,
  // behind a back arrow — the "stock or a day or a week" question asked
  // only once a base names what it's a rate OF, the same swap-in-place the
  // clock's own Custom uses. A base with no siblings (each, liters, kWh…)
  // commits straight away, same as always.
  const UNIT_GROUPS = ["count", "mass", "volume", "time", "energy"];
  const unitFamily = (baseId: string): UnitOption[] =>
    UNITS.filter(u => u.id === baseId || u.id.startsWith(baseId + "/"));
  let unitBase: string | null = null;
  const renderUnit = (): void => {
    const now = cfg.pill.get().unit;
    if (unitBase) {
      const back = el("a", "sp-back");
      back.append(el("span", "sp-back-i", "←"), el("span", null, "units"));
      back.addEventListener("click", () => { unitBase = null; render(); });
      body.appendChild(back);
      const grid = el("div", "sp-grid");
      for (const u of unitFamily(unitBase))
        grid.appendChild(card(u.emoji, u.label, now === u.id, () => { cfg.pill.set({ unit: u.id }); close(); }));
      body.appendChild(grid);
      return;
    }
    const bases = UNITS.filter(u => !u.id.includes("/"));
    for (const g of UNIT_GROUPS) {
      const us = bases.filter(u => u.group === g);
      if (!us.length) continue;
      const grp = el("div", "sp-group");
      grp.append(el("h5", "sp-group-h", g));
      const grid = el("div", "sp-grid");
      for (const u of us) {
        const fam = unitFamily(u.id);
        const on = fam.some(f => f.id === now);
        grid.appendChild(card(u.emoji, u.label, on, () => {
          if (fam.length > 1) { unitBase = u.id; render(); }
          else { cfg.pill.set({ unit: u.id }); close(); }
        }));
      }
      grp.appendChild(grid);
      body.appendChild(grp);
    }
    body.appendChild(el("div", "sp-ghost",
      "count = stock · a day, a week = rate (the planner converts by its bands) · bare hours on an offer = budget"));
  };
  const EMOJI_FLOOR = ["🌱", "🤲", "🍞", "🥬", "🍲", "🧸", "🚲", "🏠", "🔧", "🧵", "📚", "🎨", "🚗", "💊", "🪵", "⚡", "💧", "🧹"];
  const renderEmoji = (): void => {
    const grid = el("div", "sp-grid sp-emoji");
    const now = cfg.pill.get().emoji;
    for (const e of new Set([...knownEmoji(EXT, PLAN).values(), ...EMOJI_FLOOR]))
      grid.appendChild(card(e, "", now === e, () => { cfg.pill.set({ emoji: e }); close(); }));
    body.appendChild(grid);
  };

  // one row per tab: the header's title and the body's renderer. No tab strip —
  // as in theirs, each tab is reached from the control that means it (the name
  // opens type, the emoji/unit buttons theirs, 🕐/📍 theirs).
  const TABS: Record<DraftTab, { title: string; render(): void }> = {
    type:   { title: "Choose type",     render: renderType },
    when:   { title: "Time details",    render: () => body.appendChild(arcsEditor(draft.arcs,
                { onCommit: arcs => setDraft({ arcs }) })) },
    where:  { title: "Location details", render: () => body.appendChild(whereEditor(draft.where,
                locationOptions(EXT), { here: cfg.here(), onCommit: where => setDraft({ where }),
                                        onNewPlace: cfg.onNewPlace })) },
    unit:   { title: "Choose unit",     render: renderUnit },
    emoji:  { title: "Choose emoji",    render: renderEmoji },
  };

  // the bar's own top row hands over a chosen category: the type drill opens
  // already one level down, so the top row is not shown twice
  const openAt = (n: DesireNode): void => { typePath = [n]; show("type"); render(); };

  return {
    el: root, draft,
    tab: () => cur,
    show, close, openAt,
    refresh: () => { if (cur !== null) render(); },
    toggle: t => (cur === t ? close() : show(t)),
    reset: () => { Object.assign(draft, blankDraft()); cur = null; render(); },
  };
}
