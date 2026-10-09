// app/basemap.ts — the ground under the map: OpenStreetMap, served from here.
//
// One vector source, the `osm://` scheme app/map-packs.ts teaches maplibre: a
// region kept on this device answers first, the same-origin /tiles/osm route
// (server/serve-static.scm) otherwise — PMTiles archives cut from a Protomaps
// build of OpenStreetMap (tools/map-tiles.sh). The browser never contacts a
// tile provider: no per-tile location leak, the map works over the onion, and
// it works with no network for every region kept. The style is @protomaps/basemaps'
// (vendor/basemaps/basemaps.js) over its light palette, and the palette goes
// through the dial's theme on the way in, so a dark theme gets a dark map and
// a theme pick re-hues the ground in place.
//
// Attribution is the ODbL's one ask of a produced work, and it rides in the
// source: maplibre's attribution control (on in mapview.ts) shows it.

import { themeColorsIn } from "./theme.js";

/** The deepest zoom the archives are cut to; maplibre overzooms past it. */
export const OSM_MAXZOOM = 15;

const ATTRIBUTION =
  '<a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">© OpenStreetMap contributors</a>';

/** The light palette, every colour mapped by the theme in force. */
function flavor(): basemaps.Flavor {
  const out: basemaps.Flavor = {};
  for (const [k, v] of Object.entries(basemaps.LIGHT)) {
    if (typeof v === "string") out[k] = themeColorsIn(v);        // a colour, or a font name (left as it is)
    else if (v) out[k] = Object.fromEntries(Object.entries(v).map(([n, c]) => [n, themeColorsIn(c)]));
  }
  return out;
}

/** The labels' language: the device's, as OSM names it (`name:xx`). */
const lang = (): string => (navigator.language || "en").slice(0, 2);

const groundLayers = (): maplibregl.StyleLayer[] => basemaps.layers("osm", flavor(), { lang: lang() });

/** The style mkMap builds the map with. */
export function mapStyle(): unknown {
  const o = location.origin;
  return {
    version: 8,
    glyphs: o + "/assets/map/fonts/{fontstack}/{range}.pbf",
    sprite: o + "/assets/map/sprites/light",
    sources: {
      osm: { type: "vector", tiles: ["osm://{z}/{x}/{y}"],
             maxzoom: OSM_MAXZOOM, attribution: ATTRIBUTION },
    },
    layers: groundLayers(),
  };
}

/**
 * Re-hue the ground after a theme pick: the palette is read again through
 * the new theme and every paint property set in place. No style reload, so
 * the dial's own overlays (markers, routes, regions) stay where they are.
 */
export function rethemeBasemap(map: maplibregl.Map): void {
  for (const l of groundLayers())
    for (const [k, v] of Object.entries(l.paint || {}))
      map.setPaintProperty(l.id, k, v);
}
