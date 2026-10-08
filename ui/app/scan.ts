// app/scan.ts — symbols read off what the camera sees.
//
// The camera (camera.ts) shows what is in front of the person; this reads the
// symbols in it: a label's QR, a product's barcode, any other code the browser's
// Barcode Detection API knows. The reading is the browser's own; where a
// browser carries none, `canScan` says so and the sheet offers the typed code
// beside the shutter. No frame leaves the device: the detector runs on it, and
// what reaches the sheet is the symbol's format and text (symbols.ts says what
// it means).

import { canStream } from "./camera.js";
import { READ_FORMATS, type Seen } from "./symbols.js";

/** Whether this browser can read a symbol from its camera. */
export const canScan = (): boolean => typeof BarcodeDetector !== "undefined" && canStream();

/** How often the detector looks, in milliseconds: often enough to feel live, seldom enough to stay cool. */
const LOOK_EVERY = 250;
/** How long a symbol just read is not reported again, in milliseconds: a held label is one reading. */
const QUIET = 2000;

/** A watch in progress. */
export interface Scan {
  /** Stop looking. Safe to call twice. */
  stop(): void;
}

/** The formats this browser reads, of those playnet asks for. */
async function readable(): Promise<string[]> {
  try {
    const have = await BarcodeDetector.getSupportedFormats();
    const asked = READ_FORMATS.filter(f => have.includes(f));
    return asked.length ? asked : ["qr_code"];
  } catch {
    return ["qr_code"];
  }
}

/**
 * Look for symbols in VIDEO, which a camera is showing, and call ONSEEN with each
 * one read. The same symbol held in view is reported once per QUIET.
 */
export async function watchSymbols(video: HTMLVideoElement, onSeen: (s: Seen) => void): Promise<Scan> {
  let timer: ReturnType<typeof setInterval> | null = null;
  const stop = (): void => {
    if (timer !== null) clearInterval(timer);
    timer = null;
  };
  if (!canScan()) return { stop };
  const detector = new BarcodeDetector({ formats: await readable() });
  const lastAt = new Map<string, number>();
  let looking = false;
  timer = setInterval(() => {
    if (looking || video.readyState < 2) return;
    looking = true;
    detector.detect(video)
      .then(found => {
        const now = Date.now();
        for (const f of found) {
          const key = `${f.format}:${f.rawValue}`;
          if (timer === null || now - (lastAt.get(key) ?? 0) < QUIET) continue;
          lastAt.set(key, now);
          onSeen({ format: f.format, value: f.rawValue });
        }
      })
      .catch(() => { /* a frame the detector could not read; the next one follows */ })
      .finally(() => { looking = false; });
  }, LOOK_EVERY);
  return { stop };
}
