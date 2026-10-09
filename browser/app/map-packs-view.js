// app/map-packs-view.ts — "Offline maps": what this device keeps, and the way to keep more.
//
// A Fragment for settings-sections' mountFragment, redrawn from the signals
// in app/map-packs.ts (kept, landing, lastTrouble): the downloaded maps, each
// with its ⋮ (update when the gateway has a newer build, rename, view area,
// delete on a second tap — the pin book's idiom), the regions the gateway
// offers whole, and the one primary button, "Select your own map", which
// puts the frame over the live map (tabs/map/select-area.ts).
import { html } from "./template.js";
import { signal } from "./reactive.js";
import { bytes } from "./storage-health.js";
import { setFace } from "./faces.js";
import { closeAccount, openAccountPage } from "./account.js";
import { regions, keep, remove, rename, update, staler, freeName, kept, landing, lastTrouble } from "./map-packs.js";
import { enterSelectArea, AREA_MAXZOOM } from "./tabs/map/select-area.js";
const offered = signal(null);
const unreachable = signal(null);
/** The row whose ⋮ is open, and whether its rename field shows. */
const menuOpen = signal(null);
const renaming = signal(null);
let asked = false;
function ask(again = false) {
    asked = true;
    regions(again).then(r => { offered.set(r); unreachable.set(null); }, e => unreachable.set(e instanceof Error ? e.message : String(e)));
}
/** The gateway's region names are file names; these are what people call them. */
const TITLES = { sanfrancisco: "San Francisco", losangeles: "Los Angeles" };
export const title = (name) => TITLES[name] ?? name.charAt(0).toUpperCase() + name.slice(1);
const day = (iso) => iso ? new Date(iso).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" }) : "an unknown date";
const btn = (label, fn, cls = "") => html `<button type="button" class="slot-btn${cls}" onclick=${fn}>${label}</button>`;
/** Leave the sheet for the map and put the frame up; the download's end brings the list back. */
function selectOwn(fit) {
    closeAccount();
    setFace("map");
    enterSelectArea({ fit: fit?.bounds, onKept: () => openAccountPage("where") });
}
function keptRow(p, rs) {
    const stale = staler(p, rs);
    const open = menuOpen() === p.name;
    const state = `${bytes(p.bytes)} · the map of ${day(p.build)}${stale ? " · update available" : ""}`;
    const del = (e) => {
        const b = e.currentTarget;
        if (b.dataset.sure) {
            void remove(p.name);
            menuOpen.set(null);
            return;
        }
        b.dataset.sure = "1";
        b.textContent = "delete — sure?"; // a second tap, not a dialog
    };
    const menu = !open ? "" : html `
    <div class="pack-menu" onclick=${(e) => e.stopPropagation()}>
      ${renaming() === p.name
        ? html `<form class="pack-rename" onsubmit=${(e) => {
            e.preventDefault();
            const v = e.currentTarget.querySelector("input").value;
            rename(p.name, v).then(() => { renaming.set(null); menuOpen.set(null); }, err => lastTrouble.set({ name: p.name, why: err instanceof Error ? err.message : String(err) }));
        }}>
            <input type="text" maxlength="60" value="${p.name}" aria-label="name">
            <button type="submit" class="slot-btn on">rename</button>
          </form>`
        : ""}
      <div class="pack-acts">
        ${stale ? btn("update", () => { menuOpen.set(null); void update(p.name).catch(() => { }); }, " on") : ""}
        ${btn("rename", () => renaming.set(p.name))}
        ${btn("view area", () => selectOwn(p))}
        <button type="button" class="slot-btn pack-del" onclick=${del}>delete</button>
      </div>
    </div>`;
    return html `
    <li class="pack-row pack-kept">
      <span class="pack-badge" aria-hidden="true">✓</span>
      <span class="pack-body"><span class="pack-name">${p.name}</span><span class="pack-state">${state}</span></span>
      <button type="button" class="pack-more" title="update · rename · view · delete"
              onclick=${() => { menuOpen.set(open ? null : p.name); renaming.set(null); }}>⋮</button>
      ${menu}
    </li>`;
}
function landingRow(name, l) {
    const pct = l.total ? Math.floor(100 * l.done / l.total) : 0;
    return html `
    <li class="pack-row pack-landing">
      <span class="pack-badge pack-badge-busy" aria-hidden="true" style="--pct:${pct}"></span>
      <span class="pack-body"><span class="pack-name">${name}</span>
        <span class="pack-state">${l.total ? `${pct}% of ${bytes(l.total)}` : "measuring…"}</span></span>
    </li>`;
}
function regionRow(r) {
    const name = title(r.name);
    const have = kept()[name] || Object.values(kept()).find(p => p.bounds.join() === r.bounds.join());
    const busy = landing()[name];
    return html `
    <li class="pack-row">
      <span class="pack-body"><span class="pack-name">the whole of ${name}</span>
        <span class="pack-state">${bytes(r.bytes)} · the map of ${day(r.build)}</span></span>
      ${have ? html `<span class="pack-state">kept as “${have.name}”</span>`
        : busy ? ""
            : btn("keep", () => { void keep({ name: freeName(name), bounds: r.bounds, maxZoom: Math.min(AREA_MAXZOOM, r.maxZoom) }).catch(() => { }); }, " on")}
    </li>`;
}
export function mapPacksBlock() {
    if (!asked)
        ask();
    const rs = offered() ?? [];
    const packs = Object.values(kept()).sort((a, b) => b.keptAt - a.keptAt);
    const inFlight = Object.entries(landing());
    const trouble = lastTrouble();
    return html `
    <div class="packs">
      <h4 class="pack-h">Downloaded maps</h4>
      ${packs.length || inFlight.length
        ? html `<ul class="pack-list">${inFlight.map(([n, l]) => landingRow(n, l))}${packs.map(p => keptRow(p, rs))}</ul>`
        : html `<p class="pack-note">none yet — a map kept here draws with no network at all.</p>`}
      ${trouble ? html `<p class="pack-note pack-trouble">${trouble.name}: stopped (${trouble.why}) — keep it again to resume where it was.</p>` : ""}
      <h4 class="pack-h">Regions this gateway offers</h4>
      ${unreachable()
        ? html `<p class="pack-note">out of reach (${unreachable()}) — ${btn("ask again", () => ask(true))}</p>`
        : offered() === null ? html `<p class="pack-note">asking…</p>`
            : rs.length ? html `<ul class="pack-list">${rs.map(regionRow)}</ul>`
                : html `<p class="pack-note">this gateway offers no regions yet.</p>`}
      <button type="button" class="pack-primary" onclick=${() => selectOwn()}>Select your own map</button>
    </div>`;
}
