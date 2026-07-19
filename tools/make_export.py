#!/usr/bin/env python3
"""make_export.py -- pack every terrain deliverable into one shareable dist/Export.zip.

Layout inside the zip:
  webmap/index.html        the whole self-contained live map
  terrain3d/               display model (obj+mtl+png, glb), game-exact raw model, printable STL
  heightmap-data/          the raw tensor drop (bin + 16-bit png + meta + README)
  ingame/Terrain.lua       the in-game height oracle
  terrain_almanac.txt      the stats report, captured at pack time

Run:  python tools/make_export.py    (after the rest of the pipeline; build_all.ps1 does this last)
"""
import pathlib, subprocess, sys, zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "dist" / "Export.zip"

CONTENT = [
    ("webmap/index.html", ROOT / "dist" / "index.html"),
    ("ingame/Terrain.lua", ROOT / "ingame" / "Terrain.lua"),
]
for f in sorted((ROOT / "dist" / "terrain3d").glob("*")):
    CONTENT.append(("terrain3d/" + f.name, f))
for f in sorted((ROOT / "dist" / "heightmap-data").glob("*")):
    CONTENT.append(("heightmap-data/" + f.name, f))


def main():
    missing = [str(p) for _, p in CONTENT if not p.exists()]
    if missing:
        raise SystemExit("[export] missing (run build_all.ps1 first):\n  " + "\n  ".join(missing))

    almanac = subprocess.run([sys.executable, str(ROOT / "tools" / "terrain_report.py")],
                             capture_output=True, text=True).stdout

    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for arc, p in CONTENT:
            z.write(p, arc)
        z.writestr("terrain_almanac.txt", almanac)

    mb = OUT.stat().st_size / 1048576.0
    print("[export] %d files -> %s (%.1f MB)" % (len(CONTENT) + 1, OUT, mb))


if __name__ == "__main__":
    raise SystemExit(main())
