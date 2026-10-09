// app/map-packs-view.ts — the "offline maps" block: each region the gateway
// offers, whether this device keeps it, and the one button that changes that.
//
// A Fragment for settings-sections' mountFragment: it redraws from the three
// signals in app/map-packs.ts (kept, landing, lastTrouble), so a download's
// progress and its end show without anyone asking.

import { html, type Fragment } from "./template.js";
import { signal } from "./reactive.js";
import { bytes } from "./storage-health.js";
import { regions, download, remove, kept, landing, lastTrouble, type Region } from "./map-packs.js";

const offered = signal<Region[] | null>(null);
const unreachable = signal<string | null>(null);
let asked = false;

function ask(): void {
  asked = true;
  regions().then(r => offered.set(r), e => unreachable.set(e instanceof Error ? e.message : String(e)));
}

/** "sanfrancisco" → "San Francisco" is not knowable; "berlin" → "Berlin" is. */
const title = (name: string): string => name.charAt(0).toUpperCase() + name.slice(1);

const btn = (label: string, fn: () => void, cls = ""): Fragment =>
  html`<button type="button" class="slot-btn${cls}" onclick=${fn}>${label}</button>`;

function row(r: Region): Fragment {
  const have = kept()[r.name];
  const landed = landing()[r.name];
  const state =
    landed !== undefined ? `${Math.floor(100 * landed / r.bytes)}% of ${bytes(r.bytes)}`
    : have !== undefined ? (have === r.bytes ? `kept, ${bytes(have)}` : `kept, ${bytes(have)} — the gateway now has ${bytes(r.bytes)}`)
    : `${bytes(r.bytes)}, to zoom ${r.maxZoom}`;
  const act =
    landed !== undefined ? ""
    : have !== undefined ? html`${have !== r.bytes ? btn("update", () => { void remove(r.name).then(() => download(r)).catch(() => {}); }, " on") : ""}
                                ${btn("let go", () => { void remove(r.name); })}`
    : btn("keep on this device", () => { void download(r).catch(() => {}); }, " on");
  return html`
    <li class="pack-row">
      <span class="pack-name">${title(r.name)}</span>
      <span class="pack-state">${state}</span>
      <span class="pack-act">${act}</span>
    </li>`;
}

export function mapPacksBlock(): Fragment {
  if (!asked) ask();
  const list = offered();
  const trouble = lastTrouble();
  return html`
    <div class="packs">
      ${list === null && !unreachable()
        ? html`<p class="pack-note">asking the gateway which regions it offers…</p>`
        : ""}
      ${unreachable()
        ? html`<p class="pack-note">the gateway's region list is out of reach (${unreachable()}); what this device already keeps still draws.</p>`
        : ""}
      ${list && list.length === 0
        ? html`<p class="pack-note">this gateway offers no regions yet.</p>`
        : ""}
      ${list && list.length ? html`<ul class="pack-list">${list.map(row)}</ul>` : ""}
      ${trouble ? html`<p class="pack-note pack-trouble">${title(trouble.name)}: stopped (${trouble.why}) — keep again to resume where it was.</p>` : ""}
    </div>`;
}
