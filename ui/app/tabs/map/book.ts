// app/tabs/map/book.ts — the pin book's views, drawn into the map panel.
//
// mapsearch.ts is the panel's state machine; this is what the SAVED states
// look like: the book (your lists, and the commune's), one of your lists
// with its entries and notes, a shared list's members, and the "save in your
// lists" menu a row's detail opens. Every fact read here is pins.ts's; the
// two things the PANEL owns — how a result card is drawn and what selecting
// one does — arrive through the host, so this module never learns the panel.

import { USER } from '../../core.js';
import { theMap } from '../../mapview.js';
import { rows, havKm } from './atlas.js';
import type { PlacedRow } from './atlas.js';
import { esc } from '../../template.js';
import { mk } from '../../dom.js';
import * as pins from './pins.js';
import type { PinList, Pin, OurList, View } from './pins.js';

export interface BookHost {
  /** the panel's one result-card renderer */
  item(r: PlacedRow, onclick: () => void): HTMLElement;
  /** open a row's detail (fly there) */
  select(r: PlacedRow): void;
  /** leave any detail or cluster the panel had open */
  clear(): void;
}
let H: BookHost;
export function mount(host: BookHost): void { H = host; }

/** Draw VIEW into HOST — the panel calls this for every non-null view. */
export function draw(host: HTMLElement, v: NonNullable<View>): void {
  if (v.kind === "lists") { drawLists(host); return; }
  if (v.kind === "ours")  { drawOurList(host, v); return; }
  const mine = pins.listById(v.id);
  if (mine) drawList(host, mine);
  else pins.view.set({ kind: "lists" });     // its list was deleted under it
}

/** A row's detail: the chips of the lists it stands in, and the save menu when open. */
export function drawSaved(sec: HTMLElement, r: PlacedRow, menu: boolean, redraw: () => void): void {
  const inLists = pins.listsOf(pins.subjectOf(r));
  sec.hidden = !inLists.length && !menu;
  sec.replaceChildren();
  if (inLists.length) {
    const chips = mk("div", "ms-pills");
    for (const l of inLists) {
      const c = mk("span", "ms-tpill ms-inlist", `${l.emoji} ${l.name}`);
      c.title = "open this list";
      c.onclick = () => openOwnList(l.id);
      chips.append(c);
    }
    sec.append(chips);
  }
  if (menu) sec.append(saveMenu(r, redraw));
}

// ── the SAVED view: the book, a list, a shared list ─────────────────────────
// "Save in your lists": every list with a check where this row already
// stands, and a new-list form at the foot — filed on tap, no dialog.
export function saveMenu(r: PlacedRow, redraw: () => void): HTMLElement {
  const m = mk("div", "ms-savemenu");
  const subject = pins.subjectOf(r);
  m.append(mk("h3", "ms-sect", "Save in your lists"));
  for (const l of pins.lists()) {
    const on = pins.isPinned(l.id, subject);
    const row = mk("div", "ms-lrow" + (on ? " on" : ""));
    row.innerHTML = `<span class="ms-lemoji">${esc(l.emoji)}</span>` +
      `<span class="ms-lname">${esc(l.name)}<small>${l.shared ? "Shared" : "Private"} · ${pins.pinsIn(l.id).length}</small></span>` +
      `<span class="ms-lcheck">${on ? "✓" : ""}</span>`;
    row.onclick = () => { pins.togglePin(l.id, r); redraw(); };
    m.append(row);
  }
  m.append(newListForm(l => { pins.togglePin(l.id, r); redraw(); }));
  return m;
}
function newListForm(then: (l: PinList) => void): HTMLElement {
  const f = mk("div", "ms-newlist");
  const emoji = mk("input", "ms-tin ms-nemoji"); emoji.placeholder = "📌"; emoji.maxLength = 4;
  const name = mk("input", "ms-tin ms-nname"); name.placeholder = "New list";
  const go = mk("button", "ms-card", "+");
  const make = () => {
    if (!name.value.trim()) { name.focus(); return; }
    then(pins.createList(name.value, emoji.value.trim()));
    name.value = ""; emoji.value = "";
  };
  go.onclick = make;
  name.onkeydown = e => { if (e.key === "Enter") make(); };
  f.append(emoji, name, go);
  return f;
}

function drawLists(host: HTMLElement): void {
  host.replaceChildren();
  const head = mk("div", "ms-head ms-chead");
  head.append(mk("h3", "ms-count", "🔖 Saved"));
  const x = mk("button", "ms-close", "✕"); x.onclick = pins.close;
  head.append(x);
  host.append(head);
  const list = mk("div", "ms-list ms-lists");
  list.append(newListForm(l => openOwnList(l.id)));
  for (const l of pins.lists()) list.append(listRow(l));
  const ours = pins.ourLists();
  const foreign = (ours || []).filter(o => !pins.listById(o.id));
  if (foreign.length) {
    list.append(mk("h3", "ms-sect ms-oursect", "Shared in the commune"));
    for (const o of foreign) {
      const row = mk("div", "ms-item ms-lrow");
      row.innerHTML = `<span class="ms-lemoji">${esc(o.emoji || "📌")}</span>` +
        `<span class="ms-lname">${esc(o.label || o.id)}<small>Shared by ${o.by} · ${o.places} places</small></span>`;
      row.onclick = () => openOurs(o);
      list.append(row);
    }
  } else if (ours === null) {
    list.append(mk("div", "ms-note", "reading the commune's lists…"));
  }
  host.append(list);
}
// one of YOUR lists, with its ⋮ — rename, face, share, delete — inline
function listRow(l: PinList): HTMLElement {
  const row = mk("div", "ms-item ms-lrow");
  const n = pins.pinsIn(l.id).length;
  const draw = (menu: boolean): void => {
    row.innerHTML = `<span class="ms-lemoji">${esc(l.emoji)}</span>` +
      `<span class="ms-lname">${esc(l.name)}<small>${l.shared ? "Shared" : "Private"} · ${n} ${n === 1 ? "place" : "places"}</small></span>` +
      `<button class="ms-more" title="rename · share · delete">⋮</button>`;
    row.onclick = () => openOwnList(l.id);
    row.querySelector<HTMLElement>(".ms-more")!.onclick = e => { e.stopPropagation(); draw(!menu); };
    if (!menu) return;
    const m = mk("div", "ms-lmenu");
    m.onclick = e => e.stopPropagation();
    const emoji = mk("input", "ms-tin ms-nemoji"); emoji.value = l.emoji;
    const name = mk("input", "ms-tin ms-nname"); name.value = l.name;
    const ok = mk("button", "ms-card", "rename");
    ok.onclick = () => { pins.updateList(l.id, { name: name.value.trim() || l.name, emoji: emoji.value.trim() || l.emoji });
                         };
    const share = mk("button", "ms-nav", l.shared ? "make private" : "share with the commune");
    share.title = l.shared ? "the list leaves the commune's pin book"
                           : "the list and its places fold into the commune's pin book; your notes stay yours";
    share.onclick = () => { pins.updateList(l.id, { shared: !l.shared }); };
    const del = mk("button", "ms-no", "delete");
    del.onclick = () => {
      if (del.dataset.sure) { pins.deleteList(l.id); return; }
      del.dataset.sure = "1"; del.textContent = "delete — sure?";   // a second tap, not a dialog
    };
    const r1 = mk("div", "ms-newlist"); r1.append(emoji, name, ok);
    const r2 = mk("div", "ms-acts"); r2.append(share, del);
    m.append(r1, r2);
    row.append(m);
  };
  draw(false);
  return row;
}
function drawList(host: HTMLElement, l: PinList): void {
  host.replaceChildren();
  const ps = pins.pinsIn(l.id);
  const head = mk("div", "ms-dhead");
  head.innerHTML = `<button class="ms-back" title="Back to your lists">←</button>` +
    `<div class="ms-dinfo"><h2 class="ms-dtitle"><span>${esc(l.emoji)}</span> ${esc(l.name)}</h2>` +
    `<div class="ms-dprov">${l.shared ? "🌍 Shared" : "🔒 Private"} · ${ps.length} ${ps.length === 1 ? "place" : "places"}</div></div>` +
    `<button class="ms-close" title="Close">✕</button>`;
  head.querySelector<HTMLElement>(".ms-back")!.onclick = () => pins.view.set({ kind: "lists" });
  head.querySelector<HTMLElement>(".ms-close")!.onclick = pins.close;
  host.append(head);
  if (!ps.length) { host.append(mk("div", "ms-sec ms-note", "Nothing here yet — 🔖 save on any pin, or press and hold the map to drop one.")); return; }
  const list = mk("div", "ms-list");
  for (const p of ps) list.append(pinEntry(l, p));
  host.append(list);
}
// the camera takes in a list ONCE, when it opens — a draw never moves it
function fitTo(pts: { lat: number; lng: number }[]): void {
  const map = theMap();
  if (!map || !pts.length) return;
  const lats = pts.map(p => p.lat), lngs = pts.map(p => p.lng);
  map.fitBounds([[Math.min(...lngs), Math.min(...lats)], [Math.max(...lngs), Math.max(...lats)]],
                { padding: 80, duration: 600, maxZoom: 15 });
}
// a list entry: the live row when it is still on the map, else the snapshot
function pinEntry(l: PinList, p: Pin): HTMLElement {
  const live = (rows() as PlacedRow[]).find(r => r.lat != null && pins.subjectOf(r) === p.subject);
  const r = live || pins.pinRow(p);
  const it = H.item({ ...r, km: havKm(USER, r) }, () => H.select(r));
  it.classList.add("ms-pinned");
  if (!live) it.classList.add("ms-gone");
  const foot = mk("div", "ms-pinfoot");
  const note = mk("div", "ms-note ms-pnote", p.note || "");
  const edit = mk("a", "ms-split", p.note ? "✎ note" : "+ note");
  edit.onclick = e => {
    e.stopPropagation();
    const ta = mk("textarea", "ms-tin ms-ntext"); ta.value = p.note || ""; ta.rows = 2;
    ta.placeholder = "your note — stays yours, never shared";
    ta.onclick = ev => ev.stopPropagation();
    ta.onblur = () => { pins.setNote(l.id, p.subject, ta.value); };
    note.replaceWith(ta); ta.focus();
  };
  const out = mk("a", "ms-split", "✕ remove");
  out.onclick = e => { e.stopPropagation(); pins.unpin(l.id, p.subject); };
  foot.append(note, edit, out);
  it.append(foot);
  return it;
}
function drawOurList(host: HTMLElement, o: Extract<View, { kind: "ours" }>): void {
  host.replaceChildren();
  const head = mk("div", "ms-dhead");
  head.innerHTML = `<button class="ms-back" title="Back to the lists">←</button>` +
    `<div class="ms-dinfo"><h2 class="ms-dtitle"><span>${esc(o.l.emoji || "📌")}</span> ${esc(o.l.label || o.l.id)}</h2>` +
    `<div class="ms-dprov">🌍 shared by ${o.l.by} · ${o.subjects.size} ${o.subjects.size === 1 ? "place" : "places"}</div></div>` +
    `<button class="ms-close" title="Close">✕</button>`;
  head.querySelector<HTMLElement>(".ms-back")!.onclick = () => pins.view.set({ kind: "lists" });
  head.querySelector<HTMLElement>(".ms-close")!.onclick = pins.close;
  host.append(head);
  const list = mk("div", "ms-list");
  const here = (rows() as PlacedRow[]).filter(r => r.lat != null && o.subjects.has(pins.subjectOf(r)));
  for (const r of here) list.append(H.item({ ...r, km: havKm(USER, r) }, () => H.select(r)));
  const away = o.subjects.size - here.length;
  if (away > 0) list.append(mk("div", "ms-note", `${away} more not on your map right now`));
  host.append(list);
}
export function openOwnList(id: string): void {
  H.clear();
  pins.openMine(id);
  fitTo(pins.pinsIn(id));
}
export async function openOurs(o: OurList): Promise<void> {
  H.clear();
  await pins.openOurs(o);
  const v = pins.view.peek();
  if (v && v.kind === "ours")
    fitTo((rows() as PlacedRow[]).filter(r => r.lat != null && v.subjects.has(pins.subjectOf(r))));
}
