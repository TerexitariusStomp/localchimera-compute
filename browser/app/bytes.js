// app/bytes.ts — bytes as text and back: base64, base64url, hex.
//
// One spelling of each, for the pictures and audio that cross the seam as
// base64, the sealed values kept as base64url, and the keys and hashes written
// as hex. Imports nothing and touches no DOM, so the page, a worker and the
// hand-written scripts under browser/lib/ all load it.
/** Bytes as base64. Chunked, so a multi-megabyte picture stays within the engine's argument limit. */
export function toBase64(bytes) {
    let bin = "";
    for (let i = 0; i < bytes.length; i += 0x8000)
        bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(bin);
}
/** Base64 as bytes. */
export function fromBase64(text) {
    const bin = atob(text);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++)
        out[i] = bin.charCodeAt(i);
    return out;
}
/** Bytes as base64url: the URL alphabet, no padding. */
export const toBase64Url = (bytes) => toBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
/** Base64url as bytes. */
export const fromBase64Url = (text) => fromBase64(text.replace(/-/g, "+").replace(/_/g, "/"));
/** Bytes as lowercase hex. */
export const toHex = (bytes) => Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("");
/** Hex as bytes. An odd length or a non-hex digit is refused. */
export function fromHex(hex) {
    if (hex.length % 2 || /[^0-9a-fA-F]/.test(hex))
        throw new Error("not hex");
    const out = new Uint8Array(hex.length / 2);
    for (let i = 0; i < out.length; i++)
        out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    return out;
}
/** How many base64 characters N bytes take. */
export const base64Length = (n) => Math.ceil(n / 3) * 4;
