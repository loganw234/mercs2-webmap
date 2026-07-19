#!/usr/bin/env python3
"""build_terrain_stl.py -- turn the height tensor into a WATERTIGHT, 3D-PRINTABLE solid (binary STL).

Top surface = the terrain (holes filled, unscanned = flat sea), perimeter walls straight down, and a
fan-triangulated base -- a closed manifold solid a slicer will take as-is. Physical desk Venezuela.

Run:  python tools/build_terrain_stl.py [--size 180] [--zscale 1.8] [--step 2] [--base 3]
  --size MM    longest horizontal edge of the print, in mm (default 180 -- fits a common 220mm bed)
  --zscale F   vertical exaggeration on top of true scale (default 1.8; true scale prints nearly flat)
  --step N     take every Nth cell (default 2 -> ~110k top faces; 1 = full detail, ~4x file)
  --base MM    slab thickness below the deepest point, in mm (default 3)
"""
import json, base64, struct, pathlib, argparse

ROOT = pathlib.Path(__file__).resolve().parent.parent
HM_JS = ROOT / "src" / "data" / "heightmap.js"
OUT = ROOT / "dist" / "terrain3d" / "terrain_print.stl"

SENTINEL = -32768
SEA_LEVEL = -35.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", type=float, default=180.0)
    ap.add_argument("--zscale", type=float, default=1.8)
    ap.add_argument("--step", type=int, default=2)
    ap.add_argument("--base", type=float, default=3.0)
    args = ap.parse_args()

    src = HM_JS.read_text(encoding="utf-8")
    data = json.loads(src[src.index('{"cell"'):src.rindex("}") + 1])
    cell, w, h = data["cell"], data["w"], data["h"]
    q = struct.unpack("<%dh" % (w * h), base64.b64decode(data["heightsB64"]))

    # heights, holes -> 2-ring IDW fill else sea (same policy as the model/texture)
    H = [SEA_LEVEL] * (w * h)
    for i, v in enumerate(q):
        if v != SENTINEL:
            H[i] = v / 10.0
    for iz in range(h):
        for ix in range(w):
            i = iz * w + ix
            if q[i] != SENTINEL:
                continue
            sw = sv = n = 0
            for dz in range(-2, 3):
                for dx in range(-2, 3):
                    jx, jz = ix + dx, iz + dz
                    if 0 <= jx < w and 0 <= jz < h and q[jz * w + jx] != SENTINEL:
                        wgt = 1.0 / (dx * dx + dz * dz)
                        sw += wgt; sv += (q[jz * w + jx] / 10.0) * wgt; n += 1
            if n >= 3:
                H[i] = sv / sw

    step = max(1, args.step)
    xs = list(range(0, w, step))
    zs = list(range(0, h, step))
    if xs[-1] != w - 1: xs.append(w - 1)
    if zs[-1] != h - 1: zs.append(h - 1)
    nx, nz = len(xs), len(zs)

    # mm mapping: world-units -> mm so the longest edge = --size; z gets the same factor * zscale
    span = max(w, h) * cell
    s = args.size / span
    zmin = min(H)
    base_z = 0.0                        # base plane at 0; terrain floats above it by --base
    def top(ix_i, iz_i):
        ix, iz = xs[ix_i], zs[iz_i]
        return ((w - 1 - ix) * cell * s,             # mirror x so the print matches the map view
                (h - 1 - iz) * cell * s,             # north up
                args.base + (H[iz * w + ix] - zmin) * s * args.zscale)

    tris = []
    def quad(a, b, c, d):               # split a-b-d-c ... two tris with consistent outward winding
        tris.append((a, b, c)); tris.append((b, d, c))

    # top surface (upward)
    for r in range(nz - 1):
        for c_ in range(nx - 1):
            a, b = top(c_, r), top(c_ + 1, r)
            cc, d = top(c_, r + 1), top(c_ + 1, r + 1)
            tris.append((a, cc, b)); tris.append((b, cc, d))

    # perimeter walls down to the base plane
    def wall(p1, p2):                   # p1->p2 along the rim, outward-facing quad to z=0
        b1, b2 = (p1[0], p1[1], base_z), (p2[0], p2[1], base_z)
        tris.append((p1, b1, p2)); tris.append((p2, b1, b2))
    rim = []
    for c_ in range(nx - 1): rim.append((c_, 0))
    for r in range(nz - 1): rim.append((nx - 1, r))
    for c_ in range(nx - 1, 0, -1): rim.append((c_, nz - 1))
    for r in range(nz - 1, 0, -1): rim.append((0, r))
    for k in range(len(rim)):
        (c1, r1), (c2, r2) = rim[k], rim[(k + 1) % len(rim)]
        wall(top(c1, r1), top(c2, r2))

    # base: fan from the centroid of the rim (downward-facing)
    ring = [(top(c_, r)[0], top(c_, r)[1], base_z) for (c_, r) in rim]
    cx = sum(p[0] for p in ring) / len(ring)
    cy = sum(p[1] for p in ring) / len(ring)
    centre = (cx, cy, base_z)
    for k in range(len(ring)):
        tris.append((centre, ring[k], ring[(k + 1) % len(ring)]))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(b"mercs2 terrain print" + b"\x00" * 60)
        f.write(struct.pack("<I", len(tris)))
        for a, b, c in tris:
            f.write(struct.pack("<12fH", 0, 0, 0, a[0], a[1], a[2], b[0], b[1], b[2], c[0], c[1], c[2], 0))

    dims = (max(p[0] for p in ring) - min(p[0] for p in ring),
            max(p[1] for p in ring) - min(p[1] for p in ring),
            args.base + (max(H) - zmin) * s * args.zscale)
    print("[stl] %d triangles -> %s (%.1f MB)" % (len(tris), OUT, OUT.stat().st_size / 1048576))
    print("[stl] print size: %.0f x %.0f x %.1f mm (zscale %.1f, base %.1fmm)" % (dims[0], dims[1], dims[2], args.zscale, args.base))


if __name__ == "__main__":
    raise SystemExit(main())
