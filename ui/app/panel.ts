// app/panel.ts — the sidebar seam: one grip that resizes and collapses #panel.
//
// The rail's width is a single custom property on #main (`--panel-w`). Everything
// here writes that one number, and the layout follows: the stage is `flex: 1 1
// auto`, and main.js already watches #orbwrap with a ResizeObserver, so every
// face redraws itself to the width you land on while you are still dragging.
//
// Three ways to move it, because a seam is grabbed differently at every size:
// drag the grip, hit its toggle, or use the arrow keys once it has focus (it is
// a real `role="separator"`, so a keyboard reaches it). `[` toggles from
// anywhere. The chosen width and the collapsed state persist per browser.
//
// Narrow screens have no width to spare beside the stage, so the same rail
// becomes a drawer over it: the grip is a tab pinned to the left edge, the width
// is the viewport's to decide, and it starts away. The two layouts remember
// their own open/shut state — furniture beside the stage, a visit over it.
//
// Some rooms NEED the rail: settings puts its section list and its way back out
// there, so a collapsed rail would strand you in it. `holdPanelOpen(owner, true)`
// keeps it open for as long as the room is, without disturbing the state you
// chose — releasing the hold returns the rail to exactly where you left it.
// Holds are kept PER OWNER (settings, the web face, an open room): the rail is
// held while any owner holds it, and one owner letting go never frees another's.

import { readStr, writeStr } from "./store.js";
import { stage } from "./stage.js";
import { K } from "./keys.js";

// the floor is set by what the rail HOLDS, not by what fits: below ~240px the
// event and proposal lists break to one word a line
const MIN = 240;
const KEY_W = K.panelW;
const KEY_SHUT_N = K.panelShutNarrow;   // the drawer, over the stage
// the column, beside the stage — per face
const faceShutKey = (): string => K.panelShutFace + stage.face;

// Whether THIS face starts shut when nobody has touched its rail yet — faces.ts
// is the one table that knows that (its own `railShut` field), passed in by
// settlePanelForFace rather than duplicated into a second list here.
let faceDefaultShut = false;

/**
 * The three elements the rail cannot work without. Narrowing them ONCE into a
 * shell is what lets every function below keep its body verbatim: each
 * destructures the same three names it always used, and TypeScript can follow
 * that where it could not follow a module-level `ok` boolean.
 */
interface Shell {
  main: HTMLElement;
  grip: HTMLElement;
  toggle: HTMLElement;
}

const shell: Shell | null = (() => {
  const main = document.getElementById("main");
  const grip = document.getElementById("panelgrip");
  const toggle = document.getElementById("paneltoggle");
  return main && grip && toggle ? { main, grip, toggle } : null;
})();
const size = document.getElementById("panelsize");
const scrim = document.getElementById("panelscrim");

const narrow = (): boolean => window.matchMedia("(max-width: 920px)").matches;
/** Whether the rail is a drawer over the stage right now (the phone layout). */
export const isNarrow = narrow;
const maxW = (): number => Math.max(MIN, Math.min(640, window.innerWidth * 0.5));
const clamp = (w: number): number => Math.round(Math.max(MIN, Math.min(maxW(), w)));

// the rail starts at its floor — the tightest width its content packs into —
// and grows only by your hand on the grip
let width = clamp(parseInt(readStr(KEY_W) ?? "", 10) || MIN);
// The column and the drawer are the same rail in two layouts, and they want
// opposite defaults: beside the stage it is furniture and stays open; over the
// stage it covers the day, so it starts away. Two states, one toggle.
let shutNarrow = readStr(KEY_SHUT_N) !== "0";
// a room that lives IN the rail holds it open; the stored state is untouched
const holders = new Set<string>();
const isShut = (): boolean => {
  if (holders.size) return false;
  if (narrow()) return shutNarrow;
  const own = readStr(faceShutKey());
  return own != null ? own === "1" : faceDefaultShut;
};

function paint(): void {
  if (!shell) return;
  const { main, grip, toggle } = shell;
  const shut = isShut();
  main.style.setProperty("--panel-w", width + "px");
  main.classList.toggle("panel-shut", shut);
  main.toggleAttribute("data-held", holders.size > 0);   // a held rail shows even where a face hides it
  toggle.setAttribute("aria-expanded", String(!shut));
  toggle.textContent = shut ? "›" : "‹";
  toggle.title = shut ? "show the sidebar" : "hide the sidebar";
  grip.setAttribute("aria-valuenow", String(shut ? 0 : width));
  grip.setAttribute("aria-valuemin", String(MIN));
  grip.setAttribute("aria-valuemax", String(Math.round(maxW())));
  if (size) size.textContent = width + "px";
}

// a width change reflows the stage; the faces that size themselves off the
// window (rather than off #orbwrap) get told too
const settle = () => window.dispatchEvent(new Event("resize"));

function animate(fn: () => void): void {
  if (!shell) { fn(); return; }
  const { main } = shell;
  main.classList.add("panel-anim");
  fn();
  paint();
  const done = () => { main.classList.remove("panel-anim"); settle(); };
  main.addEventListener("transitionend", done, { once: true });
  setTimeout(done, 320);                    // display:none has no transition to end
}

// An explicit reach for the toggle outranks any hold: if you shut the rail while
// a room is holding it open, you meant it, and the room lets go.
function setShut(v: boolean): void {
  animate(() => {
    holders.clear();
    if (narrow()) { shutNarrow = v; writeStr(KEY_SHUT_N, v ? "1" : "0"); }
    // wide: a face's own choice, so opening the plan's rail never opens
    // everyone else's, and shutting it never shuts the ones you left be
    else writeStr(faceShutKey(), v ? "1" : "0");
  });
}

// Keep the rail open for as long as OWNER's room needs it, then give it back
// exactly as it was — no write to the stored state in either direction. Other
// owners' holds are untouched, and asking again for what is already so is a no-op.
export function holdPanelOpen(owner: string, on: boolean): void {
  if (holders.has(owner) === on) return;
  animate(() => { if (on) holders.add(owner); else holders.delete(owner); });
}

// A choice made INSIDE the drawer (a view row, a day) puts it away — the flow
// every phone calendar taught. Wide, the rail is furniture, so this is a no-op.
export function closePanelIfNarrow(): void { if (narrow() && !isShut()) setShut(true); }

// The stage changed face — settle into THAT face's own state: its stored
// choice if it has one (faceShutKey, above), else whether faces.ts marks it
// `railShut` (the one place that fact lives).
export function settlePanelForFace(railShut: boolean): void {
  // the first face is a landing, not a move: nothing is on screen yet to slide
  // from, so the rail takes its state in one paint (faces.ts stamps data-face
  // right after this call)
  if (shell && !shell.main.hasAttribute("data-face")) { faceDefaultShut = railShut; paint(); return; }
  animate(() => { faceDefaultShut = railShut; });
}
function setWidth(w: number): void { width = clamp(w); writeStr(KEY_W, String(width)); }

// ── drag ──────────────────────────────────────────────────────────────────
// The panel starts at #main's left edge, so the width under the pointer is just
// the distance from that edge, less the grip's own half-width.
let dragging = false;
if (shell) {
const { main, grip, toggle } = shell;
grip.addEventListener("pointerdown", e => {
  // shut, the grip is a button, not a seam — a click there brings the rail back
  if (narrow() || isShut() || e.target === toggle || e.button !== 0) return;
  dragging = true;
  try { grip.setPointerCapture(e.pointerId); } catch (err) { /* synthetic pointer */ }
  main.classList.add("panel-drag");
  main.classList.remove("panel-anim");
  e.preventDefault();
});
grip.addEventListener("pointermove", e => {
  if (!dragging) return;
  setWidth(e.clientX - main.getBoundingClientRect().left - grip.offsetWidth / 2);
  paint();
});
function endDrag(e: PointerEvent): void {
  if (!dragging) return;
  dragging = false;
  main.classList.remove("panel-drag");
  try { grip.releasePointerCapture(e.pointerId); } catch (err) { /* already gone */ }
  // dragged hard against the minimum: take that as "put it away"
  if (e.clientX - main.getBoundingClientRect().left < MIN - 48) setShut(true);
  else settle();
}
grip.addEventListener("pointerup", endDrag);
grip.addEventListener("pointercancel", endDrag);

// ── the toggle, the double-click, the keys ────────────────────────────────
toggle.addEventListener("click", e => { e.stopPropagation(); setShut(!isShut()); });
grip.addEventListener("click", () => { if (narrow() || isShut()) setShut(!isShut()); });
grip.addEventListener("dblclick", () => { if (!narrow()) setShut(!isShut()); });

grip.addEventListener("keydown", e => {
  const step = e.shiftKey ? 64 : 16;
  if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
    if (isShut() && e.key === "ArrowRight") { setShut(false); }
    else { setWidth(width + (e.key === "ArrowRight" ? step : -step)); paint(); settle(); }
  } else if (e.key === "Home") { setWidth(MIN); paint(); settle(); }
  else if (e.key === "End") { setWidth(maxW()); paint(); settle(); }
  else if (e.key === "Enter" || e.key === " ") { setShut(!isShut()); }
  else return;
  e.preventDefault();
});

// narrow: the drawer floats over the day, so tapping the day beside it puts it
// back — and so does Escape, before the stage's own Escape gets the key
if (scrim) scrim.addEventListener("click", () => setShut(true));
// the header's ☰ — the same act as the edge tab, sitting where a phone reaches
const ham = document.getElementById("drawerbtn");
if (ham) ham.addEventListener("click", () => setShut(!isShut()));
window.addEventListener("keydown", e => {
  // settings lives in the rail and has its own Escape — leave that key alone
  if (e.key !== "Escape" || !narrow() || isShut() || holders.size) return;
  e.stopImmediatePropagation();
  setShut(true);
});

// `[` from anywhere — except while writing, where it is a bracket
window.addEventListener("keydown", e => {
  if (e.key !== "[" || e.metaKey || e.ctrlKey || e.altKey) return;
  // duck-typed on purpose: anything focusable that takes text should keep its
  // bracket, whatever element it happens to be
  const t = e.target as HTMLElement | null;
  if (t && (t.isContentEditable || /^(input|textarea|select)$/i.test(t.tagName))) return;
  e.preventDefault();
  setShut(!isShut());
});

// the ceiling is half the window, so a shrinking window pulls the rail in with it
window.addEventListener("resize", () => {
  const w = clamp(width);
  if (w !== width) { width = w; writeStr(KEY_W, String(width)); }
  paint();
});
}

paint();

// Narrow, the rail is a fixed-position drawer over the day (see paint()'s
// `panel-shut` and the CSS it drives) — it can't sit inside #main's flex
// column, so it can't get its position from flexbox the way the wide layout
// does. --barh is the same idea by hand: the express bar's capsule's OWN lower
// edge, live, so the drawer starts exactly beneath it — a real measurement,
// not a guessed pixel count baked into the drawer's padding.
const bar = document.getElementById("sharebar");
if (bar) {
  // --barh: the capsule's reach from the bottom of the page (its height plus the margin under it) — the drawer
  // stops there, the sheet reserves it for its content, and the map's controls sit above it
  const root = document.documentElement;
  const setBarH = () => {
    const row = bar.querySelector(".sharebar-row");
    root.style.setProperty("--barh", (row ? Math.max(0, window.innerHeight - row.getBoundingClientRect().top) : 68) + "px");
  };
  const ro = new ResizeObserver(setBarH);
  let watched: Element | null = null;
  const watch = () => {
    const row = bar.querySelector(".sharebar-row");
    if (row && row !== watched) { if (watched) ro.unobserve(watched); watched = row; ro.observe(row); }
    setBarH();
  };
  ro.observe(bar);
  new MutationObserver(watch).observe(bar, { childList: true });   // the capsule is built after this runs
  watch();
}
