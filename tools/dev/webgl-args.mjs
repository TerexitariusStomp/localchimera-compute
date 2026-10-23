// SPDX-License-Identifier: AGPL-3.0-or-later
// tools/dev/webgl-args.mjs — the Chromium flags that give a HEADLESS page a real
// WebGL context, in software (SwiftShader), so the maplibre faces build a map
// and a probe or a screenshot sees its layers, markers and camera.
//
// Without them the map takes its no-WebGL offline branch (app/mapview.ts) and
// `theMap()` is null. Shared by tests/ux/ux-harness.mjs (pass them to launch())
// and tools/dev/shot.mjs, so the one list lives in one place.
//
// Tiles still come from wherever the page's style points; with none served the
// ground is plain and the dial's own overlays draw over it.
export const WEBGL_ARGS = [
  '--use-angle=swiftshader',
  '--enable-unsafe-swiftshader',
  '--ignore-gpu-blocklist',
];
