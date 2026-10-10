// app/photo.ts — a photograph taken on the device, and kept there.
//
// The photo read is the third technique a person carries (docs/observation/
// capture.md §2, §9): the camera takes the picture, the picture is reduced to
// what a model needs and the gateway will carry, and its hash goes on the
// reading as the evidence that a picture was looked at. The picture itself
// stays on the device, in an evidence store keyed by that hash, and leaves it
// only when its owner attaches it to a contest of the count (§8).
//
import { EVIDENCE_DIGITS, EVIDENCE_PREFIX } from "./count-catalogue.js";
import { table } from "./idb.js";
import { toBase64 as bytesToBase64, toHex } from "./bytes.js";
import { fault } from "./store.js";
import { ensurePersistent } from "./storage-health.js";
// The pure parts (the size a picture is fitted to, the base64 text it crosses
// in, the hash it is known by, the store's sweep) are unit tested; the camera
// and the canvas are the browser's.
/** The longest edge a picture is first reduced to. */
export const PHOTO_EDGE = 1280;
/** The bytes one picture of a read may take: four of them, as base64, fit PICTURE_MAX_CHARS (limits-catalogue.ts; held by photo-test). */
export const PHOTO_BYTES = 200_000;
/**
 * The shots of one scene a read takes: doors/lobby.scm `see-part` accepts pictures 0 to
 * 3, and four of PHOTO_BYTES (as base64, a third larger) stay within its
 * %picture-max-chars of 1200 KiB.
 */
export const SHOTS_PER_READ = 4;
/** The bytes the picture a count names may take: as base64 it fits EVIDENCE_MAX_CHARS (limits-catalogue.ts; held by photo-test). */
export const EVIDENCE_BYTES = 300_000;
/** The edge below which a picture is no longer worth reading. */
export const MIN_EDGE = 480;
/** The JPEG qualities tried at each edge, best first. */
export const QUALITIES = [0.7, 0.55, 0.4, 0.25];
/** Days an evidence picture is kept when nothing has asked for it. */
export const EVIDENCE_DAYS = 90;
/** The size a WxH picture is fitted to: its longest edge at most EDGE, never enlarged. */
export function fitSize(w, h, edge) {
    const scale = Math.min(1, edge / Math.max(w, h, 1));
    return { width: Math.max(1, Math.round(w * scale)), height: Math.max(1, Math.round(h * scale)) };
}
/**
 * The edges a picture is tried at: EDGE, then three quarters of each, down to
 * MIN_EDGE. A budget a picture misses at one edge is tried at the next.
 */
export function edges(edge) {
    const out = [];
    for (let e = edge; e >= MIN_EDGE; e = Math.floor(e * 0.75))
        out.push(e);
    return out.length ? out : [Math.max(edge, 1)];
}
/** A blob as base64 text, the form a picture crosses the seam in. */
export async function toBase64(blob) {
    return bytesToBase64(new Uint8Array(await blob.arrayBuffer()));
}
/** A blob's content hash, as it is written on a reading: `sha256:` and sixty-four hex digits. */
export async function sha256Hex(blob) {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", await blob.arrayBuffer()));
    return EVIDENCE_PREFIX + toHex(digest);
}
/** Whether TEXT is an evidence hash. */
export const isEvidenceHash = (text) => typeof text === "string" && text.startsWith(EVIDENCE_PREFIX) &&
    new RegExp(`^[0-9a-f]{${EVIDENCE_DIGITS}}$`).test(text.slice(EVIDENCE_PREFIX.length));
/**
 * BLOB as a JPEG that fits BUDGET bytes, its longest edge at most EDGE: the
 * picture is re-encoded on a canvas, which drops the camera's metadata (where
 * it was taken, what took it) and applies its orientation. "unreadable" when
 * the file is no image, "too-large" when no edge and quality fits the budget.
 */
export async function downscale(blob, edge, budget) {
    let bmp;
    try {
        bmp = await createImageBitmap(blob, { imageOrientation: "from-image" });
    }
    catch {
        return "unreadable";
    }
    try {
        for (const e of edges(edge)) {
            const { width, height } = fitSize(bmp.width, bmp.height, e);
            const canvas = document.createElement("canvas");
            canvas.width = width;
            canvas.height = height;
            const ctx = canvas.getContext("2d");
            if (!ctx)
                return "unreadable";
            ctx.drawImage(bmp, 0, 0, width, height);
            for (const q of QUALITIES) {
                const out = await new Promise(done => canvas.toBlob(done, "image/jpeg", q));
                if (out && out.size <= budget)
                    return out;
            }
        }
        return "too-large";
    }
    finally {
        bmp.close();
    }
}
/**
 * Pictures from the device's own file chooser: none when the person leaves
 * without choosing. FROMCAMERA asks a phone to open its camera app (the
 * `capture` hint); without it the chooser offers the camera roll. MULTIPLE
 * lets several be chosen at once.
 */
export function pickPhotos(fromCamera, multiple) {
    return new Promise(resolve => {
        const input = document.createElement("input");
        input.type = "file";
        input.accept = "image/*";
        input.multiple = multiple;
        if (fromCamera)
            input.setAttribute("capture", "environment");
        input.addEventListener("change", () => resolve([...(input.files ?? [])]));
        input.addEventListener("cancel", () => resolve([]));
        input.click();
    });
}
/** One picture from the chooser, or null when the person leaves without choosing. */
export const pickPhoto = async (fromCamera) => (await pickPhotos(fromCamera, false))[0] ?? null;
// ── several shots of one scene ─────────────────────────────────────────────
/** The width and height of one shot's cell on a contact sheet. */
export const CELL = { width: 640, height: 480 };
/**
 * Where N shots sit on a contact sheet: one column up to one shot, two columns
 * after, in rows; every cell CELL-sized. The sheet's own size follows.
 */
export function sheetLayout(n) {
    const count = Math.max(1, n);
    const cols = count === 1 ? 1 : 2, rows = Math.ceil(count / cols);
    return {
        width: cols * CELL.width, height: rows * CELL.height,
        cells: Array.from({ length: count }, (_, i) => ({ x: (i % cols) * CELL.width, y: Math.floor(i / cols) * CELL.height })),
    };
}
/**
 * The shots as one picture, a contact sheet, so a count that rests on several
 * names one hash and a reviewer sees them all. Each shot is shown whole in its
 * cell. "unreadable" when a shot is no image, "too-large" when no quality fits
 * EVIDENCE_BYTES.
 */
export async function contactSheet(shots) {
    const lay = sheetLayout(shots.length);
    const canvas = document.createElement("canvas");
    canvas.width = lay.width;
    canvas.height = lay.height;
    const ctx = canvas.getContext("2d");
    if (!ctx)
        return "unreadable";
    ctx.fillStyle = "#333";
    ctx.fillRect(0, 0, lay.width, lay.height);
    for (let i = 0; i < shots.length; i++) {
        let bmp;
        try {
            bmp = await createImageBitmap(shots[i], { imageOrientation: "from-image" });
        }
        catch {
            return "unreadable";
        }
        const scale = Math.min(CELL.width / bmp.width, CELL.height / bmp.height);
        const w = Math.round(bmp.width * scale), h = Math.round(bmp.height * scale);
        ctx.drawImage(bmp, lay.cells[i].x + (CELL.width - w) / 2, lay.cells[i].y + (CELL.height - h) / 2, w, h);
        bmp.close();
    }
    for (const q of QUALITIES) {
        const out = await new Promise(done => canvas.toBlob(done, "image/jpeg", q));
        if (out && out.size <= EVIDENCE_BYTES)
            return out;
    }
    return "too-large";
}
const isoSeconds = (ms) => new Date(ms).toISOString().slice(0, 19) + "Z";
/** The instant the first of the shots was taken; empty when there are none. */
export const firstTaken = (shots) => shots.map(x => x.at).sort()[0] ?? "";
/** A small picture of BLOB as a data URL, a card can show without an object URL to let go. EDGE 480 fills a card; 160 is a thumbnail. */
export async function previewOf(blob, edge = 480) {
    const small = await downscale(blob, edge, 60_000);
    return "data:image/jpeg;base64," + await toBase64(typeof small === "string" ? blob : small);
}
/** A shot of a picture already kept under HASH. */
export async function shotOf(hash, blob, at) {
    return { hash, blob, preview: await previewOf(blob), at };
}
/**
 * SOURCE as a shot: fitted to what a read carries, kept under its hash, and shown
 * small. A file the person chose carries its own instant (never one from the
 * future); a frame from the camera is taken now. The words say why a picture is
 * refused.
 */
export async function keepShot(source, now = Date.now()) {
    const out = await downscale(source, PHOTO_EDGE, PHOTO_BYTES);
    if (typeof out === "string")
        return out === "unreadable" ? "that does not read as a picture" : "that picture is too large to send, even reduced";
    const when = source instanceof File && source.lastModified > 0 ? Math.min(source.lastModified, now) : now;
    return shotOf(await keepEvidence(out), out, isoSeconds(when));
}
/**
 * The picture a reading of SHOTS names, and the pictures to send: the shot's own
 * hash when there is one, else the contact sheet of them, kept under its own, so
 * a count that rests on several still names one picture.
 */
export async function proofOf(shots) {
    const blobs = shots.map(x => x.blob);
    if (blobs.length === 1)
        return { hash: shots[0].hash, blobs };
    const sheet = await contactSheet(blobs);
    if (typeof sheet === "string")
        return sheet === "unreadable" ? "a shot does not read as a picture" : "those pictures are too large to keep as one, even reduced";
    return { hash: await keepEvidence(sheet), blobs };
}
const DB = "playnet-evidence", STORE = "pictures";
function memoryEngine() {
    const m = new Map();
    return {
        put: async (k) => { m.set(k.hash, k); },
        get: async (h) => m.get(h) ?? null,
        all: async () => [...m.values()],
        drop: async (h) => { m.delete(h); },
    };
}
// One store keyed by the picture's own hash. A later shape is a new branch in
// `upgrade` and a bumped version.
const SCHEMA = {
    name: DB,
    version: 1,
    upgrade(db, from) {
        if (from < 1)
            db.createObjectStore(STORE, { keyPath: "hash" });
    },
};
function idbEngine() {
    const t = table(SCHEMA, STORE);
    return {
        put: k => t.put(k),
        get: async (h) => (await t.get(h)) ?? null,
        all: () => t.all(),
        drop: h => t.del(h),
    };
}
let engine = null;
const store = () => engine ??= (typeof indexedDB === "undefined" ? memoryEngine() : idbEngine());
/** Use a fresh in-memory store, for a test. */
export function useMemoryStore() {
    engine = memoryEngine();
}
/**
 * Keep BLOB as evidence and return the hash it is known by. The browser is
 * asked to keep the store from eviction; a device that cannot keep the
 * picture still gets the hash, since the reading is made either way, and the
 * refusal is raised as a storage fault.
 */
export async function keepEvidence(blob, now = Date.now()) {
    const hash = await sha256Hex(blob);
    await ensurePersistent();
    try {
        await store().put({ hash, blob, at: now });
    }
    catch {
        fault("idb", DB); /* the reading stands without its picture */
    }
    return hash;
}
/** The picture kept under HASH, or null when this device holds none. */
export async function readEvidence(hash) {
    try {
        return (await store().get(hash))?.blob ?? null;
    }
    catch {
        return null;
    }
}
/** Drop the pictures kept longer than DAYS days, but those in KEEP (the shots waiting to be read). Returns how many went. */
export async function sweepEvidence(now = Date.now(), days = EVIDENCE_DAYS, keep = new Set()) {
    try {
        const cutoff = now - days * 86_400_000;
        const old = (await store().all()).filter(k => k.at < cutoff && !keep.has(k.hash));
        for (const k of old)
            await store().drop(k.hash);
        return old.length;
    }
    catch {
        return 0;
    }
}
