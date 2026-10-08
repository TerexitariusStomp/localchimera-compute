// app/deck.d.ts — the deck.gl surface the dial actually calls.
//
// Same policy as maplibre.d.ts and d3.d.ts: declare a member the first time a
// converted module calls it, never before. deck.gl is vendored as a classic
// script (vendor/deck.gl.js, loaded before any module) and reaches every one
// of its own layer types and options through window.deck — this file types
// only the ONE door app/tabs/map/deck.ts opens (MapboxOverlay), not the
// library's full surface, which is why `layers` stays `unknown[]`: the
// layer objects themselves are deck.gl's own construction (new
// deck.ScatterplotLayer({...}), etc.), read by deck internally, never by
// our code — there is nothing here for a narrower type to check.

declare global {
  namespace deck {
    /**
     * The maplibre-gl integration point: an IControl that owns an
     * interleaved WebGL layer stack sharing the map's own GL context, so a
     * deck.gl layer sorts correctly against maplibre's 3D terrain/buildings
     * instead of always drawing on top. addControl(overlay) once; setProps
     * again whenever the layer list changes.
     */
    class MapboxOverlay implements maplibregl.IControl {
      constructor(props: { interleaved?: boolean; layers?: unknown[] });
      setProps(props: { layers?: unknown[] }): void;
      onAdd(map: maplibregl.Map): HTMLElement;
      onRemove(map: maplibregl.Map): void;
    }
  }
}

export {};
