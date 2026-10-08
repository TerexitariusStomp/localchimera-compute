// tests/browser/caption-window-test.mjs — the live-caption commit ratchet
// (browser/app/voice/caption-window.js, from ui/app/voice/caption-window.ts)
//
// What this holds: the window fed to whisper stays the UNCONFIRMED block
// (never the whole growing clip once a commit has happened), the shown
// caption is always confirmed+block so nothing said is ever dropped from
// view, a commit is a one-way ratchet, and silence never commits early.
//
// Run: node tests/browser/caption-window-test.mjs

const { blankCaptionState, windowFor, applyTranscript } =
  await import("../../browser/app/voice/caption-window.js");

import { harness } from './assert.mjs';
const { check, done } = harness();

const RATE = 16000;
const BLOCK = 8 * RATE;   // 8s, the same size audio.ts wires in

console.log("\n── before any commit: the whole growing clip is one block ──");
{
  let st = blankCaptionState();
  check("windowFor starts at sample 0", windowFor(st, 20000).join(",") === "0,20000");
  const r1 = applyTranscript(st, "need three loaves of", 20000, BLOCK);
  check("short block: caption is just the block's own text", r1.caption === "need three loaves of");
  check("…and it does not commit (well under BLOCK samples)", r1.state.blockStart === 0);
  st = r1.state;
  const [from, to] = windowFor(st, 40000);
  check("next tick's window still starts at 0 — nothing confirmed yet", from === 0 && to === 40000);
}

console.log("\n── a block that reaches BLOCK_SAMPLES commits ──");
{
  let st = blankCaptionState();
  const r = applyTranscript(st, "need three loaves of bread for the harvest supper", BLOCK, BLOCK);
  check("commits once the block reaches BLOCK_SAMPLES", r.state.blockStart === BLOCK, String(r.state.blockStart));
  check("the confirmed text is exactly this tick's caption", r.state.confirmed === r.caption);
  st = r.state;
  const [from, to] = windowFor(st, BLOCK + 5000);
  check("the NEXT window starts at the commit point, not 0 — this is the whole fix",
        from === BLOCK && to === BLOCK + 5000, `${from},${to}`);
}

console.log("\n── the per-tick window stays bounded across many commits (the actual fix) ──");
{
  let st = blankCaptionState();
  let total = 0;
  const windows = [];
  // simulate a very long hold: ten blocks' worth of speech, each committing in turn
  for (let i = 0; i < 10; i++) {
    total += BLOCK;
    const [from, to] = windowFor(st, total);
    windows.push(to - from);
    st = applyTranscript(st, `chunk ${i}`, to - from, BLOCK).state;
  }
  check("every tick's window is the SAME bounded size, never growing with total hold length",
        windows.every(w => w === BLOCK), windows.join(","));
  check("…even though the total clip decoded is 10x longer than any one window", total === 10 * BLOCK);
}

console.log("\n── the caption never drops earlier words ──");
{
  let st = blankCaptionState();
  const r1 = applyTranscript(st, "the first thing said", BLOCK, BLOCK);
  st = r1.state;
  const r2 = applyTranscript(st, "and the second thing", 3000, BLOCK);
  check("after a commit, the caption is confirmed + the new block, concatenated",
        r2.caption === "the first thing said and the second thing", r2.caption);
  check("…and the new block itself hasn't committed yet (well under BLOCK)", r2.state.blockStart === r1.state.blockStart);
}

console.log("\n── silence never commits early ──");
{
  const st = blankCaptionState();
  const r = applyTranscript(st, "", BLOCK, BLOCK);   // a block that reached full length but heard nothing
  check("an empty transcript never commits, however long the block has grown",
        r.state.blockStart === 0, String(r.state.blockStart));
  check("…and shows no caption", r.caption === "");
}

done();
