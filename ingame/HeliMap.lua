local KEYVAL = "f6"   -- toggle key (add "HeliMap.lua=f6" under [OnKey]); press again to ABORT

-- HeliMap.lua -- automatic full-map terrain sweep via Object.GetHeightAboveTerrain.
--
-- Validated approach (TerrainProbe): ground = objectY - GetHeightAboveTerrain(obj), true for ANY object
-- position -> no physics, no settling, no floating. This sweeps it across the whole map:
--   * spawn ONE ROW of ROW_N objects (physics OFF, so they stay put and cost nothing) -- Logan's idea:
--     reuse a row and step it, don't respawn per point.
--   * each tick: READ the row (positioned last tick) -> ground height per object -> map + [TERRAIN] log;
--     then STEP the row forward one column and slide the heli+player along so terrain stays streamed.
--   * boustrophedon raster: sweep X across a lane, shift Z by the row width, sweep back, until the region
--     is covered. Incremental (the map saves each point) and abortable (F6 again) -- partial runs are fine.
--
-- It reads TRUE TERRAIN (pool/pit floors, ground under buildings), not the walkable surface -- so it tiers
-- below the driven/walked data, which capture where you can actually stand. A fixed "no terrain" sentinel
-- (seen as a repeated exact value over buildings/void) is filtered by a plausible-range gate.
--
-- ★ TUNE:  STEP/ROW_N (resolution vs speed & streaming reach -- keep ROW_N*STEP within the streamed radius),
--   START_/END_ bounds (default ~full map; shrink for a quick test), FLY_Y/SPAWN_Y, FOLLOW_DIST, MIN_G/MAX_G
--   (plausible ground range -> sentinel filter), TEMPLATE.

local Ess = _G.Ess
if not (Ess and Ess.Object and Ess.Object.spawn and Ess.Loop and Ess.Player) then
    if Loader and Loader.Printf then Loader.Printf("[helimap] load Ess (dist/Ess.lua) first") end
    return
end

local TEMPLATE = "Cash (Large)"
local ROW_N, STEP = 12, 32                    -- row of ROW_N objects, STEP apart; also the column step
local START_X, END_X, START_Z, END_Z = -4000, 4000, -4000, 4000   -- sweep region (default ~full map)
local FLY_Y, SPAWN_Y = 130, 100               -- player/heli altitude, and the read-object altitude
local FOLLOW_DIST = 160                        -- re-teleport the player when the sweep gets this far from them
local MIN_G, MAX_G = -48, 110                  -- accept groundY only in this range (rejects the terrain sentinel)
local DT = 0.2

local function wsline(s) if Loader and Loader.WsSend then pcall(Loader.WsSend, s) end end

_G.HeliMap = _G.HeliMap or {}
local HM = _G.HeliMap

local function cleanup()
    for _, u in ipairs(HM.row or {}) do if Ess.Object.valid(u) then pcall(Object.Remove, u) end end
    HM.row = {}
    if HM.heli and Ess.Object.valid(HM.heli) then pcall(Object.Remove, HM.heli) end
end

if HM.on then                                    -- second press: ABORT
    HM.on = false; Ess.Loop.stop("HeliMap"); cleanup()
    wsline("<<ROADLOG>>STOP " .. (HM.total or 0))
    Ess.Log(string.format("[helimap] aborted -- %d point(s) so far.", HM.total or 0)); return
end

-- raster state
HM.on, HM.total = true, 0
HM.colX, HM.laneZ, HM.dir = START_X, START_Z, 1
HM.px, HM.pz = -1e9, -1e9   -- force an initial player move

-- spawn the reusable row (physics off; they just sit where SetPosition puts them)
HM.row = {}
for i = 0, ROW_N - 1 do
    local u = Ess.Object.spawn(TEMPLATE, HM.colX, SPAWN_Y, HM.laneZ + i * STEP, 0)
    if u then pcall(Object.DisablePhysics, u); HM.row[#HM.row + 1] = u end
end
if #HM.row == 0 then HM.on = false; Ess.Log("[helimap] couldn't spawn the row -- is TEMPLATE valid?"); return end

HM.heli = (Ess.Easy and Ess.Easy.Vehicle and Ess.Easy.Vehicle.summon and Ess.Easy.Vehicle.summon("AH1Z")) or nil
if HM.heli and Ess.Object.valid(HM.heli) then pcall(Object.DisablePhysics, HM.heli) end

wsline("<<ROADLOG>>START")
Ess.Log(string.format("[helimap] sweeping x[%d..%d] z[%d..%d], row %d @ %du. F6 aborts.",
    START_X, END_X, START_Z, END_Z, ROW_N, STEP))

local function positionRow()
    for i = 1, #HM.row do
        if Ess.Object.valid(HM.row[i]) then pcall(Object.SetPosition, HM.row[i], HM.colX, SPAWN_Y, HM.laneZ + (i - 1) * STEP) end
    end
    -- keep the heli on the row; move the player (streaming anchor) only when the sweep pulls away from them
    local cz = HM.laneZ + (ROW_N - 1) * STEP / 2
    if HM.heli and Ess.Object.valid(HM.heli) then pcall(Object.SetPosition, HM.heli, HM.colX, FLY_Y, cz) end
    if math.abs(HM.colX - HM.px) > FOLLOW_DIST or math.abs(cz - HM.pz) > FOLLOW_DIST then
        HM.px, HM.pz = HM.colX, cz
        if Ess.Player.teleport then pcall(Ess.Player.teleport, HM.colX, FLY_Y, cz, 0) end
    end
end
positionRow()   -- place the row (+ player) at the first column; next tick reads it

Ess.Loop.start("HeliMap", DT, function()
    if not HM.on then return false end

    -- READ the row at its current (last-positioned) spot
    for i = 1, #HM.row do
        local u = HM.row[i]
        if Ess.Object.valid(u) then
            local okp, x, y, z = pcall(Object.GetPosition, u)
            local okh, h = pcall(Object.GetHeightAboveTerrain, u)
            if okp and x and okh and h then
                local g = y - h
                if g >= MIN_G and g <= MAX_G then   -- reject the "no terrain" sentinel (building/void)
                    HM.total = HM.total + 1
                    wsline(string.format("<<ROADLOG>>DOT %.2f,%.2f,%.2f,0.0", x, g, z))
                    Ess.Log(string.format("[TERRAIN] %d  x=%.2f  y=%.2f  z=%.2f  yaw=0.0", HM.total, x, g, z))
                end
            end
        end
    end

    -- ADVANCE one column (boustrophedon); shift lane at the ends; finish when past the region
    HM.colX = HM.colX + HM.dir * STEP
    if HM.colX > END_X or HM.colX < START_X then
        HM.colX = math.max(START_X, math.min(END_X, HM.colX))
        HM.dir = -HM.dir
        HM.laneZ = HM.laneZ + ROW_N * STEP
        if HM.laneZ > END_Z then
            HM.on = false; cleanup()
            wsline("<<ROADLOG>>STOP " .. HM.total)
            Ess.Log(string.format("[helimap] done -- %d terrain point(s).", HM.total))
            return false
        end
    end
    positionRow()
    return true
end)
