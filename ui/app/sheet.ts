// app/sheet.ts — the capture sheet's state: a short stack of screens.
//
// Every screen of the sheet (the figure, a container, the camera, the scenes
// waiting, a product's barcode, the counts of a stock) is one member of `Screen`;
// the sheet is the stack of them with the line under the screen and whether a
// door is being waited on; the helpers here are how a screen moves it. The
// screens are drawn by their own modules (capture-stock.ts, capture-look.ts,
// capture-contest.ts) and capture.ts draws whichever is on top.

import { signal } from "./reactive.js";
import { html, type Fragment } from "./template.js";
import type { Technique, CountReply, Expected } from "./count.js";
import type { LookRow, Held } from "./look.js";
import type { Stock } from "./stock.js";
import type { Allot } from "./allotment.js";
import type { CountEntry, ContestEntry } from "./contest.js";
import type { Queued } from "./queue.js";
import type { Seen } from "./symbols.js";
import type { Shot } from "./photo.js";

/** What the opener knows of the stock to be counted. */
export interface CaptureTarget {
  /** The EconomicResource's id. */
  resource: string;
  name: string;
  emoji?: string;
  unit: string;
  /** What the ledger reads, shown unless the count is blind. */
  onhand: number;
  /** What the plan expects of the stock, shown unless the count is blind. */
  expected?: Expected | null;
  /** Where the stock is held, as the face names it. */
  where?: string;
  /** The counter's commitment, when a plan asked for this count. */
  fulfills?: string;
  /** A place id the opener resolved (a scanned label); else the person's own. */
  place?: string;
  /** A blind count: the ledger's figure stays hidden until the count lands. */
  blind?: boolean;
  /** How the stock was come by; a row counted off a read label is a label count. */
  technique?: Technique;
  /** The hash of the photograph the count is made beside, kept on the device. */
  evidence?: string;
  /** Called with what the count landed. */
  onCounted?(reply: CountReply): void;
}

/** What a planned count brings to the sheet: its commitment, and whether it is counted blind. */
export interface Planned {
  fulfills: string;
  blind: boolean;
}

/** What a photo read is told of the scene, and where its rows land. */
export interface Scene {
  /** The place id rows land at; empty for the person's own place. */
  place: string;
  /** Where, as the face names it. */
  where: string;
  /** The container in view; its own count carries the plan's commitment. */
  container?: Stock;
  /** What the ledger holds in view: the rows a picture most likely shows. */
  held: Held[];
  /** HELD is what is held at a known place or in the container in view; false when no place is known, and HELD is everything the books hold. */
  here: boolean;
  plan?: Planned;
}

/** One row of a photo read, and what has been done with it. */
export interface LookLine {
  row: LookRow;
  state: "open" | "landed" | "struck";
  says: string;
  /** The id a first sighting was declared under; its lend to the commons names it. */
  rid?: string;
  /** How much more of it the person asked for from this row. */
  asked?: number;
}

export type Phase = "idle" | "reading" | "rows" | "unread";

/** The camera: it reads the symbols in view and takes a photograph. `typing` shows the box for a code read by eye. */
export type LookScreen = { kind: "look"; scene: Scene; phase: Phase; hash: string; lines: LookLine[]; reads: Allot | null; typing: boolean;
                    /** The shots taken of the scene so far: up to SHOTS_PER_READ, read together. */
                    shots: Shot[];
                    /** The id of the queued scene this read is of, when it is one; it leaves the queue when its rows are done. */
                    queued: string };

/** The scenes waiting to be read, each with a small picture of its first shot. */
export type QueueScreen = { kind: "queue"; items: { entry: Queued; thumb: string }[]; loaded: boolean; reads: Allot | null };

/** A product's barcode the device has not met: which stock is it? */
type ProductScreen = { kind: "product"; seen: Seen };

/** The counts of a stock and the contests open on them. */
export type ContestScreen = {
  kind: "contest";
  stock: { id: string; name: string };
  loaded: boolean;
  counts: CountEntry[];
  open: ContestEntry[];
  /** The count whose reason box is open. */
  asking: string;
  /** A held picture on show. */
  picture: { ballot: string; url: string } | null;
};

export type Screen =
  /** HOW is how the container was come by: a read label, or a stated count off the stock the face holds. */
  | { kind: "bin"; bin: Stock; contents: Stock[]; how: Technique; plan?: Planned }
  | { kind: "count"; target: CaptureTarget; done: boolean; counted?: number; reply?: CountReply }
  | LookScreen
  | QueueScreen
  | ProductScreen
  | ContestScreen;

export interface Sheet {
  /** The screens under the one on top, oldest first; back returns to the last. */
  stack: Screen[];
  /** The line under the screen: a prompt, a refusal, or the verdict. */
  says: string;
  busy: boolean;
}

/** How one kind of screen is drawn and what it does as it comes to the top. */
export interface ScreenKind<S extends Screen> {
  /** The card. */
  render(scr: S, deep: boolean): Fragment;
  /** The screen has just been drawn: focus a box, open the camera. */
  shown?(scr: S): void;
  /** The line under the screen while nothing has been said. */
  prompt?(scr: S): string;
  /** The buttons' readiness changed in place: what else is free or waiting. */
  ready?(scr: S, busy: boolean): void;
}

export const sheet = signal<Sheet | null>(null);

/** The element the sheet is drawn in; set once it exists. */
export const host: { el: HTMLElement | null } = { el: null };
export const q = <T extends Element>(sel: string): T | null => host.el?.querySelector<T>(sel) ?? null;
export const qa = <T extends Element>(sel: string): T[] => [...(host.el?.querySelectorAll<T>(sel) ?? [])];

export const top = (s: Sheet | null): Screen | null => (s && s.stack.length ? s.stack[s.stack.length - 1] : null);
export const say = (says: string): void => { const s = sheet.peek(); if (s) sheet.set({ ...s, says }); };
// a step ends: the line says what happened and the buttons are free again
export const settle = (says: string): void => { const s = sheet.peek(); if (s) sheet.set({ ...s, busy: false, says }); };
// a door that never answers leaves the sheet where it stands, ready to ask again
export const unanswered = (): void => settle("the gateway did not answer");
// the screen on top, when it is of KIND
export const topOf = <K extends Screen["kind"]>(kind: K): Extract<Screen, { kind: K }> | null => {
  const t = top(sheet.peek());
  return t && t.kind === kind ? t as Extract<Screen, { kind: K }> : null;
};

export function push(screen: Screen): void {
  const s = sheet.peek();
  sheet.set({ stack: [...(s?.stack ?? []), screen], says: "", busy: false });
}
export function replaceTop(screen: Screen, says = ""): void {
  const s = sheet.peek();
  if (!s) return;
  sheet.set({ stack: [...s.stack.slice(0, -1), screen], says, busy: false });
}

// what must let go when the sheet closes (the camera, the mic)
const closers: (() => void)[] = [];
export const onClose = (f: () => void): void => { closers.push(f); };

export function close(): void {
  for (const f of closers) f();
  sheet.set(null);
}

export function back(): void {
  const s = sheet.peek();
  if (!s || s.stack.length <= 1) { close(); return; }
  sheet.set({ stack: s.stack.slice(0, -1), says: "", busy: false });
}

// the inline children of a row carry no whitespace between them: a template's
// indentation between inline nodes renders as a gap
export const head = (emoji: string, name: string, deep: boolean) => html`
  <div class="cap-head">${deep ? html`<button class="cap-back" title="back" onclick=${back}>‹</button>` : ""}<span class="cap-emoji">${emoji}</span><span class="cap-name">${name}</span><button class="cap-x" title="close" onclick=${close}>✕</button></div>`;
