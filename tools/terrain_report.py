#!/usr/bin/env python3
"""terrain_report.py -- the terrain almanac: fun/useful stats straight from the height tensor.

Run:  python tools/terrain_report.py    (after tools/build_heightmap.py)
"""
import json, base64, struct, math, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
HM_JS = ROOT / "src" / "data" / "heightmap.js"

SENTINEL = -32768
SEA_LEVEL = -35.0


def main():
    src = HM_JS.read_text(encoding="utf-8")
    data = json.loads(src[src.index('{"cell"'):src.rindex("}") + 1])
    cell, ox, oz, w, h = data["cell"], data["ox"], data["oz"], data["w"], data["h"]
    q = struct.unpack("<%dh" % (w * h), base64.b64decode(data["heightsB64"]))

    def world(i):   # cell index -> world-centre coords
        ix, iz = i % w, i // w
        return (ox + ix + 0.5) * cell, (oz + iz + 0.5) * cell

    known = [(i, v / 10.0) for i, v in enumerate(q) if v != SENTINEL]
    n = len(known)
    total = w * h
    land = [(i, hv) for i, hv in known if hv > SEA_LEVEL]
    water = n - len(land)
    km2 = (cell * cell) / 1e6   # 1u = 1m

    print("=" * 62)
    print(" MERCS 2 TERRAIN ALMANAC   (%du grid, %d x %d cells)" % (cell, w, h))
    print("=" * 62)
    print(" scanned      : %d cells (%.1f%% of grid) ~= %.1f km^2" % (n, 100.0 * n / total, n * km2))
    print(" land / water : %d / %d cells  (%.1f%% land of scanned)" % (len(land), water, 100.0 * len(land) / (n or 1)))

    hi_i, hi_v = max(known, key=lambda t: t[1])
    lo_i, lo_v = min(known, key=lambda t: t[1])
    hx, hz = world(hi_i); lx, lz = world(lo_i)
    print(" highest      : %7.1fu  at (%6.0f, %6.0f)" % (hi_v, hx, hz))
    print(" deepest      : %7.1fu  at (%6.0f, %6.0f)" % (lo_v, lx, lz))
    if land:
        mean_land = sum(hv for _, hv in land) / len(land)
        print(" mean land    : %7.1fu   (sea surface %.0fu)" % (mean_land, SEA_LEVEL))

    # steepest measured slope between adjacent cells
    best = (0.0, 0)
    for i, hv in known:
        ix = i % w
        if ix + 1 < w and q[i + 1] != SENTINEL:
            g = abs(hv - q[i + 1] / 10.0) / cell
            if g > best[0]: best = (g, i)
        if i + w < total and q[i + w] != SENTINEL:
            g = abs(hv - q[i + w] / 10.0) / cell
            if g > best[0]: best = (g, i)
    sx, sz = world(best[1])
    print(" steepest     : %7.1f deg at (%6.0f, %6.0f)" % (math.degrees(math.atan(best[0])), sx, sz))

    # hypsometric curve (land only), 12 bands
    if land:
        hs = sorted(hv for _, hv in land)
        top = hs[int(len(hs) * 0.999)]
        bands = 12
        print("\n elevation profile of the land (each # ~ share of land area)")
        for b in range(bands - 1, -1, -1):
            a = SEA_LEVEL + (top - SEA_LEVEL) * b / bands
            z2 = SEA_LEVEL + (top - SEA_LEVEL) * (b + 1) / bands
            c = sum(1 for v in hs if a <= v < z2)
            bar = "#" * max(1 if c else 0, round(60.0 * c / len(hs)))
            print("  %5.0f..%-5.0f | %s" % (a, z2, bar))

    # flat ground (buildable/landable): slope under 5 deg with all 4 neighbours known
    flat = 0
    maxg = math.tan(math.radians(5))
    for i, hv in known:
        ix, iz = i % w, i // w
        if hv <= SEA_LEVEL or ix == 0 or iz == 0 or ix == w - 1 or iz == h - 1: continue
        l, r, u, d = q[i - 1], q[i + 1], q[i - w], q[i + w]
        if SENTINEL in (l, r, u, d): continue
        gx = (r - l) / 10.0 / (2 * cell); gz = (d - u) / 10.0 / (2 * cell)
        if math.hypot(gx, gz) <= maxg: flat += 1
    if land:
        print("\n flat land (<5 deg): %d cells = %.1f%% of land (~%.1f km^2)" % (flat, 100.0 * flat / len(land), flat * km2))
    print("=" * 62)


if __name__ == "__main__":
    raise SystemExit(main())
