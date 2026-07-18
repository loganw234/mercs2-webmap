local KEYVAL = "f7"   -- toggle key (add "TerrainProbe.lua=f7" under [OnKey])

-- TerrainProbe.lua -- read ground height DIRECTLY via Object.GetHeightAboveTerrain, no physics/settling.
--
-- For each point in a grid around the player: spawn a throwaway object high up, read how far it is above the
-- terrain, compute the ground height = objectY - heightAboveTerrain, log it, and delete it -- all in one
-- pass. Because ground = objectY - heightAboveTerrain holds for ANY object position, this is immune to the
-- "boxes float" bug (a floating object still reports the terrain below it) and needs no drop or settle.
--
-- This is the VALIDATION run: it logs spawnY / hAbove / groundY per point so we can see exactly what
-- GetHeightAboveTerrain returns and confirm groundY matches known road/foot heights nearby. It also streams
-- the computed points to the live map (<<ROADLOG>>DOT). Tag is [TPROBE] for now (not tiered yet -- we'll
-- decide its authority once the numbers check out). If hAbove comes back as 0 / garbage, the native needs a
-- frame after spawn and we'll add a one-tick delay; try it and paste the log.
--
-- ★ TUNE:  TEMPLATE (spawnable object), N/STEP (grid), SPAWN_Y (any height above terrain within ray range;
--   terrain tops ~70, HQ instance ~450, so 100 is safe), OFFSET.

local Ess = _G.Ess
if not (Ess and Ess.Object and Ess.Object.spawn and Ess.Player) then
    if Loader and Loader.Printf then Loader.Printf("[terrainprobe] load Ess (dist/Ess.lua) first") end
    return
end

local TEMPLATE = "Cash (Large)"
local N, STEP, SPAWN_Y, OFFSET = 8, 16, 100, 0.0

local function wsline(s) if Loader and Loader.WsSend then pcall(Loader.WsSend, s) end end

local px, _, pz = Ess.Player.pose(0)
if not px then Ess.Log("[terrainprobe] no player character"); return end

wsline("<<ROADLOG>>START")
Ess.Log(string.format("[terrainprobe] probing %dx%d @ %du via GetHeightAboveTerrain (spawnY=%d)...", N, N, STEP, SPAWN_Y))

local n, fail, half = 0, 0, (N - 1) / 2
for ix = 0, N - 1 do
    for iz = 0, N - 1 do
        local x, z = px + (ix - half) * STEP, pz + (iz - half) * STEP
        local u = Ess.Object.spawn(TEMPLATE, x, SPAWN_Y, z, 0)
        if u then
            pcall(Object.DisablePhysics, u)   -- keep it put; the formula doesn't need it, but it's cleaner
            local okp, ox, oy, oz = pcall(Object.GetPosition, u)
            local okh, h = pcall(Object.GetHeightAboveTerrain, u)
            if okp and ox and okh and h then
                local groundY = oy - h
                n = n + 1
                wsline(string.format("<<ROADLOG>>DOT %.2f,%.2f,%.2f,0.0", ox, groundY - OFFSET, oz))
                Ess.Log(string.format("[TPROBE] %d  x=%.2f  z=%.2f  spawnY=%.2f  hAbove=%.2f  groundY=%.2f", n, ox, oz, oy, h, groundY))
            else
                fail = fail + 1
                Ess.Log(string.format("[terrainprobe] query failed at (%.0f,%.0f)  okPos=%s okHeight=%s", x, z, tostring(okp), tostring(okh)))
            end
            pcall(Object.Remove, u)
        end
    end
end

wsline("<<ROADLOG>>STOP " .. n)
Ess.Log(string.format("[terrainprobe] done -- %d point(s), %d query-fail. Check the [TPROBE] lines: does groundY match known heights?", n, fail))
