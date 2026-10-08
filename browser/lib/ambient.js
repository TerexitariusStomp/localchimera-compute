// browser/lib/ambient.js — generative background music + the orb that plays it.
//
// No assets, no streams, no network: an endless ambient piece
// synthesized in WebAudio. When the day dial is on the page the music
// is BUILT FROM the time-view — the day's need-shares become the
// partials of ONE living tone, voiced over a continuous tonic drone
// (root + just octave + fifth) that glides between fundamentals: the
// dial's overtone-series rim marks made literally audible as the
// harmonics of a single sounding pitch (see readDial / startDrone).
// Just intonation throughout; the kalimba sings the major-third and
// seventh harmonics the ladder omits. Without the dial it falls back to
// a warm modal field. Different every time, never repeating, Tor-clean.
//
// The player is one breathing orb, bottom-right: click toggles,
// wheel adjusts volume (discoverable, never in the way). State
// persists in localStorage; resumes on the first gesture of the next
// visit (autoplay policy).
//
// An ES module: <script type="module" src="lib/ambient.js"></script> mounts
// the orb; the settings face imports { toggle, setVolume, playing, volume }.

import { spectrum } from "../app/spectrum.js";
// the guarded door: a blocked or full store reads as the default and keeps
// this module — and the settings face that imports it — loading
import { readStr, writeStr } from "../app/store.js";
import { K } from "../app/keys.js";

// ── the piece ──────────────────────────────────────────────────────
// Warm G-major field — "less work, more play": roots amble through
// I → IV → V → vi; pads voice root/third/sixth an octave up (airy,
// barely any sub); kalimba-ish sparkles walk the major pentatonic,
// sometimes in thirds. Morning light, not dusk.
const ROOTS = [98.0, 130.81, 146.83, 123.47];        // G2 C3 D3 B2(em-ish)
const COLOUR = [[2, 2.5, 3.33], [2, 3, 3.33], [2, 2.5, 4]]; // 3rd/6th voicings
const PENTA = [392.0, 440.0, 493.88, 587.33, 659.25, // G4 A4 B4 D5 E5
               783.99, 880.0];                       // G5 A5

// ── the time-view's harmonics ───────────────────────────────────────
// When the dial is present, the music is BUILT FROM what it shows.
// The dial's rim marks are the overtone series; the hand reading the
// band-shares is a spectrum. We voice ONE low tone whose partials are
// exactly those marks — and each partial's loudness is the share of
// the need mapped to it. Night (rest dominant) → the low partials
// ring; midday (movement/learning peak) → the high ones brighten.
// The fundamental ambles up the pentatonic across the day, so the
// root walks with the hours; σ (personal→social) flattens the
// spectrum toward even, exactly as the social dial flattens shares.
const LADDER = [2, 3, 4, 6, 8, 12];        // D∕2 D∕3 D∕4 D∕6 D∕8 D∕12
const FUND = 49.0;                          // G1 — the day's ground tone
const WALK = [1, 9 / 8, 5 / 4, 3 / 2, 5 / 3]; // major pentatonic, just

// a band's colour → warmth in [0,1]: red/gold warm (→1, richer
// harmonics), blue/violet cool (→0, purer sine). Reads #rrggbb.
function warmth(hex) {
  if (typeof hex !== "string") return 0.5;
  const m = hex.replace(/[^0-9a-f]/gi, "");
  if (m.length < 6) return 0.5;
  const r = parseInt(m.slice(0, 2), 16), b = parseInt(m.slice(4, 6), 16);
  return Math.min(1, Math.max(0, 0.5 + (r - b) / 320));
}

function readDial() {
  let st; try { st = spectrum(); } catch (_) { return null; }
  if (!st || !Array.isArray(st.bands) || !st.bands.length) return null;
  const t = Math.max(0, Math.min(24, st.t || 0));
  const sigma = Math.max(0, Math.min(1, st.sigma || 0));
  // register tracks the pinch: an hour-turn rings high and quick, a
  // year-turn low and vast. Shift octaves by log2(day∕turn), ±2.
  const turnH = st.turnH > 0 ? st.turnH : 24;
  const shift = Math.max(-2, Math.min(2, Math.log2(24 / turnH) * 0.5));
  // fundamental walks the pentatonic over the turn, lifted by register
  const fundamental = FUND * WALK[Math.min(WALK.length - 1,
                                 (t / 24 * WALK.length) | 0)]
                      * Math.pow(2, shift);
  // bands → partials, in dial order; share = partial gain (normalized
  // to the loudest), flattened toward even by σ; colour → warmth.
  const bands = st.bands.slice(0, LADDER.length);
  const peak = Math.max(1e-6, ...bands.map(b => b.share));
  const mean = bands.reduce((a, b) => a + b.share, 0) / bands.length / peak;
  const partials = bands.map((b, k) => ({
    n: LADDER[k],
    g: (b.share / peak) * (1 - sigma) + mean * sigma,
    warm: warmth(b.col),
  })).filter(p => p.g > 0.04);
  // pace: high register breathes a touch quicker, low vaster
  const pace = Math.pow(2, -shift * 0.35);
  return { fundamental, partials, sigma, pace };
}

let ctx = null, master = null, padBus = null, running = false;
let chordTimer = null, sparkTimer = null, currentRoot = 0;
let volume = +(readStr(K.ambientVolume) || 0.5); // 0..1 UI scale

const VOL = () => 0.22 * volume * volume; // perceptual-ish curve

function buildGraph() {
  ctx = new (window.AudioContext || window.webkitAudioContext)();
  master = ctx.createGain();
  master.gain.value = 0;

  // gentle glue + safety ceiling
  const comp = ctx.createDynamicsCompressor();
  comp.threshold.value = -24; comp.ratio.value = 4;

  // the space: two cross-fed delays, darkened in the loop
  const wet = ctx.createGain(); wet.gain.value = 0.3;
  const d1 = ctx.createDelay(2); d1.delayTime.value = 0.31;
  const d2 = ctx.createDelay(2); d2.delayTime.value = 0.47;
  const fb1 = ctx.createGain(); fb1.gain.value = 0.3;
  const fb2 = ctx.createGain(); fb2.gain.value = 0.28;
  const dark = ctx.createBiquadFilter();
  dark.type = "lowpass"; dark.frequency.value = 1900;
  d1.connect(fb1).connect(dark).connect(d2);
  d2.connect(fb2).connect(d1);
  d1.connect(wet); d2.connect(wet);

  // a slow breath on the master tone
  const tone = ctx.createBiquadFilter();
  tone.type = "lowpass"; tone.frequency.value = 2600; tone.Q.value = 0.4;
  const lfo = ctx.createOscillator(); lfo.frequency.value = 0.02;
  const lfoAmt = ctx.createGain(); lfoAmt.gain.value = 350;
  lfo.connect(lfoAmt).connect(tone.frequency); lfo.start();

  padBus = ctx.createGain(); padBus.gain.value = 1;
  padBus.connect(tone); padBus.connect(d1);
  wet.connect(tone);
  tone.connect(comp).connect(master).connect(ctx.destination);
}

// one pad voice: detuned triangles + a sine an octave under,
// breathing in over ~6s and out over ~9s
function padNote(freq, when, dur) {
  const g = ctx.createGain();
  g.gain.setValueAtTime(0, when);
  g.gain.linearRampToValueAtTime(0.04, when + 4);
  g.gain.setValueAtTime(0.04, when + dur - 6);
  g.gain.linearRampToValueAtTime(0, when + dur);
  const lead = ctx.createOscillator();          // sine-led = light
  lead.type = "sine"; lead.frequency.value = freq;
  lead.connect(g); lead.start(when); lead.stop(when + dur + 0.1);
  const shimmer = ctx.createOscillator();
  const shg = ctx.createGain(); shg.gain.value = 0.35;
  shimmer.type = "triangle"; shimmer.frequency.value = freq;
  shimmer.detune.value = 5;
  shimmer.connect(shg).connect(g);
  shimmer.start(when); shimmer.stop(when + dur + 0.1);
  const warm = ctx.createOscillator();          // a whisper of ground
  const wg = ctx.createGain(); wg.gain.value = 0.25;
  warm.type = "sine"; warm.frequency.value = freq / 2;
  warm.connect(wg).connect(g); warm.start(when); warm.stop(when + dur + 0.1);
  g.connect(padBus);
}

// a slow, even shimmer: pin the beat between a voice and its detuned
// twin to ~1 Hz REGARDLESS of register (cents would beat fast up high
// and slow down low — ugly; constant-Hz beating is the hypnotic kind).
const BEAT = 0.9;                          // Hz — the breath inside a tone

// one breathing partial of the day's fundamental, gain = its share,
// TIMBRE = the need's warmth: a cool need rings as a pure sine; a warm
// need grows a genuinely richer harmonic series — its own octave and
// fifth roll in (the natural overtones of a brighter timbre), each
// shimmering against a Hz-pinned twin. Stereo: lows centred and
// grounding, highs spread wide and airy (pan rises with the partial).
function partialNote(freq, peak, warm, when, dur, pan) {
  const g = ctx.createGain();
  g.gain.setValueAtTime(0, when);
  g.gain.linearRampToValueAtTime(0.06 * peak, when + 5);
  g.gain.setValueAtTime(0.06 * peak, when + dur - 7);
  g.gain.linearRampToValueAtTime(0, when + dur);
  // a voice + its twin, beating slowly; warmth opens the twin's gain
  const voice = (f, type, gain, beat) => {
    const o = ctx.createOscillator(); o.type = type; o.frequency.value = f + beat;
    const vg = ctx.createGain(); vg.gain.value = gain;
    o.connect(vg).connect(g); o.start(when); o.stop(when + dur + 0.1);
  };
  voice(freq, warm > 0.55 ? "triangle" : "sine", 1, 0);
  if (warm > 0.3) voice(freq, "triangle", 0.14 + 0.28 * warm, BEAT);   // shimmer twin
  if (warm > 0.45) voice(freq * 2, "sine", 0.10 * warm, BEAT * 1.5);   // its octave
  if (warm > 0.7)  voice(freq * 3, "sine", 0.05 * (warm - 0.5) * 2, BEAT * 2); // its fifth
  const p = ctx.createStereoPanner ? ctx.createStereoPanner() : null;
  if (p) { p.pan.value = pan || 0; g.connect(p).connect(padBus); }
  else g.connect(padBus);
}

// ── the drone: the fundamental itself, made audible ─────────────────
// The band ladder starts at partial 2 — so the true fundamental (n=1)
// never sounds, and the spectrum is a halo with no floor. Voice it as
// a continuous tonic drone — root + just octave + just fifth, a
// tanpura ground — and the breathing partials become the overtones of
// ONE living tone. The drone GLIDES between fundamentals (portamento)
// so the walk up the pentatonic is a slow singing line, never a jump.
let drone = null;       // { gain, o1, o2, o3 } while playing
let lastFund = FUND;

function startDrone(f0) {
  if (drone || !ctx) return;
  lastFund = f0;
  const gain = ctx.createGain();
  gain.gain.setValueAtTime(0, ctx.currentTime);
  gain.gain.linearRampToValueAtTime(0.05, ctx.currentTime + 8);
  const mk = (mult, lvl) => {
    const o = ctx.createOscillator(); o.type = "sine";
    o.frequency.value = f0 * mult;
    const lg = ctx.createGain(); lg.gain.value = lvl;
    o.connect(lg).connect(gain); o.start();
    return o;
  };
  const o1 = mk(1, 1), o2 = mk(2, 0.45), o3 = mk(1.5, 0.30);
  gain.connect(padBus);
  drone = { gain, o1, o2, o3 };
}
function glideDrone(f0) {
  if (!drone) return;
  lastFund = f0;
  const t = ctx.currentTime, glide = 6;     // a slow portamento
  drone.o1.frequency.linearRampToValueAtTime(f0, t + glide);
  drone.o2.frequency.linearRampToValueAtTime(f0 * 2, t + glide);
  drone.o3.frequency.linearRampToValueAtTime(f0 * 1.5, t + glide);
}
function stopDrone() {
  if (!drone) return;
  const d = drone; drone = null;
  d.gain.gain.cancelScheduledValues(ctx.currentTime);
  d.gain.gain.linearRampToValueAtTime(0, ctx.currentTime + 1.5);
  const at = ctx.currentTime + 1.9;
  d.o1.stop(at); d.o2.stop(at); d.o3.stop(at);
}

let liveSpectrum = null;        // the partials currently sounding (for sparkles)

function nextChord() {
  if (!running) return;
  const dial = readDial();
  const dur = 18 + Math.random() * 10;
  const t = ctx.currentTime + 0.05;
  if (dial) {
    // THE TIME-VIEW MADE AUDIBLE: the day's needs as the partials of
    // one tone, each as loud as its share where the hand stands, each
    // timbred by its warmth; the register and pace set by the pinch.
    // The drone glides to this fundamental so it all reads as ONE tone.
    glideDrone(dial.fundamental);
    liveSpectrum = dial.partials.map(p => dial.fundamental * p.n);
    const pdur = dur * (dial.pace || 1);
    dial.partials.forEach((p, i) => {
      // lows centred and grounding, highs spread wide and airy
      const pan = Math.max(-0.7, Math.min(0.7,
        (i % 2 ? 1 : -1) * Math.min(0.7, 0.12 * p.n)));
      partialNote(dial.fundamental * p.n, p.g, p.warm, t, pdur, pan);
    });
    chordTimer = setTimeout(nextChord, (pdur - 6) * 1000);
    return;
  } else {
    // standalone: the warm modal field, grounded by a gliding drone
    liveSpectrum = null;
    const root = ROOTS[currentRoot];
    currentRoot = (currentRoot + (Math.random() < 0.7 ? 1 : 2)) % ROOTS.length;
    glideDrone(root / 2);                 // the field's own ground tone
    const voicing = COLOUR[(Math.random() * COLOUR.length) | 0];
    for (const ratio of voicing) padNote(root * ratio, t, dur);
  }
  chordTimer = setTimeout(nextChord, (dur - 6) * 1000); // overlap = crossfade
}

// a kalimba note: quick bloom, woody decay; sometimes its third
// answers a heartbeat later (play, not solemnity)
function pluck(f, t, peak) {
  const o = ctx.createOscillator(); o.type = "triangle"; o.frequency.value = f;
  const g = ctx.createGain();
  g.gain.setValueAtTime(0, t);
  g.gain.linearRampToValueAtTime(peak, t + 0.008);
  g.gain.exponentialRampToValueAtTime(0.0004, t + 1.2 + Math.random() * 1.0);
  const pan = ctx.createStereoPanner ? ctx.createStereoPanner() : null;
  if (pan) { pan.pan.value = Math.random() * 1.2 - 0.6; o.connect(g).connect(pan).connect(padBus); }
  else o.connect(g).connect(padBus);
  o.start(t); o.stop(t + 3);
}
function sparkle() {
  if (!running) return;
  const t = ctx.currentTime + 0.02;
  const peak = 0.035 + Math.random() * 0.045;
  if (liveSpectrum && liveSpectrum.length && drone) {
    // the pads voice the ladder (2,3,4,6,8,12) — octaves and fifths,
    // NO major third, NO seventh. The kalimba sings exactly those
    // MISSING overtones (5th, 7th, 9th, 11th harmonics, just-tuned),
    // colouring the drone with what the spectrum itself can't reach.
    const MISSING = [5, 7, 9, 11, 5 / 2, 7 / 4];
    let f = lastFund * MISSING[(Math.random() * MISSING.length) | 0];
    while (f < 330) f *= 2;                       // lift into voice
    while (f > 1100) f /= 2;
    pluck(f, t, peak);
    if (Math.random() < 0.3) pluck(f * 1.5, t + 0.13, peak * 0.6); // a fifth
  } else {
    const i = (Math.random() * PENTA.length) | 0;
    pluck(PENTA[i], t, peak);
    if (Math.random() < 0.35) pluck(PENTA[(i + 2) % PENTA.length], t + 0.13, peak * 0.7);
  }
  sparkTimer = setTimeout(sparkle, 2200 + Math.random() * 5500);
}

function start() {
  if (!ctx) buildGraph();
  ctx.resume();
  running = true;
  master.gain.cancelScheduledValues(ctx.currentTime);
  master.gain.linearRampToValueAtTime(VOL(), ctx.currentTime + 4);
  const seed = readDial();
  startDrone(seed ? seed.fundamental : ROOTS[currentRoot] / 2);
  nextChord();
  sparkTimer = setTimeout(sparkle, 1500);
  writeStr(K.ambientOn, "1");
  orb.classList.add("playing");
}

function stop() {
  running = false;
  clearTimeout(chordTimer); clearTimeout(sparkTimer);
  stopDrone();
  if (ctx) {
    master.gain.cancelScheduledValues(ctx.currentTime);
    master.gain.linearRampToValueAtTime(0, ctx.currentTime + 1.5);
    setTimeout(() => { if (!running && ctx) ctx.suspend(); }, 1800);
  }
  writeStr(K.ambientOn, "0");
  orb.classList.remove("playing");
}

function toggle() { running ? stop() : start(); }

function setVolume(v) {
  volume = Math.min(1, Math.max(0, v));
  writeStr(K.ambientVolume, String(volume));
  if (running && ctx)
    master.gain.linearRampToValueAtTime(VOL(), ctx.currentTime + 0.3);
  orb.style.setProperty("--amb-level", String(0.35 + volume * 0.65));
}

// ── the orb ────────────────────────────────────────────────────────
const style = document.createElement("style");
style.textContent = `
  .ambient-orb { position: fixed; top: 8px; left: 50%;
    margin-left: -11px;
    width: 22px; height: 22px; border-radius: 50%; cursor: pointer;
    z-index: 900; opacity: 0.35; --amb-level: 0.7;
    background: radial-gradient(circle at 35% 35%,
      rgba(212,184,48,0.85), rgba(122,176,212,0.5) 75%);
    box-shadow: 0 0 0 1px rgba(255,255,255,0.10);
    transition: opacity .4s, transform .25s; }
  .ambient-orb:hover { opacity: 0.85; transform: scale(1.12); }
  .ambient-orb.playing { opacity: calc(0.55 * var(--amb-level) + 0.25);
    animation: ambient-breathe 7s ease-in-out infinite; }
  .ambient-orb.playing::after { content: ""; position: absolute;
    inset: -6px; border-radius: 50%;
    border: 1px solid rgba(212,184,48,0.35);
    animation: ambient-ring 7s ease-out infinite; }
  @keyframes ambient-breathe {
    0%, 100% { transform: scale(1); }
    50%      { transform: scale(1.10); } }
  @keyframes ambient-ring {
    0%   { transform: scale(0.8); opacity: 0.7; }
    70%  { transform: scale(1.45); opacity: 0; }
    100% { transform: scale(1.45); opacity: 0; } }`;
document.head.appendChild(style);

const orb = document.createElement("div");
orb.className = "ambient-orb";
orb.title = "ambient — click to play, wheel for volume";
orb.addEventListener("click", toggle);
orb.addEventListener("wheel", e => {
  e.preventDefault();
  setVolume(volume - Math.sign(e.deltaY) * 0.08);
}, { passive: false });
(document.body
   ? Promise.resolve()
   : new Promise(r => addEventListener("DOMContentLoaded", r)))
  .then(() => document.body.appendChild(orb));

setVolume(volume);

// resume across visits — on the first gesture (autoplay policy)
if (readStr(K.ambientOn) === "1") {
  const once = () => { if (!running) start(); };
  addEventListener("pointerdown", once, { once: true });
}

export { toggle, setVolume };
export const playing = () => running;
export const level = () => volume;
