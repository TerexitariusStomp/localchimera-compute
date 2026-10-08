// app/topojson.d.ts — the topojson-client surface the dial calls.
//
// The third hand-declared foreign global, and by far the smallest: the dial
// calls exactly one function. Vendored as a classic script alongside d3, so a
// global rather than an import, under the same declare-on-first-use policy.
//
// TopoJSON stores a topology — shared arcs, quantised — which is why the
// vendored boundary files are a fraction of the GeoJSON they expand to. It is
// not drawable as it stands: `feature` is the one call that turns a named
// object inside a topology back into the GeoJSON a projection can path.

declare global {
  namespace topojson {
    /**
     * A topology as the vendored files carry it. `objects` is deliberately
     * loose — the caller names the one it wants ("states", "countries") and
     * that name is the only claim being made about the file's contents.
     */
    interface Topology {
      type: "Topology";
      objects: Record<string, unknown>;
      arcs: number[][][];
    }

    /** Expand a named object of a topology into drawable GeoJSON. */
    function feature(topology: Topology, object: unknown): maplibregl.FeatureCollection;
  }
}

export {};
