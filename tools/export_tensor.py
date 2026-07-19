#!/usr/bin/env python3
"""export_tensor.py -- publish the height tensor as standalone, tool-agnostic data files.

For anyone who wants the raw terrain data without our pipeline. Writes dist/heightmap-data/:
  heights.bin     raw little-endian int16, row-major w*h -- height*10 (0.1u), -32768 = never scanned
  tiers.bin       raw uint8, same layout -- source authority per cell (5=road..1=heli, 0=none)
  heightmap.png   16-bit grayscale PNG, value = height*10 + 32768 (0 = never scanned) -- drops straight
                  into Blender/Unity/QGIS as a displacement/height texture
  meta.json       grid geometry, encoding, axes and provenance -- everything needed to consume the above
  README.md       the format, worked Python/JS examples

Run:  python tools/export_tensor.py    (after tools/build_heightmap.py)
"""
import json, base64, struct, zlib, pathlib, datetime

ROOT = pathlib.Path(__file__).resolve().parent.parent
HM_JS = ROOT / "src" / "data" / "heightmap.js"
OUT_DIR = ROOT / "dist" / "heightmap-data"

SENTINEL = -32768
SEA_LEVEL = -35.0


def write_png16(path, w, h, values):
    """16-bit grayscale PNG (big-endian samples per spec). values = iterable of uint16, row-major."""
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    rows = []
    it = iter(values)
    for _ in range(h):
        rows.append(b"\x00" + struct.pack(">%dH" % w, *(next(it) for _ in range(w))))
    path.write_bytes(b"\x89PNG\r\n\x1a\n"
                     + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 16, 0, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(b"".join(rows), 6))
                     + chunk(b"IEND", b""))


def main():
    src = HM_JS.read_text(encoding="utf-8")
    data = json.loads(src[src.index('{"cell"'):src.rindex("}") + 1])
    cell, ox, oz, w, h = data["cell"], data["ox"], data["oz"], data["w"], data["h"]
    heights = base64.b64decode(data["heightsB64"])
    tiers = base64.b64decode(data["tiersB64"])
    q = struct.unpack("<%dh" % (w * h), heights)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    (OUT_DIR / "heights.bin").write_bytes(heights)
    (OUT_DIR / "tiers.bin").write_bytes(tiers)
    write_png16(OUT_DIR / "heightmap.png", w, h,
                (0 if v == SENTINEL else v + 32768 for v in q))

    known = sum(1 for v in q if v != SENTINEL)
    meta = {
        "format": "mercs2 terrain height tensor",
        "version": 1,
        "generated": datetime.date.today().isoformat(),
        "grid": {
            "cell_world_units": cell,
            "width_cells": w, "height_cells": h,
            "origin_cell_x": ox, "origin_cell_z": oz,
            "layout": "row-major: index = (cz - origin_cell_z) * width_cells + (cx - origin_cell_x), "
                      "where cx = floor(world_x / cell), cz = floor(world_z / cell)",
            "cell_center_world": "world_x = (origin_cell_x + ix + 0.5) * cell  (same for z)",
        },
        "heights_bin": {"dtype": "int16 little-endian", "scale": "value / 10 = height in world units",
                        "sentinel": SENTINEL, "meaning_of_sentinel": "never scanned"},
        "tiers_bin": {"dtype": "uint8", "values": {"5": "vehicle (road)", "4": "on foot", "3": "terrain probe",
                                                   "2": "grid probe", "1": "heli sweep", "0": "no data"}},
        "heightmap_png": {"depth": "16-bit grayscale", "encoding": "pixel = height*10 + 32768; 0 = never scanned",
                          "note": "pixel row 0 = MINIMUM world z (south); world +x increases with pixel column"},
        "world": {"axes": "y is UP; x runs WEST-positive in-game; z north-positive",
                  "sea_level": SEA_LEVEL, "deepest_seabed_approx": -167.2,
                  "map_extent": "roughly +/-4002 world units on x and z, 1 world unit ~= 1 m"},
        "coverage": {"scanned_cells": known, "total_cells": w * h,
                     "percent": round(100.0 * known / (w * h), 1)},
        "source_logs": data.get("logs", []),
        "samples": data.get("n", 0),
    }
    (OUT_DIR / "meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")

    (OUT_DIR / "README.md").write_text("""# Mercs2 terrain height tensor

Ground-height grid of the Mercenaries 2 world, recovered in-game via `Object.GetHeightAboveTerrain`
camera-probe sweeps (16 world-unit cells, 1 wu ~= 1 m). See `meta.json` for exact geometry + coverage.

## Files
| file | what |
|---|---|
| `heights.bin` | int16 LE, row-major `w*h`; **height*10** in world units; `-32768` = never scanned |
| `tiers.bin` | uint8, same layout; data source per cell (5=road, 4=foot, 3=terrain probe, 2=grid, 1=heli, 0=none) |
| `heightmap.png` | 16-bit grayscale; `pixel = height*10 + 32768`, `0` = never scanned |
| `meta.json` | grid origin/size, encodings, axes, provenance |

## Reading it (Python)
```python
import json, struct
meta = json.load(open("meta.json"))
g = meta["grid"]; w, h = g["width_cells"], g["height_cells"]
q = struct.unpack("<%dh" % (w*h), open("heights.bin","rb").read())

def height_at(world_x, world_z):          # world units -> height or None
    ix = world_x // g["cell_world_units"] - g["origin_cell_x"]
    iz = world_z // g["cell_world_units"] - g["origin_cell_z"]
    if not (0 <= ix < w and 0 <= iz < h): return None
    v = q[int(iz)*w + int(ix)]
    return None if v == -32768 else v / 10
```

## Reading it (JS)
```js
const q = new Int16Array(await (await fetch("heights.bin")).arrayBuffer());
// index = (Math.floor(z/cell) - oz) * w + (Math.floor(x/cell) - ox);  q[i] === -32768 -> no data, else /10
```

Water surface sits at **-35**; anything lower is seabed (down to ~-167). Heights are the terrain mesh --
bridges/buildings are not separate (a heightfield has no overhangs).
""", encoding="utf-8")

    kb = sum((OUT_DIR / f).stat().st_size for f in ("heights.bin", "tiers.bin", "heightmap.png")) // 1024
    print("[tensor-export] %d/%d cells -> %s (bin+png+meta, %d KB)" % (known, w * h, OUT_DIR, kb))


if __name__ == "__main__":
    raise SystemExit(main())
