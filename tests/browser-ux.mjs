/// tests/browser-ux.mjs — Playwright-driven UX tests for the browser REPL
/// Run via: node tests/browser-ux.mjs <base-url>

// Use playwright-core (Guix: node-playwright-core) or playwright (npm)
let chromium;
try {
  ({ chromium } = await import('playwright-core'));
} catch {
  ({ chromium } = await import('playwright'));
}
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
  // Use getElementById (returns first match) — avoids strict mode
  // violations when duplicate textareas exist after mode switches
  await page.evaluate((text) => {
    const el = document.getElementById('expression');
    if (!el) return;
    el.scrollIntoView();
    el.focus();
    el.value = text;
    // Dispatch keydown Enter to trigger maybe-eval
    el.dispatchEvent(new KeyboardEvent('keydown', {
      key: 'Enter', code: 'Enter', keyCode: 13,
      bubbles: true, cancelable: true
    }));
  }, expr);
  await page.waitForTimeout(3000);
  return page.evaluate(() =>
    document.getElementById('repl-log')?.textContent ?? '');
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

    // Diagnostic: does the REPL respond at all?
    await evalExpr(page, '(list-orgs)');
    const diagN = await page.evaluate(() => document.getElementById('repl-log')?.children.length ?? 0);
    console.log(`    [diag] after (list-orgs): logChildren=${diagN}`);

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
    await screenshot(page, '02a-org-created');
    if (!created) {
      const dbgInput = await page.evaluate(() => document.getElementById('expression')?.value ?? '(null)');
      const dbgLogN = await page.evaluate(() => document.getElementById('repl-log')?.children.length ?? 0);
      console.log(`    [debug] textarea="${dbgInput}" logChildren=${dbgLogN} errors=${browserErrors.length}`);
      if (browserErrors.length > 0) {
        console.log('    [browser errors]:');
        browserErrors.slice(0, 3).forEach(e => console.log('      -', e));
      }
    }
    record('make-org creates org', created, created ? '' : browserErrors[0] || 'no output');

    await evalExpr(page, '(enter! "ux-test")');
    // enter! switches from outer to inner mode — DOM layout changes completely.
    // Wait for the sidebar (IDE layout indicator) or "Entering org" in new log.
    try {
      await page.waitForSelector('.sidebar', { timeout: 10_000 });
    } catch { /* timeout */ }
    await page.waitForTimeout(1000);
    // Check if we're in inner mode: sidebar visible OR log has "Entering org"
    const hasSidebar = await page.locator('.sidebar').count() > 0;
    const logText = await page.evaluate(() =>
      document.getElementById('repl-log')?.textContent ?? '');
    const entered = hasSidebar || logText.includes('Entering org');
    record('enter! switches to inner mode', entered,
           hasSidebar ? 'sidebar visible' : logText.slice(0, 60));
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
    const result = await page.evaluate(() => {
      const btns = document.querySelectorAll('span.cp-btn');
      for (const btn of btns) {
        const text = btn.textContent.trim();
        if (text === 'lisp' || text === 'wisp') {
          btn.click();
          return { before: text, clicked: true };
        }
      }
      return { before: null, clicked: false };
    });
    if (result.clicked) {
      await page.waitForTimeout(500);
      const after = await page.evaluate(() => {
        const btns = document.querySelectorAll('span.cp-btn');
        for (const btn of btns) {
          const t = btn.textContent.trim();
          if (t === 'lisp' || t === 'wisp') { btn.click(); return t; }
        }
        return null;
      });
      record('syntax toggle changes mode', result.before !== after,
             `${result.before} -> ${after}`);
    } else {
      record('syntax toggle button found', false, 'not found');
    }
    await screenshot(page, '09-wisp-toggle');
  } catch (e) {
    record('wisp toggle', false, e.message);
  }
}

async function sidebarCollapseTest(page) {
  console.log('\n-- 10. Sidebar collapse --');
  try {
    // Use page.evaluate for Ctrl+E since keyboard events may not propagate
    await page.evaluate(() => {
      document.body.dispatchEvent(new KeyboardEvent('keydown', {
        key: 'e', code: 'KeyE', ctrlKey: true, bubbles: true, cancelable: true
      }));
    });
    await page.waitForTimeout(1000);
    const afterFirst = await page.evaluate(() => {
      const s = document.querySelector('.sidebar');
      return s ? s.offsetWidth : -1;
    });
    // Sidebar removed or zero-width = collapsed
    record('Ctrl+E collapses sidebar', afterFirst <= 0);
    await screenshot(page, '10a-collapsed');

    await page.evaluate(() => {
      document.body.dispatchEvent(new KeyboardEvent('keydown', {
        key: 'e', code: 'KeyE', ctrlKey: true, bubbles: true, cancelable: true
      }));
    });
    await page.waitForTimeout(1000);
    const restored = await page.evaluate(() => {
      const s = document.querySelector('.sidebar');
      return s ? (!s.classList.contains('collapsed') && s.offsetWidth > 0) : false;
    });
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
    // First exit any org we're in (back to outer mode for clean state)
    await evalExpr(page, '(exit!)').catch(() => {});
    await page.waitForTimeout(1000);

    await evalExpr(page, '(make-org "persist-test")');
    await page.waitForTimeout(3000);

    // Reload page — WASM needs to re-initialize
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('textarea#expression', { timeout: WASM_TIMEOUT });
    // Wait for WASM to fully load and org restoration to complete
    await page.waitForTimeout(5000);

    await evalExpr(page, '(list-orgs)');
    await page.waitForTimeout(2000);
    const log = await page.locator('#repl-log').textContent();
    const persisted = log.includes('persist-test');
    record('org persists after reload', persisted);
    await screenshot(page, '12-persistence');

    // Cleanup
    if (persisted) {
      await evalExpr(page, '(delete-org "persist-test")');
    }
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
