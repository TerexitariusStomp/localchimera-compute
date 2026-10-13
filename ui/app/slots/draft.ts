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
//   when      the card's own arcsEditor, on the draft
//   where     the card's own whereEditor, on the draft
//   unit      UNITS as a tappable grid, with the reading below
//   emoji     the glyphs the plan and inventory already carry, plus a floor

import { EXT, PLAN } from '../core.js';
import { runPass, aiAvailable } from '../day/extract.js';
import { arcsEditor, whereEditor } from './editors.js';
import { UNITS, knownEmoji, locationOptions, blankDraft }
  from './model.js';
import type { Draft, SlotKind, Arc, LocationOption, UnitOption } from './model.js';
import { mk as el } from '../dom.js';

/** The pill's four inputs, as one value. */
export interface PillFields { name: string; emoji: string; qty: number; unit: string }

/** How the panel reaches the pill: read the fields, write some, move focus. */
export interface PillAccess {
  get(): PillFields;
  set(patch: Partial<PillFields>): void;
  focus(which: "name" | "qty"): void;
}

export type DraftTab = "when" | "where" | "unit" | "emoji";

export interface DraftPanelConfig {
  pill: PillAccess;
  kind(): SlotKind;
  setKind(k: SlotKind): void;
  here(): string | null;
  /** The draft or the open tab moved: the pill re-lights its toggles. */
  onChange(): void;
  /** Make a place from a name (+ optional coordinates); resolves to its id. */
  onNewPlace?(name: string, lat: number, lon: number, address: string): Promise<string | null>;
}

export interface DraftPanel {
  el: HTMLElement;
  draft: Draft;
  tab(): DraftTab | null;
  /** Open this tab (idempotent). */
  show(t: DraftTab): void;
  /** Open this tab, or close the panel when it is the one already open. */
  toggle(t: DraftTab): void;
  close(): void;
  /** Redraw the open tab — the pill's fields moved under it. */
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
    if (cur) { body.title = TABS[cur].title; TABS[cur].render(); }
    cfg.onChange();
  };
  const show = (t: DraftTab): void => { if (cur !== t) { cur = t; render(); } };
  const close = (): void => { if (cur !== null) { cur = null; unitBase = null; render(); } };
  const setDraft = (patch: Partial<Draft>): void => { Object.assign(draft, patch); render(); };

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
  // as in theirs, each tab is reached from the control that means it (the
  // emoji/unit buttons theirs, 🕐/📍 theirs).
  const TABS: Record<DraftTab, { title: string; render(): void }> = {
    when:   { title: "Time details",    render: () => body.appendChild(arcsEditor(draft.arcs,
                { onCommit: arcs => setDraft({ arcs }) })) },
    where:  { title: "Location details", render: () => body.appendChild(whereEditor(draft.where,
                locationOptions(EXT), { here: cfg.here(), onCommit: where => setDraft({ where }),
                                        onNewPlace: cfg.onNewPlace })) },
    unit:   { title: "Choose unit",     render: renderUnit },
    emoji:  { title: "Choose emoji",    render: renderEmoji },
  };

  return {
    el: root, draft,
    tab: () => cur,
    show, close,
    refresh: () => { if (cur !== null) render(); },
    toggle: t => (cur === t ? close() : show(t)),
    reset: () => { Object.assign(draft, blankDraft()); cur = null; render(); },
  };
}
