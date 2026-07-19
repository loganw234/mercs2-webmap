# build_all.ps1 -- one-shot pipeline: data/*.log -> tensor -> webmap -> 3D models -> in-game oracle -> STL.
#   1. tools/build_heightmap.py   : merge logs into src/data/heightmap.js (+ missing_data.txt gap report)
#   2. build.py                   : bundle everything into dist/index.html
#   3. tools/build_terrain_3d.py  : DISPLAY model (map-view mirror, 1.5x height) -> dist/terrain3d/terrain.*
#   4. tools/build_terrain_3d.py --raw : GAME-EXACT model (true world coords, 1:1, full res) -> terrain_raw.*
#   5. tools/build_terrain_lua.py : in-game height oracle -> ingame/Terrain.lua
#   6. tools/build_terrain_stl.py : printable solid -> dist/terrain3d/terrain_print.stl
#   7. tools/terrain_report.py    : terrain almanac (end-of-build summary)
# Usage:  .\build_all.ps1            (from the repo root; stops on the first failing step)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Write-Host "== 1/9 height tensor ==" -ForegroundColor Cyan
python tools/build_heightmap.py
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "== 2/9 webmap bundle ==" -ForegroundColor Cyan
python build.py
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "== 3/9 3D display model ==" -ForegroundColor Cyan
python tools/build_terrain_3d.py --step 2 --zscale 1.5 --texscale 2
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "== 4/9 3D game-exact model (raw) ==" -ForegroundColor Cyan
python tools/build_terrain_3d.py --raw
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "== 5/9 in-game Terrain.lua oracle ==" -ForegroundColor Cyan
python tools/build_terrain_lua.py
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "== 6/9 printable STL ==" -ForegroundColor Cyan
python tools/build_terrain_stl.py
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "== 7/9 raw tensor export (heightmap-data) ==" -ForegroundColor Cyan
python tools/export_tensor.py
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "== 8/9 terrain almanac ==" -ForegroundColor Cyan
python tools/terrain_report.py
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "== 9/9 Export.zip ==" -ForegroundColor Cyan
python tools/make_export.py
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "== done: dist/Export.zip (webmap + 3D models + STL + tensor data + Terrain.lua + almanac) ==" -ForegroundColor Green
