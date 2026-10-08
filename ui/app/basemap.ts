// app/basemap.ts — the tiles under the map, chosen and kept.
//
// Three faces of the same proxy (server/serve-static.scm %tile-upstreams).
// STREET is the default: it carries its own labels and weighs a fraction of
// imagery, so the map is up before a satellite tile would have left the CDN.
// Satellite adds the reference-labels layer on top, because imagery says no
// names. The pick persists per device and applies as a VISIBILITY FLIP — no
// style reload, and a hidden layer's tiles are never fetched, so three basemaps
// cost exactly one until the picker asks otherwise.
//
// The style and the basemap list live in one file because they name the same
// four layers twice over. Apart, a renamed layer would break the visibility
// flip silently — the map would keep drawing and the picker would stop working.

import { readStr, writeStr } from "./store.js";
import { K } from "./keys.js";

/** One basemap, and the style layers it turns on. */
interface Basemap {
  id: string;
  name: string;
  /** Layer ids, in draw order. Satellite carries labels because imagery has none. */
  layers: string[];
}

const BASEMAPS: Basemap[] = [
  { id: "street", name: "Map",       layers: ["street"] },
  { id: "topo",   name: "Terrain",   layers: ["topo"] },
  { id: "sat",    name: "Satellite", layers: ["sat", "labels"] },
];

/** The remembered pick, or street. Storage may be denied; street is the answer. */
export const basemapGet = (): string => {
  const v = readStr(K.basemap);
  return BASEMAPS.some(b => b.id === v) ? v! : "street";
};

const layersOf = (id: string): string[] =>
  (BASEMAPS.find(b => b.id === id) || BASEMAPS[0]).layers;

/**
 * The style mkMap builds the map with.
 *
 * Every source is the SAME-ORIGIN tile proxy (server/serve-static.scm) and
 * never Esri from the browser: no per-tile IP or location leak, it works over
 * the onion with no mixed content, and it works offline once cached. Upstream
 * stays © Esri.
 */
export function mapStyle(): unknown {
  // The credit the Esri services lead with: Esri, and the data houses whose
  // names their street, topo and labels layers carry (OpenStreetMap among
  // them). The full per-service source lists are each service's copyrightText
  // (…/MapServer?f=pjson); this is the short form, and it is only until the
  // basemap moves to OpenStreetMap data (docs/legal/README.md §9 A).
  const esri = "© Esri, HERE, Garmin, © OpenStreetMap contributors";
  const credit = { street: esri, topo: esri, labels: esri,
                   satellite: "© Esri, Vantor, Earthstar Geographics" };
  const on = layersOf(basemapGet());
  const vis = (id: string): { visibility: string } =>
    ({ visibility: on.includes(id) ? "visible" : "none" });
  return {
    version: 8,
    sources: {
      street: { type: "raster", tileSize: 256, maxzoom: 19, attribution: credit.street,
        tiles: ["/tiles/street/{z}/{y}/{x}"] },
      topo: { type: "raster", tileSize: 256, maxzoom: 19, attribution: credit.topo,
        tiles: ["/tiles/topo/{z}/{y}/{x}"] },
      satellite: { type: "raster", tileSize: 256, maxzoom: 19, attribution: credit.satellite,
        tiles: ["/tiles/sat/{z}/{y}/{x}"] },
      labels: { type: "raster", tileSize: 256, maxzoom: 19, attribution: credit.labels,
        tiles: ["/tiles/labels/{z}/{y}/{x}"] },
    },
    layers: [
      { id: "street", type: "raster", source: "street",    layout: vis("street") },
      { id: "topo",   type: "raster", source: "topo",      layout: vis("topo") },
      { id: "sat",    type: "raster", source: "satellite", layout: vis("sat") },
      { id: "labels", type: "raster", source: "labels",    layout: vis("labels") },
    ],
  };
}

/** Remember the pick and flip the layers to match it. */
function applyBasemap(map: maplibregl.Map, id: string): void {
  writeStr(K.basemap, id);
  const on = layersOf(id);
  for (const b of BASEMAPS) for (const l of b.layers)
    map.setLayoutProperty(l, "visibility", on.includes(l) ? "visible" : "none");
  d3.selectAll("#basemapPick .bm-opt").classed("on", function (this: Element) {
    return (this as HTMLElement).dataset.bm === id;
  });
}

/**
 * The picker: a thumbnail chip that unfolds into the row of basemaps. Each
 * option's face is a REAL TILE of its own layer, served by the same proxy — so
 * the chooser cannot show a basemap the proxy would not serve.
 */
export function mountBasemapPick(map: maplibregl.Map): void {
  const host = map.getContainer();
  if (host.querySelector("#basemapPick")) return;
  const box = document.createElement("div");
  box.id = "basemapPick";
  const cur = basemapGet();
  box.innerHTML = BASEMAPS.map(b =>
    `<a class="bm-opt${b.id === cur ? " on" : ""}" data-bm="${b.id}" title="${b.name}" tabindex="0">
       <span class="bm-thumb" style="background-image:url('/tiles/${b.layers[0]}/13/3165/1310')"></span>
       <span class="bm-name">${b.name}</span>
     </a>`).join("");
  box.querySelectorAll<HTMLElement>(".bm-opt").forEach(a =>
    a.addEventListener("click", e => {
      e.stopPropagation();
      applyBasemap(map, a.dataset.bm!);   // written into the markup four lines up
      a.blur();   // else :focus-within holds the row open after the pick
    }));
  host.appendChild(box);
}
