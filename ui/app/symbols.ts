// app/symbols.ts — what a camera read off a symbol means in playnet.
//
// The camera reads whatever symbol is in view (scan.ts): a playnet label's QR,
// a product's barcode, a code printed on a crate. This module says which it is,
// purely, so the capture sheet and a unit test read a symbol the same way. A
// label names a container of the scope's; a product code names a kind of thing
// the device learns once, by being told which stock it is (barcodes.ts); any
// other symbol is text the sheet reports and leaves alone.

import { codeIn } from "./labels.js";
import { connectIn, type ConnectLink } from "./connect-link.js";

/** One symbol the detector read: its format as the Barcode Detection API names it, and what it carries. */
export interface Seen {
  format: string;
  value: string;
}

/** What a symbol is to playnet. */
export type Reading =
  | { kind: "label"; code: string }
  | { kind: "person"; link: ConnectLink }
  | { kind: "product"; format: string; value: string }
  | { kind: "text"; format: string; value: string };

/** The formats of a product: the linear codes on packaging and shelves, and the data matrix on trade goods. */
export const PRODUCT_FORMATS: readonly string[] =
  ["ean_13", "ean_8", "upc_a", "upc_e", "code_128", "code_39", "code_93", "codabar", "itf", "data_matrix"];

/** Every format the camera is asked to read, a label's QR first. */
export const READ_FORMATS: readonly string[] = ["qr_code", ...PRODUCT_FORMATS, "aztec", "pdf417"];

/** The symbol, classified: a label's QR names a container; a person's QR names them; a product format a product; the rest is text. */
export function classify(s: Seen): Reading {
  const value = String(s.value ?? "").trim();
  if (s.format === "qr_code") {
    const code = codeIn(value);
    if (code) return { kind: "label", code };
    const link = connectIn(value);
    if (link) return { kind: "person", link };
  }
  if (PRODUCT_FORMATS.includes(s.format) && value) return { kind: "product", format: s.format, value };
  return { kind: "text", format: s.format, value };
}

const NAMES: Record<string, string> = {
  ean_13: "EAN-13", ean_8: "EAN-8", upc_a: "UPC-A", upc_e: "UPC-E", code_128: "Code 128", code_39: "Code 39",
  code_93: "Code 93", codabar: "Codabar", itf: "ITF", data_matrix: "Data Matrix", qr_code: "QR", aztec: "Aztec", pdf417: "PDF417",
};

/** A format as it is printed in the standards: "ean_13" → "EAN-13". */
export const formatName = (format: string): string => NAMES[format] ?? format;
