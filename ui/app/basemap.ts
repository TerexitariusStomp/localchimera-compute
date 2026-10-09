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
import { readStr, writeStr } from "./store.js";
import { K } from "./keys.js";

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

// ── the places the map labels ────────────────────────────────────────────
// The style's `pois` layer draws every kind OpenStreetMap tags; a city block
// of restaurants is noise over the dial's own pins. The kinds fall into
// families a person switches on and off; the choice persists per device and
// applies as a FILTER on that one layer — no style reload. What starts on is
// the commons' side of the street: nature, ways to get around, culture, and
// what is free to use — care, play, the commons' benches, toilets and water.
// Food, shops and institutions start off; a device turns them on. The tiles
// carry more kinds than the style draws: a kind with no sprite of its own is
// drawn as the style's plain dot, its name beside it.

/** An emoji per kind: the row's face in the panel and the search, and the family's in settings; the map draws the sprite. */
export const POI_FACE: Record<string, string> = {
  park: "🌳", garden: "🌱", forest: "🌲", beach: "🏖", peak: "⛰", marina: "⚓", zoo: "🦁", animal: "🐾",
  station: "🚉", bus_stop: "🚏", ferry_terminal: "⛴", aerodrome: "✈",
  school: "🏫", university: "🎓", library: "📚", townhall: "🏛", post_office: "📮", building: "🏢",
  museum: "🖼", theatre: "🎭", attraction: "🎡", artwork: "🎨", stadium: "🏟",
  restaurant: "🍽", cafe: "☕", bar: "🍸", fast_food: "🍔",
  supermarket: "🛒", convenience: "🏪", books: "📖", clothes: "👕", electronics: "🔌", beauty: "💇",
  bench: "🪑", toilets: "🚻", drinking_water: "🚰",
  subway: "🚇", tram_stop: "🚊", bus_station: "🚌", bicycle_parking: "🚲",
  hospital: "🏥", clinic: "🩺", doctors: "🩺", dentist: "🦷", pharmacy: "💊", social_facility: "🤝", childcare: "🧸",
  kindergarten: "🧸", community_centre: "🏘", veterinary: "🐕", shelter: "⛺",
  playground: "🛝", pitch: "⚽", sports_centre: "🏃", swimming_pool: "🏊", dog_park: "🐕", picnic_site: "🧺", viewpoint: "🔭",
  allotments: "🥕", recycling: "♻", information: "ℹ", memorial: "🕯", courthouse: "⚖", police: "👮", fire_station: "🚒",
};

/** The faces of a family's kinds, for its row in settings. */
export const familyFaces = (f: PoiFamily): string => [...new Set(f.kinds.map(k => POI_FACE[k]).filter(Boolean))].join(" ");

/** A family of place kinds, as the Protomaps `pois` layer names them. */
export interface PoiFamily { id: string; label: string; kinds: string[]; on: boolean; }

export const POI_FAMILIES: PoiFamily[] = [
  { id: "nature",  label: "parks and nature",     on: true,
    kinds: ["park", "garden", "forest", "beach", "peak", "marina", "zoo", "animal"] },
  { id: "transit", label: "getting around",       on: true,
    kinds: ["station", "subway", "tram_stop", "bus_stop", "bus_station", "ferry_terminal", "aerodrome", "bicycle_parking"] },
  { id: "care",    label: "care and help",        on: true,
    kinds: ["hospital", "clinic", "doctors", "dentist", "pharmacy", "social_facility", "childcare",
            "kindergarten", "community_centre", "veterinary", "shelter"] },
  { id: "play",    label: "play and sport",       on: true,
    kinds: ["playground", "pitch", "sports_centre", "swimming_pool", "dog_park", "picnic_site", "viewpoint"] },
  { id: "commons", label: "the commons",          on: true,
    kinds: ["library", "allotments", "recycling", "drinking_water", "toilets", "bench", "information"] },
  { id: "civic",   label: "schools and civic",    on: false,
    kinds: ["school", "university", "townhall", "post_office", "building", "courthouse", "police", "fire_station"] },
  { id: "culture", label: "culture and sights",   on: true,
    kinds: ["museum", "theatre", "attraction", "artwork", "memorial", "stadium"] },
  { id: "food",    label: "food and drink",       on: false,
    kinds: ["restaurant", "cafe", "bar", "fast_food"] },
  { id: "shops",   label: "shops",                on: false,
    kinds: ["supermarket", "convenience", "books", "clothes", "electronics", "beauty"] },
];

/** The families switched OFF, as ids — what is remembered, so a family added later starts as its default. */
function poiFamiliesOff(): Set<string> {
  const v = readStr(K.mapPoisOff);
  return new Set(v === null ? POI_FAMILIES.filter(f => !f.on).map(f => f.id) : v ? v.split(",") : []);
}

/** The families switched on, as ids. */
export function poiFamiliesOn(): string[] {
  const off = poiFamiliesOff();
  return POI_FAMILIES.filter(f => !off.has(f.id)).map(f => f.id);
}

export const poiFamilyOn = (id: string): boolean => !poiFamiliesOff().has(id);

/** Switch family ID on or off, remember it, and re-filter the map if one is up. */
export function setPoiFamily(id: string, on: boolean, map?: maplibregl.Map | null): void {
  const off = poiFamiliesOff();
  if (on) off.delete(id); else off.add(id);
  writeStr(K.mapPoisOff, [...off].join(","));
  if (map) applyPoiChoice(map);
}

const POI_LAYER = "pois";

/**
 * The places layer's filter: the kinds switched on, each from the zoom the
 * build gives it (`min_zoom`, as the style's own filter reads it). The
 * style's kind list is replaced, not narrowed: the tiles carry kinds it
 * never draws, and the families name some of them.
 */
function poiFilter(): maplibregl.Expression {
  const on = new Set(poiFamiliesOn());
  const kinds = POI_FAMILIES.filter(f => on.has(f.id)).flatMap(f => f.kinds);
  return ["all", ["in", ["get", "kind"], ["literal", kinds]], [">=", ["zoom"], ["+", ["get", "min_zoom"], 0]]];
}

/** The kinds the sprite sheet has an icon for (assets/map/sprites); every other kind takes the dot. */
const SPRITED = ["beach", "forest", "marina", "park", "peak", "zoo", "garden", "bench", "aerodrome", "bus_stop",
  "ferry_terminal", "stadium", "university", "library", "school", "animal", "toilets", "drinking_water", "post_office",
  "building", "restaurant", "fast_food", "cafe", "bar", "supermarket", "convenience", "books", "beauty", "electronics",
  "clothes", "attraction", "museum", "theatre", "artwork"];

/** The style's icon by kind — the station's own name in the sheet — and the dot for a kind the sheet lacks. */
const poiIcon = (): maplibregl.Expression =>
  ["match", ["get", "kind"], SPRITED, ["get", "kind"], "station", "train_station", "townspot"];

/** Narrow the places layer of LAYERS to the chosen families, and give every kind a face. */
const withPoiChoice = (layers: maplibregl.StyleLayer[]): maplibregl.StyleLayer[] =>
  layers.map(l => l.id === POI_LAYER
    ? { ...l, filter: poiFilter(), layout: { ...(l.layout || {}), "icon-image": poiIcon() } }
    : l);

/** Re-filter the places layer of a live map after a choice. */
export function applyPoiChoice(map: maplibregl.Map): void {
  map.setFilter(POI_LAYER, poiFilter());
}

const groundLayers = (): maplibregl.StyleLayer[] => withPoiChoice(basemaps.layers("osm", flavor(), { lang: lang() }));

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
