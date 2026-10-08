// app/barcodes.ts — which stock a product's barcode is.
//
// A product code names a kind of thing, and the books know things by their own
// ids; the two meet once, when a person scanning a barcode says which stock it
// is. The device keeps that pairing (store.ts, the one localStorage door), so
// the next scan of the same code opens the stock's count. The pairing is the
// person's own and travels with this device alone.
import { readJSON, writeJSON } from "./store.js";
import { K } from "./keys.js";
const KEY = K.barcodes;
const all = () => readJSON(KEY, {});
/** The id of the stock this barcode was paired with, or empty. */
export const boundTo = (value) => all()[value] ?? "";
/** Pair the barcode with the stock. */
export function bind(value, resource) {
    writeJSON(KEY, { ...all(), [value]: resource });
}
/** Let the pairing go. */
export function unbind(value) {
    const { [value]: _gone, ...rest } = all();
    writeJSON(KEY, rest);
}
