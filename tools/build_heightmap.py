#!/usr/bin/env python3
"""build_heightmap.py -- turn position logs into a DENSE height tensor for the webmap.

Reads every data/*.log, pulls out `x= y= z=` samples (y = height -- works for [ROAD] drive logs, [TERRAIN]
GroundStream rasters, AND [LOCATION] "standing here" captures), bins them to a grid, and packs the result as
a dense row-major Int16 array (base64) instead of a sparse JSON dict: at 16u full-map coverage (~251k cells)
that's ~0.7 MB embedded vs ~7 MB of JSON, decodes to a typed array in one pass, and makes heightAt() pure
index math. Each occupied cell stores the MEDIAN height of its best-tier samples; median (not mean) shrugs
off outliers, and re-scanning a spot only sharpens the estimate.

Output is src/data/heightmap.js:
  window.MERCS_HEIGHTMAP = {
    cell,            # cell size in world units
    ox, oz, w, h,    # grid origin (in CELL coords: cx=floor(x/cell)) and width/height in cells
    heightsB64,      # base64 of w*h little-endian Int16, row-major (index = (cz-oz)*w + (cx-ox)),
                     #   height * 10 (0.1u precision); -32768 = never sampled
    tiersB64,        # base64 of w*h Uint8 source tiers (0 = never sampled)
    yMin, yMax, n, cellCount, logs,
  }

Run:  python tools/build_heightmap.py [--cell 16]
"""
import re, glob, json, math, statistics, pathlib, argparse, base64, struct

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOGS_DIR = ROOT / "data"
OUT = ROOT / "src" / "data" / "heightmap.js"
# tolerant: matches "x=.. y=.. z=.." anywhere on a line (ROAD, TERRAIN, LOCATION, or any future tagged pose line)
RX = re.compile(r"x=(-?[\d.]+)\s+y=(-?[\d.]+)\s+z=(-?[\d.]+)")

SENTINEL = -32768   # Int16 "no data"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cell", type=int, default=16, help="grid cell size in world units (match GroundStream RES)")
    ap.add_argument("--ymin", type=float, default=-200.0, help="drop samples below this y (fell through the world; real seafloor reaches ~-167)")
    ap.add_argument("--ymax", type=float, default=700.0, help="drop samples above this y (keeps the ~472 edge mountains)")
    args = ap.parse_args()
    cell = max(1, args.cell)

    # Just a sanity range. NOTE: no PMC-HQ-corner filter -- the terrain gather (GetHeightAboveTerrain) reads the
    # REAL ground even at the HQ corner (the HQ interior is a separate instance it never hits), and the edge
    # mountains there (~472) overlap the HQ altitude, so a corner cap would wrongly drop real mountain terrain.
    def keep(x, y, z):
        return args.ymin <= y <= args.ymax

    # source authority -- when sources disagree in a cell, the more trustworthy one wins the height. vehicle
    # (on the road) > foot (standing, may be mid-jump) > terrain (GetHeightAboveTerrain -- direct + accurate,
    # matches road/foot to ~0.14u, but reads the mesh UNDER bridges so it yields to physical-surface sources)
    # > grid probe (may stack / land on a roof) > heli sweep (drops from altitude, least accurate).
    TIER = {"vehicle": 5, "foot": 4, "terrain": 3, "grid": 2, "heli": 1}
    def source(line):
        if "[ROAD]" in line: return "vehicle"
        if "[FOOT]" in line or "[LOCATION]" in line: return "foot"
        if "[TERRAIN]" in line: return "terrain"   # GetHeightAboveTerrain fly-around gather (GroundStream)
        if "[HELI]" in line: return "heli"          # automated aerial sweep -- least accurate
        return "grid"   # [GRID] hand-placed probe, and anything unrecognised

    buckets, dropped, dropped0 = {}, 0, 0   # (cx, cz) -> { tier: [y, ...] }
    files = sorted(glob.glob(str(LOGS_DIR / "*.log")))
    for f in files:
        for line in open(f, encoding="utf-8", errors="ignore"):
            m = RX.search(line)
            if not m:
                continue
            x, y, z = float(m.group(1)), float(m.group(2)), float(m.group(3))
            if not keep(x, y, z):
                dropped += 1
                continue
            src = source(line)
            # a terrain probe reading of EXACTLY 0 is the engine's unstreamed-geometry placeholder, not
            # ground (real water surface is ~-33, seafloor ~-180) -- poison, drop it
            if src == "terrain" and abs(y) < 0.005:
                dropped0 += 1
                continue
            key = (math.floor(x / cell), math.floor(z / cell))
            buckets.setdefault(key, {}).setdefault(src, []).append(y)

    if not buckets:
        raise SystemExit("no x=/y=/z= samples found in %s/*.log" % LOGS_DIR)

    # dense grid bounds from the occupied cells (grows as coverage grows; full map at cell=16 is ~501x501)
    ox = min(k[0] for k in buckets); oz = min(k[1] for k in buckets)
    w = max(k[0] for k in buckets) - ox + 1
    h = max(k[1] for k in buckets) - oz + 1
    if w * h > 8_000_000:
        raise SystemExit("grid %dx%d is implausibly large -- outlier sample? check the logs" % (w, h))

    hts = [SENTINEL] * (w * h)
    tiers = bytearray(w * h)
    heights = []
    for (cx, cz), bytier in buckets.items():
        best = max(bytier, key=lambda t: TIER[t])      # highest-authority source present in this cell
        hv = statistics.median(bytier[best])           # median WITHIN that source only (lower tiers don't dilute it)
        q = max(-32767, min(32767, round(hv * 10)))    # 0.1u precision
        i = (cz - oz) * w + (cx - ox)
        hts[i] = q
        tiers[i] = TIER[best]
        heights.append(hv)

    n = sum(len(v) for bt in buckets.values() for v in bt.values())
    data = {
        "cell": cell,
        "ox": ox, "oz": oz, "w": w, "h": h,
        "heightsB64": base64.b64encode(struct.pack("<%dh" % len(hts), *hts)).decode("ascii"),
        "tiersB64": base64.b64encode(bytes(tiers)).decode("ascii"),
        "yMin": round(min(heights), 2),
        "yMax": round(max(heights), 2),
        "n": n,
        "cellCount": len(buckets),
        "logs": [pathlib.Path(f).name for f in files],
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(
        "// GENERATED by tools/build_heightmap.py from data/*.log -- do not hand-edit.\n"
        "// DENSE height tensor: cell=%d world-units, grid %dx%d cells from cell-origin (%d,%d).\n"
        "// heightsB64 = base64 little-endian Int16, row-major (cz-oz)*w+(cx-ox), height*10; -32768 = no data.\n"
        "// tiersB64 = Uint8 per cell: 5=vehicle(road) 4=foot 3=terrain 2=grid-probe 1=heli-sweep 0=no data.\n"
        "window.MERCS_HEIGHTMAP = %s;\n" % (cell, w, h, ox, oz, json.dumps(data, separators=(",", ":"))),
        encoding="utf-8")
    kb = OUT.stat().st_size // 1024
    print("[heightmap] %d samples -> %d/%d cells (%.1f%% of %dx%d grid, cell=%d), y %.1f..%.1f -> %d KB, from %d log(s): %s"
          % (n, len(buckets), w * h, 100.0 * len(buckets) / (w * h), w, h, cell,
             data["yMin"], data["yMax"], kb, len(files), ", ".join(data["logs"])))
    if dropped:
        print("[heightmap] dropped %d out-of-range sample(s) (fell-through / y<%.0f or y>%.0f)"
              % (dropped, args.ymin, args.ymax))
    if dropped0:
        print("[heightmap] dropped %d exact-0 terrain sample(s) (unstreamed-geometry placeholders, not ground)"
              % dropped0)

    # ---- missing-data report: interior gaps inside otherwise-scanned rows (streaming skips etc.), so a
    # patch pass can target them. Gap runs longer than MAX_GAP cells are "unscanned expanse", not holes,
    # and are summarised rather than listed (the full-map pass covers those anyway).
    MAX_GAP = 64
    byrow = {}
    for (cx, cz) in buckets:
        byrow.setdefault(cz, []).append(cx)
    lines, hole_cells, expanse_rows = [], 0, 0
    for cz in sorted(byrow):
        row = sorted(byrow[cz])
        if len(row) < 2:
            continue
        wz = cz * cell + cell // 2
        runs, big = [], False
        prev = row[0]
        for cx in row[1:]:
            gap = cx - prev - 1
            if gap > 0:
                if gap <= MAX_GAP:
                    x0 = (prev + 1) * cell + cell // 2
                    x1 = (cx - 1) * cell + cell // 2
                    runs.append("x[%d..%d] (%d)" % (x0, x1, gap))
                    hole_cells += gap
                else:
                    big = True
            prev = cx
        if big:
            expanse_rows += 1
        if runs:
            lines.append("z=%-6d  %s" % (wz, "  ".join(runs)))
    miss_path = ROOT / "missing_data.txt"
    miss_path.write_text(
        "# GAPS inside scanned rows (cell=%du, world cell-centre coords). Fill with a GroundStream patch\n"
        "# pass: set RESUME row_z to a listed z and let it re-sweep that row. Runs >%d cells are unscanned\n"
        "# expanse (not listed; the full-map pass covers them) -- %d row(s) contain such expanse.\n"
        "# %d hole cell(s) across %d row(s).\n"
        % (cell, MAX_GAP, expanse_rows, hole_cells, len(lines))
        + "\n".join(lines) + "\n", encoding="utf-8")
    print("[heightmap] %d interior hole cell(s) across %d row(s) -> %s" % (hole_cells, len(lines), miss_path.name))


if __name__ == "__main__":
    raise SystemExit(main())
