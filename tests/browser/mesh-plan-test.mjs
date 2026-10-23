// SPDX-License-Identifier: AGPL-3.0-or-later
// tests/browser/mesh-plan-test.mjs — the mesh's video budget (app/voice/mesh-plan.ts).
// Plain node over the emitted module. What it pins is a property of the whole range
// of room sizes, not a table of numbers: the streams a person sends stay within the
// budget at every size a room can reach, and the ceiling is the one the budget gives.
//
// Run: make test-mesh-plan
import { VIDEO_BUDGET, MIN_VIDEO, MAX_VIDEO, maxPeers, videoPlan } from "../../browser/app/voice/mesh-plan.js";

import { harness } from './assert.mjs';
const { check, done } = harness();
const sizes = Array.from({ length: maxPeers }, (_, i) => i + 1);

console.log("── the ceiling is what the budget gives ──");
check("maxPeers is the budget over the smallest stream, less yourself",
      maxPeers === Math.floor(VIDEO_BUDGET / MIN_VIDEO) - 1);
check("a room can hold more than a pair", maxPeers >= 2);

console.log("── every size a room can reach is within budget ──");
check("the streams sum to no more than the budget, at every size",
      sizes.every(n => n * videoPlan(n).maxBitrate <= VIDEO_BUDGET));
check("every stream is at least the smallest worth sending",
      sizes.every(n => videoPlan(n).maxBitrate >= MIN_VIDEO));
check("no stream exceeds the most one needs",
      sizes.every(n => videoPlan(n).maxBitrate <= MAX_VIDEO));

console.log("── a bigger room sends less, each, and a smaller picture ──");
check("the rate never rises as peers join",
      sizes.slice(1).every(n => videoPlan(n).maxBitrate <= videoPlan(n - 1).maxBitrate));
check("the picture never grows as peers join",
      sizes.slice(1).every(n => videoPlan(n).scaleDown >= videoPlan(n - 1).scaleDown));
check("a pair gets the full-size picture", videoPlan(1).scaleDown === 1);

console.log("── outside the range reads as the nearest end ──");
check("no peers reads as one", videoPlan(0).maxBitrate === videoPlan(1).maxBitrate);
check("past the ceiling reads as the ceiling", videoPlan(maxPeers + 7).maxBitrate === videoPlan(maxPeers).maxBitrate);

done();
