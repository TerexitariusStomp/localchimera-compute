// tests/browser/photo-test.mjs — a photograph taken on the device and kept there
// (browser/app/photo.js, from ui/app/photo.ts).
//
// The camera and the canvas are the browser's; what is pinned here is the rest:
//
//   • a picture is fitted so its longest edge is at most the edge asked, never
//     enlarged, and the edges tried step down to a floor;
//   • a blob crosses the seam as base64, and is known by its sha256, written
//     the way a reading carries it;
//   • the evidence store keeps a picture under its hash, returns it, and sweeps
//     what has sat longer than its days.
//
// Run: node tests/browser/photo-test.mjs

const P = await import("../../browser/app/photo.js");

import { harness } from './assert.mjs';
const { check, done } = harness();

console.log("\n── fitting a picture ──");
{
  const big = P.fitSize(4000, 3000, 1280);
  check("the longest edge is the edge asked", big.width === 1280 && big.height === 960);
  const tall = P.fitSize(3000, 4000, 1280);
  check("…whichever edge is longer", tall.height === 1280 && tall.width === 960);
  const small = P.fitSize(640, 480, 1280);
  check("a small picture is never enlarged", small.width === 640 && small.height === 480);
  check("a degenerate picture keeps a pixel", P.fitSize(0, 0, 1280).width >= 1);
  const e = P.edges(1280);
  check("the edges step down from the first", e[0] === 1280 && e.every((x, i) => i === 0 || x < e[i - 1]));
  check("…and stop at the floor", e[e.length - 1] >= P.MIN_EDGE && Math.floor(e[e.length - 1] * 0.75) < P.MIN_EDGE);
  check("an edge under the floor is tried once", P.edges(300).length === 1);
  // the page's budgets against the gateway's own bounds (limits-catalogue.js is generated from them)
  const L = await import("../../browser/app/limits-catalogue.js");
  const { base64Length } = await import("../../browser/app/bytes.js");
  check("the shots of one read, as base64, fit the gateway's bound on a read's pictures",
        P.SHOTS_PER_READ * base64Length(P.PHOTO_BYTES) <= L.PICTURE_MAX_CHARS);
  check("the picture a count names, as base64, fits the gateway's bound on it",
        base64Length(P.EVIDENCE_BYTES) <= L.EVIDENCE_MAX_CHARS);
}

console.log("\n── base64 and the hash ──");
{
  const abc = new Blob([new TextEncoder().encode("abc")]);
  check("a blob crosses as base64", await P.toBase64(abc) === "YWJj");
  const big = new Blob([new Uint8Array(100_000).fill(7)]);
  check("a large blob crosses whole", atob(await P.toBase64(big)).length === 100_000);
  const h = await P.sha256Hex(abc);
  check("a picture is known by its sha256", h === "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", h);
  check("…written as a reading carries it", P.isEvidenceHash(h));
  check("text that is not a hash is not one",
        !P.isEvidenceHash("sha256:ABC") && !P.isEvidenceHash("md5:" + "0".repeat(32)) && !P.isEvidenceHash(null));
  check("the same bytes give the same hash", h === await P.sha256Hex(new Blob([new TextEncoder().encode("abc")])));
}

console.log("\n── the evidence store ──");
{
  P.useMemoryStore();
  const pic = new Blob([new TextEncoder().encode("a picture")]);
  const hash = await P.keepEvidence(pic, 1_000);
  check("a kept picture is known by its hash", hash === await P.sha256Hex(pic));
  const back = await P.readEvidence(hash);
  check("…and read back by it", back !== null && await P.toBase64(back) === await P.toBase64(pic));
  check("a hash that was never kept reads as none", await P.readEvidence("sha256:" + "0".repeat(64)) === null);
  const other = await P.keepEvidence(new Blob([new TextEncoder().encode("another")]), 1_000 + 80 * 86_400_000);
  const gone = await P.sweepEvidence(1_000 + 100 * 86_400_000, 90);
  check("the sweep drops what sat longer than its days", gone === 1);
  check("…the old one is gone", await P.readEvidence(hash) === null);
  check("…the newer one stays", await P.readEvidence(other) !== null);
  check("a second sweep finds nothing more", await P.sweepEvidence(1_000 + 100 * 86_400_000, 90) === 0);
}

done();
