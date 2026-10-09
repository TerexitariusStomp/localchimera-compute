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
const ATTRIBUTION = '<a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">© OpenStreetMap contributors</a>';
/** The light palette, every colour mapped by the theme in force. */
function flavor() {
    const out = {};
    for (const [k, v] of Object.entries(basemaps.LIGHT)) {
        if (typeof v === "string")
            out[k] = themeColorsIn(v); // a colour, or a font name (left as it is)
        else if (v)
            out[k] = Object.fromEntries(Object.entries(v).map(([n, c]) => [n, themeColorsIn(c)]));
    }
    return out;
}
/** The labels' language: the device's, as OSM names it (`name:xx`). */
const lang = () => (navigator.language || "en").slice(0, 2);
export const POI_FAMILIES = [
    { id: "nature", label: "parks and nature", on: true,
        kinds: ["park", "garden", "forest", "beach", "peak", "marina", "zoo", "animal"] },
    { id: "transit", label: "getting around", on: true,
        kinds: ["station", "bus_stop", "ferry_terminal", "aerodrome"] },
    { id: "civic", label: "schools and civic", on: false,
        kinds: ["school", "university", "library", "townhall", "post_office", "building"] },
    { id: "culture", label: "culture and sights", on: true,
        kinds: ["museum", "theatre", "attraction", "artwork", "stadium"] },
    { id: "food", label: "food and drink", on: false,
        kinds: ["restaurant", "cafe", "bar", "fast_food"] },
    { id: "shops", label: "shops", on: false,
        kinds: ["supermarket", "convenience", "books", "clothes", "electronics", "beauty"] },
    { id: "street", label: "benches, public toilets, drinking water", on: true,
        kinds: ["bench", "toilets", "drinking_water"] },
];
/** The families switched on, as ids; the defaults until the device says otherwise. */
export function poiFamiliesOn() {
    const v = readStr(K.mapPois);
    if (v === null)
        return POI_FAMILIES.filter(f => f.on).map(f => f.id);
    return v ? v.split(",") : [];
}
export const poiFamilyOn = (id) => poiFamiliesOn().includes(id);
/** Switch family ID on or off, remember it, and re-filter the map if one is up. */
export function setPoiFamily(id, on, map) {
    const now = new Set(poiFamiliesOn());
    if (on)
        now.add(id);
    else
        now.delete(id);
    writeStr(K.mapPois, [...now].join(","));
    if (map)
        applyPoiChoice(map);
}
const POI_LAYER = "pois";
/** The style's own filter for the places layer, narrowed to the kinds switched on. */
function poiFilter(own) {
    const on = new Set(poiFamiliesOn());
    const kinds = POI_FAMILIES.filter(f => on.has(f.id)).flatMap(f => f.kinds);
    const mine = ["in", ["get", "kind"], ["literal", kinds]];
    return own ? ["all", own, mine] : mine;
}
/** Narrow the places layer of LAYERS to the chosen families. */
const withPoiChoice = (layers) => layers.map(l => l.id === POI_LAYER ? { ...l, filter: poiFilter(l.filter) } : l);
/** Re-filter the places layer of a live map after a choice. */
export function applyPoiChoice(map) {
    const own = basemaps.layers("osm", basemaps.LIGHT, { lang: lang() }).find(l => l.id === POI_LAYER)?.filter;
    map.setFilter(POI_LAYER, poiFilter(own));
}
const groundLayers = () => withPoiChoice(basemaps.layers("osm", flavor(), { lang: lang() }));
/** The style mkMap builds the map with. */
export function mapStyle() {
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
export function rethemeBasemap(map) {
    for (const l of groundLayers())
        for (const [k, v] of Object.entries(l.paint || {}))
            map.setPaintProperty(l.id, k, v);
}
