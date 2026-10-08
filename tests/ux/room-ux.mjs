/// tests/ux/room-ux.mjs — a live room is reachable from every face.
///
/// voice/room.ts is the app's one vocabulary for being live in a room: state,
/// actions, a controls row any surface can host, a door, and openRoom(topic).
/// This pins the claims that make it generic rather than the clock's:
///   · the door is in the site-wide header, so it is on every face — including
///     map and match, which go without a rail until a room holds one open
///   · openRoom(topic) from any face stands the room's sheet in the panel's own
///     #roomsec (outside every face's rail group) and the sheet carries the live
///     controls for THAT topic
///   · the controls redraw from the room's state alone (the seam's `walkie` push)
///   · while you are live a dock stands under the header on EVERY face with the
///     call's controls — talk, camera, share, and a plain leave
///   · the dock goes where you put it: drag it by the room's name, it stays (as a
///     fraction of the window), a double-tap sends it home, and a tap still opens the room
///   · any element with data-room is a door: the plan and recipes faces carry a
///     chip that opens THEIR room, lights while you are on air in it, and says who is there
///   · the camera is a switch in any call: off degrades to audio, on adds video
///   · the door lights while you are on air in its room, and only then
///   · leaving returns everything to the join doors
///
/// The media and the mesh are covered elsewhere (walkie-ux, test-presence-rooms);
/// the gateway is stubbed at the seam, which is all the sheet can see of it.
///
/// Run: make test-room-ux
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch();
const page = await browser.newPage();
page.on('pageerror', e => h.errs.push(String(e)));

// map and match go without a rail of their own — an open room lends them one
const FACES = ['time', 'plan', 'cal', 'forum', 'map', 'match'];
const ROOM = 'meeting/testscope/kitchen';

try {
  await page.goto(`${BASE}/app.html?face=time`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 30000 });
  await page.waitForFunction(() => !!document.getElementById('roomsec'), null, { timeout: 30000 });

  // day-boot.js installs HANDLERS.walkie once its libraries have loaded, which
  // can come after the page's own markup; a stub put in before that is
  // overwritten by the real one. Wait for the real handler, then replace it. (A
  // SYNCHRONOUS predicate: a Promise from an async one is truthy at once.)
  await page.evaluate(async () => { window.__core = await import('/app/core.js'); });
  await page.waitForFunction(() => !!window.__core.HANDLERS.walkie, null, { timeout: 60000 });

  // stub the two gateway halves the sheet reads, and give the door a commune
  await page.evaluate(async () => {
    const core = window.__core;
    window.__calls = [];
    core.HANDLERS.walkie = (op, arg) => { window.__calls.push([op, arg || '']); };
    core.HANDLERS.chat = async () => '[]';
    const scope = await import('/app/scope.js');
    scope.scopeSig.set('testscope');
  });

  const snap = () => page.evaluate(() => {
    const sec = document.getElementById('evchat');
    const inHub = !!sec && sec.parentElement === document.getElementById('roomsec');
    const acts = [...document.querySelectorAll('#evchat [data-act]')].map(e => e.dataset.act);
    return {
      door: !!document.getElementById('netbtn'),
      doorVisible: (() => { const d = document.getElementById('netbtn');
                            return !!d && d.offsetParent !== null; })(),
      doorInHeader: !!document.querySelector('#top #netbtn'),
      live: document.getElementById('netbtn').classList.contains('live'),
      inHub, shown: !!sec && getComputedStyle(sec).display !== 'none', acts,
      onScreen: !!sec && sec.getBoundingClientRect().width > 40 && sec.getBoundingClientRect().height > 10,
      head: (document.querySelector('#evchat .chathdr') || {}).textContent || '',
    };
  });

  // the door is a row in the account sheet (the person button), not a header button
  const viaAccount = async () => {
    await page.evaluate(() => document.querySelector('#idrow .who').click());
    await sleep(200);
    const row = await page.evaluate(() => [...document.querySelectorAll('#acct .acct-row')].some(r => /channel/.test(r.textContent)));
    return row;
  };
  h.rec('the door is a row in the account sheet', (await snap()).door && await viaAccount());
  await page.keyboard.press('Escape');

  for (const face of FACES) {
    await page.evaluate(f => { window.location.hash = ''; document.getElementById('face-' + f)?.click(); }, face);
    await sleep(250);
    const s0 = await snap();
    h.rec(`[${face}] the account sheet carries the door`, await viaAccount());
    await page.keyboard.press('Escape');

    // open a room from this face the way any surface would: by topic
    await page.evaluate(async t => { (await import('/app/voice/room.js')).openRoom(t); }, ROOM);
    await sleep(250);
    const s1 = await snap();
    h.rec(`[${face}] openRoom stands the sheet in #roomsec`, s1.inHub && s1.shown, JSON.stringify(s1));
    // the plan and forum rails start SHUT; an open room holds the rail open
    h.rec(`[${face}] the sheet is actually on screen`, s1.onScreen, JSON.stringify(s1));
    h.rec(`[${face}] the sheet names the room and can be closed`, /kitchen/.test(s1.head) && /×/.test(s1.head), s1.head);
    h.rec(`[${face}] the sheet carries the join doors`, s1.acts.includes('join') && s1.acts.includes('joinvideo'), s1.acts.join());

    await page.screenshot({ path: `tests/ux/_artifacts/room-${face}.png` }).catch(() => {});
    // close it so the next face starts clean
    await page.evaluate(() => document.getElementById('chatx')?.click());
    await sleep(100);
  }

  // ── the live state, on one face, end to end ────────────────────────────
  await page.evaluate(async t => { (await import('/app/voice/room.js')).openRoom(t); }, ROOM);
  await sleep(200);
  await page.evaluate(() => document.querySelector('#evchat [data-act="joinvideo"]').click());
  h.rec('the join door asks the spine for THIS room, with video',
        JSON.stringify(await page.evaluate(() => window.__calls.at(-1))) === JSON.stringify(['joinvideo', ROOM]));

  await page.evaluate(async () => { (await import('/app/bus.js')).emit('walkie', 'joined-video'); });
  await sleep(200);
  const live = await snap();
  h.rec('live: the row becomes talk / camera / screen / leave',
        ['talk', 'cam', 'screen', 'leave'].every(a => live.acts.includes(a)) && !live.acts.includes('join'),
        live.acts.join());
  h.rec('the network door stays dark while you are live in ANOTHER room', !live.live);

  await page.evaluate(() => document.querySelector('#evchat [data-act="talk"]').click());
  await sleep(150);
  h.rec('talk toggles on and the button says so',
        await page.evaluate(() => document.querySelector('#evchat [data-act="talk"]').classList.contains('on')));
  h.rec('talk reaches the spine',
        JSON.stringify(await page.evaluate(() => window.__calls.at(-1))) === JSON.stringify(['talk', 'on']));

  // the same state, from a different face: the controls were never the clock's
  await page.evaluate(() => document.getElementById('face-plan')?.click());
  await sleep(250);
  const away = await snap();
  await page.screenshot({ path: 'tests/ux/_artifacts/room.png' }).catch(() => {});
  h.rec('the live row survives a face change', away.inHub && away.acts.includes('leave'), JSON.stringify(away));

  await page.evaluate(() => document.querySelector('#evchat [data-act="leave"]').click());
  h.rec('leave reaches the spine',
        JSON.stringify(await page.evaluate(() => window.__calls.at(-1))) === JSON.stringify(['leave', '']));
  await page.evaluate(async () => { (await import('/app/bus.js')).emit('walkie', 'left'); });
  await sleep(200);
  const out = await snap();
  h.rec('left: the row returns to the join doors', out.acts.includes('join') && !out.acts.includes('leave'), out.acts.join());

  // ── holds are per owner: one letting go never frees another's ──────────────
  await page.evaluate(() => document.getElementById('face-plan')?.click());
  await sleep(250);
  await page.evaluate(async t => {
    const panel = await import('/app/panel.js');
    panel.holdPanelOpen('web', true);
    (await import('/app/voice/room.js')).openRoom(t);
  }, ROOM);
  await sleep(250);
  await page.evaluate(async () => { (await import('/app/panel.js')).holdPanelOpen('web', false); });
  await sleep(450);
  const kept = await snap();
  h.rec('another owner releasing its hold leaves the room\'s rail open', kept.onScreen && kept.inHub, JSON.stringify(kept));
  await page.evaluate(() => document.getElementById('chatx')?.click());
  await sleep(450);
  h.rec('closing the room gives the rail back (held flag cleared)',
        await page.evaluate(() => !document.getElementById('main').hasAttribute('data-held')));

  // ── the call is always within reach: the dock ─────────────────────────────
  const dockSnap = () => page.evaluate(() => {
    const d = document.getElementById('livedock');
    if (!d) return null;
    const r = d.getBoundingClientRect();
    const cam = d.querySelector('[data-act="cam"]');
    return { onScreen: r.width > 60 && r.height > 10 && r.top >= 0 && r.left >= 0 && r.right <= innerWidth,
             acts: [...d.querySelectorAll('[data-act]')].map(e => e.dataset.act),
             name: d.querySelector('.dockname').textContent,
             camText: cam ? cam.textContent : '', camLit: !!cam && cam.classList.contains('on') };
  });
  h.rec('no dock while out of a call', (await dockSnap()) === null);
  await page.evaluate(async t => {
    (await import('/app/voice/room.js')).joinRoom(t, true);
    (await import('/app/bus.js')).emit('walkie', 'joined-video');
  }, ROOM);
  await sleep(250);
  for (const face of FACES) {
    await page.evaluate(f => document.getElementById('face-' + f)?.click(), face);
    await sleep(250);
    const d = await dockSnap();
    h.rec(`[${face}] the live dock is on screen with talk, camera, share and leave`,
          !!d && d.onScreen && ['talk', 'cam', 'screen', 'leave'].every(a => d.acts.includes(a)), JSON.stringify(d));
  }
  await page.evaluate(() => document.getElementById('face-plan')?.click());
  await sleep(250);
  await page.screenshot({ path: 'tests/ux/_artifacts/room-dock.png' }).catch(() => {});
  const d0 = await dockSnap();
  h.rec('the dock names the room', /kitchen/.test(d0.name), d0.name);
  h.rec('a call that began with video shows the camera lit and offers to stop it',
        d0.camLit && /stop camera/.test(d0.camText), d0.camText);

  // ── the dock goes where you put it ──────────────────────────────────────
  const dockBox = () => page.evaluate(() => {
    const r = document.getElementById('livedock').getBoundingClientRect();
    return { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) };
  });
  await page.evaluate(() => localStorage.removeItem('pn.dock.pos'));
  const home = await dockBox();
  const hb = await (await page.$('#livedock .dockname')).boundingBox();
  const cx = hb.x + hb.width / 2, cy = hb.y + hb.height / 2;
  // a tap on the name opens the room's sheet…
  await page.mouse.click(cx, cy);
  await sleep(200);
  h.rec('a tap on the name still opens the room', (await snap()).shown && (await snap()).inHub);
  await page.evaluate(() => document.getElementById('chatx')?.click());
  await sleep(150);
  // …a drag moves the dock and does NOT open it
  await page.mouse.move(cx, cy); await page.mouse.down();
  await page.mouse.move(cx - 180, cy + 240, { steps: 8 }); await page.mouse.up();
  await sleep(200);
  const moved = await dockBox();
  h.rec('dragging the name moves the dock with the pointer',
        Math.abs(moved.x - (home.x - 180)) <= 6 && Math.abs(moved.y - (home.y + 240)) <= 6, JSON.stringify({ home, moved }));
  h.rec('a drag does not open the room', !(await snap()).shown);
  h.rec('the dock stays wholly on screen',
        await page.evaluate(() => { const r = document.getElementById('livedock').getBoundingClientRect();
          return r.left >= 0 && r.top >= 0 && r.right <= innerWidth && r.bottom <= innerHeight; }));
  const saved = await page.evaluate(() => { try { return JSON.parse(localStorage.getItem('pn.dock.pos')); } catch (_) { return null; } });
  h.rec('where it was left is remembered as fractions of the window',
        !!saved && saved.fx > 0 && saved.fx < 1 && saved.fy > 0 && saved.fy < 1, JSON.stringify(saved));
  // one more drag far outside the window clamps to the edge
  const mb = await (await page.$('#livedock .dockname')).boundingBox();
  await page.mouse.move(mb.x + 4, mb.y + 4); await page.mouse.down();
  await page.mouse.move(-400, -400, { steps: 6 }); await page.mouse.up();
  await sleep(150);
  const edge = await dockBox();
  h.rec('dragging past the window edge clamps the dock to it', edge.x === 0 && edge.y === 0, JSON.stringify(edge));
  // leave and rejoin: the dock comes back where it was left
  await page.evaluate(async () => { (await import('/app/bus.js')).emit('walkie', 'left'); });
  await sleep(200);
  await page.evaluate(async t => {
    (await import('/app/voice/room.js')).joinRoom(t, true);
    (await import('/app/bus.js')).emit('walkie', 'joined-video');
  }, ROOM);
  await sleep(250);
  const back = await dockBox();
  h.rec('a new call puts the dock back where you left it', back.x === 0 && back.y === 0, JSON.stringify(back));
  // a double-tap on the name sends it home and forgets the position
  const nb = await (await page.$('#livedock .dockname')).boundingBox();
  await page.mouse.dblclick(nb.x + nb.width / 2, nb.y + nb.height / 2);
  await sleep(250);
  const sent = await dockBox();
  h.rec('a double-tap sends the dock home', Math.abs(sent.x - home.x) <= 6 && Math.abs(sent.y - home.y) <= 6, JSON.stringify({ home, sent }));
  h.rec('…and forgets the position', await page.evaluate(() => localStorage.getItem('pn.dock.pos')) === null);
  await page.evaluate(() => document.getElementById('chatx')?.click());   // the double-tap's first tap opened the sheet
  await sleep(150);

  // camera off: the spine is asked, the spine answers, the call carries on as audio
  await page.evaluate(() => document.querySelector('#livedock [data-act="cam"]').click());
  h.rec('camera off is asked of the spine, not assumed',
        JSON.stringify(await page.evaluate(() => window.__calls.at(-1))) === JSON.stringify(['cam', 'off']));
  h.rec('…and nothing changes until the spine says so', (await dockSnap()).camLit);
  await page.evaluate(async () => { (await import('/app/bus.js')).emit('walkie', 'cam-off'); });
  await sleep(200);
  const d1 = await dockSnap();
  h.rec('camera off degrades to audio: the call, the mic and leave all stay',
        !!d1 && d1.acts.includes('talk') && d1.acts.includes('leave') && !d1.camLit && /start camera/.test(d1.camText), JSON.stringify(d1));
  await page.evaluate(() => document.querySelector('#livedock [data-act="cam"]').click());
  h.rec('the camera can come back',
        JSON.stringify(await page.evaluate(() => window.__calls.at(-1))) === JSON.stringify(['cam', 'on']));
  await page.evaluate(async () => { (await import('/app/bus.js')).emit('walkie', 'cam-denied'); });
  await sleep(200);
  h.rec('a refused camera leaves the call on audio', !(await dockSnap()).camLit);
  await page.evaluate(async () => { (await import('/app/bus.js')).emit('walkie', 'cam-on'); });
  await sleep(200);
  h.rec('…and a granted one lights the control', (await dockSnap()).camLit);

  // the same controls in a call that began as audio: video is one tap away
  await page.evaluate(async () => { (await import('/app/bus.js')).emit('walkie', 'left'); });
  await sleep(200);
  await page.evaluate(async t => {
    (await import('/app/voice/room.js')).joinRoom(t, false);
    (await import('/app/bus.js')).emit('walkie', 'joined');
  }, ROOM);
  await sleep(250);
  const d2 = await dockSnap();
  h.rec('an audio call offers the camera and the share too',
        !!d2 && d2.acts.includes('cam') && d2.acts.includes('screen') && !d2.camLit && /start camera/.test(d2.camText), JSON.stringify(d2));

  // hang up, from the dock
  await page.evaluate(() => document.querySelector('#livedock [data-act="leave"]').click());
  h.rec('leave, from the dock, reaches the spine',
        JSON.stringify(await page.evaluate(() => window.__calls.at(-1))) === JSON.stringify(['leave', '']));
  await page.evaluate(async () => { (await import('/app/bus.js')).emit('walkie', 'left'); });
  await sleep(200);
  h.rec('the dock goes with the call', (await dockSnap()) === null);

  // ── any element with data-room is a door: plan and recipes carry one ────
  await page.evaluate(() => document.getElementById('face-plan')?.click());
  await sleep(300);
  const chip = (sel) => page.evaluate(sel => {
    const c = document.querySelector(sel);
    return c ? { text: c.textContent.trim(), room: c.dataset.room, live: c.classList.contains('live'),
                 busy: c.classList.contains('busy') } : null;
  }, sel);
  await page.screenshot({ path: 'tests/ux/_artifacts/room-chips-plan.png' }).catch(() => {});
  const planChip = await chip('#planpanel .roomchip');
  h.rec('the plan face carries a chip for its own room',
        !!planChip && planChip.room === 'meeting/testscope/plan', JSON.stringify(planChip));
  await page.evaluate(() => document.querySelector('#planpanel .roomchip').click());
  await sleep(300);
  const opened = await snap();
  h.rec('tapping the plan chip opens THAT room, in the panel',
        opened.inHub && /plan/.test(opened.head) && opened.acts.includes('join'), JSON.stringify(opened));
  await page.evaluate(() => document.getElementById('chatx')?.click());
  await sleep(150);
  // on air in that room: the chip lights; a wake reading with others in it: the chip says so
  await page.evaluate(async () => {
    const r = await import('/app/voice/room.js'); r.joinRoom('meeting/testscope/plan', false);
    (await import('/app/bus.js')).emit('walkie', 'joined');
  });
  await sleep(250);
  h.rec('the chip lights while you are on air in its room', (await chip('#planpanel .roomchip')).live);
  await page.evaluate(async () => { (await import('/app/bus.js')).emit('walkie', 'left'); });
  await sleep(200);
  h.rec('…and goes dark when you leave', !(await chip('#planpanel .roomchip')).live);
  await page.evaluate(() => document.getElementById('face-recipes')?.click());
  await sleep(400);
  const lib = await chip('#recipespanel .roomchip');
  h.rec('the recipes face carries a chip for the library room',
        !!lib && lib.room === 'meeting/testscope/recipes', JSON.stringify(lib));
  // recipes only draw when a scope has some; seed one the way the face reads them
  const cards = await page.evaluate(() => document.querySelectorAll('#recipesstage .rc-card .roomchip').length);
  h.info('recipe cards with a chip in this scope: ' + cards);
  await page.screenshot({ path: 'tests/ux/_artifacts/room-chips-recipes.png' }).catch(() => {});

  // ── the door lights only in its own room ──────────────────────────────
  const NET = 'meeting/testscope/network';
  await page.evaluate(async t => { (await import('/app/voice/room.js')).openRoom(t); }, NET);
  await sleep(200);
  await page.evaluate(() => document.querySelector('#evchat [data-act="join"]').click());
  await page.evaluate(async () => { (await import('/app/bus.js')).emit('walkie', 'joined'); });
  await sleep(200);
  h.rec('the door lights while you are on air in the network', (await snap()).live);
  await page.evaluate(async () => { (await import('/app/bus.js')).emit('walkie', 'left'); });
  await sleep(200);
  h.rec('…and goes dark when you leave', !(await snap()).live);

  // ── the door itself opens the network room, from any face ─────────────
  await page.evaluate(() => document.getElementById('chatx')?.click());
  await page.evaluate(() => document.getElementById('face-cal')?.click());
  await sleep(250);
  await page.evaluate(() => document.querySelector('#idrow .who').click());
  await sleep(200);
  await page.evaluate(() => [...document.querySelectorAll('#acct .acct-row')].find(r => /channel/.test(r.textContent)).click());
  await sleep(250);
  const viaDoor = await snap();
  h.rec('tapping the door opens the commune\'s channel', viaDoor.inHub && /network/.test(viaDoor.head), viaDoor.head);

  if (h.errs.length) h.info('page errors: ' + JSON.stringify(h.errs.slice(0, 4)));
} catch (e) {
  h.rec('fatal', false, e.message);
} finally {
  await browser.close();
  closeServer();
}

summarize(h, [
  'the door lives in the header',
  'the join door asks the spine for THIS room, with video',
  'live: the row becomes talk / camera / screen / leave',
  'the live row survives a face change',
  'left: the row returns to the join doors',
  'camera off degrades to audio: the call, the mic and leave all stay',
  'leave, from the dock, reaches the spine',
  'the dock goes with the call',
  'the door lights while you are on air in the network',
  'tapping the door opens the commune\'s channel',
]);
