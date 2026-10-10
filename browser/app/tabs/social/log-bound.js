// app/tabs/social/log-bound.ts — how much of the captain's log is kept where.
//
// Two stores hold the log and each has a size it refuses past. The gateway's
// per-person backup takes at most SYNC_MAX_BYTES (vf/facts/limits.scm
// %max-user-data-bytes) and rejects a larger document whole. The device's
// localStorage holds about 5 MB for the entire origin, and a log that fills
// it takes every other write down with it. So each store is handed the
// newest entries that fit its budget: the log is newest-first, and the tail
// that does not fit is the oldest.
//
// Pure, so the arithmetic is tested by itself (tests/browser/log-bound-test.mjs).
import { USER_DATA_MAX_BYTES } from "../../limits-catalogue.js";
/** The backup's row count. */
export const SYNC_MAX_ENTRIES = 400;
/** The gateway's cap on one person's synced document (generated from vf/facts/limits.scm). */
export const SYNC_MAX_BYTES = USER_DATA_MAX_BYTES;
/** The device's budget for the log: well inside localStorage's ~5 MB for the origin. */
export const LOCAL_MAX_BYTES = 2 * 1024 * 1024;
const utf8 = new TextEncoder();
/**
 * The size the gateway measures a document at. It measures the Scheme-written
 * string: the UTF-8 bytes, a backslash before every `"` and `\`, and the two
 * quotes around it.
 */
export function wireBytes(doc) {
    let escapes = 0;
    for (let i = 0; i < doc.length; i++) {
        const c = doc.charCodeAt(i);
        if (c === 34 || c === 92)
            escapes++;
    }
    return utf8.encode(doc).length + escapes + 2;
}
/**
 * The longest newest-first prefix of ENTRIES that is at most MAX_ENTRIES long
 * and whose JSON array measures at most MAX_BYTES by SIZE.
 */
export function fitNewest(entries, maxEntries, maxBytes, size = wireBytes) {
    const out = [];
    let doc = "[]";
    for (const e of entries) {
        if (out.length >= maxEntries)
            break;
        const next = out.length ? doc.slice(0, -1) + "," + JSON.stringify(e) + "]" : "[" + JSON.stringify(e) + "]";
        if (size(next) > maxBytes)
            break;
        out.push(e);
        doc = next;
    }
    return out;
}
