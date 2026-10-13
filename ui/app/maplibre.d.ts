// app/maplibre.d.ts — the maplibre-gl surface the dial actually calls.
//
// The second foreign API declared by hand, under the same policy as d3.d.ts:
// DECLARE A MEMBER THE FIRST TIME A CONVERTED MODULE CALLS IT, never before. An
// undeclared member is a type error at the call site, so every line here is a
// claim someone made deliberately and can check — not a wholesale import of
// claims nobody read.
//
// maplibre-gl is vendored as a classic script (vendor/maplibre-gl.js, loaded
// before any module), so it is a global rather than an import, and `new
// maplibregl.Map(…)` in main.js reaches it as one.
//
// Unlike d3 there is no hard half here. maplibre's imperative API is small,
// flat and exactly typable — addSource / addLayer / setPaintProperty and the
// event pair — with none of the datum-generic depth that made the selection DSL
// worth refusing. What it does carry is STYLE EXPRESSIONS, and those are typed
// as what they are: JSON arrays, checked for shape and not for meaning (see
// Expression).

declare global {
  namespace maplibregl {
    // ── GeoJSON, as much of it as crosses this boundary ──────────────────────
    // Declared here because maplibre is where it is consumed, and only the two
    // geometries the dial draws and hit-tests. `number[]` rather than a
    // [lng, lat] tuple is the truthful shape: GeoJSON permits a third
    // (altitude) element, and readers here take [0] and [1] regardless.
    type Position = number[];

    interface Polygon {
      type: "Polygon";
      /** Outer ring first, then holes. Each ring closed (first === last). */
      coordinates: Position[][];
    }
    interface MultiPolygon {
      type: "MultiPolygon";
      coordinates: Position[][][];
    }
    interface Point {
      type: "Point";
      coordinates: Position;
    }
    interface LineString {
      type: "LineString";
      coordinates: Position[];
    }
    type Geometry = Point | Polygon | MultiPolygon | LineString;

    interface Feature {
      type: "Feature";
      /** Read back by style expressions as ["get", name] — hence unknown. */
      properties: Record<string, unknown>;
      geometry: Geometry;
    }
    interface FeatureCollection {
      type: "FeatureCollection";
      features: Feature[];
    }

    /**
     * A style expression — maplibre's little JSON language, in which
     * ["match", ["get", "depth"], 0, 0.3, 0.05] means "read the feature's depth
     * and pick an opacity".
     *
     * Typed as the JSON it is: shape, not meaning. Nothing here checks that
     * "match" takes alternating pairs or that ["get"] names a property that
     * exists — maplibre validates at runtime and says so clearly, and a
     * hand-written approximation of its grammar would look checked without
     * being it. What this DOES buy is that an expression cannot be confused
     * with a value, and that building one by push() stays honest about mixing
     * strings and numbers.
     */
    type Expression = string | number | boolean | null | Expression[];

    /** What a paint or layout property accepts: a constant or an expression. */
    type StyleValue = string | number | boolean | Expression;

    /**
     * What a geojson source accepts. A COLLECTION is what the overlays hand it
     * — many shapes, each carrying properties a style expression reads back.
     * A bare feature is equally valid GeoJSON and is what the route line is:
     * one shape, styled by constants, with nothing to read off it. Keeping them
     * distinct is what lets Feature.properties stay required for the readers
     * that do `f.properties.id` without a guard.
     */
    interface BareFeature {
      type: "Feature";
      geometry: LineString;
    }
    type SourceData = FeatureCollection | Feature | BareFeature;

    /** A source you can hand new data to without rebuilding the layer. */
    interface GeoJSONSource {
      setData(data: SourceData): void;
    }

    interface LayerSpec {
      id: string;
      type: "fill" | "line" | "symbol";
      source: string;
      /** Which of the source's features the layer draws — how one source carries a chosen way and its alternatives. */
      filter?: Expression;
      paint?: Record<string, StyleValue>;
      layout?: Record<string, StyleValue>;
    }

    /**
     * A layer as a STYLE carries it — what @protomaps/basemaps hands back for
     * the ground under the map (app/basemap.ts). Wider than LayerSpec, which is
     * the dial's own two overlay kinds: a vector-tile layer names its
     * source-layer, filters, and may be a symbol or the background.
     */
    interface StyleLayer {
      id: string;
      type: "background" | "fill" | "line" | "symbol";
      source?: string;
      "source-layer"?: string;
      filter?: Expression;
      minzoom?: number;
      maxzoom?: number;
      paint?: Record<string, StyleValue>;
      layout?: Record<string, StyleValue>;
    }

    interface GeoJSONSourceSpec {
      type: "geojson";
      data: SourceData;
    }

    /**
     * A DOM marker anchored to a coordinate. The element BELONGS to maplibre
     * once handed over: the library stamps maplibregl-* classes on it and
     * positions it through style.transform, which is why markers.ts morphs an
     * existing element rather than replacing it.
     */
    class Marker {
      constructor(opts: { element: HTMLElement; anchor?: string });
      setLngLat(coordinates: [number, number]): Marker;
      addTo(map: Map): Marker;
      remove(): Marker;
    }

    /**
     * A coordinate in maplibre's unit Mercator space — x and y both in [0, 1]
     * across the whole world. The clustering buckets in THIS space rather than
     * in screen pixels, which is exactly what makes a pan change nothing: the
     * world coordinate of a point does not depend on where you are looking.
     */
    class MercatorCoordinate {
      static fromLngLat(coordinates: [number, number], altitude?: number): MercatorCoordinate;
      x: number;
      y: number;
      z: number;
    }

    /** A feature as a query hands one back: the tile's own properties, an id when the tile gives one. */
    interface QueriedFeature {
      id?: number | string;
      properties: Record<string, unknown>;
      geometry: { type: string; coordinates: unknown };
    }

    /** A coordinate as maplibre hands one back. */
    interface LngLat {
      lng: number;
      lat: number;
    }

    /** What the constructor is given. */
    interface MapOptions {
      /** The element id THIS face owns — never the other face's. */
      container: string;
      style: unknown;
      center: [number, number] | LngLat;
      zoom: number;
      attributionControl?: boolean;
      antialias?: boolean;
      /** Seconds the symbols fade in over; 0 is a hard cut. */
      fadeDuration?: number;
    }

    /**
     * Declared as a CLASS, not an interface, because `new maplibregl.Map(…)`
     * needs the value as well as the type — the same reason Marker and
     * MercatorCoordinate are classes here.
     */
    class Map {
      constructor(opts: MapOptions);
      /**
       * Style-dependent calls (addSource, addLayer) are rejected before the
       * style is up, which is why mount() defers on "load".
       */
      isStyleLoaded(): boolean;
      on(type: string, listener: () => void): Map;
      /** The error channel, which carries a payload the others do not. */
      on(type: "error", listener: (e: unknown) => void): Map;
      /** Fired by GeolocateControl with a real GeolocationPosition — the one
       *  other channel besides error that carries a payload. */
      on(type: "geolocate", listener: (e: { coords: { latitude: number; longitude: number } }) => void): Map;
      /** A pointer event on the map: where it landed. contextmenu is the one
       *  the dial reads (right-click, or press-and-hold on touch). */
      on(type: "contextmenu", listener: (e: { lngLat: { lat: number; lng: number } }) => void): Map;
      /** A tap on the map itself (a marker's own click stops before it): where, in the container's pixels. */
      on(type: "click", listener: (e: { point: { x: number; y: number }; lngLat: LngLat }) => void): Map;
      /** The drawn features under a point, of the layers named — how a tap finds the place under it. */
      queryRenderedFeatures(point: [number, number], opts: { layers: string[] }): QueriedFeature[];
      /** The features of a source layer on the tiles the map holds — what a search by name reads. */
      querySourceFeatures(source: string, opts: { sourceLayer: string }): QueriedFeature[];
      once(type: string, listener: () => void): Map;
      off(type: string, listener: () => void): Map;

      getZoom(): number;
      /** Map bearing, degrees. Carried through a fitBounds so a rotated map stays rotated. */
      getBearing(): number;
      /**
       * Ease to a point. Unlike jumpTo this ANIMATES, which is the difference
       * between arriving somewhere and being teleported there.
       */
      easeTo(opts: { center: [number, number]; zoom?: number; duration?: number }): Map;
      /** Ease to a point, animated. */
      flyTo(opts: {
        center: [number, number]; zoom?: number; duration?: number;
        /** Room to leave around the framed point — the search panel's width. */
        padding?: { left?: number; top?: number; right?: number; bottom?: number };
      }): Map;
      /**
       * The room the camera keeps around its centre. flyTo's `padding` PERSISTS here, and fitBounds's own
       * padding is added to it — so a framing that means its padding exactly clears this first.
       */
      setPadding(padding: { left: number; top: number; right: number; bottom: number }): Map;
      /** Frame a bounding box: [[west, south], [east, north]]. */
      fitBounds(bounds: [[number, number], [number, number]],
                opts?: { padding?: number | { left?: number; top?: number; right?: number; bottom?: number };
                         duration?: number; maxZoom?: number;
                         /** Kept from getBearing, so framing a cluster does not un-rotate the map. */
                         bearing?: number }): Map;

      addSource(id: string, source: GeoJSONSourceSpec): Map;
      /** undefined when the id is unknown — the guard before every setData. */
      getSource(id: string): GeoJSONSource | undefined;
      removeSource(id: string): Map;

      addLayer(layer: LayerSpec, before?: string): Map;
      /** undefined when the id is unknown — the guard before every remove. */
      getLayer(id: string): unknown;
      removeLayer(id: string): Map;

      /** The element the map was built into — where an overlay mounts. */
      getContainer(): HTMLElement;
      /** A position in the container's pixels → its coordinate: how the area frame reads the map under it. */
      unproject(point: [number, number]): LngLat;
      /** Re-read the container's size. Every sizer ends with one. */
      resize(): Map;
      /** Tear the instance down. A face switch rebuilds rather than moves. */
      remove(): void;

      getCenter(): LngLat;
      /**
       * A coordinate → its position in the container's pixels. How the walking
       * isochrones are drawn at a true scale: a kilometre east of you is
       * projected and MEASURED rather than assumed.
       */
      project(coordinates: [number, number]): { x: number; y: number };
      /** Jump with no animation — a re-frame, not a journey. */
      jumpTo(opts: { center: [number, number] | LngLat; zoom?: number }): Map;
      /** Rotate the map. The compass turns the satellite with you. */
      setBearing(degrees: number): Map;

      /**
       * The dial's OWN stamps, not maplibre's. Each marks a listener bound once
       * per instance, so a re-open cannot stack a second — and a rebuilt map
       * starts clean because the stamp goes with the instance it was on.
       */
      _markersBound?: boolean;
      _threadsBound?: boolean;
      _controlsBound?: boolean;

      setPaintProperty(layer: string, name: string, value: StyleValue): Map;
      /** Narrow a layer to the features an expression admits — how the places families apply. */
      setFilter(layer: string, filter: Expression): Map;
      setLayoutProperty(layer: string, name: string, value: StyleValue): Map;

      /**
       * The dial's own stamp, not maplibre's: containers.ts binds one "zoom"
       * listener per map and marks the map so a re-mount does not stack a
       * second. Declared here because this is where the property lives, and
       * naming it beats widening the Map type until the assignment compiles.
       */
      __containersZoomBound?: boolean;

      /** The dial's stamp again, journeys.ts's this time: the arc source and
       *  layer are added once per map instance, and the stamp is what makes
       *  a re-mount on the same instance a no-op. */
      __journeysMounted?: boolean;

      /** Mounts anything shaped like IControl — a vendored zoom/compass/ruler
       *  button, or deck.gl's own MapboxOverlay (deck.d.ts). */
      addControl(control: IControl, position?: string): Map;
      removeControl(control: IControl): Map;
      /** Programmatic zoom, no animation — mapbox-controls.js's zoom buttons. */
      zoomIn(): Map;
      zoomOut(): Map;
      getCanvas(): HTMLCanvasElement;
    }

    /**
     * Teach the library a URL scheme: the handler answers a tile request with
     * its bytes (uncompressed — the library does not inflate what a protocol
     * hands it). app/map-packs.ts's `osm://`, which reads kept regions off the
     * device before asking the gateway.
     */
    function addProtocol(scheme: string,
                         handler: (req: { url: string }, abort: AbortController) => Promise<{ data: ArrayBuffer }>): void;

    /** What addControl expects — the same tiny contract mapbox-controls.js's
     *  vendored classes and deck.gl's MapboxOverlay both implement. */
    interface IControl {
      onAdd(map: Map): HTMLElement;
      onRemove(map: Map): void;
    }

    /**
     * maplibre's OWN "centre on me" button — native to maplibre-gl.js, no
     * further vendoring needed. Its onAdd fires "geolocate" on the map
     * whenever it moves you there (an initial click, and again on every fix
     * while trackUserLocation keeps watching) — mapview.ts listens and
     * re-bakes MAP_ANCHOR from that same fix, so the button's own recentre
     * and the rest of the map's fabric can't drift apart the way a
     * geolocation update that bypassed MAP_ANCHOR entirely once did.
     */
    class GeolocateControl implements IControl {
      constructor(options?: {
        positionOptions?: { enableHighAccuracy?: boolean; timeout?: number };
        trackUserLocation?: boolean;
        showUserLocation?: boolean;
        showAccuracyCircle?: boolean;
      });
      onAdd(map: Map): HTMLElement;
      onRemove(map: Map): void;
    }
  }
}

export {};
