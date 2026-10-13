// app/me-view.ts — you, as the person others add: your code to show, their code to scan.
//
// One view, two modes, a toggle between them (the way a phone's QR screen has
// them): MY CODE is your link as a QR on a card, the same link in a box with
// its copy icon inside it, and one Share; SCAN is the camera in a square frame,
// with a box to paste a link into and a picture you already have. Either way a
// person read ends in the same place — connect.ts `propose` — and the view
// closes onto the card that asks about them.
//
// Where it stands: the Contacts view (the "you" tile, and ＋ connect), and the
// account sheet's contact-code page. The name under the code is the field you
// change it in, and the identifier sits beside it to copy; with `profile`, the
// ways to be reached sit below, the same block settings shows (reach-view.ts),
// so there is one place each is written. The terms and the privacy notice
// stay where they are kept: the account sheet's foot and its notices page.
import { hint } from "./core.js";
import { mk } from "./dom.js";
import { signal, effect } from "./reactive.js";
import { html, raw, render, type Fragment } from "./template.js";
import { identity } from "./tabs/social/id.js";
import { myLink, copyLink, shareLink, propose } from "./connect.js";
import { connectIn } from "./connect-link.js";
import { classify, type Seen } from "./symbols.js";
import { Viewfinder } from "./viewfinder.js";
import { readStill } from "./scan.js";
import { canStream } from "./camera.js";
import { saveMyName } from "./who-view.js";
import { reachBlock } from "./reach-view.js";

export type MeMode = "code" | "scan";

export interface MeViewOptions {
  /** The mode it opens in. */
  start: MeMode;
  /** Show your ways to be reached below the code. */
  profile: boolean;
  /** A person was read and proposed: the caller closes the view onto the card. */
  onDone: () => void;
}

export interface MeView {
  el: HTMLElement;
  /** Let the camera and every effect go. Safe to call twice. */
  dispose(): void;
}

/** The size the code is drawn at, in pixels. */
const CODE_PX = 220;

// small line icons, drawn here so they take the text's colour
const ICON_COPY = raw(`<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V6a2 2 0 0 1 2-2h9"/></svg>`);
const ICON_PASTE = raw(`<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="5" y="4" width="14" height="17" rx="2"/><path d="M9 4h6v3H9z"/><path d="M9 13h6M9 17h4"/></svg>`);
const ICON_SCAN = raw(`<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3"/><rect x="8" y="8" width="3" height="3"/><rect x="13" y="8" width="3" height="3"/><rect x="8" y="13" width="3" height="3"/><path d="M13 13h3v3"/></svg>`);
const ICON_CODE = raw(`<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="4" y="4" width="6" height="6" rx="1"/><rect x="14" y="4" width="6" height="6" rx="1"/><rect x="4" y="14" width="6" height="6" rx="1"/><path d="M14 14h2v2h-2zM18 18h2v2h-2zM14 18h.01M20 14h.01"/></svg>`);

/** A block that redraws itself from the signals it reads, in an element of its own. */
function mounted(block: () => Fragment, into: HTMLElement, disposers: (() => void)[]): void {
  disposers.push(effect(() => { render(into, block()); }));
}

export function meView(opts: MeViewOptions): MeView {
  const mode = signal<MeMode>(opts.start);
  /** Bumped when the camera could not be had, so the frame says why. */
  const tick = signal(0);
  const el = mk("div", "me-view");
  const main = mk("div", "me-main");
  el.append(main);
  const disposers: (() => void)[] = [];
  let finder: Viewfinder | null = null;
  let gone = false;

  const stopCamera = (): void => { finder?.stop(); finder = null; };

  // a person read, by camera, picture or paste: ask about them, and let the caller close onto the card
  const read = (text: string): boolean => {
    const link = connectIn(text);
    if (!link) return false;
    stopCamera();
    propose(link);
    opts.onDone();
    return true;
  };
  const onSeen = (sym: Seen): void => {
    const r = classify(sym);
    if (r.kind === "person") { read(sym.value); return; }
    hint(r.kind === "label" ? "that is a label, not a person — labels are read by the camera in the dock" : "that is not a playnet person's code", "notice");
  };
  const paste = async (box: HTMLInputElement): Promise<void> => {
    let text = box.value.trim();
    if (!text && navigator.clipboard?.readText) { try { text = (await navigator.clipboard.readText()).trim(); } catch { /* the browser kept the clipboard */ } }
    if (!text) { box.focus(); return; }
    box.value = text;
    if (!read(text)) hint("that is not a playnet person's link", "warn");
  };
  const pickPicture = (): void => {
    const pick = mk("input");
    pick.type = "file"; pick.accept = "image/*";
    pick.addEventListener("change", () => {
      const file = pick.files?.[0];
      if (!file) return;
      void readStill(file).then(seen => {
        if (gone) return;
        const person = seen.find(s => classify(s).kind === "person");
        if (person) read(person.value); else hint("no person's code in that picture", "warn");
      });
    });
    pick.click();
  };

  // the two modes, one tap apart: the drawer's own segmented look
  const toggle = (): Fragment => html`
    <div class="share-rail share-rail-h" role="tablist" aria-label="your code or theirs">
      <a class="share-seg seg-me${mode() === "code" ? " on" : ""}" role="tab" onclick=${() => mode.set("code")}>${ICON_CODE}<span class="share-seg-l">My code</span></a>
      <a class="share-seg seg-me${mode() === "scan" ? " on" : ""}" role="tab" onclick=${() => mode.set("scan")}>${ICON_SCAN}<span class="share-seg-l">Scan</span></a>
    </div>`;

  // ── my code ─────────────────────────────────────────────────────────────
  const codeBody = (): Fragment => {
    const me = identity();
    const mine = me ? myLink(CODE_PX) : null;
    if (!me || !mine) return html`<p class="me-say">Make an identity (tap your name) and you have a code of your own to show.</p>`;
    const name = me.name || "you";
    const short = me.aid.length > 16 ? `${me.aid.slice(0, 8)}…${me.aid.slice(-6)}` : me.aid;
    // the name is a field that reads as the card's caption: tap it and it is yours to change, ↵ or leaving it keeps it
    const keep = (box: HTMLInputElement): void => { if (box.value.trim() !== (identity.peek()?.name || "")) void saveMyName(box.value); };
    return html`
      <div class="me-qrcard">
        <span class="me-av" aria-hidden="true">${name.trim().charAt(0).toUpperCase() || "·"}</span>
        <div class="me-qr" role="img" aria-label="your contact code, a QR">${raw(mine.qr)}</div>
        <label class="me-namefield" title="what people call you — tap to change">
          <input type="text" class="me-name" maxlength="60" autocomplete="nickname" spellcheck="false" placeholder="your name"
                 aria-label="your name" value="${me.name}"
                 onkeydown=${(e: KeyboardEvent) => { if (e.key === "Enter") (e.currentTarget as HTMLInputElement).blur(); }}
                 onblur=${(e: Event) => keep(e.currentTarget as HTMLInputElement)}>
          <span class="me-pen" aria-hidden="true">✎</span>
        </label>
        <button type="button" class="me-aid" title="your identifier names you and is not secret — copy it" aria-label="copy your identifier"
                onclick=${() => { if (navigator.clipboard) void navigator.clipboard.writeText(me.aid); hint("identifier copied", "success"); }}>
          <span>${short}</span>${ICON_COPY}</button>
      </div>
      <div class="me-linkbox">
        <input type="text" readonly aria-label="your link" value="${mine.link}"
               onfocus=${(e: Event) => (e.currentTarget as HTMLInputElement).select()}>
        <button type="button" class="me-ico" title="copy my link" aria-label="copy my link"
                onclick=${() => copyLink(mine.link)}>${ICON_COPY}</button>
      </div>
      <button type="button" class="me-share" onclick=${() => shareLink(mine.link, name)}>Share my code</button>`;
  };

  // ── scan ────────────────────────────────────────────────────────────────
  const scanBody = (): Fragment => {
    tick();
    const live = canStream() && !finder?.note;
    return html`
      <div class="me-scan">
        <div class="me-frame">
          ${live ? html`<video class="me-video" muted playsinline></video>`
                 : html`<div class="me-nocam">${finder?.note || "no camera here — paste a link below"}</div>`}
          <i class="me-corner tl"></i><i class="me-corner tr"></i><i class="me-corner bl"></i><i class="me-corner br"></i>
        </div>
        <div class="me-scansay">Scan QR code</div>
        <div class="me-linkbox">
          <input type="text" class="me-paste" placeholder="or paste a link" aria-label="paste a person's link" spellcheck="false"
                 onkeydown=${(e: KeyboardEvent) => { if (e.key === "Enter") void paste(e.currentTarget as HTMLInputElement); }}>
          <button type="button" class="me-ico" title="paste, and connect" aria-label="paste a link"
                  onclick=${(e: Event) => void paste((e.currentTarget as HTMLElement).parentElement!.querySelector<HTMLInputElement>(".me-paste")!)}>${ICON_PASTE}</button>
        </div>
        <button type="button" class="me-switch" onclick=${pickPicture}><span>🖼</span><span>a picture you have</span></button>
      </div>`;
  };

  // the mode draws into MAIN; the camera follows the frame each draw makes
  disposers.push(effect(() => {
    const m = mode();
    el.classList.toggle("me-scanning", m === "scan");
    render(main, html`${toggle()}${m === "scan" ? scanBody() : codeBody()}`);
    if (m === "code") { stopCamera(); return; }
    const video = main.querySelector<HTMLVideoElement>(".me-video");
    if (!video || gone) return;
    finder ??= new Viewfinder(onSeen, () => tick.update(n => n + 1));
    void finder.follow(video);
  }));

  // ── you: the name, and the ways to be reached — settings' own blocks ──
  if (opts.profile) {
    const profile = mk("div", "me-profile");
    const reach = mk("div", "me-block");
    profile.append(mk("div", "me-h", "how to reach you"), reach);
    mounted(reachBlock, reach, disposers);
    el.append(profile);
  }

  // the camera is let go while the view is out of sight (the drawer put away) and taken up again when it is back
  if (typeof IntersectionObserver !== "undefined") {
    const seen = new IntersectionObserver(entries => {
      const shown = entries.some(e => e.isIntersecting);
      if (!shown) stopCamera();
      else if (mode.peek() === "scan" && !finder && !gone) tick.update(n => n + 1);
    });
    seen.observe(el);
    disposers.push(() => seen.disconnect());
  }

  return {
    el,
    dispose() {
      if (gone) return;
      gone = true;
      stopCamera();
      disposers.splice(0).forEach(d => d());
    },
  };
}
