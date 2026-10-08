/// tests/ux/responsive-ux.mjs — the shell fits the screen. On every device the
/// dial ships to, on every face, the page is ONE screen: the header and the
/// share bar (the floor) are both wholly inside the viewport, nothing extends
/// past the right edge, and the document has no scroll of its own in either
/// axis. Faces scroll INSIDE their own boxes (the eco list, the calendar grid);
/// the document never does.
///
/// Devices are Playwright's emulation descriptors (viewport, DPR, touch, UA);
/// the ENGINE is BROWSER=chromium|firefox|webkit (tests/ux/ux-harness.mjs) — all
/// three from guix, nothing vendored — so the same matrix runs under each.
/// WebKit is what every iPhone actually renders with; Gecko has its own flex
/// and aspect-ratio readings. On those two the device is its viewport.
///
///   make test-responsive-ux              chromium
///   make test-responsive-engines-ux      chromium, then firefox, then webkit
///   BROWSER=webkit FACES=time,cal DEVICES='iPhone SE' node tests/ux/responsive-ux.mjs
///   SHOTS=1 …   → tests/ux/_artifacts/responsive/<engine>/<device>-<face>.png
import { harness, launchLayout, summarize, sleep, devices, ENGINE } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();
const h = harness();

/** The matrix. Named Playwright descriptors plus the desktop sizes that have no
 *  descriptor of their own (a small laptop, a 1080p monitor, a 1440p one). */
const MATRIX = [
  // phones, both orientations
  'iPhone SE', 'iPhone SE landscape',
  'iPhone 13', 'iPhone 13 landscape',
  'iPhone 15 Pro Max', 'iPhone 15 Pro Max landscape',
  'Pixel 7', 'Pixel 7 landscape',
  'Galaxy S9+', 'Galaxy S9+ landscape',
  // Playwright's device table lags new phones, so this one is stated outright:
  // 360×780 CSS px at 3×, a touch screen on a mobile browser
  { name: 'Galaxy S24', viewport: { width: 360, height: 780 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true },
  // tablets
  'iPad Mini', 'iPad Mini landscape',
  'iPad Pro 11', 'iPad Pro 11 landscape',
  'Galaxy Tab S4', 'Galaxy Tab S4 landscape',
  // desktops
  { name: 'laptop 1280×720',  viewport: { width: 1280, height: 720 } },
  { name: 'laptop 1366×768',  viewport: { width: 1366, height: 768 } },
  { name: 'laptop 1440×900',  viewport: { width: 1440, height: 900 } },
  { name: 'desktop 1920×1080', viewport: { width: 1920, height: 1080 } },
  { name: 'desktop 2560×1440', viewport: { width: 2560, height: 1440 }, deviceScaleFactor: 2 },
  { name: 'split 960×1080',   viewport: { width: 960, height: 1080 } },
  { name: 'short 1024×600',   viewport: { width: 1024, height: 600 } },
];
const FACES = ['time', 'cal', 'map', 'plan', 'shop', 'store', 'family', 'match', 'log',
               'law', 'frag', 'eco', 'rift', 'gov', 'recipes', 'corpus'];

const pick = (env, all, key = x => x) =>
  process.env[env] ? all.filter(d => process.env[env].split(',').map(s => s.trim()).includes(key(d))) : all;
const rows = pick('DEVICES', MATRIX, d => typeof d === 'string' ? d : d.name)
  .map(d => typeof d === 'string'
    ? { name: d, ...devices[d] }
    : { deviceScaleFactor: 1, ...d });
const faces = pick('FACES', FACES);
for (const d of rows) if (!d.viewport) throw new Error(`unknown device: ${d.name}`);

/** Read the shell's geometry against the viewport. */
const measure = () => {
  const vw = window.innerWidth, vh = window.innerHeight;
  const se = document.scrollingElement;
  const r = (sel) => { const el = document.querySelector(sel); if (!el) return null;
    const b = el.getBoundingClientRect(); return { t: b.top, b: b.bottom, l: b.left, r: b.right, h: b.height, w: b.width }; };
  // anything painted past the right edge — the classic horizontal-overflow
  // tell. Content an ancestor CLIPS (overflow hidden) or SCROLLS (overflow auto) is not
  // overflow of the page while that ancestor is itself on screen: a map label half off
  // the map's edge is fine, and so is a horizontal strip of cards the hand scrolls
  // (the shop's roads). An ancestor that is itself off screen still counts.
  const clipped = (el) => {
    for (let a = el.parentElement; a && a !== document.body; a = a.parentElement) {
      const o = getComputedStyle(a).overflowX;
      if (o === 'hidden' || o === 'clip' || o === 'auto' || o === 'scroll')
        return a.getBoundingClientRect().right <= vw + 1;
    }
    return false;
  };
  const wide = [];
  for (const el of document.body.querySelectorAll('*')) {
    const cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden') continue;
    const b = el.getBoundingClientRect();
    if (b.width > 0 && b.right > vw + 1 && b.left < vw && !clipped(el))
      wide.push(`${el.tagName.toLowerCase()}#${el.id || ''}.${[...el.classList].join('.')}@${Math.round(b.right)}`);
    if (wide.length >= 5) break;
  }
  return { vw, vh, sw: se.scrollWidth, sh: se.scrollHeight, cw: se.clientWidth, ch: se.clientHeight,
           top: r('#top'), bar: r('#sharebar'), main: r('#main'),
           // painted, not merely present: an engine that refused a module
           // leaves the shell's boxes empty, and an empty box fits anywhere
           barRow: !!document.querySelector('#sharebar .sharebar-row'), topKids: document.getElementById('top')?.children.length || 0, face: document.getElementById('main')?.getAttribute('data-face'), wide };
};

const browser = await launchLayout();
h.info(`engine: ${ENGINE} ${browser.version()}`);
const SHOTDIR = `tests/ux/_artifacts/responsive/${ENGINE}`;
if (process.env.SHOTS) (await import('node:fs')).mkdirSync(SHOTDIR, { recursive: true });
const slug = s => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/-$/, '');
for (const d of rows) {
  const { name, ...desc } = d;
  const page = await browser.device(desc);
  const errs = page.errors;
  for (const f of faces) {
    await page.goto(`${BASE}/app.html?face=${f}`);
    // settle on the shell being painted, not on a clock: the floor's row is
    // the last thing the boot draws, and a loaded CPU draws it late
    for (let i = 0; i < 40; i++) {
      if (await page.evaluate(() => !!document.querySelector('#sharebar .sharebar-row'))) break;
      await sleep(250);
    }
    await sleep(400);
    const m = await page.evaluate(measure);
    const tag = `${ENGINE} · ${name} · ${f}`;
    const fits = (x) => x && x.t >= -0.5 && x.b <= m.vh + 0.5 && x.l >= -0.5 && x.r <= m.vw + 0.5;
    const detail = `vp ${m.vw}×${m.vh} doc ${m.sw}×${m.sh} top ${m.top && `${Math.round(m.top.t)}..${Math.round(m.top.b)}`} bar ${m.bar && `${Math.round(m.bar.t)}..${Math.round(m.bar.b)}`}`;
    h.rec(`${tag}: the document has no vertical scroll`, m.sh <= m.ch + 1, detail);
    h.rec(`${tag}: the document has no horizontal scroll`, m.sw <= m.cw + 1 && m.wide.length === 0, m.wide.join(' ') || detail);
    h.rec(`${tag}: the header is on screen`, fits(m.top), detail);
    h.rec(`${tag}: the floor (share bar) is on screen`, fits(m.bar), detail);
    h.rec(`${tag}: the shell is painted (floor row, header controls)`, m.barRow && m.topKids >= 3, `barRow=${m.barRow} topKids=${m.topKids} bar.h=${m.bar?.h}`);
    h.rec(`${tag}: the header is not most of the screen`, m.top && m.top.h <= m.vh * 0.3, `top.h=${m.top?.h}`);
    if (process.env.SHOTS) await page.screenshot({ path: `${SHOTDIR}/${slug(name)}-${f}.png` });
  }
  h.rec(`${ENGINE} · ${name}: no page errors`, errs.length === 0, errs.slice(0, 2).join(' | '));
  await page.close();
}
await browser.close(); closeServer(); summarize(h);
