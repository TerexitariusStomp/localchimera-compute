// SPDX-License-Identifier: AGPL-3.0-or-later
// ui/lib/ambient.d.ts — the shape of browser/lib/ambient.js, which stays
// hand-written JavaScript (the audio engine); this lets a face import it.
export function toggle(): void;
export function setVolume(v: number): void;
export function playing(): boolean;
export function level(): number;
