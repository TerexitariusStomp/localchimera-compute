// app/capture-stock.ts — the capture sheet's screens of the books: the figure of
// one stock, a container and what is in it, and a product's barcode asking which
// stock it is.
//
// A count lands through the count door (HANDLERS.countStock); a container is read
// off its label (HANDLERS.readLabel) or off the stock the face holds; a barcode is
// paired with a stock once and the device keeps the pairing (barcodes.ts).

import { HANDLERS } from "./core.js";
import { emit } from "./bus.js";
import { html, type Fragment } from "./template.js";
import { currentPlace } from "./tabs/social/location.js";
import { parseFigure, readReply, refused, parseReply, verdict, quantity, planRange, planVerdict, against, farOff, type Technique } from "./count.js";
import { armer } from "./arm.js";
import { planNote } from "./plan-note.js";
import { spoken, checklist, labelSheet, nameCards, print, type ChecklistLine, type Labelled } from "./labels.js";
import { LABEL_LENGTH } from "./count-catalogue.js";
import { formatName } from "./symbols.js";
import { bind } from "./barcodes.js";
import { placePath } from "./store-tree.js";
import { stockOf, stocksOf, lotDate, within, type Stock } from "./stock.js";
import { knownPlaces, heldStocks } from "./books.js";
import { withCodes } from "./label-codes.js";
import { sheet, top, say, unanswered, push, replaceTop, back, head, q, qa, type Screen, type ScreenKind, type Planned, type CaptureTarget } from "./sheet.js";
import { sceneOf, openLook } from "./capture-scene.js";

function readBin(raw: unknown): { bin: Stock; contents: Stock[] } | { err: string } {
  const j = parseReply(raw);
  if (refused(j)) return j;
  const bin = stockOf(j.resource);
  if (!bin || !bin.id) return { err: "the gateway's answer named no thing" };
  return { bin, contents: stocksOf(j.contents) };
}

// the screen a stock opens on: a container on its lines, anything else at its figure
export function screenOf(found: { bin: Stock; contents: Stock[] }, how: Technique, plan?: Planned): Screen {
  return found.contents.length
    ? { kind: "bin", bin: found.bin, contents: found.contents, how, plan }
    : { kind: "count", target: countOf(found.bin, found.bin, how, plan), done: false };
}

export function find(code: string | null): void {
  const s = sheet.peek();
  if (!s || s.busy) return;
  if (!code) { say(`a code is ${LABEL_LENGTH} characters, as printed beneath the symbol`); return; }
  if (!HANDLERS.readLabel) { say("sign in to read a label"); return; }
  sheet.set({ ...s, busy: true, says: `looking for ${spoken(code)}…` });
  HANDLERS.readLabel(code).then(raw => {
    const now = sheet.peek();
    if (!now || top(now)?.kind !== "look") return;          // the sheet moved on
    const r = readBin(raw);
    if ("err" in r) { sheet.set({ ...now, busy: false, says: r.err }); return; }
    replaceTop({ kind: "bin", bin: r.bin, contents: r.contents, how: "label" });
  }).catch(unanswered);
}

// the barcode is this stock, from now on: its count opens
export function pair(value: string, rid: string): void {
  const found = fromStock(rid);
  if (!found) return;
  bind(value, rid);
  replaceTop(screenOf(found, "label"));
}

export const figureIn = (): HTMLInputElement | null => q<HTMLInputElement>(".cap-figure");

// a figure far from what is held lands on a second tap (count.ts farOff), the
// rule a row of a photo read answers to; a blind count is asked nothing, since
// the question would say what the ledger reads
const twice = armer();

function count(): void {
  const s = sheet.peek(), scr = top(s);
  if (!s || s.busy || scr?.kind !== "count" || scr.done) return;
  const n = parseFigure(figureIn()?.value ?? "");
  if (n === null) { say("how much is there?"); return; }
  if (!HANDLERS.countStock) { say("sign in to count"); return; }
  const t = scr.target;
  if (!t.blind && farOff(n, t) && twice.armed() !== `${t.resource}:${n}`) {
    twice.arm(`${t.resource}:${n}`, count);
    say(`really ${quantity(n, t.unit)}? the ledger read ${quantity(t.onhand, t.unit)} · count it again to land it`);
    return;
  }
  const note = (q<HTMLInputElement>(".cap-note")?.value ?? "").trim();
  sheet.set({ ...s, busy: true, says: "counting…" });
  HANDLERS.countStock(t.resource, n, t.unit, t.technique ?? "stated", t.place ?? currentPlace() ?? "",
                      "", t.fulfills ?? "", t.evidence ?? "", note)
    .then(raw => {
      const now = sheet.peek();
      if (!now || top(now) !== scr) return;                 // the sheet moved on
      const r = readReply(raw);
      if (refused(r)) { sheet.set({ ...now, busy: false, says: r.err }); return; }
      // a planned count lands its hours beside its figure, and says so
      const worked = r.hours > 0 ? ` · ${quantity(r.hours, "h")} of counting recorded` : "";
      replaceTop({ ...scr, done: true, counted: n, reply: r }, verdict(r, t.unit) + worked);
      t.onCounted?.(r);
      emit("counted", t.resource);
    })
    .catch(unanswered);
}

// a container's lines, replaced where its screen sits in the stack
function relined(bin: Stock, contents: Stock[]): void {
  const s = sheet.peek();
  if (!s) return;
  sheet.set({ ...s, stack: s.stack.map(x => (x.kind === "bin" && x.bin.id === bin.id
                                             ? { ...x, bin, contents } : x)) });
}

// a count made off a container lands at the container's place and reads the
// container's lines again on the way back
export function countOf(thing: Stock, bin: Stock, how: Technique, plan?: Planned): CaptureTarget {
  return {
    resource: thing.id, name: thing.name, emoji: thing.emoji || undefined, unit: thing.unit, onhand: thing.onhand, expected: thing.expected,
    where: placePath(bin.location, knownPlaces()), place: bin.location || undefined, technique: how,
    fulfills: plan?.fulfills, blind: plan?.blind,
    onCounted: () => {
      if (!HANDLERS.readLabel || !bin.code) return;
      HANDLERS.readLabel(bin.code).then(raw => {
        const r = readBin(raw);
        if (!("err" in r)) relined(r.bin, r.contents);
      }).catch(() => { /* the lines are read again on the next push of the stock */ });
    },
  };
}

// a thing and everything inside it, off the stock the face already holds
export function fromStock(rid: string): { bin: Stock; contents: Stock[] } | null {
  const things = heldStocks();
  const bin = things.find(t => t.id === rid);
  return bin ? { bin, contents: within(rid, things) } : null;
}

// the stock moved: a container on the sheet reads its lines off the new stock
export function restock(): void {
  const s = sheet.peek();
  if (!s) return;
  for (const x of s.stack) {
    if (x.kind !== "bin") continue;
    const now = fromStock(x.bin.id);
    if (now) relined({ ...now.bin, code: now.bin.code || x.bin.code }, now.contents);
  }
}

const labelled = (t: Stock): Labelled => ({ code: t.code, name: t.name, where: placePath(t.location, knownPlaces()) });

function printChecklist(bin: Stock, contents: Stock[], blind: boolean): void {
  say("laying the sheet out…");
  void withCodes([bin, ...contents]).then(all => {
    const head = all.find(t => t.id === bin.id);
    if (!head) { say("this container has no code yet; sign in to give it one"); return; }
    const lines: ChecklistLine[] = all.filter(t => t.id !== bin.id).map(t => ({
      ...labelled(t), onhand: t.onhand, unit: t.unit,
      expires: t.expires || undefined, expiresKind: t.expiresKind || undefined,
    }));
    print(checklist(labelled(head), lines, { blind, day: new Date().toLocaleDateString(undefined, { dateStyle: "long" }) }));
    say("");
  });
}

function printLabels(things: Stock[], cards: boolean): void {
  say("laying the sheet out…");
  void withCodes(things).then(all => {
    if (!all.length) { say("nothing here has a code yet; sign in to give one"); return; }
    print((cards ? nameCards : labelSheet)(all.map(labelled)));
    say("");
  });
}

// what the line under a count says while the figure is awaited
const COUNT_PROMPT = "type the figure, or hold the mic and say it";

function renderCount(scr: Extract<Screen, { kind: "count" }>, deep: boolean): Fragment {
    const t = scr.target;
    const reads = t.blind && !scr.done ? "a blind count: the ledger's figure shows once yours lands"
                                       : `the ledger read ${quantity(t.onhand, t.unit)}`;
    // before the figure the plan's range waits beside the ledger's; once it has landed the plan's word on it
    const expected = scr.done ? scr.reply?.expected : t.blind ? null : t.expected;
    const plan = !expected ? ""
      : scr.done && scr.counted !== undefined
        ? planNote(expected, t.unit, planVerdict(scr.counted, expected, t.unit), against(scr.counted, expected) !== "within")
        : planNote(expected, t.unit, `the plan expects ${planRange(expected, t.unit)}`);
    return html`
      <div class="cap-card" role="dialog" aria-modal="true" aria-label="count ${t.name}">
        ${head(t.emoji || "📦", t.name, deep)}
        <div class="cap-sub">${t.where ? `${t.where} · ` : ""}${reads}${t.fulfills ? " · the plan asked for this count" : ""}</div>
        ${scr.done ? "" : html`
          <div class="cap-row"><input class="cap-figure" inputmode="decimal" placeholder="how much is there?"
                   oninput=${() => { if (sheet.peek()?.says) say(""); }}
                   onkeydown=${(e: Event) => { if ((e as KeyboardEvent).key === "Enter") count(); }}><span class="cap-unit">${t.unit}</span></div>`}
        ${scr.done ? "" : plan}
        ${scr.done ? "" : html`
          <details class="cap-notebox"><summary>add a note</summary>
            <input class="cap-note" placeholder="where you looked, what you saw"></details>`}
        <div class="cap-says"></div>
        ${scr.done ? plan : ""}
        <button class="cap-go" onclick=${scr.done ? back : count}>${scr.done ? "done" : "count it"}</button>
      </div>`;
}

function renderBin(scr: Extract<Screen, { kind: "bin" }>, deep: boolean): Fragment {
    const { bin, contents, plan, how } = scr;
    const where = placePath(bin.location, knownPlaces());
    const date = (t: Stock): string => t.expires ? ` · ${lotDate(t.expires, t.expiresKind)}` : "";
    const line = (t: Stock) => html`
      <li><div class="cap-line"><span class="cap-lname">${t.emoji ? `${t.emoji} ` : ""}${t.name}</span><span class="cap-lsub">${plan?.blind ? (t.unit || "counted blind") : `${quantity(t.onhand, t.unit)}${t.expected ? ` · the plan expects ${planRange(t.expected, t.unit)}` : ""}`}${date(t)}</span></div><button class="cap-mini" onclick=${() => push({ kind: "count", target: countOf(t, bin, how, plan), done: false })}>count</button></li>`;
    return html`
      <div class="cap-card" role="dialog" aria-modal="true" aria-label="${bin.name}">
        ${head(bin.emoji || "📦", bin.name, deep)}
        <div class="cap-sub">${[where, bin.code ? spoken(bin.code) : "",
                                contents.length ? `holds ${contents.length}` : "the ledger holds nothing in it",
                                plan ? "the plan asked for this count" : "",
                                plan?.blind ? "counted blind" : ""].filter(Boolean).join(" · ")}</div>
        <ul class="cap-lines">${contents.map(line)}</ul>
        <div class="cap-says"></div>
        <div class="cap-bin-acts">
          <button class="cap-mini" onclick=${() => push({ kind: "count", target: countOf(bin, bin, how, plan), done: false })}>count the container</button>
          <details class="cap-printmenu"><summary class="cap-mini">print ▾</summary><div class="cap-menu cap-tools">${plan?.blind ? "" : html`<button class="cap-mini" onclick=${() => printChecklist(bin, contents, false)}>checklist</button>`}<button class="cap-mini" onclick=${() => printChecklist(bin, contents, true)}>blind checklist</button><button class="cap-mini" onclick=${() => printLabels([bin, ...contents], false)}>labels</button><button class="cap-mini" onclick=${() => printLabels([bin], true)}>name card</button></div></details>
          <span style="flex:1"></span>
          <button class="cap-go" onclick=${() => openLook(sceneOf(bin, contents, plan))}>📷 photograph it</button>
        </div>
      </div>`;
}

function renderProduct(scr: Extract<Screen, { kind: "product" }>, deep: boolean): Fragment {
    const { format, value } = scr.seen;
    const stocks = heldStocks().slice().sort((x, y) => x.name.localeCompare(y.name));
    // the filter hides rows in place: a redraw would take the box the person is typing in
    const narrow = (e: Event): void => {
      const f = (e.target as HTMLInputElement).value.trim().toLowerCase();
      qa<HTMLElement>(".cap-pairs li").forEach(li => { li.hidden = !!f && !(li.dataset.name ?? "").includes(f); });
    };
    return html`
      <div class="cap-card" role="dialog" aria-modal="true" aria-label="a product code">
        ${head("▥", `${formatName(format)} · ${value}`, deep)}
        <div class="cap-sub">a product code this device has not met: which stock is it? The next scan of it opens that stock.</div>
        <input class="cap-filter" placeholder="find the stock by name" oninput=${narrow}>
        <ul class="cap-lines cap-pairs">${stocks.map(t => html`
          <li data-name="${t.name.toLowerCase()}"><div class="cap-line"><span class="cap-lname">${t.name}</span><span class="cap-lsub">${quantity(t.onhand, t.unit)}${t.location ? ` · ${placePath(t.location, knownPlaces())}` : ""}</span></div><button class="cap-mini" onclick=${() => pair(value, t.id)}>this one</button></li>`)}</ul>
        <div class="cap-says"></div>
      </div>`;
}

export const countScreen: ScreenKind<Extract<Screen, { kind: "count" }>> = {
  render: renderCount,
  shown: scr => { if (!scr.done) queueMicrotask(() => figureIn()?.focus()); },
  prompt: scr => (scr.done ? "" : COUNT_PROMPT),
};
export const binScreen: ScreenKind<Extract<Screen, { kind: "bin" }>> = { render: renderBin };
export const productScreen: ScreenKind<Extract<Screen, { kind: "product" }>> = {
  render: renderProduct,
  shown: () => { queueMicrotask(() => q<HTMLInputElement>(".cap-filter")?.focus()); },
};
