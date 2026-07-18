local KEYVAL = "f6"   -- toggle key (add "HeliMap.lua=f6" under [OnKey]); press again to ABORT

-- HeliMap.lua -- automatic terrain sweep via Object.GetHeightAboveTerrain.
--
-- Validated (TerrainProbe): ground = objectY - GetHeightAboveTerrain(obj), for ANY object position -> no
-- physics, no settling. This reuses ONE row of objects (physics OFF), steps it column-by-column in a
-- boustrophedon raster reading ground height at each, and slides the heli+player along so terrain streams.
--
-- STARTUP ORDER MATTERS: teleport the player to the start FIRST and wait for streaming, THEN summon the heli
-- and spawn the row -- else Pg.Spawn into an unstreamed area silently fails and nothing happens (Logan's fix).
--
-- Reads TRUE terrain (pit/pool floors, ground under buildings), so it tiers below driven/walked data. A "no
-- terrain" sentinel (over buildings/void) is dropped by the MIN_G/MAX_G gate. Incremental + abortable (F6).
--
-- ★ TUNE:  START_X/START_Z (nil = start where you stand; set to e.g. -4000,-4000 for a map corner),
--   REGION_W/H (sweep size from start; crank to ~8000 for the whole map), STEP/ROW_N, STREAM_WAIT (raise if
--   the first spawn still fails), FLY_Y, FOLLOW_DIST, MIN_G/MAX_G, TEMPLATE.

local Ess = _G.Ess
if not (Ess and Ess.Object and Ess.Object.spawn and Ess.Loop and Ess.Player) then
    if Loader and Loader.Printf then Loader.Printf("[helimap] load Ess (dist/Ess.lua) first") end
    return
end

local TEMPLATE = "Cash (Large)"
local ROW_N, STEP = 12, 32
local START_X, START_Z = nil, nil        -- nil = start where you stand; set fixed coords for a corner sweep
local REGION_W, REGION_H = 1024, 1024    -- sweep this far from the start (crank up for more; ~8000 = whole map)
local FLY_Y, SPAWN_Y = 130, 100
local STREAM_WAIT = 3.0                  -- wait after the initial teleport for the area to stream in
local FOLLOW_DIST = 160
local MIN_G, MAX_G = -48, 110            -- accept groundY only in this range (drops the terrain sentinel)
local DT = 0.2

local function wsline(s) if Loader and Loader.WsSend then pcall(Loader.WsSend, s) end end

_G.HeliMap = _G.HeliMap or {}
local HM = _G.HeliMap

local function cleanup()
    for _, u in ipairs(HM.row or {}) do if Ess.Object.valid(u) then pcall(Object.Remove, u) end end
    HM.row = {}
    if HM.heli and Ess.Object.valid(HM.heli) then pcall(Object.Remove, HM.heli) end
    HM.heli = nil
end

if HM.on then                                    -- second press: ABORT
    HM.on = false; Ess.Loop.stop("HeliMap"); cleanup()
    wsline("<<ROADLOG>>STOP " .. (HM.total or 0))
    Ess.Log(string.format("[helimap] aborted -- %d point(s) so far.", HM.total or 0)); return
end

local px, _, pz = Ess.Player.pose(0)
if not px then Ess.Log("[helimap] no player character"); return end

local sx, sz = START_X or px, START_Z or pz
HM.on, HM.total = true, 0
HM.colX, HM.laneZ, HM.dir = sx, sz, 1
HM.endX, HM.endZ = sx + REGION_W, sz + REGION_H
HM.px, HM.pz = -1e9, -1e9
HM.row, HM.heli = {}, nil
HM.phase, HM.wait = "spawn", STREAM_WAIT

-- THE FIX: put the player at the start first so it streams in, THEN (after the wait) spawn.
if Ess.Player.teleport then pcall(Ess.Player.teleport, sx, FLY_Y, sz + (ROW_N - 1) * STEP / 2, 0) end
Ess.Log(string.format("[helimap] moving to start (%.0f,%.0f), streaming %.1fs then spawning...", sx, sz, STREAM_WAIT))

-- SetPosition the row + heli to the current column; re-teleport the player only when the sweep pulls away
local function positionRow()
    for i = 1, #HM.row do
        if Ess.Object.valid(HM.row[i]) then pcall(Object.SetPosition, HM.row[i], HM.colX, SPAWN_Y, HM.laneZ + (i - 1) * STEP) end
    end
    local cz = HM.laneZ + (ROW_N - 1) * STEP / 2
    if HM.heli and Ess.Object.valid(HM.heli) then pcall(Object.SetPosition, HM.heli, HM.colX, FLY_Y, cz) end
    if math.abs(HM.colX - HM.px) > FOLLOW_DIST or math.abs(cz - HM.pz) > FOLLOW_DIST then
        HM.px, HM.pz = HM.colX, cz
        if Ess.Player.teleport then pcall(Ess.Player.teleport, HM.colX, FLY_Y, cz, 0) end
    end
end

Ess.Loop.start("HeliMap", DT, function()
    if not HM.on then return false end
    if HM.wait > 0 then HM.wait = HM.wait - DT; return true end

    if HM.phase == "spawn" then
        HM.heli = (Ess.Easy and Ess.Easy.Vehicle and Ess.Easy.Vehicle.summon and Ess.Easy.Vehicle.summon("AH1Z")) or nil
        if HM.heli and Ess.Object.valid(HM.heli) then pcall(Object.DisablePhysics, HM.heli) end
        for i = 0, ROW_N - 1 do
            local u = Ess.Object.spawn(TEMPLATE, HM.colX, SPAWN_Y, HM.laneZ + i * STEP, 0)
            if u then pcall(Object.DisablePhysics, u); HM.row[#HM.row + 1] = u end
        end
        if #HM.row == 0 then
            HM.on = false; cleanup()
            Ess.Log("[helimap] spawn still failed after streaming -- raise STREAM_WAIT, or is TEMPLATE valid?")
            return false
        end
        wsline("<<ROADLOG>>START")
        Ess.Log(string.format("[helimap] spawned %d, sweeping x[%.0f..%.0f] z[%.0f..%.0f]. F6 aborts.",
            #HM.row, HM.colX, HM.endX, HM.laneZ, HM.endZ))
        HM.phase = "sweep"
        return true
    end

    -- READ the row at its current spot
    for i = 1, #HM.row do
        local u = HM.row[i]
        if Ess.Object.valid(u) then
            local okp, x, y, z = pcall(Object.GetPosition, u)
            local okh, h = pcall(Object.GetHeightAboveTerrain, u)
            if okp and x and okh and h then
                local g = y - h
                if g >= MIN_G and g <= MAX_G then
                    HM.total = HM.total + 1
                    wsline(string.format("<<ROADLOG>>DOT %.2f,%.2f,%.2f,0.0", x, g, z))
                    Ess.Log(string.format("[TERRAIN] %d  x=%.2f  y=%.2f  z=%.2f  yaw=0.0", HM.total, x, g, z))
                end
            end
        end
    end

    -- ADVANCE one column; shift lane at the ends; finish past the region
    HM.colX = HM.colX + HM.dir * STEP
    if HM.colX > HM.endX or HM.colX < sx then
        HM.colX = math.max(sx, math.min(HM.endX, HM.colX))
        HM.dir = -HM.dir
        HM.laneZ = HM.laneZ + ROW_N * STEP
        if HM.laneZ > HM.endZ then
            HM.on = false; cleanup()
            wsline("<<ROADLOG>>STOP " .. HM.total)
            Ess.Log(string.format("[helimap] done -- %d terrain point(s).", HM.total))
            return false
        end
    end
    positionRow()
    return true
end)
