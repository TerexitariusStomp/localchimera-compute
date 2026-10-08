// app/drag.ts — move a fixed-position element by a handle, and keep it on screen.
//
// One small mechanism for a floating surface that should go where the person
// wants it: pointer capture on the handle, a few pixels of slack so a TAP stays a
// tap, the element clamped to the viewport as it moves and again when the window
// changes size. It moves the element with `left`/`top` and never touches its
// contents, so whatever the element holds keeps working while it travels.

export interface Pos { x: number; y: number; }

export interface DragOpts {
  /** What you grab. A pointerdown here starts a drag. */
  handle: HTMLElement;
  /** What moves. */
  target: HTMLElement;
  /** Called once when a drag ends, with where the element now stands. */
  onEnd?: (pos: Pos) => void;
  /** Pixels of travel before a press counts as a drag (default 4). */
  slack?: number;
}

export interface Draggable {
  /** True for the click that follows a drag, so a handler can ignore it. */
  justDragged(): boolean;
  /** Put the element at X, Y (clamped to the viewport). */
  place(x: number, y: number): void;
  /** Hand the element back to its stylesheet position. */
  reset(): void;
  /** Stop listening. */
  dispose(): void;
}

const clamp = (v: number, lo: number, hi: number): number => Math.max(lo, Math.min(hi, v));

export function makeDraggable(o: DragOpts): Draggable {
  const { handle, target } = o;
  const slack = o.slack ?? 4;
  let grab: { dx: number; dy: number; x0: number; y0: number } | null = null;
  let moved = false, dragged = false, placed = false;

  const place = (x: number, y: number): void => {
    // the stylesheet centres the element with auto margins and right/left insets;
    // an explicit position replaces all of that at once
    const maxX = Math.max(0, innerWidth - target.offsetWidth);
    const maxY = Math.max(0, innerHeight - target.offsetHeight);
    target.style.left = clamp(x, 0, maxX) + "px";
    target.style.top = clamp(y, 0, maxY) + "px";
    target.style.right = "auto";
    target.style.margin = "0";
    placed = true;
  };

  const down = (e: PointerEvent): void => {
    if (e.button !== 0) return;
    const r = target.getBoundingClientRect();
    grab = { dx: e.clientX - r.left, dy: e.clientY - r.top, x0: e.clientX, y0: e.clientY };
    moved = false;
    try { handle.setPointerCapture(e.pointerId); } catch (_) { /* synthetic pointer */ }
  };
  const move = (e: PointerEvent): void => {
    if (!grab) return;
    if (!moved && Math.hypot(e.clientX - grab.x0, e.clientY - grab.y0) < slack) return;
    moved = true;
    target.classList.add("dragging");
    place(e.clientX - grab.dx, e.clientY - grab.dy);
  };
  const up = (e: PointerEvent): void => {
    if (!grab) return;
    try { handle.releasePointerCapture(e.pointerId); } catch (_) { /* already gone */ }
    grab = null;
    target.classList.remove("dragging");
    if (moved) {
      dragged = true;
      // the click that closes this press arrives before any other event
      setTimeout(() => { dragged = false; }, 0);
      const r = target.getBoundingClientRect();
      if (o.onEnd) o.onEnd({ x: r.left, y: r.top });
    }
  };
  const resize = (): void => {
    if (!placed) return;
    const r = target.getBoundingClientRect();
    place(r.left, r.top);
  };

  handle.addEventListener("pointerdown", down);
  handle.addEventListener("pointermove", move);
  handle.addEventListener("pointerup", up);
  handle.addEventListener("pointercancel", up);
  window.addEventListener("resize", resize);

  return {
    justDragged: () => dragged,
    place,
    reset() {
      for (const p of ["left", "top", "right", "margin"] as const) target.style[p] = "";
      placed = false;
    },
    dispose() {
      handle.removeEventListener("pointerdown", down);
      handle.removeEventListener("pointermove", move);
      handle.removeEventListener("pointerup", up);
      handle.removeEventListener("pointercancel", up);
      window.removeEventListener("resize", resize);
    },
  };
}
