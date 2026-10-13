// app/scan.ts — symbols read off what the camera sees.
//
// The camera (camera.ts) shows what is in front of the person; this reads the
// symbols in it: a label's QR, a product's barcode, any other code the browser's
// Barcode Detection API knows. The reading is the browser's own; where a
// browser carries none, a QR reader of our own (the vendored jsQR, loaded the
// first time it is needed) reads the QR codes — people's and labels' — and the
// sheet offers the typed code beside the shutter for the rest. No frame leaves
// the device: the decoding runs on it, and what reaches the sheet is the
// symbol's format and text (symbols.ts says what it means).
import { canStream } from "./camera.js";
import { READ_FORMATS } from "./symbols.js";
/** Whether this browser can read a symbol from its camera: the native reader where there is one, jsQR everywhere else. */
export const canScan = () => canStream();
/** The widest a frame is decoded at, in pixels: wide enough for a QR held at arm's length, small enough to read in a few milliseconds. */
const FRAME_WIDTH = 640;
let fallback = null;
/** Load the vendored QR reader once; false when it cannot be had (offline before first load). */
function loadFallback() {
    if (typeof jsQR === "function")
        return Promise.resolve(true);
    fallback ??= new Promise(done => {
        const tag = document.createElement("script");
        tag.src = "vendor/jsQR.js";
        tag.onload = () => done(typeof jsQR === "function");
        tag.onerror = () => { fallback = null; done(false); };
        document.head.append(tag);
    });
    return fallback;
}
/** The QR codes in a picture, by jsQR: at most one (the reader finds the strongest). */
function readQR(source, w, h) {
    if (!w || !h)
        return [];
    const scale = Math.min(1, FRAME_WIDTH / w);
    const cw = Math.max(1, Math.round(w * scale)), ch = Math.max(1, Math.round(h * scale));
    const canvas = document.createElement("canvas");
    canvas.width = cw;
    canvas.height = ch;
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    if (!ctx)
        return [];
    ctx.drawImage(source, 0, 0, cw, ch);
    const px = ctx.getImageData(0, 0, cw, ch);
    const found = jsQR(px.data, cw, ch, { inversionAttempts: "attemptBoth" });
    return found && found.data ? [{ format: "qr_code", value: found.data }] : [];
}
/** A reader for this browser: the native detector, else jsQR; null where neither can be had. */
async function reader() {
    if (typeof BarcodeDetector !== "undefined") {
        const detector = new BarcodeDetector({ formats: await readable() });
        return async (src) => (await detector.detect(src)).map(f => ({ format: f.format, value: f.rawValue }));
    }
    if (!(await loadFallback()))
        return null;
    return async (src, w, h) => readQR(src, w, h);
}
/** How often the detector looks, in milliseconds: often enough to feel live, seldom enough to stay cool. */
const LOOK_EVERY = 250;
/** How long a symbol just read is not reported again, in milliseconds: a held label is one reading. */
const QUIET = 2000;
/** The formats this browser reads, of those playnet asks for. */
async function readable() {
    try {
        const have = await BarcodeDetector.getSupportedFormats();
        const asked = READ_FORMATS.filter(f => have.includes(f));
        return asked.length ? asked : ["qr_code"];
    }
    catch {
        return ["qr_code"];
    }
}
/**
 * Look for symbols in VIDEO, which a camera is showing, and call ONSEEN with each
 * one read. The same symbol held in view is reported once per QUIET.
 */
export async function watchSymbols(video, onSeen) {
    let timer = null;
    const stop = () => {
        if (timer !== null)
            clearInterval(timer);
        timer = null;
    };
    if (!canScan())
        return { stop };
    const read = await reader();
    if (!read)
        return { stop };
    const lastAt = new Map();
    let looking = false;
    timer = setInterval(() => {
        if (looking || video.readyState < 2)
            return;
        looking = true;
        read(video, video.videoWidth, video.videoHeight)
            .then(found => {
            const now = Date.now();
            for (const f of found) {
                const key = `${f.format}:${f.value}`;
                if (timer === null || now - (lastAt.get(key) ?? 0) < QUIET)
                    continue;
                lastAt.set(key, now);
                onSeen(f);
            }
        })
            .catch(() => { })
            .finally(() => { looking = false; });
    }, LOOK_EVERY);
    return { stop };
}
/** The symbols in one picture (a photograph taken or picked): what a held label or a person's code would have said live. */
export async function readStill(picture) {
    try {
        const read = await reader();
        if (!read)
            return [];
        const bitmap = await createImageBitmap(picture);
        try {
            return await read(bitmap, bitmap.width, bitmap.height);
        }
        finally {
            bitmap.close();
        }
    }
    catch {
        return [];
    }
}
