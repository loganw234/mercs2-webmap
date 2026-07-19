#!/usr/bin/env python3
"""build_terrain_3d.py -- turn the dense height tensor into a textured 3D terrain model.

Reads src/data/heightmap.js (run tools/build_heightmap.py first) and writes into dist/terrain3d/:
  terrain.obj + terrain.mtl + terrain_diffuse.png   -- classic trio (Blender, MeshLab, 3D Viewer)
  terrain.glb                                       -- single-file glTF 2.0 with the texture EMBEDDED
                                                       (drag-and-drop shareable; Windows 3D Viewer, web)

The texture is baked with the SAME rendering as the map page's overlay -- split hypsometric ramp anchored
at the -35 coastline (bathymetry below, green-up land above) with Horn hillshade -- so the model matches
the webmap's look. Holes are filled for mesh continuity (same 2-ring neighbour interpolation as the page);
cells with no data anywhere near them become flat sea surface (-35) painted as water.

Run:  python tools/build_terrain_3d.py [--step 1] [--zscale 1.0] [--texscale 2]
  --step N     take every Nth cell (2 = quarter the triangles, for lighter models)
  --zscale F   vertical exaggeration (1.0 = true scale; terrain reads well at 1.5-2)
  --texscale N texture pixels per cell (2 = smoother shading than 1)
"""
import json, math, base64, struct, zlib, pathlib, argparse

ROOT = pathlib.Path(__file__).resolve().parent.parent
HM_JS = ROOT / "src" / "data" / "heightmap.js"
OUT_DIR = ROOT / "dist" / "terrain3d"

SENTINEL = -32768
SEA_LEVEL = -35.0

# same palettes as 34_heightmap.js
LAND_STOPS = [(0.0, (72, 142, 82)), (0.3, (140, 182, 74)), (0.55, (214, 202, 84)), (0.78, (212, 124, 46)), (1.0, (172, 50, 50))]
BATHY_STOPS = [(0.0, (14, 38, 74)), (1.0, (66, 146, 196))]


def ramp_of(stops, t):
    t = 0.0 if t < 0 else 1.0 if t > 1 else t
    for i in range(1, len(stops)):
        if t <= stops[i][0]:
            (t0, a), (t1, b) = stops[i - 1], stops[i]
            f = (t - t0) / ((t1 - t0) or 1)
            return tuple(round(a[k] + (b[k] - a[k]) * f) for k in range(3))
    return stops[-1][1]


def write_png(path, w, h, rows):
    """rows = list of h bytearrays, each 3*w RGB bytes. Pure-stdlib PNG writer. Returns the PNG bytes."""
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 6))
           + chunk(b"IEND", b""))
    path.write_bytes(png)
    return png


def write_glb(path, positions, uvs, indices, png_bytes):
    """Minimal glTF 2.0 binary: one mesh primitive, one embedded PNG texture. Pure stdlib."""
    nv, ni = len(positions) // 3, len(indices)
    pos = struct.pack("<%df" % len(positions), *positions)
    uv = struct.pack("<%df" % len(uvs), *uvs)
    idx = struct.pack("<%dI" % ni, *indices)

    def pad4(b, fill=b"\x00"):
        return b + fill * ((4 - len(b) % 4) % 4)

    pos, uv, idx = pad4(pos), pad4(uv), pad4(idx)
    img = pad4(png_bytes)
    off_pos, off_uv, off_idx = 0, len(pos), len(pos) + len(uv)
    off_img = off_idx + len(idx)
    bin_chunk = pos + uv + idx + img

    mins = [min(positions[i::3]) for i in range(3)]
    maxs = [max(positions[i::3]) for i in range(3)]
    gltf = {
        "asset": {"version": "2.0", "generator": "mercs2-webmap build_terrain_3d.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": "Mercs2Terrain"}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "TEXCOORD_0": 1}, "indices": 2, "material": 0}]}],
        "materials": [{"pbrMetallicRoughness": {"baseColorTexture": {"index": 0}, "metallicFactor": 0.0, "roughnessFactor": 1.0}, "name": "terrain"}],
        "textures": [{"source": 0, "sampler": 0}],
        "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 33071, "wrapT": 33071}],
        "images": [{"bufferView": 3, "mimeType": "image/png"}],
        "buffers": [{"byteLength": len(bin_chunk)}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": off_pos, "byteLength": len(pos), "target": 34962},
            {"buffer": 0, "byteOffset": off_uv, "byteLength": len(uv), "target": 34962},
            {"buffer": 0, "byteOffset": off_idx, "byteLength": len(idx), "target": 34963},
            {"buffer": 0, "byteOffset": off_img, "byteLength": len(png_bytes)},
        ],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": nv, "type": "VEC3", "min": mins, "max": maxs},
            {"bufferView": 1, "componentType": 5126, "count": nv, "type": "VEC2"},
            {"bufferView": 2, "componentType": 5125, "count": ni, "type": "SCALAR"},
        ],
    }
    js = pad4(json.dumps(gltf, separators=(",", ":")).encode("utf-8"), b" ")
    total = 12 + 8 + len(js) + 8 + len(bin_chunk)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))              # glTF magic, version, length
        f.write(struct.pack("<II", len(js), 0x4E4F534A) + js)           # JSON chunk
        f.write(struct.pack("<II", len(bin_chunk), 0x004E4942) + bin_chunk)   # BIN chunk


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--step", type=int, default=1, help="take every Nth cell (mesh decimation)")
    ap.add_argument("--zscale", type=float, default=1.0, help="vertical exaggeration")
    ap.add_argument("--texscale", type=int, default=2, help="texture pixels per cell")
    ap.add_argument("--raw", action="store_true",
                    help="GAME-EXACT export (terrain_raw.*): true world coords -- no x mirror, no vertical "
                         "exaggeration, full resolution. Use this one for reimporting into the game.")
    args = ap.parse_args()

    src = HM_JS.read_text(encoding="utf-8")
    data = json.loads(src[src.index('{"cell"'):src.rindex("}") + 1])
    cell, ox, oz, w, h = data["cell"], data["ox"], data["oz"], data["w"], data["h"]
    q = struct.unpack("<%dh" % (w * h), base64.b64decode(data["heightsB64"]))

    # heights in world units, holes filled: 2-ring IDW where >=3 known neighbours, else flat sea surface
    H = [SEA_LEVEL] * (w * h)
    known = bytearray(w * h)
    for i, v in enumerate(q):
        if v != SENTINEL:
            H[i] = v / 10.0
            known[i] = 1
    for iz in range(h):
        for ix in range(w):
            i = iz * w + ix
            if known[i]:
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
                known[i] = 2   # interpolated

    # colour anchors, same rule as the page: land ramp tops out at p98 of land heights
    land = sorted(v for i, v in enumerate(H) if known[i] and v > SEA_LEVEL)
    ramp_hi = land[int(len(land) * 0.98)] if land else 400.0
    bathy_lo = min((v for v in H if v < SEA_LEVEL), default=-167.0)

    def color_for(hv):
        if hv <= SEA_LEVEL:
            return ramp_of(BATHY_STOPS, (hv - bathy_lo) / ((SEA_LEVEL - bathy_lo) or 1))
        return ramp_of(LAND_STOPS, (hv - SEA_LEVEL) / ((ramp_hi - SEA_LEVEL) or 1))

    def height_at(ix, iz):   # clamped grid lookup (for shading)
        ix = 0 if ix < 0 else w - 1 if ix >= w else ix
        iz = 0 if iz < 0 else h - 1 if iz >= h else iz
        return H[iz * w + ix]

    def shade(ix, iz):   # Horn hillshade, sun NW @ 45deg, 1.6x exaggeration -- same as the page
        dzdx = ((height_at(ix + 1, iz - 1) + 2 * height_at(ix + 1, iz) + height_at(ix + 1, iz + 1))
                - (height_at(ix - 1, iz - 1) + 2 * height_at(ix - 1, iz) + height_at(ix - 1, iz + 1))) / (8 * cell)
        dzdz = ((height_at(ix - 1, iz + 1) + 2 * height_at(ix, iz + 1) + height_at(ix + 1, iz + 1))
                - (height_at(ix - 1, iz - 1) + 2 * height_at(ix, iz - 1) + height_at(ix + 1, iz - 1))) / (8 * cell)
        slope = math.atan(1.6 * math.hypot(dzdx, dzdz))
        aspect = math.atan2(dzdz, -dzdx)
        az, alt = math.radians(315), math.radians(45)
        s = math.cos(alt) * math.cos(slope) + math.sin(alt) * math.sin(slope) * math.cos(az - aspect)
        return max(0.0, s)

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # ---- texture: texscale px per cell, grid-aligned (uv maps straight to grid, no flips to reason about)
    ts = max(1, args.texscale)
    tw, th = w * ts, h * ts
    rows = []
    for py in range(th):
        iz = py // ts
        row = bytearray(tw * 3)
        for px_ in range(tw):
            ix = px_ // ts
            col = color_for(H[iz * w + ix])
            s = 0.35 + 0.75 * shade(ix, iz)
            for k in range(3):
                v = int(col[k] * s)
                row[px_ * 3 + k] = 255 if v > 255 else v
        rows.append(row)
    png_bytes = write_png(OUT_DIR / "terrain_diffuse.png", tw, th, rows)

    # ---- mesh arrays: vertex per cell centre (every step-th), y = height * zscale.
    # DISPLAY model: x = -world_x (un-mirrors the west-positive game axis to match the map page view).
    # RAW model (--raw): true world coords, zscale 1, step 1 -- vertex(x,y,z) == in-game (x,y,z) exactly.
    step = 1 if args.raw else max(1, args.step)
    zsc = 1.0 if args.raw else args.zscale
    xsign = 1.0 if args.raw else -1.0
    xs = list(range(0, w, step))
    zs = list(range(0, h, step))
    nx, nz = len(xs), len(zs)
    positions, uvs = [], []
    for iz in zs:
        for ix in xs:
            positions.extend((xsign * (ox + ix + 0.5) * cell, H[iz * w + ix] * zsc, (oz + iz + 0.5) * cell))
            uvs.extend(((ix + 0.5) / w, (iz + 0.5) / h))   # glTF v runs top-down = our row order
    indices = []
    for r in range(nz - 1):
        for c in range(nx - 1):
            a = r * nx + c
            b, cc, d = a + 1, a + nx, a + nx + 1
            if args.raw: indices.extend((a, cc, b, b, cc, d))   # winding flips with the un-mirrored x axis
            else: indices.extend((a, b, cc, b, d, cc))

    # ---- OBJ + MTL (v flipped: OBJ vt origin is bottom-left)
    name = "terrain_raw" if args.raw else "terrain"
    with open(OUT_DIR / (name + ".obj"), "w", encoding="ascii") as f:
        f.write("# Mercs2 terrain -- generated by tools/build_terrain_3d.py%s\n" % (" (RAW: true world coords)" if args.raw else ""))
        f.write("# grid %dx%d, cell %du, zscale %.2f, y-up; +x %s, +z world +z\n"
                % (nx, nz, cell * step, zsc, "WORLD +x (game-exact)" if args.raw else "east (world -x, map-view mirror)"))
        f.write("mtllib %s.mtl\nusemtl terrain\n" % name)
        for i in range(0, len(positions), 3):
            f.write("v %.1f %.2f %.1f\n" % (positions[i], positions[i + 1], positions[i + 2]))
        for i in range(0, len(uvs), 2):
            f.write("vt %.5f %.5f\n" % (uvs[i], 1.0 - uvs[i + 1]))
        for i in range(0, len(indices), 3):
            a, b, c = indices[i] + 1, indices[i + 1] + 1, indices[i + 2] + 1
            f.write("f %d/%d %d/%d %d/%d\n" % (a, a, b, b, c, c))
    (OUT_DIR / (name + ".mtl")).write_text(
        "newmtl terrain\nKa 1 1 1\nKd 1 1 1\nKs 0 0 0\nillum 1\nmap_Kd terrain_diffuse.png\n", encoding="ascii")

    # ---- GLB (single file, texture embedded)
    write_glb(OUT_DIR / (name + ".glb"), positions, uvs, indices, png_bytes)

    glb_mb = (OUT_DIR / (name + ".glb")).stat().st_size / 1048576.0
    print("[terrain3d] %s: %dx%d verts (%d tris), texture %dx%d -> %s" % (name, nx, nz, len(indices) // 3, tw, th, OUT_DIR))
    print("[terrain3d] %s.obj (+mtl+png) and %s.glb (%.1f MB, self-contained)%s"
          % (name, name, glb_mb, " -- vertex(x,y,z) == in-game coords" if args.raw else ""))


if __name__ == "__main__":
    raise SystemExit(main())
