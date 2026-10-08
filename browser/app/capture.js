// app/capture.ts — the capture sheet: one gesture from a look to a reading.
//
// Every face that asks for a count opens this sheet (docs/observation/
// capture.md §10): the inventory face on a row, the calendar on a planned
// count, the share bar's camera on whatever is in front of the person. It fills
// the six fields a reading carries — what, how much, where, when, by what
// technique, for whom — from what the opener already knows, and asks the person
// for the one thing only they can give: the figure.
//
// The sheet is a short stack of screens (sheet.ts), each drawn by its own module:
//
//   camera   (capture-look.ts)    what the camera sees: a label or a barcode in
//            view is read, shots go into a tray, read together as rows, each
//            row confirmed, struck or corrected, then landed as a count or a
//            first sighting declared; or kept to be read later
//   queue    (capture-look.ts)    the scenes waiting to be read
//   bin      (capture-stock.ts)   a container and what is in it, each line
//            countable, the prints
//   count    (capture-stock.ts)   the figure, then what the count found
//   product  (capture-stock.ts)   a barcode asking which stock it is
//   contest  (capture-contest.ts) the counts of a stock: one a member says was
//            not done is contested; the counter attaches the photograph the
//            count names, and the franchise sees it
//
// A screen is drawn once when it comes to the top; between those the status
// line and the button's readiness change in place, so what a person has typed,
// and their caret, stay where they are. This module draws whichever screen is
// on top, claims the footer mic while the sheet is open (voice/sink.ts), so a
// spoken "eight and a half" lands in the figure the way a typed one does, and
// opens the sheet for the faces that ask.
import { on } from "./bus.js";
import { effect } from "./reactive.js";
import { render } from "./template.js";
import { claimVoice } from "./voice/sink.js";
import { parseFigure } from "./count.js";
import { codeIn, spoken } from "./labels.js";
import { readEvidence, sweepEvidence, EVIDENCE_DAYS } from "./photo.js";
import { queuedHashes, pruneQueued } from "./queue.js";
import { sheet, top, say, push, replaceTop, close, onClose, q, qa, host } from "./sheet.js";
import { countScreen, binScreen, productScreen, find, figureIn, fromStock, screenOf, restock } from "./capture-stock.js";
import { lookKind, queueKind, queueScreen, loadQueue, releaseCamera, resetTyped, setTyped, focusedQty } from "./capture-look.js";
import { aiming, lookTop, lookScreen, sceneOf, wantReads } from "./capture-scene.js";
import { contestScreen, loadContests } from "./capture-contest.js";
// every kind of screen has its own module's drawing: a kind added to Screen with
// none here does not compile
const SCREENS = {
    count: countScreen, bin: binScreen, product: productScreen, look: lookKind, queue: queueKind, contest: contestScreen,
};
const kindOf = (scr) => SCREENS[scr.kind];
let node = null;
let releaseVoice = null;
let drawn = null;
onClose(releaseCamera);
onClose(() => { releaseVoice?.(); releaseVoice = null; });
function draw() {
    const s = sheet(), scr = top(s);
    if (!node)
        return;
    node.hidden = !scr;
    if (!s || !scr) {
        drawn = null;
        return;
    }
    const kind = kindOf(scr);
    if (drawn !== scr) {
        render(node, kind.render(scr, s.stack.length > 1));
        drawn = scr;
        if (!aiming(scr))
            releaseCamera(); // the camera is open only while the screen waits for a shot
        kind.shown?.(scr);
    }
    // the status line and the buttons' readiness change in place
    const says = q(".cap-says");
    if (says)
        says.textContent = s.says || kind.prompt?.(scr) || "";
    for (const b of qa(".cap-go, .cap-mini, .cap-choice"))
        b.disabled = s.busy || b.dataset.off === "1";
    kind.ready?.(scr, s.busy);
}
// the mic's words land in whichever box the top screen asks of: a figure, or a
// code read aloud. A caption still growing is read as it grows, and the release
// text is the one that stands.
const sink = {
    hear(text, live) {
        const s = sheet.peek(), scr = top(s);
        if (!s || !scr)
            return;
        if (scr.kind === "count" && !scr.done) {
            const box = figureIn(), n = parseFigure(text);
            if (!box)
                return;
            if (n !== null) {
                box.value = String(n);
                say(live ? "listening…" : "");
            }
            else if (!live && text)
                say(`heard “${text}” and found no figure in it`);
        }
        else if (scr.kind === "look" && scr.phase === "rows") {
            // the figure of the row last touched, spoken
            const n = parseFigure(text), box = focusedQty();
            if (box && n !== null) {
                box.value = String(n);
                say(live ? "listening…" : "");
            }
            else if (!live && text)
                say(`heard “${text}”: touch the quantity of a row first`);
        }
        else if (aiming(scr)) {
            const box = q(".cap-code"), code = codeIn(text);
            if (code) {
                if (box) {
                    box.value = spoken(code);
                    setTyped(box.value);
                }
                if (!live)
                    find(code);
            }
            else if (!live && text)
                say(`heard “${text}” and found no code in it`);
        }
    },
    type() {
        const box = figureIn() ?? q(".cap-code");
        if (box) {
            box.focus();
            return;
        }
        const scr = lookTop();
        if (aiming(scr)) {
            replaceTop({ ...scr, typing: true });
            queueMicrotask(() => q(".cap-code")?.focus());
        }
    },
};
function ensure() {
    if (node)
        return node;
    node = document.createElement("div");
    node.id = "capture";
    node.hidden = true;
    host.el = node;
    // a tap on the ground around the card closes the sheet
    node.addEventListener("click", e => { if (e.target === node)
        close(); });
    document.addEventListener("keydown", e => { if (e.key === "Escape" && sheet.peek())
        close(); });
    document.body.append(node);
    effect(draw);
    on("inventory", restock);
    return node;
}
function open(screen) {
    ensure();
    releaseCamera();
    resetTyped();
    releaseVoice ??= claimVoice(sink);
    sheet.set({ stack: [screen], says: "", busy: false });
}
/** Open the sheet on a stock, at the figure. A sheet already open moves to the new stock. */
export function openCapture(target) {
    open({ kind: "count", target, done: false });
}
/** Open the sheet on the counts of a stock, where a count a member doubts is contested. */
export function openCaptureContests(stock) {
    open({ kind: "contest", stock, loaded: false, counts: [], open: [], asking: "", picture: null });
    void loadContests();
}
/**
 * Open the sheet on a stock the face holds: a container on its lines, each
 * countable, anything else at its figure. False when the stock holds no such
 * thing, so the caller can say so.
 */
export function openCaptureStock(rid) {
    const found = fromStock(rid);
    if (!found)
        return false;
    open(screenOf(found, "stated"));
    return true;
}
/** Open the sheet on a photograph of one stock and what is in it. False when the stock is not held. */
export function openCapturePhotoOf(rid) {
    const found = fromStock(rid);
    if (!found)
        return false;
    open(lookScreen(sceneOf(found.bin, found.contents)));
    wantReads();
    return true;
}
/** Open the sheet on a photograph of whatever is in front of the person. */
export function openCaptureLook() {
    open(lookScreen(sceneOf()));
    wantReads();
}
/** Open the sheet on the photographs waiting to be read. */
export function openCaptureQueue() {
    const screen = queueScreen();
    if (sheet.peek())
        push(screen);
    else
        open(screen);
    void loadQueue();
}
/**
 * The camera button inside the Express pill, beside the microphone: one tap to
 * a photograph of whatever is in front of the person. Mounted once, where the
 * pill exists.
 */
export function initCapture() {
    if (document.getElementById("capbtn"))
        return;
    // pictures kept past their days go with the boot, but those waiting to be read; a scene whose pictures are gone leaves the queue
    void sweepEvidence(Date.now(), EVIDENCE_DAYS, queuedHashes()).then(() => pruneQueued(async (h) => !!(await readEvidence(h))));
    const mic = document.getElementById("sbmic");
    if (!mic)
        return;
    const btn = document.createElement("button");
    btn.id = "capbtn";
    btn.type = "button";
    btn.textContent = "📷";
    btn.title = "take a photograph: a model proposes what it shows, you confirm each row";
    btn.setAttribute("aria-label", "take a photograph");
    btn.addEventListener("click", openCaptureLook);
    mic.after(btn); // inside the Express pill, beside the microphone
}
/** Open the camera on a label: it reads the symbol in view, or the code is typed. */
export function openCaptureLabel() {
    open(lookScreen(sceneOf()));
    wantReads();
}
/**
 * Open the sheet on a count the plan asked for: the target out of the stock
 * the face holds, with the commitment the count fulfils. A target holding
 * things opens on its lines; one holding nothing opens at its figure. False
 * when the stock holds no such thing, so the caller can say so.
 */
export function openCapturePlanned(target, fulfills, blind) {
    const found = fromStock(target);
    if (!found)
        return false;
    open(screenOf(found, "stated", { fulfills, blind }));
    return true;
}
/** Open the sheet on the thing a code names; the label screen says so when it names none. */
export function openCaptureCode(code) {
    open({ ...lookScreen(sceneOf()), typing: true });
    const c = codeIn(code);
    setTyped(c ? spoken(c) : code);
    queueMicrotask(() => find(c));
}
/** Whether the sheet is open, for a face that draws differently beside it. */
export const captureOpen = () => sheet() !== null;
