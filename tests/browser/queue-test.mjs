// tests/browser/queue-test.mjs — photographs waiting to be read, and the sheet of several
// (browser/app/queue.js, browser/app/photo.js; from ui/app/queue.ts, photo.ts).
//
// What is pinned: a scene put in the queue is listed with its shots, the place,
// the container, the plan and the instant it was taken; the oldest give way past
// the cap; a scene leaves when asked; the sweep is told which shots to spare; a
// scene whose pictures are gone leaves and one that lost some keeps the rest;
// a scene reads in a line; the contact sheet lays one shot whole, two side by
// side and three or four in a grid; the sweep spares what is waiting.
//
// Run: node tests/browser/queue-test.mjs

const store = new Map();
globalThis.localStorage = { getItem: k => store.get(k) ?? null, setItem: (k, v) => { store.set(k, String(v)); }, removeItem: k => { store.delete(k); } };

const Q = await import("../../browser/app/queue.js");
const P = await import("../../browser/app/photo.js");

import { harness } from './assert.mjs';
const { check, done } = harness();

const scene = (n, extra = {}) => ({ at: `2026-10-01T09:${String(n).padStart(2, "0")}:00Z`, shots: [`sha256:${String(n).repeat(64)}`], place: "place:pantry", container: "", label: `shelf ${n}`, ...extra });

console.log("\n── the queue ──");
check("an empty queue lists nothing", Q.listQueued().length === 0);
const a = Q.enqueue(scene(1, { container: "demo:shelf", plan: { fulfills: "cmt-1", blind: true } }), 1000);
const b = Q.enqueue(scene(2), 2000);
check("a scene is listed, oldest first", Q.listQueued().map(e => e.label).join() === "shelf 1,shelf 2");
check("…with what it knew: place, container, plan, instant",
      JSON.stringify([Q.listQueued()[0].place, Q.listQueued()[0].container, Q.listQueued()[0].plan, Q.listQueued()[0].at]) === JSON.stringify(["place:pantry", "demo:shelf", { fulfills: "cmt-1", blind: true }, "2026-10-01T09:01:00Z"]));
check("each has its own id", a.id !== b.id && a.id.startsWith("q-"));
check("the shots waiting are named for the sweep to spare", Q.queuedHashes().size === 2 && Q.queuedHashes().has(a.shots[0]));
Q.dequeue(a.id);
check("a scene leaves when asked", Q.listQueued().map(e => e.label).join() === "shelf 2");
for (let i = 3; i < 3 + Q.QUEUE_MAX + 4; i++) Q.enqueue(scene(i % 60), 5000 + i);
check("past the cap the oldest give way", Q.listQueued().length === Q.QUEUE_MAX && !Q.listQueued().some(e => e.id === b.id));

console.log("\n── pruning ──");
store.clear();
const keepBoth = Q.enqueue({ ...scene(1), shots: ["h-a", "h-b"] }, 1);
const lostOne = Q.enqueue({ ...scene(2), shots: ["h-c", "h-gone"] }, 2);
const lostAll = Q.enqueue({ ...scene(3), shots: ["h-gone"] }, 3);
const gone = await Q.pruneQueued(async h => h !== "h-gone");
const left = Q.listQueued();
check("a scene whose pictures are all gone leaves", gone === 1 && !left.some(e => e.id === lostAll.id));
check("a scene that lost some keeps the rest", left.find(e => e.id === lostOne.id)?.shots.join() === "h-c");
check("a scene that lost none is as it was", left.find(e => e.id === keepBoth.id)?.shots.join() === "h-a,h-b");

console.log("\n── a line ──");
check("a scene reads as what, how many, when", /^shelf 1 · 2 photos · \d\d:\d\d$/.test(Q.queuedLine({ ...scene(1), shots: ["a", "b"], id: "x" })), Q.queuedLine({ ...scene(1), shots: ["a", "b"], id: "x" }));
check("one photograph is singular", /1 photo ·/.test(Q.queuedLine({ ...scene(1), id: "x" })));
check("a scene with no label is a scene", /^a scene ·/.test(Q.queuedLine({ ...scene(1), label: "", id: "x" })));
check("an unreadable instant leaves the time off", Q.queuedLine({ ...scene(1), at: "soon", id: "x" }) === "shelf 1 · 1 photo");

console.log("\n── the contact sheet ──");
const lay = n => P.sheetLayout(n);
check("one shot is one cell", lay(1).width === P.CELL.width && lay(1).height === P.CELL.height && lay(1).cells.length === 1);
check("two sit side by side", lay(2).width === 2 * P.CELL.width && lay(2).height === P.CELL.height);
check("three and four make a grid", lay(3).height === 2 * P.CELL.height && lay(4).cells[3].x === P.CELL.width && lay(4).cells[3].y === P.CELL.height);
check("no cells overlap", [1, 2, 3, 4].every(n => new Set(lay(n).cells.map(c => `${c.x},${c.y}`)).size === n));
check("four shots fit one upload: their base64 stays within the gateway's bound", Math.ceil(P.SHOTS_PER_READ * P.PHOTO_BYTES * 4 / 3) <= 1200 * 1024);
check("the sheet fits the evidence bound", Math.ceil(P.EVIDENCE_BYTES * 4 / 3) <= 400 * 1024);

console.log("\n── the sweep spares what waits ──");
P.useMemoryStore();
const day = 86_400_000, now = Date.now();
const old = await P.keepEvidence(new Blob([new Uint8Array([1])]), now - 100 * day);
const oldQueued = await P.keepEvidence(new Blob([new Uint8Array([2])]), now - 100 * day);
const went = await P.sweepEvidence(now, 90, new Set([oldQueued]));
check("a picture past its days goes, one waiting to be read stays", went === 1 && (await P.readEvidence(old)) === null && (await P.readEvidence(oldQueued)) !== null);

done();
