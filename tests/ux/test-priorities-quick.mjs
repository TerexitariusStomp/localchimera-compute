/// tests/ux/test-priorities-quick.mjs — Quick Playwright test for the priorities tab
/// Run: guix shell node-playwright-core node -- sh -c 'cd browser && python3 -m http.server 8088 &
///      sleep 1 && CHROMIUM_PATH=/snap/bin/chromium node tests/ux/test-priorities-quick.mjs'

let chromium;
const pick = (m) => m.chromium ?? m.default?.chromium;
try { chromium = pick(await import('playwright-core')); } catch {}
if (!chromium) try { chromium = pick(await import('playwright')); } catch {}
if (!chromium) throw new Error("playwright-core not found");

const BASE_URL = process.argv[2] || 'http://localhost:8088';
const WASM_TIMEOUT = 90_000;

const launchOpts = { headless: true, args: ['--no-sandbox', '--disable-gpu'] };
if (process.env.CHROMIUM_PATH) launchOpts.executablePath = process.env.CHROMIUM_PATH;

const browser = await chromium.launch(launchOpts);
const page = await (await browser.newContext({ viewport: { width: 1280, height: 800 } })).newPage();

// Capture console
page.on('console', msg => {
  if (msg.type() === 'error') console.log('  [browser error]', msg.text().slice(0, 200));
});
page.on('pageerror', err => console.log('  [page error]', String(err).slice(0, 200)));

console.log(`Loading ${BASE_URL}/index.html ...`);
await page.goto(`${BASE_URL}/index.html`, { waitUntil: 'domcontentloaded' });

// Wait for WASM to boot — the REPL creates textarea#expression when ready
console.log('Waiting for WASM to initialize (textarea#expression) ...');
try {
  await page.waitForSelector('textarea#expression', { timeout: WASM_TIMEOUT });
  console.log('PASS: REPL loaded');
} catch (e) {
  console.log('FAIL: REPL did not load within timeout');
  // Dump page content for diagnosis
  const html = await page.content();
  console.log('Page title:', await page.title());
  console.log('Body text length:', html.length);
  const bodyText = await page.evaluate(() => document.body?.innerText?.slice(0, 500) ?? '(empty)');
  console.log('Body snippet:', bodyText.slice(0, 300));
  await browser.close();
  process.exit(1);
}

await page.waitForTimeout(2000);

// Now test the priorities tab
console.log('\n-- Testing priorities tab --');

// Find and click the priorities tab
const clicked = await page.evaluate(() => {
  const tabs = document.querySelectorAll('.tab-bar .tab');
  for (const tab of tabs) {
    if (tab.textContent.trim() === 'priorities') {
      tab.click();
      return true;
    }
  }
  return false;
});

if (!clicked) {
  console.log('FAIL: priorities tab not found (WASM may need rebuild)');
  // List available tabs for diagnosis
  const tabNames = await page.evaluate(() =>
    Array.from(document.querySelectorAll('.tab-bar .tab')).map(t => t.textContent.trim()));
  console.log('Available tabs:', tabNames.join(', '));
  await browser.close();
  process.exit(1);
}

console.log('PASS: priorities tab found and clicked');
await page.waitForTimeout(1000);

// Check for the prio-view container
const hasPrioView = await page.locator('.prio-view').count() > 0;
console.log(hasPrioView ? 'PASS: .prio-view rendered' : 'FAIL: .prio-view not found');

// Check for empty state
const hasAddBtn = await page.locator('.prio-add-btn').count() > 0;
console.log(hasAddBtn ? 'PASS: empty state with add button' : 'FAIL: no add button');

if (hasAddBtn) {
  // Click add
  await page.locator('.prio-add-btn').click();
  await page.waitForTimeout(500);

  const nodeCount = await page.locator('.prio-node').count();
  console.log(nodeCount === 1 ? 'PASS: first node created' : `FAIL: expected 1 node, got ${nodeCount}`);

  // Add more via toolbar
  const toolbarBtn = page.locator('.prio-toolbar-btn');
  await toolbarBtn.click();
  await page.waitForTimeout(300);
  await toolbarBtn.click();
  await page.waitForTimeout(300);

  const threeNodes = await page.locator('.prio-node').count();
  console.log(threeNodes === 3 ? 'PASS: three nodes created' : `FAIL: expected 3 nodes, got ${threeNodes}`);

  // Check they have different positions (treemap layout working)
  const positions = await page.evaluate(() => {
    const nodes = document.querySelectorAll('.prio-node');
    return Array.from(nodes).map(n => n.style.left + ',' + n.style.top);
  });
  const unique = new Set(positions);
  console.log(unique.size === positions.length
    ? 'PASS: treemap assigns unique positions'
    : `FAIL: positions not unique: ${positions.join(' | ')}`);

  // Test resize: drag a node up
  const firstNode = page.locator('.prio-node').first();
  const box = await firstNode.boundingBox();
  if (box) {
    const widthBefore = await page.evaluate(() =>
      document.querySelector('.prio-node')?.style.width ?? '');

    const cx = box.x + box.width / 2;
    const cy = box.y + box.height / 2;
    await page.mouse.move(cx, cy);
    await page.mouse.down();
    await page.mouse.move(cx, cy - 50, { steps: 10 });
    await page.waitForTimeout(100);
    await page.mouse.up();
    await page.waitForTimeout(500);

    const widthAfter = await page.evaluate(() =>
      document.querySelector('.prio-node')?.style.width ?? '');
    console.log(widthBefore !== widthAfter
      ? 'PASS: resize changes node size'
      : `WARN: resize may not have worked (before=${widthBefore}, after=${widthAfter})`);
  }

  // Test navigation: click into a node (first add children)
  // For now just verify breadcrumb exists
  const hasBreadcrumb = await page.locator('.prio-breadcrumb').count() > 0;
  console.log(hasBreadcrumb ? 'PASS: breadcrumb rendered' : 'FAIL: no breadcrumb');

  // Test persistence
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('textarea#expression', { timeout: WASM_TIMEOUT });
  await page.waitForTimeout(3000);

  // Re-click priorities tab
  await page.evaluate(() => {
    const tabs = document.querySelectorAll('.tab-bar .tab');
    for (const tab of tabs) {
      if (tab.textContent.trim() === 'priorities') { tab.click(); break; }
    }
  });
  await page.waitForTimeout(1000);

  const nodesAfterReload = await page.locator('.prio-node').count();
  console.log(nodesAfterReload === 3
    ? 'PASS: tree persists after reload'
    : `FAIL: expected 3 nodes after reload, got ${nodesAfterReload}`);
}

console.log('\n-- Done --');
await browser.close();
