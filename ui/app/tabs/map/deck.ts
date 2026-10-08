// app/tabs/map/deck.ts — deck.gl, mounted once, over the SAME maplibre map.
//
// Vendored deck.gl's MapboxOverlay (deck.d.ts) is the one door: interleaved
// with maplibre's own WebGL context, so a deck.gl layer sorts against the
// map's own 3D features correctly instead of always drawing on top. Nothing
// here picks a layer — that is deliberate: this module is the MOUNT POINT, the
// same way atlas.ts is the map's data layer and markers.ts is its DOM one.
// Whichever face wants deck.gl's power (a heatmap over demand density, an arc
// between a matched need and offer, a hexbin of activity) calls setDeckLayers
// with whatever `new deck.SomeLayer({...})` it built — this module only ever
// owns the ONE overlay instance and hands it the list.

let overlay: deck.MapboxOverlay | null = null;

/** Mount the overlay onto a map — once per map instance. A re-open rebuilds
 *  the map (mapview.ts), so this is safe to call every openMap(). */
export function mountDeck(map: maplibregl.Map): void {
  if (overlay) return;
  overlay = new deck.MapboxOverlay({ interleaved: true, layers: [] });
  map.addControl(overlay);
}

/** Replace the whole layer list. Pass [] to clear. A no-op before mountDeck
 *  has run (offline, or before the map exists) rather than a throw. */
export function setDeckLayers(layers: unknown[]): void {
  if (overlay) overlay.setProps({ layers });
}

export function unmountDeck(map: maplibregl.Map): void {
  if (!overlay) return;
  map.removeControl(overlay);
  overlay = null;
}
