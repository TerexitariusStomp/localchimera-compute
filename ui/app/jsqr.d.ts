// app/jsqr.d.ts — the jsQR surface the scanner calls (app/scan.ts).
//
// jsQR is a classic script (browser/vendor/jsQR.js, Apache-2.0), loaded by
// scan.ts only where the browser has no BarcodeDetector, so it is a global
// rather than an import. Declared on first use: the one function the fallback
// calls, with the one option it passes.

interface JsQRCode {
  /** What the symbol carries, as text. */
  data: string;
}

declare function jsQR(
  data: Uint8ClampedArray, width: number, height: number,
  options?: { inversionAttempts?: "dontInvert" | "onlyInvert" | "attemptBoth" | "invertFirst" },
): JsQRCode | null;
