// app/toast.ts — the site's voice for a passing remark: toasts.
//
// A reply from the gateway ("willing — you're in the race", "the grant did not
// go through") used to be whispered onto the voice-state line beside the mic,
// which is on the time face alone: act from the log, the shop or the map and the
// answer landed where you could not see it. A toast speaks over whichever face
// you are on, then leaves.
//
// The shape is Notyf's — a small card at the corner, a coloured edge, a glyph, a
// life measured in seconds — carried here as ~150 lines with no dependency, so
// it themes and behaves like the rest of the site rather than beside it:
//
//   · the stack is a SIGNAL (app/reactive.ts) and one effect reconciles the DOM
//     against it, keyed by id — the same event-driven reactive discipline the
//     panels use, so `toasts()` is readable state a face can watch.
//   · every colour is a theme token in app.html's sheet (.toast, .toast-*), so
//     night / sepia / ink re-hue the toasts with everything else.
//   · a repeat of what is already on screen bumps a ×n badge instead of stacking
//     a second copy, and the stack keeps its newest MAX.
//   · the clock pauses while the pointer rests on a card, so a long sentence
//     stays readable, and any card can be dismissed by click, ✕, or Escape.
//
// hint() in app/core.js speaks through here, so ~30 existing call sites arrive
// as toasts already; pass a kind ("error", "success", "warn") where the site
// knows which it is.

import { signal, effect } from "./reactive.js";

/** The four voices. A card's colour is CSS's, by class `toast-<kind>`. */
export type ToastKind = "notice" | "success" | "warn" | "error";

/** A card on (or bound for) the stack. */
export interface Toast {
  id: number;
  message: string;
  kind: ToastKind;
  /** How many times this same remark has been made; shown as ×n past 1. */
  count: number;
  /** Milliseconds of life. 0 means it stays until dismissed. */
  duration: number;
  dismissible: boolean;
  /** What a tap on the card does, before the card leaves. The ✕ only dismisses. */
  onTap?: () => void;
}

export interface ToastOptions {
  duration?: number;
  dismissible?: boolean;
  onTap?: () => void;
}

/** Returned to a caller who wants to speak twice on one card. */
export interface ToastHandle {
  id: number;
  dismiss(): void;
  update(message: unknown, kind?: ToastKind): ToastHandle;
}

/**
 * A toast's remaining life. `at` is when the current timer started, so hovering
 * can bank what is left. Set together with `timer` and only by wind(), which is
 * what lets bank() read `at` once it has seen a live `timer`.
 */
interface Clock {
  left: number;
  at?: number;
  timer?: number | null;
}

const MAX = 4;                 // cards on screen; the newest win
const LIFE: Record<ToastKind, number> = { notice: 4200, success: 4200, warn: 6000, error: 7000 };

// glyph per kind — the card's colour is CSS's (class `toast-<kind>`)
const GLYPH: Record<ToastKind, string> = { notice: "·", success: "✓", warn: "!", error: "✕" };

// the live stack, oldest first. Readable by anyone: `toasts()` inside an effect
// re-runs when a toast arrives or leaves.
export const toasts = signal<Toast[]>([]);

let seq = 0;
const nodes = new Map<number, HTMLElement>();       // id → the card element on screen
const clocks = new Map<number, Clock>();            // id → the life remaining

function container(): HTMLElement {
  let c = document.getElementById("toasts");
  if (!c) {
    c = document.createElement("div");
    c.id = "toasts";
    // polite: a toast reports what just happened and never steals focus. Error
    // cards carry role="alert" of their own, which reads through immediately.
    c.setAttribute("role", "status");
    c.setAttribute("aria-live", "polite");
    document.body.appendChild(c);
  }
  return c;
}

// ── the clock ──────────────────────────────────────────────────────────────
// A toast's life is spent, not counted down from a fixed start: hovering banks
// what is left and moving away spends it again, so a card under the pointer
// waits for you.
function wind(t: Toast): void {
  if (!t.duration) return;                       // 0 = stays until dismissed
  const c = clocks.get(t.id) || { left: t.duration };
  clearTimeout(c.timer ?? undefined);
  c.at = performance.now();
  c.timer = setTimeout(() => dismiss(t.id), c.left);
  clocks.set(t.id, c);
}
function bank(id: number): void {
  const c = clocks.get(id);
  if (!c || !c.timer) return;
  clearTimeout(c.timer);
  c.timer = null;
  // A live `timer` can only have been set by wind(), which sets `at` first —
  // so reaching here means `at` is set.
  c.left = Math.max(600, c.left - (performance.now() - c.at!));
}
function stop(id: number): void {
  const c = clocks.get(id);
  if (c) clearTimeout(c.timer ?? undefined);
  clocks.delete(id);
}

// ── raising one ────────────────────────────────────────────────────────────
export function toast(message: unknown, kind: ToastKind = "notice", opts?: ToastOptions): ToastHandle | null {
  opts = opts || {};
  const text = String(message == null ? "" : message).trim();
  if (!text) return null;
  // Callers are still mostly plain JS, so a kind the site does not know reaches
  // here as an ordinary string; fall back rather than paint an unstyled card.
  if (!(kind in GLYPH)) kind = "notice";

  const live = toasts.peek();
  // the same remark twice over is one card wearing a count
  const same = live.find(t => t.message === text && t.kind === kind);
  if (same) {
    toasts.set(live.map(t => (t === same ? { ...t, count: t.count + 1 } : t)));
    const c = clocks.get(same.id);
    if (c) c.left = same.duration;               // a repeat renews the life
    wind(same);
    return handle(same.id);
  }

  const t: Toast = {
    id: ++seq,
    message: text,
    kind,
    count: 1,
    duration: opts.duration != null ? opts.duration : LIFE[kind],
    dismissible: opts.dismissible !== false,
    onTap: opts.onTap,
  };
  const next = [...live, t];
  for (const old of next.slice(0, Math.max(0, next.length - MAX))) stop(old.id);
  toasts.set(next.slice(-MAX));
  wind(t);
  return handle(t.id);
}

// a handle for the caller who wants to speak twice — "committing…" then
// "committed" — on one card
function handle(id: number): ToastHandle {
  return {
    id,
    dismiss: () => dismiss(id),
    update(message: unknown, kind?: ToastKind): ToastHandle {
      toasts.set(toasts.peek().map(t => t.id === id
        ? { ...t, message: String(message), kind: kind && kind in GLYPH ? kind : t.kind }
        : t));
      const t = toasts.peek().find(x => x.id === id);
      if (t) { const c = clocks.get(id); if (c) c.left = t.duration; wind(t); }
      return this;
    },
  };
}

export function dismiss(id: number): void {
  stop(id);
  toasts.set(toasts.peek().filter(t => t.id !== id));
}
export function clear(): void {
  for (const t of toasts.peek()) stop(t.id);
  toasts.set([]);
}

toast.success = (m: unknown, o?: ToastOptions) => toast(m, "success", o);
toast.error   = (m: unknown, o?: ToastOptions) => toast(m, "error", o);
toast.warn    = (m: unknown, o?: ToastOptions) => toast(m, "warn", o);
toast.notice  = (m: unknown, o?: ToastOptions) => toast(m, "notice", o);
toast.dismiss = dismiss;
toast.clear   = clear;

// ── the DOM, reconciled against the stack ──────────────────────────────────
// Keyed by id so a card that stays on screen keeps its element (and so its
// entrance animation runs once): new ids are built, gone ids leave with their
// exit transition, and the survivors have their text re-synced.
function card(t: Toast): HTMLElement {
  const el = document.createElement("div");
  el.className = "toast toast-" + t.kind;
  el.dataset.id = String(t.id);
  if (t.kind === "error") el.setAttribute("role", "alert");
  el.innerHTML =
    '<span class="toast-glyph" aria-hidden="true"></span>' +
    '<span class="toast-msg"></span>' +
    '<span class="toast-count" aria-hidden="true"></span>' +
    (t.dismissible ? '<button class="toast-x" title="dismiss" aria-label="dismiss">✕</button>' : "");
  el.addEventListener("pointerenter", () => bank(t.id));
  el.addEventListener("pointerleave", () => { const s = toasts.peek().find(x => x.id === t.id); if (s) wind(s); });
  if (t.onTap) {
    const act = t.onTap;
    el.addEventListener("click", e => {
      if (!(e.target as Element).closest(".toast-x")) act();
      dismiss(t.id);
    });
  } else if (t.dismissible) el.addEventListener("click", () => dismiss(t.id));
  return el;
}

function sync(el: HTMLElement, t: Toast): void {
  el.className = "toast toast-" + t.kind + (t.onTap ? " toast-tap" : "") + (el.classList.contains("in") ? " in" : "");
  // The three spans are written by card() above, so they are present on every
  // element that reaches here.
  el.querySelector<HTMLElement>(".toast-glyph")!.textContent = GLYPH[t.kind];
  el.querySelector<HTMLElement>(".toast-msg")!.textContent = t.message;
  el.querySelector<HTMLElement>(".toast-count")!.textContent = t.count > 1 ? "×" + t.count : "";
}

function leave(el: HTMLElement): void {
  el.classList.remove("in");
  el.classList.add("out");
  el.addEventListener("transitionend", () => el.remove(), { once: true });
  setTimeout(() => el.remove(), 400);            // reduced motion has no transition to end
}

effect(() => {
  const live = toasts();
  const c = container();

  for (const [id, el] of nodes)
    if (!live.some(t => t.id === id)) { nodes.delete(id); leave(el); }

  for (const t of live) {
    let el = nodes.get(t.id);
    if (!el) {
      el = card(t);
      nodes.set(t.id, el);
      c.appendChild(el);
      // one frame on the far side of the entrance, so the transition has
      // somewhere to travel from
      const entering = el;
      requestAnimationFrame(() => requestAnimationFrame(() => entering.classList.add("in")));
    } else {
      c.appendChild(el);                          // newest at the bottom of the stack
    }
    sync(el, t);
  }
});

// Escape clears the stack — the same key that puts every other passing thing
// away. It runs on the way down and leaves the event alone, so a face that also
// listens for Escape still gets it.
window.addEventListener("keydown", e => { if (e.key === "Escape" && toasts.peek().length) clear(); });

export default toast;
