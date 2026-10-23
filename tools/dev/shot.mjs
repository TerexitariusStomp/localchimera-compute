// SPDX-License-Identifier: AGPL-3.0-or-later
// tools/dev/shot.mjs — headless screenshot via Playwright + guix chromium.
// Driven by tools/dev/shot.sh (which enters the browser-test guix shell, links
// node_modules, and sets CHROMIUM_PATH). Not run directly.
//
//   node tools/dev/shot.mjs <url> <out.png> [width] [height] [settleMs]
//
// The dial animates continuously (requestAnimationFrame), so we do NOT wait for
// network idle (it never settles) — we wait for `load` + a fixed settle delay,
// then capture the viewport. Uses the same chromium/launch config as the repo's
// ux-harness (headless, --no-sandbox --disable-gpu, executablePath=CHROMIUM_PATH).

import { WEBGL_ARGS } from './webgl-args.mjs';

const pick = (m) => m.chromium ?? m.default?.chromium;
let chromium;
try { chromium = pick(await import('playwright-core')); } catch {}
if (!chromium) { try { chromium = pick(await import('playwright')); } catch {} }
if (!chromium) { console.error('shot: could not load chromium from playwright'); process.exit(2); }

const [, , url, out, wStr, hStr, settleStr] = process.argv;
if (!url || !out) { console.error('usage: node shot.mjs <url> <out.png> [w] [h] [settleMs]'); process.exit(2); }
const width = +(wStr || 1400), height = +(hStr || 900), settle = +(settleStr || 2500);

// The maplibre faces build a real map here: WEBGL_ARGS give the headless page a
// software WebGL context (tools/dev/webgl-args.mjs). Tiles come from whatever
// the page's style points at; with none served the ground is plain and the
// dial's overlays, markers and chrome draw over it.
const opts = { headless: true, args: ['--no-sandbox', '--disable-gpu', ...WEBGL_ARGS] };
if (process.env.CHROMIUM_PATH) opts.executablePath = process.env.CHROMIUM_PATH;

const browser = await chromium.launch(opts);
try {
  const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 2 });
  // Optional: state the page opens INTO. SHOT_INIT is a JS snippet run before
  // any of the page's own scripts (e.g. seed localStorage so a first-run walk
  // reads as done), where SHOT_EVAL below runs after the page has settled.
  if (process.env.SHOT_INIT) await page.addInitScript(process.env.SHOT_INIT);
  const errs = [];
  page.on('pageerror', (e) => errs.push(String(e)));
  page.on('console', (m) => { if (m.type() === 'error') errs.push('console: ' + m.text()); });
  await page.goto(url, { waitUntil: 'load', timeout: 30000 }).catch((e) => console.error('shot: goto', String(e)));
  await page.waitForTimeout(settle);
  // Optional: drive the page into a specific state before capturing.
  // SHOT_EVAL is a JS snippet run in page context (e.g. select an option, click a chip).
  if (process.env.SHOT_EVAL) { await page.evaluate(process.env.SHOT_EVAL); await page.waitForTimeout(500); }
  await page.screenshot({ path: out });
  console.log('shot:', out, `(${width}x${height})`);
  if (errs.length) console.error('shot: page errors:\n  ' + errs.slice(0, 8).join('\n  '));
} finally {
  await browser.close();
}
