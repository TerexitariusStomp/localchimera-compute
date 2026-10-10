// app/tabs/map/ready.ts — when the map's style can take a source and a layer.
// ONE test and ONE wait for every overlay the dial mounts on the map (labels,
// journeys, containers). The style is ready the moment its JSON is parsed —
// `style.load` — well before the tiles are in; `isStyleLoaded()` holds out
// for every source's tiles too, and `load`/`idle` come after them, which is
// why a name waited on those drew after OpenStreetMap's had.
/** True once the style's JSON is parsed. Learns it once per map, on first ask. */
export function styleReady(map) {
    const m = map;
    if (m.__styleReady === undefined) {
        m.__styleReady = map.isStyleLoaded();
        if (!m.__styleReady)
            map.once("style.load", () => { m.__styleReady = true; });
    }
    return m.__styleReady;
}
/** Call FN now when the style is ready, else the moment it is. */
export function onStyleReady(map, fn) {
    if (styleReady(map))
        fn();
    else
        map.once("style.load", fn);
}
