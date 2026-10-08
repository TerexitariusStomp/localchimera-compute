// app/projection.ts — the dial, as a small JSON for surfaces that cannot run it.
//
// THIN RENDERERS: home-screen widgets (app/), watch faces (browser/watch/),
// e-ink — surfaces that can fill a polygon but cannot run d3
// (docs/dev/clock-projection.md). What ships is LAYOUT, never curves: per-band
// cumulative edges and met boundaries in permil, M+1 closed samples around the
// turn. The receiver ticks the hand itself and draws area-true, r(f) = R√f.
//
// Top level only — the needs ARE the dial, and a widget that showed the
// children of a focus would be showing something the wearer never chose.
//
// Three destinations, one shape, and that is the whole point of the file:
//   · window.dialProjection — read by lib/ambient.js and by anything on the page
//   · the Capacitor bridge  — pushed on every data change, for the widget
//   · a Bangle watch        — over Web Bluetooth, at a coarser M
// A fourth would need no new code here.

import { shell } from './pwa.js';
import { S } from './state.js';
import { n, clamp01 } from './geom.js';
import { evs, pending } from './events.js';
import { layout, spectrum, peakHours } from './bands.js';
import type { Sample } from './bands.js';
import type { DesireNode } from './desire.js';
import type { DayEvent } from './seam.js';

/**
 * One need's rhythm reading. `k` is the harmonic it is locked to, or 0 for
 * standing capacity — a need with no peak is not a need with a peak at zero,
 * and `lead` being null rather than 0 says the same thing again: there is no
 * quarter-period to anticipate by.
 */
export interface ProjectedNeed {
  id: string;
  name: string;
  col?: string;
  /** The dominant harmonic (1 circadian, 2 the commute pair…), 0 if unpeaked. */
  k: number;
  /** The whole spectrum [R̄_1 … R̄_6], rounded to a thousandth. */
  spec: number[];
  /** Peak hours of the turn, where the need is peaked at all. */
  peaks: number[];
  /** The quarter-period anticipation lead τ∕4k, null for standing capacity. */
  lead: number | null;
}

/**
 * An event, positionally: [t0, t1, label, kind, action, serves]. A tuple rather
 * than an object because this crosses to a watch over a 20-byte BLE MTU, and
 * six field names per event is most of the budget.
 */
export type ProjectedEvent = [number, number, string, string | undefined,
                              string | undefined, string | null];

/** A proposal is an event plus who it is from. */
export type ProjectedProposal = [...ProjectedEvent, string | undefined];

/** The whole dial, as a receiver reads it. */
export interface Projection {
  /** Schema version. Bump it when a receiver would misread the old shape. */
  v: number;
  /** Hours per turn the samples span. */
  turn: number;
  /** Sample count; the arrays below are M+1 long, closed around the turn. */
  m: number;
  /** Local wall-clock position within the turn, hours, to a hundredth. */
  at: number;
  /** Minutes east of UTC, so a receiver can label the samples. */
  tz: number;
  needs: ProjectedNeed[];
  /** Permil, M+1 samples: the cumulative edges and the met boundaries. */
  bands: { cum: number[][]; met: number[][] };
  events: ProjectedEvent[];
  proposals: ProjectedProposal[];
}

const q = (x: number): number => Math.round(1000 * clamp01(x));

const evRow = (e: DayEvent): ProjectedEvent =>
  [e.t0, e.t1, e.label, e.kind, e.action, e.serves || null];

/** The dial's current state, sampled M times around the turn. */
export function dialProjection(M = 96): Projection {
  // The spine is built at boot and its top level IS the dial, so both
  // assertions hold wherever a projection can be asked for. They are also what
  // the original did implicitly: layout() throws on an absent sibling set.
  const children = S.root!.children!;
  const lay = layout(children);              // at the current σ
  const samp = (f: (s: Sample) => number): number[] =>
    d3.range(M + 1).map(i => q(f(lay[Math.round(i * n / M)])));
  const d0 = new Date();
  return {
    v: 1, turn: 24, m: M,
    at: Math.round((d0.getHours() + d0.getMinutes() / 60 + d0.getSeconds() / 3600) * 100) / 100,
    tz: -d0.getTimezoneOffset(),
    needs: children.map((d: DesireNode, k: number) => {
      const share = (i: number): number => lay[i].cum[k + 1] - lay[i].cum[k];
      const spec = spectrum(share);
      const kb = spec.indexOf(d3.max(spec)!) + 1;
      const peaked = spec[kb - 1] >= 0.25;        // showRhythm's planning rule
      return { id: d.id, name: d.name, col: d.col,
               k: peaked ? kb : 0,                // 0 → standing capacity
               spec: spec.map(v => Math.round(v * 1000) / 1000),
               peaks: peaked ? peakHours(share).map(p => Math.round(p.t * 100) / 100) : [],
               lead: peaked ? 24 / (4 * kb) : null };
    }),
    bands: { cum: children.map((_, k) => samp(s => s.cum[k + 1])),
             met: children.map((_, k) => samp(s => s.met[k])) },
    events: evs.map(evRow),
    proposals: pending().map(p => [...evRow(p), p.from] as ProjectedProposal),
  };
}

/** The shell's projection plugin (ProjectionBridgePlugin.java in playnet-app). */
interface ProjectionBridge { setProjection(arg: { json: string }): void }

/**
 * Hand the widget a fresh projection. The bridge stores it and nudges every
 * thin renderer; a shell without the plugin just keeps the one it has, which is
 * why the whole thing sits inside a try.
 */
export function pushProjection(): void {
  const cap = shell();
  if (!cap) return;
  try {
    (cap.Plugins!.ProjectionBridge as ProjectionBridge).setProjection(
      { json: JSON.stringify(dialProjection(96)) });
  } catch (_) { /* shell without the plugin: the widget just stays put */ }
}

// ── send to watch (Web Bluetooth) ───────────────────────────────────────────
// The watch is a thin renderer of the projection and the PWA is its companion
// app — no native code anywhere. The push goes over the Nordic UART REPL
// exactly the way the Bangle app loader uploads apps: one echo-off line that
// writes Storage and calls the face's reload hook (browser/watch/bangle-clock.js).
// Web Bluetooth needs a secure context and a Chrome-family browser, so the
// button only appears where it can work.

const NUS    = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
const NUS_RX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";

/** How the send reports itself: a line of text, replaced as it advances. */
export type SendStatus = (message: string) => void;

async function sendToWatch(status: SendStatus, bt: Bluetooth): Promise<void> {
  const dev = await bt.requestDevice({ filters: [{ services: [NUS] }] });
  status("connecting…");
  const gatt = await dev.gatt.connect();
  try {
    const rx = await (await gatt.getPrimaryService(NUS)).getCharacteristic(NUS_RX);
    // \x03 clears any half-typed REPL input; \x10 = echo off for this line
    const line = "\x03\x10require(\"Storage\").writeJSON(\"playnet.proj.json\"," +
      JSON.stringify(dialProjection(48)) +
      ");if(global.PLAYNET_RELOAD)PLAYNET_RELOAD()\n";
    const enc = new TextEncoder().encode(line);
    for (let i = 0; i < enc.length; i += 20) {    // BLE-MTU-safe chunks;
      await rx.writeValue(enc.slice(i, i + 20));  // with-response = flow control
      status(`sending… ${Math.round(100 * i / enc.length)}%`);
    }
    status("sent ✓ — the face is live");
  } finally { gatt.disconnect(); }
}

/**
 * Publish the projection: to the page, to the shell, and — where Web Bluetooth
 * exists — behind a button that offers the watch.
 */
export function initProjection(): void {
  (window as { dialProjection?: typeof dialProjection }).dialProjection = dialProjection;
  pushProjection();
  const bt = navigator.bluetooth;
  if (!bt) return;
  d3.select("#watchrow").style("display", "block");
  d3.select("#towatch").on("click", () => {
    const st: SendStatus = s => { d3.select("#watchst").text(s); };
    // NotFoundError is the user dismissing the chooser — a cancellation, and
    // it clears the line rather than reporting a failure that did not happen.
    sendToWatch(st, bt).catch((e: Error) =>
      st(e.name === "NotFoundError" ? "" : "✗ " + e.message));
  });
}
