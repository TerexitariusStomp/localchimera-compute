// app/tabs/map/osm-places.ts — what OpenStreetMap knows of a place, as a row of the map's own.
//
// The basemap's `pois` layer draws a city's parks, stations, museums, toilets
// (app/basemap.ts chooses which families). Here each becomes a PlacedRow —
// the same shape the dial's pins, offers and dropped spots take — so a tap on
// one opens the same panel (location, directions, save) and the search bar
// lists them beside the commons' own rows. The features come from the tiles
// already on screen: queryRenderedFeatures under a tap, querySourceFeatures
// for a search — nothing is fetched that the map has not drawn.
import { POI_FAMILIES, poiFamiliesOn } from "../../basemap.js";
const LAYER = "pois";
const SOURCE = "osm";
/** An emoji per kind, for the row's face; the style draws the sprite on the map. */
const FACE = {
    park: "🌳", garden: "🌱", forest: "🌲", beach: "🏖", peak: "⛰", marina: "⚓", zoo: "🦁", animal: "🐾",
    station: "🚉", bus_stop: "🚏", ferry_terminal: "⛴", aerodrome: "✈",
    school: "🏫", university: "🎓", library: "📚", townhall: "🏛", post_office: "📮", building: "🏢",
    museum: "🖼", theatre: "🎭", attraction: "🎡", artwork: "🎨", stadium: "🏟",
    restaurant: "🍽", cafe: "☕", bar: "🍸", fast_food: "🍔",
    supermarket: "🛒", convenience: "🏪", books: "📖", clothes: "👕", electronics: "🔌", beauty: "💇",
    bench: "🪑", toilets: "🚻", drinking_water: "🚰",
};
/** The kind, as a person reads it: "public toilets", "bus stop". */
const WORD = {
    toilets: "public toilets", drinking_water: "drinking water", fast_food: "fast food",
    bus_stop: "bus stop", ferry_terminal: "ferry terminal", post_office: "post office", townhall: "town hall",
};
export const kindWord = (kind) => WORD[kind] ?? kind.replace(/_/g, " ");
/** The kinds the families switched on admit. */
function kindsOn() {
    const on = new Set(poiFamiliesOn());
    return new Set(POI_FAMILIES.filter(f => on.has(f.id)).flatMap(f => f.kinds));
}
/** A feature of the places layer as a row, or null when it has no name or no point. */
export function placeRow(f) {
    const p = f.properties || {};
    const name = typeof p.name === "string" ? p.name : null;
    const kind = typeof p.kind === "string" ? p.kind : "";
    if (!name || f.geometry.type !== "Point")
        return null;
    const [lng, lat] = f.geometry.coordinates;
    return { id: `osm:${f.id ?? `${kind}:${lng.toFixed(5)},${lat.toFixed(5)}`}`, kind: "place",
        emoji: FACE[kind] ?? "📍", name, provider: "OpenStreetMap", note: kindWord(kind),
        lat, lng, arcs: [] };
}
/** The place drawn under POINT (the map's pixels), or null. */
export function placeAt(map, point) {
    for (const f of map.queryRenderedFeatures([point.x, point.y], { layers: [LAYER] })) {
        const r = placeRow(f);
        if (r)
            return r;
    }
    return null;
}
/**
 * The places on the tiles the map holds whose name says Q, in the families
 * switched on — one row per place (a feature cut by a tile edge is listed
 * once). Empty for an empty Q: the search lists them beside the commons'
 * rows only when asked by name.
 */
export function placesNamed(map, q) {
    const needle = q.trim().toLowerCase();
    if (!needle)
        return [];
    const kinds = kindsOn();
    const seen = new Set();
    const out = [];
    for (const f of map.querySourceFeatures(SOURCE, { sourceLayer: LAYER })) {
        const kind = typeof f.properties?.kind === "string" ? f.properties.kind : "";
        if (!kinds.has(kind))
            continue;
        const r = placeRow(f);
        if (!r || !r.name.toLowerCase().includes(needle) || seen.has(r.id))
            continue;
        seen.add(r.id);
        out.push(r);
    }
    return out;
}
