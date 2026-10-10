// app/tabs/map/labels.ts — the names of the dial's own markers, drawn by the map.
//
// One label renderer for every label on the map: the map's own symbol layer,
// with the settings the ground's places are drawn by — the same font, the
// same size curve, the same wrap at eight ems, the same halo, and the same
// collision rules, so a name steps aside for a neighbour's and for
// OpenStreetMap's. The markers themselves (app/markers.ts) keep only their
// faces: the emoji, the rings, the cluster bubbles, the tap. Each render
// hands this module one label per single marker, in that kind's own ink.
import { themeColorsIn } from "../../theme.js";
import { styleReady, onStyleReady } from "./ready.js";
const SRC = "dial-labels";
const LAYER = "dial-labels";
let _map = null;
let last = [];
const ground = () => themeColorsIn("#ffffff");
const collection = (ls) => ({
    type: "FeatureCollection",
    features: ls.map(l => ({
        type: "Feature",
        properties: { text: l.text, ink: themeColorsIn(l.ink), sel: !!l.sel, open: !!l.open },
        geometry: { type: "Point", coordinates: [l.lng, l.lat] },
    })),
});
/** Mount the source and the layer once per map; safe to call again. */
export function mountLabels(map) {
    _map = map;
    if (!map)
        return;
    if (!styleReady(map)) {
        onStyleReady(map, () => mountLabels(map));
        return;
    }
    if (map.__labelsMounted && map.getSource(SRC)) {
        setLabels(last);
        return;
    }
    map.__labelsMounted = true;
    map.addSource(SRC, { type: "geojson", data: collection(last) });
    map.addLayer({
        id: LAYER, type: "symbol", source: SRC,
        layout: {
            "text-field": ["get", "text"],
            "text-font": ["case", ["get", "open"], ["literal", ["Noto Sans Italic"]], ["literal", ["Noto Sans Medium"]]],
            // the ground's own curve (pois: 10 at z17 → 16 at z19), reachable from
            // the zooms the dial's places are drawn at
            "text-size": ["interpolate", ["linear"], ["zoom"], 12, 10, 17, 11, 19, 15],
            "text-max-width": 8,
            "text-variable-anchor": ["left", "right"],
            "text-justify": "auto",
            // the ground's gap (its pois: 1.1 em off a ~15 px icon, ≈4.5 px clear)
            // from a face that is 22 px at every zoom: (11 + 4.5) px in the ems of
            // each zoom's text size, so the gap holds while the em moves
            "text-offset": ["interpolate", ["linear"], ["zoom"], 12, ["literal", [1.55, 0]], 17, ["literal", [1.41, 0]], 19, ["literal", [1.03, 0]]],
            "text-padding": 2,
            "symbol-sort-key": ["case", ["get", "sel"], 0, 1],
        },
        paint: {
            "text-color": ["get", "ink"],
            "text-halo-color": ground(),
            "text-halo-width": 1.2,
        },
    });
}
/** Hand the map this render's labels. Kept until the map is up, then set. */
export function setLabels(ls) {
    last = ls;
    const src = _map?.getSource(SRC);
    if (src)
        src.setData(collection(ls));
}
/** After a theme pick: the halo is the new ground, the inks are re-read. */
export function rethemeLabels() {
    if (!_map?.getSource(SRC))
        return;
    _map.setPaintProperty(LAYER, "text-halo-color", ground());
    setLabels(last);
}
