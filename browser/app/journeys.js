// app/journeys.ts — the map's JOURNEY ARCS: a move drawn between its ends.
//
// Any day-event carrying BOTH a venue and a destination with coordinates
// (loc → toLoc — a schedule move, a lived transfer) draws a dashed line from
// where it leaves to where it lands, arrow-less on purpose: the dash reads as
// motion at every zoom, where an arrowhead needs a symbol layer and a sprite.
//
// The arcs show exactly the set the markers show — the same turn window
// (clipped to the event's own day), the same facets, the same calendars —
// because they are derived from the same mapOffers() read. An arc can never
// outlive the pins it connects.
import { mapOffers, inTurnWindow } from './offers.js';
import { passesFacets } from './facets.js';
const SRC = "journeys";
const LINE = "journeys-line";
const empty = () => ({ type: "FeatureCollection", features: [] });
function features() {
    const out = [];
    for (const o of mapOffers()) {
        if (!(o.loc && o.loc.lat != null && o.toLoc && o.toLoc.lat != null))
            continue;
        if (!inTurnWindow(o) || !passesFacets(o))
            continue;
        out.push({ type: "Feature",
            properties: { action: o.action || "" },
            geometry: { type: "LineString",
                coordinates: [[o.loc.lng, o.loc.lat], [o.toLoc.lng, o.toLoc.lat]] } });
    }
    return { type: "FeatureCollection", features: out };
}
let _map = null;
/** Mount the source+layer on this map instance; idempotent per instance. */
export function mountJourneys(map) {
    _map = map;
    if (!map)
        return;
    if (!map.isStyleLoaded()) {
        map.once("load", () => mountJourneys(map));
        return;
    }
    if (map.__journeysMounted && map.getSource(SRC)) {
        renderJourneys();
        return;
    }
    map.__journeysMounted = true;
    map.addSource(SRC, { type: "geojson", data: empty() });
    map.addLayer({
        id: LINE, type: "line", source: SRC,
        paint: { "line-color": "#b0653a", // the schedule calendar's own ink
            "line-width": 2,
            "line-opacity": 0.75,
            "line-dasharray": [2, 2] },
    });
    renderJourneys();
}
/** Re-derive the arcs. Called beside renderMarkers, so the two never drift. */
export function renderJourneys() {
    if (!_map)
        return;
    const src = _map.getSource(SRC);
    if (src)
        src.setData(features());
}
