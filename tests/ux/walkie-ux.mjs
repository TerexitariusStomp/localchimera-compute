/// tests/ux/walkie-ux.mjs — the walkie's MEDIA layer, in a real browser.
///
/// The room/roster half of the meeting station is covered in Scheme
/// (tests/gateway/test-presence-rooms.scm). This covers the half no Scheme
/// test can reach: getUserMedia, the tracks actually riding a peer connection,
/// screen share via replaceTrack, and the tile grid.
///
/// It runs two RTCPeerConnections against each other INSIDE ONE PAGE, wired
/// by direct SDP/ICE handoff instead of the gateway relay. That is the honest
/// scope: it proves the media plumbing that day-boot.js owns, and deliberately
/// does not restate the signalling path that presence.scm already pins.
///
/// The property worth guarding hardest is NO RENEGOTIATION — the whole mesh
/// design rests on it (docs/planning/faces/meeting-station.md, Layer 1), and a
/// screen share that silently triggered one would break every peer. §4 asserts
/// the signalling state never leaves "stable" and that no negotiationneeded
/// fires after the initial exchange.
///
/// Run: make test-walkie-ux
import { harness, launch, summarize, sleep, FAKE_MEDIA_ARGS } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';

const { base: BASE, close: closeServer } = await serveBrowser();

const h = harness();
const browser = await launch(FAKE_MEDIA_ARGS);
const page = await browser.newPage();
page.on('pageerror', e => h.errs.push(String(e)));
page.on('console', m => { const t = m.text(); if (t) h.logs.push(t.slice(0, 160)); });

try {
  await page.goto(`${BASE}/app.html`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#idrow', { timeout: 30000 });
  // the media door is an export of day-boot.js, set when it builds its imports.
  // Keep the module namespace (its exports are live bindings) and wait on a
  // SYNCHRONOUS predicate: Playwright treats the Promise an async predicate
  // returns as truthy, so `async () => !!(await import(...)).walkieRTC` stopped
  // waiting at once and the suite only passed when boot happened to be quick.
  await page.evaluate(async () => { window.__dayboot = await import('/day-boot.js'); });
  await page.waitForFunction(() => !!window.__dayboot.walkieRTC, null, { timeout: 30000 });
  h.rec('walkie media layer is present', true);

  // The spine's wasm declares every webRTC door it calls; the worker provides the
  // names in RTC_DOORS (browser/lib/spine-imports.js). A door declared and not
  // provided is a LinkError at instantiate and the whole app fails to connect, so
  // the page itself is the witness: the spine says it loaded, and never that it failed.
  const spineSaid = () => h.logs.join('\n');
  for (let i = 0; i < 300 && !/wasm loaded|spine failed|boot failed/.test(spineSaid()); i++) await sleep(100);
  h.rec('the spine boots: every import its wasm declares is provided',
        /wasm loaded/.test(spineSaid()) && !/spine failed|boot failed/.test(spineSaid()),
        (spineSaid().match(/(spine failed|boot failed)[^\n]*/) || [''])[0]);

  // ── 1. local capture ────────────────────────────────────────────────
  const capture = await page.evaluate(async () => {
    const rtc = (await import('/day-boot.js')).walkieRTC;
    const once = (fn) => new Promise(res => fn(res));
    const mic = await once(cb => rtc.micGet(cb));
    const cam = await once(cb => rtc.camGet(cb));
    return {
      mic, cam,
      hasCam: rtc.hasCam(),
      micStartsMuted: rtc.tracks().mic ? rtc.tracks().mic.enabled === false : null,
      selfTile: !!document.getElementById('dial-tile-self'),
      selfHasStream: !!(document.getElementById('dial-tile-self') || {}).srcObject,
      selfIsMuted: (document.getElementById('dial-tile-self') || {}).muted,
    };
  });
  h.rec('microphone acquires', capture.mic === 1);
  h.rec('camera acquires', capture.cam === 1 && capture.hasCam === 1);
  // PTT semantics: you join muted and press to talk. A mic that arrived live
  // would put every joiner on air the instant they entered a room.
  h.rec('mic starts muted (push-to-talk)', capture.micStartsMuted === true);
  h.rec('self tile created with the camera stream',
        capture.selfTile === true && capture.selfHasStream === true);
  h.rec('self tile is muted (no feedback loop)', capture.selfIsMuted === true);

  // ── 2. two peer connections, real media flowing ─────────────────────
  const meshed = await page.evaluate(async () => {
    const rtc = (await import('/day-boot.js')).walkieRTC;
    const A = rtc.newPc(), B = rtc.newPc();
    window.__A = A; window.__B = B;
    window.__negotiations = { A: 0, B: 0 };
    A.onnegotiationneeded = () => window.__negotiations.A++;
    B.onnegotiationneeded = () => window.__negotiations.B++;

    // A is us: mic + camera go on BEFORE the offer, exactly as walkie-equip!
    // does. B stands in for the far end and is equipped the same way.
    // A offers, so it puts the video sender in its offer; B answers, and adopts
    // the offer's own (adding one of its own first would sit beside it).
    rtc.addMic(A); rtc.addCam(A);
    rtc.addMic(B);
    rtc.onRemoteMedia(B, 'peerA');          // B renders what A sends

    let candidates = 0;
    A.onicecandidate = e => { if (e.candidate) { candidates++; B.addIceCandidate(e.candidate); } };
    B.onicecandidate = e => { if (e.candidate) A.addIceCandidate(e.candidate); };

    const offer = await new Promise(res => rtc.offer(A, res));
    await rtc.setRemote(B, offer);
    const answer = await new Promise(res => rtc.answer(B, res));
    await rtc.setRemote(A, answer);

    // wait for the connection to actually come up
    const deadline = Date.now() + 15000;
    while (A.connectionState !== 'connected' && Date.now() < deadline)
      await new Promise(r => setTimeout(r, 200));

    // a peer's tile follows the peer's own word (the walkie-cam signal), so it
    // waits for it even though the stream has already arrived
    const tileBeforeWord = !!document.getElementById('dial-tile-peerA');
    rtc.peerVideo('peerA', 1);

    const senders = A.getSenders().filter(s => s.track).map(s => s.track.kind).sort();
    const receivers = B.getReceivers().filter(r => r.track).map(r => r.track.kind).sort();
    return {
      state: A.connectionState, candidates,
      senders, receivers,
      tileBeforeWord,
      answererVideoDir: (B.getTransceivers().find(x => x.receiver.track.kind === 'video') || {}).currentDirection,
      answererVideoTransceivers: B.getTransceivers().filter(x => x.receiver.track.kind === 'video').length,
      tile: !!document.getElementById('dial-tile-peerA'),
      tileHasStream: !!(document.getElementById('dial-tile-peerA') || {}).srcObject,
      audioSink: !!document.getElementById('dial-audio-peerA'),
      signalling: [A.signalingState, B.signalingState],
    };
  });
  // ICE needs a gatherable network interface. A network-isolated sandbox
  // gathers ZERO candidates (gathering "complete", nothing emitted), so the
  // transport leg is untestable there — report that plainly instead of
  // failing a correct implementation or passing a broken one. Everything
  // below this line rides setRemoteDescription, not connectivity, so it stays
  // gated either way.
  if (meshed.candidates === 0) {
    h.info('no ICE candidates gathered — no usable network interface; '
         + 'transport leg unverified in this environment');
  } else {
    h.rec('peer connection establishes', meshed.state === 'connected', meshed.state);
  }
  h.rec('SDP exchange completes', meshed.signalling[0] === 'stable'
                               && meshed.signalling[1] === 'stable');
  h.rec('mic AND camera ride the same connection',
        JSON.stringify(meshed.senders) === '["audio","video"]', meshed.senders.join(','));
  h.rec('the far end receives both tracks, and only those',
        JSON.stringify(meshed.receivers) === '["audio","video"]', meshed.receivers.join(','));
  h.rec('the answerer sends video back too: it adopted the offer\'s video transceiver',
        meshed.answererVideoDir === 'sendrecv' && meshed.answererVideoTransceivers === 1,
        `${meshed.answererVideoDir} ×${meshed.answererVideoTransceivers}`);
  h.rec('a peer\'s tile waits for the peer to say it is sending video',
        meshed.tileBeforeWord === false);
  h.rec('…and appears, with its stream, once it does',
        meshed.tile === true && meshed.tileHasStream === true);
  h.rec('a remote audio sink appears', meshed.audioSink === true);

  // ── 3. the mic flips; the camera STOPS, and the call carries on as audio ─
  const degrade = await page.evaluate(async () => {
    const rtc = (await import('/day-boot.js')).walkieRTC;
    const A = window.__A;
    const negBefore = window.__negotiations.A;
    const tx = A.getTransceivers().length, senders = A.getSenders().length;
    rtc.micEnabled(1);
    const midMic = rtc.tracks().mic.enabled;
    const oldCam = rtc.tracks().cam;

    rtc.camStop();                                  // what walkie-cam! does, then…
    rtc.replaceVideo(A, 0);                         // …empties the video sender
    await new Promise(r => setTimeout(r, 400));
    const videoSender = A.getTransceivers().find(x => x.receiver.track.kind === 'video').sender;
    const audioSender = A.getTransceivers().find(x => x.receiver.track.kind === 'audio').sender;
    const off = {
      camReleased: oldCam.readyState === 'ended' && rtc.tracks().cam === null,
      senderEmpty: videoSender.track === null,
      audioStillLive: !!audioSender.track && audioSender.track.readyState === 'live',
      selfTileGone: !document.getElementById('dial-tile-self'),
      sameShape: A.getTransceivers().length === tx && A.getSenders().length === senders,
    };

    await new Promise(res => rtc.camGet(res));      // and back on: a fresh capture…
    rtc.replaceVideo(A, 0);                         // …into the SAME sender
    await new Promise(r => setTimeout(r, 400));
    const on = {
      newTrack: rtc.tracks().cam && rtc.tracks().cam !== oldCam && videoSender.track === rtc.tracks().cam,
      selfTileBack: !!document.getElementById('dial-tile-self'),
    };
    return { midMic, off, on, signalling: A.signalingState,
             newNegotiations: window.__negotiations.A - negBefore };
  });
  h.rec('talk flips the mic track', degrade.midMic === true);
  h.rec('camera off releases the capture — the track ends, the light goes out',
        degrade.off.camReleased === true);
  h.rec('…the video sender empties and the mic keeps going: the call degrades to audio',
        degrade.off.senderEmpty === true && degrade.off.audioStillLive === true);
  h.rec('…and our own tile goes with the camera', degrade.off.selfTileGone === true);
  h.rec('…without a new senders or transceivers', degrade.off.sameShape === true);
  h.rec('camera on again is a fresh capture in the same sender',
        degrade.on.newTrack === true && degrade.on.selfTileBack === true);
  h.rec('camera off and on never renegotiate',
        degrade.signalling === 'stable' && degrade.newNegotiations === 0,
        `state=${degrade.signalling} negotiationneeded=${degrade.newNegotiations}`);

  // ── 4. screen share via replaceTrack — the no-renegotiation property ─
  // getDisplayMedia under --use-fake-ui-for-media-stream returns the fake
  // device without a picker. If a chromium build declines it we say so rather
  // than silently passing.
  const shared = await page.evaluate(async () => {
    const rtc = (await import('/day-boot.js')).walkieRTC;
    const negotiationsBefore = { ...window.__negotiations };
    const ok = await new Promise(res => rtc.screenGet(res));
    if (ok !== 1) return { ok };
    const camTrack = window.__A.getSenders()
      .find(s => s.track && s.track.kind === 'video').track;
    rtc.replaceVideo(window.__A, 1);
    await new Promise(r => setTimeout(r, 600));
    const nowTrack = window.__A.getSenders()
      .find(s => s.track && s.track.kind === 'video').track;
    const swapped = nowTrack !== camTrack && nowTrack === rtc.tracks().screen;
    rtc.replaceVideo(window.__A, 0);
    rtc.screenStop();                               // the real flow ends the capture too
    await new Promise(r => setTimeout(r, 400));
    const backTrack = window.__A.getSenders()
      .find(s => s.track && s.track.kind === 'video').track;
    return {
      ok, swapped, restored: backTrack === rtc.tracks().cam,
      signalling: window.__A.signalingState,
      newNegotiations: window.__negotiations.A - negotiationsBefore.A,
      senders: window.__A.getSenders().filter(s => s.track).length,
    };
  });
  if (shared.ok !== 1) {
    h.info('getDisplayMedia unavailable in this chromium — screen share unverified');
    h.rec('screen share swaps the video sender', false, 'getDisplayMedia declined');
  } else {
    h.rec('screen share swaps the video sender', shared.swapped === true);
    h.rec('stopping the share restores the camera', shared.restored === true);
    // the property the whole mesh design rests on
    h.rec('screen share does NOT renegotiate',
          shared.signalling === 'stable' && shared.newNegotiations === 0,
          `state=${shared.signalling} negotiationneeded=${shared.newNegotiations}`);
    h.rec('sender count unchanged by the swap', shared.senders === 2);
  }

  // ── 4b. the video budget follows the room, and the servers follow the gateway ─
  // Every video sender is cut to the plan for the number of peers held
  // (app/voice/mesh-plan.ts), at each change of that number, and the plan changes
  // no negotiation. The ICE servers a pc is made with are the ones the spine
  // handed over (setIce): the page names none.
  const budget = await page.evaluate(async () => {
    const rtc = (await import('/day-boot.js')).walkieRTC;
    const { videoPlan } = await import('/app/voice/mesh-plan.js');
    const rate = (pc) => {
      const tr = pc.getTransceivers().find(x => x.receiver.track.kind === 'video');
      const e = tr && tr.sender.getParameters().encodings;
      return e && e[0] ? { max: e[0].maxBitrate, scale: e[0].scaleResolutionDownBy } : null;
    };
    const settle = () => new Promise(r => setTimeout(r, 150));
    const negBefore = window.__negotiations.A;
    const at2 = rate(window.__A);
    const C = rtc.newPc();                                // a third peer: the plan for three
    await settle();
    const at3 = rate(window.__A);
    rtc.closePc(C);                                       // …and back to the plan for two
    await settle();
    const back2 = rate(window.__A);
    rtc.setIce(JSON.stringify([{ urls: 'stun:ice.test.invalid:3478' }]));
    const D = rtc.newPc();
    const iced = D.getConfiguration().iceServers.map(x => [].concat(x.urls).join());
    rtc.closePc(D);
    rtc.setIce('not json');                               // a bad list is no list, never a crash
    const E = rtc.newPc();
    const bare = E.getConfiguration().iceServers.length;
    rtc.closePc(E);
    return {
      plan2: videoPlan(2), plan3: videoPlan(3), at2, at3, back2, iced, bare,
      newNegotiations: window.__negotiations.A - negBefore,
    };
  });
  h.rec('a video sender carries the plan for the peers held',
        budget.at2 && budget.at2.max === budget.plan2.maxBitrate && budget.at2.scale === budget.plan2.scaleDown,
        JSON.stringify([budget.at2, budget.plan2]));
  h.rec('a third peer reshapes the first sender to the plan for three',
        budget.at3 && budget.at3.max === budget.plan3.maxBitrate && budget.at3.max < budget.at2.max,
        JSON.stringify([budget.at3, budget.plan3]));
  h.rec('…and it comes back when that peer leaves',
        budget.back2 && budget.back2.max === budget.plan2.maxBitrate);
  h.rec('reshaping a sender renegotiates nothing', budget.newNegotiations === 0, String(budget.newNegotiations));
  h.rec('a peer connection is made with the servers the spine handed over',
        JSON.stringify(budget.iced) === '["stun:ice.test.invalid:3478"]', JSON.stringify(budget.iced));
  h.rec('a list that does not parse leaves no servers', budget.bare === 0, String(budget.bare));

  // ── 5. teardown leaves nothing behind ───────────────────────────────
  const cleaned = await page.evaluate(async () => {
    const rtc = (await import('/day-boot.js')).walkieRTC;
    rtc.dropMedia('peerA');
    const afterOne = {
      tile: !!document.getElementById('dial-tile-peerA'),
      audio: !!document.getElementById('dial-audio-peerA'),
    };
    const stageWithSelf = !!document.getElementById('dial-stage');
    rtc.camStop();                                  // the last video on the call stops…
    const stageGone = !document.getElementById('dial-stage');   // …and the box goes with it
    await new Promise(res => rtc.camGet(res));      // a real camera for the teardown to find
    rtc.dropAllMedia();
    return {
      afterOne, stageWithSelf, stageGone,
      grid: !!document.getElementById('dial-tiles'),
      cam: !!rtc.tracks().cam,
      screen: !!rtc.tracks().screen,
    };
  });
  h.rec('dropping one peer removes its tile and sink',
        cleaned.afterOne.tile === false && cleaned.afterOne.audio === false);
  h.rec('the stage stands while any video does, and goes when the last stops',
        cleaned.stageWithSelf === true && cleaned.stageGone === true);
  h.rec('leaving tears down the whole media surface',
        cleaned.grid === false && cleaned.cam === false && cleaned.screen === false);

  // ── the orb's status line is the orb's while it listens ─────────────────
  // core's hint() writes the same #voicestate with every reply the app raises;
  // a share-bar declare landing mid-hold must not replace "listening"
  await page.evaluate(() => document.getElementById('face-time').click()); await sleep(400);
  const vs = () => page.evaluate(() => document.getElementById('voicestate').textContent);
  const mb = await (await page.$('#micbtn')).boundingBox();
  await page.mouse.move(mb.x + mb.width / 2, mb.y + mb.height / 2); await page.mouse.down(); await sleep(600);
  const held = await vs();
  h.rec('holding the orb mic says listening and marks the row busy',
        /^listening/.test(held) && await page.evaluate(() => document.getElementById('voicerow').classList.contains('busy')), held);
  await page.fill('#sharebar .share-name', 'bricks'); await page.press('#sharebar .share-name', 'Enter'); await sleep(150);
  const during = await vs();
  h.rec('…and a share-bar declare landing mid-hold leaves the orb\'s line alone', /^listening/.test(during), during);
  // every hold-to-speak mic shares ONE dance (voice/audio.ts pressToSpeak):
  // the hold can't become a scroll, and recording looks the same everywhere
  const micLook = await page.evaluate(() => ['micbtn', 'sbmic'].map(id => {
    const b = document.getElementById(id), cs = getComputedStyle(b);
    return { id, touch: cs.touchAction, rec: b.classList.contains('rec'), anim: cs.animationName };
  }));
  h.rec('the orb mic, held, pulses and refuses touch scrolling',
        micLook[0].rec && micLook[0].anim === 'recpulse' && micLook[0].touch === 'none', JSON.stringify(micLook[0]));
  h.rec('the share-bar mic refuses touch scrolling too, idle or not — the same dance',
        micLook[1].touch === 'none', JSON.stringify(micLook[1]));
  await page.mouse.up(); await sleep(300);
  const after = await vs();
  h.rec('…and release hands the line to the next state — transcribing (still the orb\'s) or idle (hint\'s again)',
        await page.evaluate(a => document.getElementById('voicerow').classList.contains('busy') === /^(listening|transcribing|thinking)/.test(a), after), after);

  await page.screenshot({ path: 'tests/ux/_artifacts/day-walkie.png' }).catch(() => {});
  if (h.errs.length) h.info('page errors: ' + JSON.stringify(h.errs.slice(0, 4)));
} catch (e) {
  h.rec('fatal', false, e.message);
} finally {
  await browser.close();
  closeServer();
}

summarize(h, [
  'walkie media layer is present',
  'the spine boots: every import its wasm declares is provided',
  'microphone acquires',
  'camera acquires',
  'mic starts muted (push-to-talk)',
  'self tile created with the camera stream',
  'SDP exchange completes',
  'mic AND camera ride the same connection',
  'the far end receives both tracks',
  'a remote video tile appears',
  'camera off releases the capture — the track ends, the light goes out',
  '…the video sender empties and the mic keeps going: the call degrades to audio',
  'camera off and on never renegotiate',
  'a video sender carries the plan for the peers held',
  'a peer connection is made with the servers the spine handed over',
  'leaving tears down the whole media surface',
]);
