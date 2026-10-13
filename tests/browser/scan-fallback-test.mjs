// tests/browser/scan-fallback-test.mjs — a person's code, read where the browser has no reader
// (browser/app/scan.js with the vendored browser/vendor/jsQR.js).
//
// A browser without the Barcode Detection API reads a QR with jsQR. What is pinned:
//
//   • a code our own encoder (app/qr.js) draws is read back by jsQR, text for text, at
//     the sizes a phone camera hands over and with the picture inverted (a code on a
//     dark screen);
//   • what is read is classified as a person, with the identifier the link names, and a
//     label's QR still classifies as a label;
//   • a picture with no code in it reads as nothing.
//
// Run: node tests/browser/scan-fallback-test.mjs

import { createRequire } from "node:module";
import { harness } from "./assert.mjs";

const jsQR = createRequire(import.meta.url)("../../browser/vendor/jsQR.js");
const { encode } = await import("../../browser/app/qr.js");
const { connectLink } = await import("../../browser/app/connect-link.js");
const { classify } = await import("../../browser/app/symbols.js");
const { labelText } = await import("../../browser/app/labels.js");
const { LABEL_LENGTH, LABEL_ALPHABET } = await import("../../browser/app/count-catalogue.js");

const { check, section, done } = harness();

// a symbol as the pixels a camera would hand over: PX a module, a quiet zone of four, dark on light
function pixels(sym, px, invert = false) {
  const span = sym.size + 8, side = span * px;
  const data = new Uint8ClampedArray(side * side * 4);
  for (let y = 0; y < side; y++) for (let x = 0; x < side; x++) {
    const mx = Math.floor(x / px) - 4, my = Math.floor(y / px) - 4;
    const dark = mx >= 0 && my >= 0 && mx < sym.size && my < sym.size && sym.dark[my][mx];
    const v = dark !== invert ? 0 : 255, i = (y * side + x) * 4;
    data[i] = data[i + 1] = data[i + 2] = v; data[i + 3] = 255;
  }
  return { data, side };
}
const read = (sym, px, invert) => {
  const { data, side } = pixels(sym, px, invert);
  return jsQR(data, side, side, { inversionAttempts: "attemptBoth" });
};

const AID = "E" + "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-aBcDe".slice(0, 43);

section("a person's link");
const link = connectLink("https://playnet.example/app.html", AID, "Ana Ünal");
const sym = encode(link);
check("the link fits a symbol", !!sym, sym ? `version ${sym.version}` : "no symbol");
for (const px of [3, 4, 6]) {
  const got = read(sym, px, false);
  check(`read back at ${px} px a module`, got?.data === link, got?.data ?? "nothing");
}
const inv = read(sym, 4, true);
check("read back inverted (a code shown on a dark screen)", inv?.data === link, inv?.data ?? "nothing");

section("what is read means");
const seen = { format: "qr_code", value: read(sym, 4, false).data };
const r = classify(seen);
check("a person's code classifies as a person", r.kind === "person", r.kind);
check("…naming the identifier in the link", r.link?.aid === AID, r.link?.aid);
check("…and the name they go by", r.link?.name === "Ana Ünal", r.link?.name);
const code = [...LABEL_ALPHABET].slice(0, LABEL_LENGTH).join("");
const lab = encode(labelText(code));
const l = lab ? classify({ format: "qr_code", value: read(lab, 4, false)?.data ?? "" }) : null;
check("a label's code still classifies as a label", l?.kind === "label", l?.kind);

section("no code");
const blank = new Uint8ClampedArray(200 * 200 * 4).fill(255);
check("a plain picture reads as nothing", jsQR(blank, 200, 200) === null);

done();
