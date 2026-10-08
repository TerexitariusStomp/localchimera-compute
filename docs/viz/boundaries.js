// boundaries.js — vendored REAL admin / parcel polygons for ecosystem-live-map regions.
// ---------------------------------------------------------------------------------------------
// A place's `area` in flows-map-data.js may be a STRING id that looks up here, e.g.
//     { id:"ams", area:"ams" }   →   window.__boundaries.ams
// Each entry is an outer ring of [lng,lat] pairs. Empty by default → the inline `area` rings in
// flows-map-data.js are used as-is, so nothing changes until you populate this.
//
// To fill with REAL boundaries, fetch over Tor (keeps your clearnet IP private) and simplify to a
// single outer ring, e.g. via OSM Nominatim (returns GeoJSON polygon you can thin):
//     torsocks curl 'https://nominatim.openstreetmap.org/search?q=Gemeente+Amsterdam&polygon_geojson=1&format=json'
//     torsocks curl 'https://nominatim.openstreetmap.org/search?q=Flevoland&polygon_geojson=1&format=json'
//   take .[0].geojson.coordinates[0] (outer ring), optionally Douglas–Peucker simplify, and paste as
//   ams: [[lng,lat], …]. For multipolygons, pick the largest ring (or extend traceRegion for holes).
window.__boundaries = {
  // ams:   [[4.72,52.31],[4.75,52.43], /* … real municipality outline … */ ],
  // flevo: [[/* … */]],
};
