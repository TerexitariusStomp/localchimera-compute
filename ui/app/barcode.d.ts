// app/barcode.d.ts — the Barcode Detection API, as far as the label scanner
// calls it (app/scan.ts).
//
// A browser API lib.dom does not carry, since not every engine ships it:
// Chromium on Android and macOS does, and a browser without it reads a label
// from the code typed beneath the symbol. Declared on first use, member by
// member, the policy d3.d.ts and webbluetooth.d.ts follow.

interface DetectedBarcode {
  /** What the symbol carries, as text. */
  rawValue: string;
  format: string;
}

interface BarcodeDetectorOptions {
  formats?: string[];
}

declare class BarcodeDetector {
  constructor(options?: BarcodeDetectorOptions);
  detect(image: HTMLVideoElement | ImageBitmap | HTMLCanvasElement | Blob): Promise<DetectedBarcode[]>;
  static getSupportedFormats(): Promise<string[]>;
}
