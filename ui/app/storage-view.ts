// app/storage-view.ts — the settings rows for this device's storage: how much
// is used, whether the browser has promised to keep it, whether the dial is
// installed, and what on the device is waiting for the person.
//
// The rows read signals (app/storage-health.ts, app/install.ts) and the
// settings pane draws rows inside its own effect, so a promise granted or an
// install finished repaints the section by itself.

import type { SettingRow } from "./settings.js";
import { persisted, usageNow, refreshHealth, ensurePersistent, bytes } from "./storage-health.js";
import { matters } from "./attention.js";
import { shell } from "./pwa.js";
import { installBlock } from "./install.js";
import { render } from "./template.js";
import { effect } from "./reactive.js";

// One element for the page's life, re-rendered by its own effect: the pane
// calls rows() afresh on every draw, and a row built inline there would mint
// a new element and a new effect each time (settings-sections.ts mountFragment).
let installNode: HTMLElement | null = null;
const installEl = (): HTMLElement => {
  if (!installNode) {
    const el = installNode = document.createElement("div");
    effect(() => render(el, installBlock()));
  }
  return installNode;
};

/**
 * This engine's standing, as one line: whether the page is cross-origin
 * isolated (the speech runtime's threads need it), whether the service worker
 * controls the page (offline use), whether WebGPU is there, the device's
 * memory as the engine reports it, and whether this is the installed shell.
 */
export function deviceFacts(): string {
  const nav = navigator as Navigator & { deviceMemory?: number; gpu?: unknown };
  const yes = (b: boolean): string => (b ? "yes" : "no");
  return [
    `isolated: ${yes(globalThis.crossOriginIsolated === true)}`,
    `offline worker: ${yes(!!nav.serviceWorker?.controller)}`,
    `WebGPU: ${yes(!!nav.gpu)}`,
    `memory: ${nav.deviceMemory ? nav.deviceMemory + " GB" : "not reported"}`,
    `app shell: ${yes(!!shell())}`,
  ].join(" · ");
}

let read = false;

export function storageRows(): SettingRow[] {
  // one reading per page life, taken when the section is first drawn
  if (!read) { read = true; void refreshHealth(); }

  const u = usageNow();
  const kept = persisted();
  const rows: SettingRow[] = [];

  // what is waiting on this device heads the section (app/attention.ts)
  for (const m of matters())
    rows.push(m.act ? { kind: "button", label: m.says, text: m.act.label, action: m.act.run }
                    : { kind: "note", text: m.says });

  rows.push({ kind: "note",
    text: u ? `${bytes(u.used)} used of the ${bytes(u.quota)} this browser allows.`
            : "This browser does not report how much is used." });

  if (kept === true)
    rows.push({ kind: "note", text: "The browser has promised to keep it: it is cleared only when you clear it." });
  else
    rows.push({ kind: "button", label: "keep what is stored here",
      note: kept === false
        ? "The browser may clear this device's copy when the disk runs short. Your passcode still opens your identity; what only this device holds would go."
        : "This browser makes no promise to keep it.",
      text: "ask the browser",
      action: () => { void ensurePersistent().then(refreshHealth); } });

  rows.push({ kind: "custom", build: installEl });

  // what this engine gives the app, in one line a person can read out: the
  // facts a question about speech, offline use or the installed app turns on
  rows.push({ kind: "note", text: deviceFacts() });

  return rows;
}
