// The feedback lane — tier 1 of the two-tier issue flow. A visitor says what
// they think of the interface, points at the parts they mean, and optionally
// attaches a screenshot; the whole utterance POSTs as one JSON body to
// /feedback, the server's anonymous prunable pool. No account, no signature —
// the pool is testimony, not record; synthesis into Radicle issues happens
// operator-side.
//
// It is layout chrome like the bar it rides in: initFeedback() (called from
// main.ts after initShareBar()) puts a 💬 button in the sharebar row and an
// in-flow panel above the drawer. share.ts owns none of it.
//
// SPEAKING is the footer mic's job, not a second mic's: while this panel is
// open it claims the universal mic (voice/sink.js), so holding the one button
// in the bar speaks into the feedback draft and tapping it focuses the text.
//
// POINTING: "point" mode captures one click anywhere on the page, names the
// element (app/refsel.js), drops a [n] marker into the prose at the cursor
// and grows a chip below. Tapping a chip scrolls to that element and flashes
// it — the revealSlot pattern generalised to any element. The marker and the
// chip are one reference in two places, so dropping the chip takes the marker
// out of the prose with it. That is what keeps numbering safe as mere
// max-of-current: a number is free to be reused precisely because no marker
// bearing it survives its chip, and nothing has to remember a high-water mark
// across a reload to keep the live references distinct.

import { claimVoice, type VoiceSink } from "./voice/sink.js";
import { selectorFor, labelFor, withinFor } from "./refsel.js";
import { diagText, diagFaults, diagLines, bootTrace, redact } from "./diag.js";
import { signal, effect } from "./reactive.js";
import { devMode } from "./prefs.js";
import { html, render, list } from "./template.js";
import { stage } from "./stage.js";
import { toast } from "./toast.js";
import { readJSON, writeJSON, forget } from "./store.js";
import { downscale, pickPhoto, toBase64 } from "./photo.js";
import { FEEDBACK_MAX_BYTES } from "./limits-catalogue.js";
import { K } from "./keys.js";

interface ElementRef {
  n: number;        // the [n] marker this chip anchors in the prose
  label: string;    // for people — `span.scopepill-l “earth”`
  sel: string;      // best-effort selector to find it again
  /** the nearest ancestor that names itself, when this element does not —
   *  a bare <path> in the wheel is grep-able only through its layer */
  within: string;
  face: string;     // which face was showing when it was picked
}

interface Draft {
  text: string;
  refs: ElementRef[];
}

const DRAFT_KEY = K.feedbackDraft;   // anonymous pool → un-scoped key
const MAX_BODY = FEEDBACK_MAX_BYTES;     // the server's cap (generated from gateway/limits.scm)
const SHOT_EDGE = 800;                   // longest screenshot edge after downscale
const DIAG_BYTES = 16384;                // the diagnostic's share of the body

/** Open/closed is state, so it is a signal and the panel is drawn from it. */
const open = signal(false);
const refs = signal<ElementRef[]>([]);
const shot = signal<string | null>(null);   // data-URL JPEG, already downscaled
/** Whether to send what the page said about itself. Off until asked for. */
const withDiag = signal(false);

let ta: HTMLTextAreaElement | null = null;
let panel: HTMLElement | null = null;
let releaseVoice: (() => void) | null = null;
let picking = false;

// ── element references ──────────────────────────────────────────────

function flashRef(ref: ElementRef): void {
  // a selector built on one face can be unaddressable on another, and
  // querySelector THROWS on a malformed one rather than returning null
  let el: Element | null = null;
  try { el = ref.sel ? document.querySelector(ref.sel) : null; } catch { el = null; }
  if (!el) {
    toast(`can't find ${ref.label} right now — it may live on the “${ref.face}” face`, "notice");
    return;
  }
  el.scrollIntoView({ behavior: "smooth", block: "center" });
  el.classList.add("pn-flash");
  setTimeout(() => el.classList.remove("pn-flash"), 1600);
}

/** Drop a reference: the chip and its marker in the prose go together. */
function dropRef(ref: ElementRef): void {
  refs.set(refs().filter(r => r !== ref));
  if (ta) ta.value = ta.value.replace(new RegExp(`\\s*\\[${ref.n}\\]`, "g"), "");
  save();
}

function beginPick(): void {
  if (picking) return;
  picking = true;
  document.body.classList.add("fb-picking");
  let hovered: Element | null = null;
  const clearHover = (): void => {
    if (hovered) hovered.classList.remove("fb-pick-hover");
    hovered = null;
  };
  const mine = (t: Element | null): boolean => !!t && !!panel && panel.contains(t);
  const move = (ev: PointerEvent): void => {
    const t = ev.target instanceof Element ? ev.target : null;
    if (t === hovered) return;
    clearHover();
    if (t && !mine(t)) { hovered = t; t.classList.add("fb-pick-hover"); }
  };
  const done = (): void => {
    picking = false;
    clearHover();
    document.body.classList.remove("fb-picking");
    document.removeEventListener("pointermove", move, true);
    document.removeEventListener("pointerdown", pick, true);
    document.removeEventListener("keydown", key, true);
  };
  const pick = (ev: PointerEvent): void => {
    const t = ev.target instanceof Element ? ev.target : null;
    if (!t || mine(t)) { done(); return; }
    ev.preventDefault();
    ev.stopPropagation();
    done();
    // past the highest LIVE number: unique among the references that exist,
    // which is the whole invariant, since a dropped one took its marker with it
    const n = refs().reduce((m, r) => Math.max(m, r.n), 0) + 1;
    refs.set([...refs(), { n, label: labelFor(t), sel: selectorFor(t, document.body),
                           within: withinFor(t, document.body), face: stage.face }]);
    insertMarker(n);
    save();
  };
  const key = (ev: KeyboardEvent): void => {
    if (ev.key === "Escape") { ev.preventDefault(); done(); }
  };
  document.addEventListener("pointermove", move, true);
  document.addEventListener("pointerdown", pick, true);
  document.addEventListener("keydown", key, true);
  toast("tap the element you mean — esc cancels", "notice");
}

function insertMarker(n: number): void {
  if (!ta) return;
  const at = ta.selectionStart ?? ta.value.length;
  const before = ta.value.slice(0, at);
  const pad = before && !before.endsWith(" ") ? " " : "";
  ta.value = `${before}${pad}[${n}] ${ta.value.slice(at)}`;
  ta.focus();
}

// ── screenshot attach ───────────────────────────────────────────────

// Downscale to fit the server's cap: longest edge 800px, JPEG, the quality
// stepped down (photo.ts) until it fits beside the text.
async function acceptImage(file: Blob): Promise<void> {
  const room = MAX_BODY - 32768;         // leave space for prose + context
  const out = await downscale(file, SHOT_EDGE, Math.floor(room * 3 / 4));
  if (out === "unreadable") { toast("that file doesn't read as an image", "warn"); return; }
  if (out === "too-large") { toast("image is too large even downscaled — skipped", "warn"); return; }
  shot.set("data:image/jpeg;base64," + await toBase64(out));
}

// ── draft persistence ───────────────────────────────────────────────

function save(): void {
  if (!ta) return;
  if (!ta.value && refs().length === 0) { forget(DRAFT_KEY); return; }
  writeJSON(DRAFT_KEY, { text: ta.value, refs: refs() } satisfies Draft);
}

// ── submit ──────────────────────────────────────────────────────────

function payload(): string {
  return JSON.stringify({
    v: 1,
    text: ta ? ta.value.trim() : "",
    refs: refs(),
    shot: shot() || undefined,
    diag: withDiag() ? diagText(DIAG_BYTES) : undefined,
    boot: withDiag() ? (bootTrace().slice(0, 2048) || undefined) : undefined,
    face: stage.face,
    mode: stage.mode,
    // scrubbed like the diagnostic: `?gateway=<sturdyref>` is the dial's own
    // documented local flow, so the URL is a live route for exactly the
    // bearer capability diag.js exists to keep out of an anonymous pool
    path: redact(location.pathname + location.search + location.hash),
    vw: window.innerWidth,
    vh: window.innerHeight,
    dpr: window.devicePixelRatio,
    lang: navigator.language,
    ua: navigator.userAgent,
    at: new Date().toISOString(),
  });
}

function send(): void {
  if (!ta || !ta.value.trim()) { toast("say something first", "notice"); return; }
  const body = payload();
  if (body.length > MAX_BODY) {
    toast("this feedback is too large — trim the text or drop the screenshot", "warn");
    return;
  }
  const t = toast("sending feedback…", "notice", { duration: 0 });
  window.fetch("/feedback", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body,
  })
    .then(r => r.ok ? r.json() : Promise.reject(r.status))
    .then(() => {
      t?.update("feedback sent — thank you ✓", "success");
      if (ta) ta.value = "";
      refs.set([]); shot.set(null); withDiag.set(false);
      forget(DRAFT_KEY);
      open.set(false);
    })
    .catch(() => t?.update("couldn't send — kept as a draft, try again later", "warn"));
}

// ── the panel ───────────────────────────────────────────────────────

/** The mic speaks in here while the panel is open. */
const sink: VoiceSink = {
  hear(text, live) {
    if (!ta) return;
    ta.classList.toggle("live", live);
    // the live caption REPLACES itself as it grows; only the release text is
    // kept, appended to whatever was already typed
    const base = ta.dataset.spoken ?? ta.value;
    ta.dataset.spoken = base;
    ta.value = base + (base && !base.endsWith(" ") ? " " : "") + text + (live ? " …" : "");
    if (!live) { delete ta.dataset.spoken; save(); ta.focus(); }
  },
  type() { ta?.focus(); },
};

function drawRefs(): void {
  list(".fb-chips", refs(), r => r.n, r => html`
    <span class="fb-chip" title="tap to show what this refers to"
          onclick=${() => flashRef(r)}>[${r.n}] ${r.label}<span
      class="fb-chip-x" title="remove this reference"
      onclick=${(ev: Event) => { ev.stopPropagation(); dropRef(r); }}>×</span></span>`);
}

/**
 * The diagnostic row: what the page said about itself, offered rather than
 * taken. It shows the count and the faults before anything is attached, and
 * turning it on reveals the actual lines — a person can read exactly what
 * they would be sending, which is the only honest way to offer this from a
 * pool that promises to be anonymous.
 */
function drawDiag(): void {
  const on = withDiag();
  open();                         // redrawn on every open: the ring and the boot trace fill after boot
  const lines = diagLines();
  const faults = diagFaults();
  const boot = bootTrace();
  // day-boot.js keeps its own breadcrumbs, and they are the only record of a
  // failure that happens before the app's modules run. So the offer is
  // made whenever EITHER has something, and the preview shows what would
  // actually be sent rather than a summary of it.
  if (!lines.length && !boot) { render(".fb-diagrow", html``); return; }
  const body = [boot ? `boot: ${boot}` : "", diagText(DIAG_BYTES)]
    .filter(Boolean).join("\n");
  render(".fb-diagrow", html`
    <label class="fb-diag-ask">
      <input type="checkbox" ${on ? "checked" : ""} onchange=${
        (ev: Event) => withDiag.set((ev.target as HTMLInputElement).checked)}>
      attach what the page said about itself — ${lines.length} lines${
        faults ? html`, <b>${faults} error${faults === 1 ? "" : "s"}</b>` : html``}
    </label>
    ${on ? html`<pre class="fb-diag">${body}</pre>` : html``}`);
}

function drawShot(): void {
  const url = shot();
  render(".fb-shotrow", url
    ? html`<img class="fb-shot" src="${url}" alt="attached screenshot"><span
        class="fb-chip-x" title="remove the screenshot"
        onclick=${() => shot.set(null)}>×</span>`
    : html``);
}

export function initFeedback(): void {
  if (document.getElementById("fbbtn")) return;
  const bar = document.getElementById("sharebar");
  const row = bar?.querySelector(".sharebar-row");
  if (!bar || !row) return;   // no share bar on this page — the lane stays off

  panel = document.createElement("div");
  panel.id = "fbpanel";
  panel.className = "fb-panel";

  // The panel's markup in one expression — the chips and the screenshot are
  // drawn into their rows from the signals that hold them.
  render(panel, html`
    <textarea class="fb-text" rows="3"
      placeholder="what happened? what should be better? point 👆 at what you mean…"></textarea>
    <div class="fb-chips"></div>
    <div class="fb-shotrow"></div>
    <div class="fb-diagrow"></div>
    <div class="fb-tools">
      <button class="fb-tool" type="button"
        title="point at the element you're talking about" onclick=${beginPick}>👆</button>
      <button class="fb-tool" type="button"
        title="attach a screenshot (or paste one into the text)"
        onclick=${() => { void pickPhoto(false).then(f => { if (f) void acceptImage(f); }); }}>🖼️</button>
      <button class="fb-send" type="button" onclick=${send}>send</button>
    </div>
    <div class="fb-note">anonymous — lands in the maintainers' feedback pool,
      may become an issue on the board</div>`);

  ta = panel.querySelector<HTMLTextAreaElement>(".fb-text")!;   // just rendered
  ta.addEventListener("input", save);
  ta.addEventListener("paste", ev => {
    const img = Array.from(ev.clipboardData?.items ?? [])
      .find(i => i.type.startsWith("image/"));
    const file = img?.getAsFile();
    if (file) { ev.preventDefault(); void acceptImage(file); }
  });

  const btn = document.createElement("button");
  btn.id = "fbbtn";
  btn.className = "fb-btn";
  btn.type = "button";
  btn.textContent = "💬";
  btn.title = "leave feedback about playnet itself";
  btn.addEventListener("click", () => open.set(!open()));

  // beside the backpack, inside the bar's one flex group, so it wraps with
  // the expression instead of floating on a row of its own
  const handle = row.querySelector(".sharebar-handle");
  if (handle) handle.before(btn); else row.append(btn);
  const drawer = bar.querySelector(".share-drawer");
  if (drawer) drawer.before(panel); else bar.append(panel);

  // One effect per fact. Whether the panel SHOWS is CSS's answer to the class,
  // not a display property written from here (settings.ts and share.ts both
  // read this way). Opening claims the footer mic; closing gives it back.
  effect(() => {
    const on = open();
    panel!.classList.toggle("on", on);
    btn.classList.toggle("on", on);
    if (on) { releaseVoice ??= claimVoice(sink); ta!.focus(); }
    else { releaseVoice?.(); releaseVoice = null; }
  });
  // dev mode (settings) is what shows the button; turning it off closes the lane
  effect(() => {
    const dev = devMode();
    btn.hidden = !dev;
    if (!dev) open.set(false);
  });
  effect(drawRefs);
  effect(drawShot);
  effect(drawDiag);

  const saved = readJSON<Draft>(DRAFT_KEY, { text: "", refs: [] });
  ta.value = saved.text || "";
  refs.set(Array.isArray(saved.refs) ? saved.refs : []);
}
