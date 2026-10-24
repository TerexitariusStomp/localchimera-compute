#!/usr/bin/env python3
"""fetch-fr-parcels.py — one French commune's cadastral parcels as places.

    tools/law/fetch-fr-parcels.py <insee> > data/law/fr-<insee>-parcels.sexp

A parcel's `contained-in` is the COMMUNE, never its zone. Measured on a real
test commune, about 5% of parcels are cut by a zone-TYPE boundary and 7% by a
zone label — and
`contained-in` is single-parent, so a zone cannot be a parcel's container without
lying about one parcel in twenty. The zones a parcel touches ride `within`
instead, so a straddling parcel becomes several endpoints and meets BOTH zones'
rules, doubly-wrapped by the same mechanism that wraps a transport arc.

Kind is `parcel`, deliberately not `locality`: the law-face snapshot draws
nations, regions and localities, and a commune's few thousand parcels are its own
inventory rather than a jurisdiction anyone legislates over. For the same reason
this writes OUTSIDE docs/legal/contexts/ — it is not a context pack, it is the
places half of one, for a scope to seed its own store from.

OWNERSHIP is absent and cannot be otherwise: the cadastre carries geometry and
fiscal attributes, while owners live in the publicité foncière — closed, per
parcel, paid. That is not a gap to close by scraping. A member DECLARES what they
hold, the declaration is an ownership attestation, and `title-permits?`
(socialization.scm) enforces it; the state register is what one consults to
CONTEST a claim, not to populate one.

Sources: cadastre.data.gouv.fr (Etalab GeoJSON), apicarto.ign.fr/api/gpu.
"""
import gzip, json, math, re, sys, urllib.request

UA = {"User-Agent": "localchimera-law-ingest/1.0"}

def fetch(url, gz=False, tries=4):
    # the open services reset a connection now and then; a bulk pull that dies
    # halfway is worse than a slow one
    for n in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=180) as r:
                raw = r.read()
            break
        except Exception:
            if n == tries - 1:
                raise
            import time; time.sleep(2 * (n + 1))
    if gz or url.endswith(".gz"):
        try:
            return json.loads(gzip.decompress(raw))
        except Exception:
            pass
    return json.loads(raw)

def rings(g):
    cs = g["coordinates"]
    return cs if g["type"] == "MultiPolygon" else [cs]

def bbox(g):
    xs, ys = [], []
    for p in rings(g):
        for r in p:
            for x, y in r:
                xs.append(x); ys.append(y)
    return min(xs), min(ys), max(xs), max(ys)

def in_ring(pt, r):
    x, y = pt; c = False
    for i in range(len(r) - 1):
        x1, y1 = r[i]; x2, y2 = r[i + 1]
        if ((y1 > y) != (y2 > y)) and (x < (x2 - x1) * (y - y1) / (y2 - y1) + x1):
            c = not c
    return c

def in_poly(pt, g):
    for p in rings(g):
        if in_ring(pt, p[0]) and not any(in_ring(pt, h) for h in p[1:]):
            return True
    return False

def probes(g, n=9):
    """Interior probe points: the centroid, and vertices pulled toward it.

    Sampling a parcel's own VERTICES is what a first pass did, and it reported
    25% of parcels as straddling — an artifact, because a parcel edge lying on a
    zone edge ray-casts ambiguously. Pulled inward the honest figure is 5%."""
    out = []
    for p in rings(g):
        r = p[0]
        cx = sum(q[0] for q in r[:-1]) / (len(r) - 1)
        cy = sum(q[1] for q in r[:-1]) / (len(r) - 1)
        step = max(1, (len(r) - 1) // n)
        cand = [(cx, cy)] + [(x + 0.15 * (cx - x), y + 0.15 * (cy - y))
                             for x, y in [r[i] for i in range(0, len(r) - 1, step)][:n]]
        out += [q for q in cand if in_poly(q, g)]
    return out or [(0, 0)]

def scm_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'

def extents_path(insee):
    return "data/law/fr-%s-parcels.geojson" % insee

def main(insee, limit=None):
    dep = insee[:2] if not insee.startswith("97") else insee[:3]
    # `latest/` redirects to a dated release; its listing names the real file
    listing = None
    for n in range(4):
        try:
            listing = urllib.request.urlopen(urllib.request.Request(
                "https://cadastre.data.gouv.fr/data/etalab-cadastre/latest/geojson/communes/%s/%s/"
                % (dep, insee), headers=UA), timeout=120).read().decode()
            break
        except Exception:
            if n == 3:
                raise
            import time; time.sleep(2 * (n + 1))
    m = re.search(r'href="([^"]*cadastre-%s-parcelles\.json\.gz)"' % insee, listing)
    url = "https://cadastre.data.gouv.fr" + m.group(1) if m else None
    parcels = fetch(url)["features"]
    zones = fetch("https://apicarto.ign.fr/api/gpu/zone-urba?partition=DU_%s" % insee)["features"]
    if limit:
        parcels = parcels[:limit]

    zs = [(f["properties"]["libelle"], f["properties"]["typezone"], f["geometry"],
           bbox(f["geometry"])) for f in zones]

    def zones_of(g):
        hit = []
        for q in probes(g):
            for lb, tz, zg, (a, b, c, d) in zs:
                if a <= q[0] <= c and b <= q[1] <= d and in_poly(q, zg):
                    if lb not in hit:
                        hit.append(lb)
                    break
        return hit

    com = "fr-%s" % insee
    rows, straddle, unzoned = [], 0, 0
    for f in parcels:
        p = f["properties"]; g = f["geometry"]
        zl = zones_of(g)
        if not zl:
            unzoned += 1
        if len({z for z in zl}) > 1:
            straddle += 1
        r = rings(g)[0][0]
        cx = sum(q[0] for q in r[:-1]) / (len(r) - 1)
        cy = sum(q[1] for q in r[:-1]) / (len(r) - 1)
        extra = "((section . %s) (numero . %s) (contenance . %s)%s)" % (
            scm_str(p.get("section")), scm_str(p.get("numero")), p.get("contenance") or 0,
            (" (within . (%s))" % " ".join(scm_str("%s-%s" % (com, z)) for z in zl)) if zl else "")
        rows.append('  (%s %s %s parcel %s %.6f %.6f)' % (
            scm_str(p["id"]), scm_str("Parcelle %s %s" % (p.get("section"), p.get("numero"))),
            scm_str(com), extra, cy, cx))

    hdr = [
        ";;; fr-%s-parcels.sexp — the commune's cadastral parcels, as places." % insee,
        ";;; tools/law/fetch-fr-parcels.py %s" % insee,
        ";;; %d parcels · %d straddle a zone boundary (%.1f%%) · %d fall in no zone"
        % (len(rows), straddle, 100.0 * straddle / max(1, len(rows)), unzoned),
        ";;;",
        ";;; contained-in is the COMMUNE; the zones a parcel touches ride `within`, so a",
        ";;; parcel cut by a zone line becomes several endpoints and meets both zones'",
        ";;; rules. A single-parent `contained-in` would have to pick one and be wrong",
        ";;; about one parcel in twenty.",
        ";;;",
        ";;; NO OWNER: the cadastre is geometry and tax, the publicité foncière is closed.",
        ";;; A holder is DECLARED by the member and enforced by `title-permits?`.",
        ";;;",
        ";;; The polygons themselves are written beside this as %s," % extents_path(insee),
        ";;; on the boundaries convention (properties.id + derivation) — so the `within`",
        ";;; assignments above can be checked and redone rather than taken on trust.",
    ]
    # ── the EXTENTS, on the single source ────────────────────────────────────
    # The polygons were fetched and then thrown away: the pack kept a centroid,
    # and the zone a parcel stands `within` was decided by a point-in-polygon
    # test in this script, whose answer nothing downstream could check or redo.
    # `browser/data/geo/boundaries.json` is where a SpatialThing's extent lives
    # (properties.id names the thing, `derivation` says where the polygon came
    # from) — the convention tools/qgis/ingest-boundaries.scm writes for
    # DEM-derived bioregion sheds. A parcel's extent is the same kind of fact,
    # so it is written the same way, and the `within` assignment stops being a
    # claim only this script can make.
    #
    # A SEPARATE file, not boundaries.json: that one holds four bioregion sheds
    # and is read at boot by every scope. A commune's few thousand parcels are
    # its own inventory and are loaded by path when a scope wants them.
    derivation = {
        "source": "cadastre.data.gouv.fr — Etalab GeoJSON (DGFiP plan cadastral informatisé)",
        "zones": "apicarto.ign.fr/api/gpu zone-urba, by partition",
        "within": ("interior probe points: the centroid plus vertices pulled 15% toward it, "
                   "point-in-polygon against each zone. Parcel VERTICES alone report ~25% "
                   "straddling, an artifact of an edge lying on a zone edge; pulled inward "
                   "the figure is 7%."),
        "tool": "tools/law/fetch-fr-parcels.py",
    }
    fc = {"type": "FeatureCollection", "features": [
        {"type": "Feature",
         "geometry": f["geometry"],
         "properties": {"id": f["properties"]["id"],
                        "name": "Parcelle %s %s" % (f["properties"].get("section"),
                                                    f["properties"].get("numero")),
                        "tier": "parcel",
                        "commune": com,
                        "within": zones_of(f["geometry"]),
                        "derivation": derivation}}
        for f in parcels]}
    import os
    os.makedirs(os.path.dirname(extents_path(insee)) or ".", exist_ok=True)
    with open(extents_path(insee), "w", encoding="utf-8") as fh:
        json.dump(fc, fh, ensure_ascii=False)
    sys.stderr.write("wrote %s (%d extents)\n" % (extents_path(insee), len(fc["features"])))

    sys.stdout.write("\n".join(hdr) + "\n((places\n" + "\n".join(rows) + ")\n (rules))\n")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: fetch-fr-parcels.py <insee> [limit]")
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else None)
