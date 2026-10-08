#!/usr/bin/env python3
"""tools/tiles-warm.py — pre-warm the basemap tile cache for the regions the
routing engine already covers.

The dial's map tiles are proxied + disk-cached same-origin by server/serve-static
(/tiles/{layer}/{z}/{y}/{x}). On-demand that cache fills itself as you pan; this
makes it INTENTIONAL — a twin of the prebuilt Valhalla atlas (SF + Berlin, see
tools/valhalla-local.sh). After a warm, the map is guaranteed-offline for those
regions (Tor / mesh / air-gapped), same as routing already is.

It just replays the exact requests the browser would make — GET through the
LOCAL proxy — so the warmed bytes are identical to on-demand ones, and it
inherits whatever the server is configured with (PLAYNET_TILES_TOR, etc). Needs
`make serve` running.

  make tiles-warm                     # default regions + zooms
  ZMIN=8 ZMAX=15 make tiles-warm      # deeper (more tiles!)
  REGIONS=berlin make tiles-warm      # just one

Env: PROXY (default http://127.0.0.1:8080), ZMIN (8), ZMAX (14), REGIONS (all),
     LAYERS (sat,labels).
"""
import math, os, sys, urllib.request, urllib.error

PROXY = os.environ.get("PROXY", "http://127.0.0.1:8080").rstrip("/")
ZMIN = int(os.environ.get("ZMIN", "8"))
ZMAX = int(os.environ.get("ZMAX", "13"))  # the map's default open zoom; bump for street detail
LAYERS = [s for s in os.environ.get("LAYERS", "sat,labels").split(",") if s]

# Twin of the Valhalla atlas (tools/valhalla-local.sh). Boxes are (W, S, E, N).
# LA/Bulgaria are parked there too — add rows here to match if you restore them.
REGIONS = {
    "sanfrancisco": (-122.63, 37.11, -121.57, 38.09),
    "berlin":       (13.05, 52.33, 13.77, 52.68),
}


def deg2tile(lon, lat, z):
    n = 2 ** z
    x = int((lon + 180.0) / 360.0 * n)
    lat_r = math.radians(lat)
    y = int((1.0 - math.asinh(math.tan(lat_r)) / math.pi) / 2.0 * n)
    return max(0, min(n - 1, x)), max(0, min(n - 1, y))


def tiles_for(region, z):
    w, s, e, n = region
    x0, y0 = deg2tile(w, n, z)   # NW corner: min x, min y
    x1, y1 = deg2tile(e, s, z)   # SE corner: max x, max y
    for x in range(min(x0, x1), max(x0, x1) + 1):
        for y in range(min(y0, y1), max(y0, y1) + 1):
            yield x, y


def main():
    wanted = os.environ.get("REGIONS")
    names = [r.strip() for r in wanted.split(",")] if wanted else list(REGIONS)
    for name in names:
        if name not in REGIONS:
            print(f"unknown region {name!r}; known: {', '.join(REGIONS)}")
            return 1

    # Count first — never silently pull a huge set.
    plan = []
    for name in names:
        for z in range(ZMIN, ZMAX + 1):
            coords = list(tiles_for(REGIONS[name], z))
            for layer in LAYERS:
                plan.append((name, layer, z, coords))
    total = sum(len(c) for _, _, _, c in plan)
    print(f"warming {total} tiles: regions={names} layers={LAYERS} "
          f"z={ZMIN}..{ZMAX} via {PROXY}")

    done = ok = fail = 0
    for name, layer, z, coords in plan:
        for x, y in coords:
            url = f"{PROXY}/tiles/{layer}/{z}/{y}/{x}"
            try:
                with urllib.request.urlopen(url, timeout=30) as r:
                    ok += 1 if r.status == 200 else 0
            except (urllib.error.URLError, OSError):
                fail += 1
            done += 1
            if done % 100 == 0 or done == total:
                print(f"  {done}/{total}  ok={ok} fail={fail}", flush=True)
    print(f"done: {ok} cached, {fail} failed (of {total}).")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\ntiles-warm: stopped")
