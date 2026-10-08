// app/mapbox-controls.d.ts — the vendored mapbox-controls surface.
//
// Same policy as maplibre.d.ts: declared the first time a module calls it.
// vendor/mapbox-controls.js is a classic script exposing window.MapboxControls
// with three constructors, each an IControl (maplibre.d.ts) — mount any of
// them with map.addControl(new MapboxControls.ZoomControl()).

declare global {
  namespace MapboxControls {
    class ZoomControl implements maplibregl.IControl {
      onAdd(map: maplibregl.Map): HTMLElement;
      onRemove(map: maplibregl.Map): void;
    }
    class CompassControl implements maplibregl.IControl {
      constructor(options?: {
        instant?: boolean; title?: string;
        /** May claim the click by returning true; otherwise the map eases back to north. */
        onClick?: (map: maplibregl.Map) => boolean | void;
      });
      onAdd(map: maplibregl.Map): HTMLElement;
      onRemove(map: maplibregl.Map): void;
    }
    /** Click a rendered feature to see its layer/properties — a debugging
     *  tool. Sees real maplibre layers only (a future GeoJSON overlay, say);
     *  the DOM markers everything else here draws aren't layers, so it
     *  can't see needs/offers/places. */
    class InspectControl implements maplibregl.IControl {
      /** the control's own box (its .maplibregl-ctrl-group), hidden by the app
       *  while dev mode is off; `isActive` is whether a click is being read */
      container: HTMLElement;
      isActive: boolean;
      deactivate(): void;
      onAdd(map: maplibregl.Map): HTMLElement;
      onRemove(map: maplibregl.Map): void;
    }
  }
}

export {};
