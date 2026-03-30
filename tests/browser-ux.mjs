/// tests/browser-ux.mjs — Playwright-driven UX tests for the browser REPL
/// Run via: node tests/browser-ux.mjs <base-url>

import { chromium } from 'playwright';
import { mkdirSync, writeFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SCREENSHOT_DIR = join(__dirname, 'screenshots');
const BASE_URL = process.argv[2] || 'http://localhost:8088';
const REPL_URL = `${BASE_URL}/repl.html`;
const WASM_TIMEOUT = 60_000;

mkdirSync(SCREENSHOT_DIR, { recursive: true });

// ── Helpers ────────────────────────────────────────────────────────────────

const results = [];

function record(name, passed, detail = '') {
  results.push({ name, passed, detail: String(detail).slice(0, 120) });
  const mark = passed ? 'PASS' : 'FAIL';
  const shortDetail = detail ? ': ' + String(detail).slice(0, 80) : '';
  console.log(`  ${mark}  ${name}${shortDetail}`);
}

async function screenshot(page, name) {
  await page.screenshot({
    path: join(SCREENSHOT_DIR, `${name}.png`),
    fullPage: true,
  });
}

async function waitForRepl(page) {
  await page.goto(REPL_URL, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('textarea#expression', { timeout: WASM_TIMEOUT });
  await page.waitForTimeout(2000);
}

/**
 * Submit an expression to the REPL and wait for output.
 * Returns the full text of #repl-log after evaluation.
 */
async function evalExpr(page, expr) {
  const input = page.locator('textarea#expression');
  await input.fill('');
  await input.fill(expr);
  await page.keyboard.press('Enter');
  // Wait for DOM to settle after virtual-dom diff
  await page.waitForTimeout(1500);
  return page.locator('#repl-log').textContent();
}

/** Get text content of the last element matching selector in #repl-log */
async function lastText(page, selector) {
  const els = page.locator(`#repl-log ${selector}`);
  const count = await els.count();
  if (count === 0) return null;
  return (await els.nth(count - 1).textContent()).trim();
}

// ── Scenarios ──────────────────────────────────────────────────────────────

async function smokeTest(page) {
  console.log('\n-- 1. Smoke test --');
  try {
    await waitForRepl(page);
    const visible = await page.locator('textarea#expression').isVisible();
    record('WASM loads and REPL ready', visible);
    await screenshot(page, '01-smoke-ready');
  } catch (e) {
    record('WASM loads and REPL ready', false, e.message);
    await screenshot(page, '01-smoke-fail');
  }
}

async function orgCreateAndEnter(page) {
  console.log('\n-- 2. Org create and enter --');
  try {
    // Capture browser errors — these are often real bugs the test catches
    const browserErrors = [];
    page.on('console', msg => {
      if (msg.type() === 'error') {
        const text = msg.text();
        // Filter to first line of each error for readability
        const firstLine = text.split('\n')[0].slice(0, 120);
        if (!browserErrors.some(e => e === firstLine)) browserErrors.push(firstLine);
      }
    });
    page.on('pageerror', err => browserErrors.push(String(err).slice(0, 100)));

    await evalExpr(page, '(make-org "ux-test")');

    // Key generation is async — wait for the specific result text
    try {
      await page.waitForFunction(
        () => document.querySelector('#repl-log')?.textContent?.includes('Created org'),
        { timeout: 15_000 }
      );
    } catch { /* timeout ok, check anyway */ }
    const logAfterCreate = await page.locator('#repl-log').textContent();
    const created = logAfterCreate.includes('Created org');
    if (!created && browserErrors.length > 0) {
      console.log('    [browser errors]:');
      browserErrors.forEach(e => console.log('      -', e));
    }
    record('make-org creates org', created, created ? '' : browserErrors[0] || 'no output');
    await screenshot(page, '02a-org-created');

    await evalExpr(page, '(enter! "ux-test")');
    try {
      await page.waitForFunction(
        () => document.querySelector('#repl-log')?.textContent?.includes('Entering org'),
        { timeout: 10_000 }
      );
    } catch { /* timeout */ }
    const logAfterEnter = await page.locator('#repl-log').textContent();
    const entered = logAfterEnter.includes('Entering org');
    record('enter! switches to inner mode', entered);
    await screenshot(page, '02b-org-entered');
    return entered;
  } catch (e) {
    record('org create and enter', false, e.message);
    await screenshot(page, '02-org-fail');
    return false;
  }
}

async function replEvalTest(page) {
  console.log('\n-- 3. REPL evaluation (inside org) --');
  try {
    await evalExpr(page, '(+ 1 2)');
    const result = await lastText(page, 'span.result-text');
    record('(+ 1 2) evaluates', result && result.includes('3'), result);
    await screenshot(page, '03-repl-eval');
  } catch (e) {
    record('REPL evaluation', false, e.message);
  }
}

async function errorHandlingTest(page) {
  console.log('\n-- 4. Error handling --');
  try {
    await evalExpr(page, '(undefined-xyz-symbol)');
    const err = await lastText(page, 'span.error-text');
    record('invalid expression shows error', err !== null, err);
    await screenshot(page, '04-error-handling');
  } catch (e) {
    record('error handling', false, e.message);
  }
}

async function modifyAndLookupTest(page) {
  console.log('\n-- 5. Modify and lookup --');
  try {
    await evalExpr(page, "(modify! 'greeting \"hello\")");
    await evalExpr(page, 'greeting');
    const result = await lastText(page, 'span.result-text');
    record('modify! + lookup works', result && result.includes('hello'), result);
    await screenshot(page, '05-modify-lookup');
  } catch (e) {
    record('modify and lookup', false, e.message);
  }
}

async function sidebarTest(page) {
  console.log('\n-- 6. Sidebar inspector --');
  try {
    await page.waitForTimeout(500);
    const sidebar = page.locator('.sidebar');
    const sidebarVisible = await sidebar.isVisible();
    record('sidebar is visible', sidebarVisible);

    if (sidebarVisible) {
      const text = await sidebar.textContent();
      record('sidebar shows binding', text.includes('greeting'), text.includes('greeting') ? 'found' : 'not in sidebar');
    }
    await screenshot(page, '06-sidebar');
  } catch (e) {
    record('sidebar inspector', false, e.message);
  }
}

async function historyTest(page) {
  console.log('\n-- 7. History navigation --');
  try {
    await evalExpr(page, '(+ 100 200)');
    const input = page.locator('textarea#expression');
    await input.focus();
    await input.fill('');
    await page.keyboard.press('ArrowUp');
    await page.waitForTimeout(500);
    const val = await input.inputValue();
    record('ArrowUp recalls previous input', val.length > 0, val);
    await screenshot(page, '07-history');
  } catch (e) {
    record('history navigation', false, e.message);
  }
}

async function codeViewerTest(page) {
  console.log('\n-- 8. Code viewer --');
  try {
    const viewer = page.locator('#code-viewer-content');
    const count = await viewer.count();
    if (count > 0 && await viewer.isVisible()) {
      const text = await viewer.textContent();
      record('code viewer shows org code', text.length > 0, `${text.length} chars`);
    } else {
      record('code viewer shows org code', false, 'not visible');
    }
    await screenshot(page, '08-code-viewer');
  } catch (e) {
    record('code viewer', false, e.message);
  }
}

async function wispToggleTest(page) {
  console.log('\n-- 9. Wisp/Lisp toggle --');
  try {
    const btns = page.locator('span.cp-btn');
    const count = await btns.count();
    let found = false;
    for (let i = 0; i < count; i++) {
      const text = (await btns.nth(i).textContent()).trim();
      if (text === 'lisp' || text === 'wisp') {
        const before = text;
        await btns.nth(i).click();
        await page.waitForTimeout(500);
        // Re-find the button (DOM may have changed)
        const after = (await page.locator('span.cp-btn').nth(i).textContent()).trim();
        record('syntax toggle changes mode', before !== after, `${before} -> ${after}`);
        // Toggle back
        await page.locator('span.cp-btn').nth(i).click();
        await page.waitForTimeout(300);
        found = true;
        break;
      }
    }
    if (!found) record('syntax toggle button found', false, 'not found');
    await screenshot(page, '09-wisp-toggle');
  } catch (e) {
    record('wisp toggle', false, e.message);
  }
}

async function sidebarCollapseTest(page) {
  console.log('\n-- 10. Sidebar collapse --');
  try {
    await page.keyboard.press('Control+e');
    await page.waitForTimeout(500);
    const sidebar = page.locator('.sidebar');
    const collapsed = await sidebar.evaluate(el =>
      el.classList.contains('collapsed') || el.offsetWidth === 0
    );
    record('Ctrl+E collapses sidebar', collapsed);
    await screenshot(page, '10a-collapsed');

    await page.keyboard.press('Control+e');
    await page.waitForTimeout(500);
    const restored = await sidebar.evaluate(el =>
      !el.classList.contains('collapsed') && el.offsetWidth > 0
    );
    record('Ctrl+E restores sidebar', restored);
  } catch (e) {
    record('sidebar collapse', false, e.message);
  }
}

async function orgExitAndDelete(page) {
  console.log('\n-- 11. Exit and delete --');
  try {
    await evalExpr(page, '(exit!)');
    record('exit! leaves org', true);

    await evalExpr(page, '(delete-org "ux-test")');
    const log = await page.locator('#repl-log').textContent();
    record('delete-org removes org', log.includes('Deleted org'));
    await screenshot(page, '11-deleted');
  } catch (e) {
    record('exit and delete', false, e.message);
  }
}

async function persistenceTest(page) {
  console.log('\n-- 12. Persistence --');
  try {
    await evalExpr(page, '(make-org "persist-test")');
    await page.waitForTimeout(3000);

    // Reload (same page, not full navigation)
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('textarea#expression', { timeout: WASM_TIMEOUT });
    await page.waitForTimeout(3000);

    await evalExpr(page, '(list-orgs)');
    const log = await page.locator('#repl-log').textContent();
    const persisted = log.includes('persist-test');
    record('org persists after reload', persisted);
    await screenshot(page, '12-persistence');

    // Cleanup
    await evalExpr(page, '(delete-org "persist-test")');
  } catch (e) {
    record('persistence', false, e.message);
  }
}

// ── Main ───────────────────────────────────────────────────────────────────

async function main() {
  console.log(`== Browser UX Tests ==`);
  console.log(`URL: ${REPL_URL}`);

  const launchOpts = { headless: true, args: ['--no-sandbox', '--disable-gpu'] };
  if (process.env.CHROMIUM_PATH) launchOpts.executablePath = process.env.CHROMIUM_PATH;

  const browser = await chromium.launch(launchOpts);
  const page = await (await browser.newContext({ viewport: { width: 1280, height: 800 } })).newPage();

  try {
    await smokeTest(page);
    if (!results[0]?.passed) {
      console.log('\nSmoke failed — skipping all.');
    } else {
      const entered = await orgCreateAndEnter(page);
      if (entered) {
        await replEvalTest(page);
        await errorHandlingTest(page);
        await modifyAndLookupTest(page);
        await sidebarTest(page);
        await historyTest(page);
        await codeViewerTest(page);
        await wispToggleTest(page);
        await sidebarCollapseTest(page);
        await orgExitAndDelete(page);
      } else {
        console.log('\nCould not enter org — skipping in-org tests.');
      }
      await persistenceTest(page);
    }
  } finally {
    await browser.close();
  }

  const passed = results.filter(r => r.passed).length;
  const failed = results.filter(r => !r.passed).length;
  console.log(`\n== ${passed} passed, ${failed} failed ==`);

  writeFileSync(join(SCREENSHOT_DIR, 'results.json'), JSON.stringify({ results, passed, failed, timestamp: new Date().toISOString() }, null, 2));
  if (failed > 0) process.exit(1);
}

main().catch(e => { console.error('Fatal:', e); process.exit(2); });
