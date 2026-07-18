local KEYVAL = "f6"   -- toggle key (add "HeliMap.lua=f6" under [OnKey]); press again to ABORT

-- HeliMap.lua -- terrain-height stripe sweep that NEVER SetPositions/teleports the player mid-run.
--
-- Moving the *player* with SetPosition/teleport every tick triggers load-screen loops + crashes (Logan). So:
-- teleport the player ONCE to the start, wait until their position is STEADY, then Ess.Easy.Vehicle.summon
-- (which seats them in the driver seat). From then on we ONLY move the HELICOPTER -- the seated player rides
-- along, so terrain streams around us with no load trigger. A row of physics-off boxes is SetPosition'd to
-- hang under the heli and read ground via GetHeightAboveTerrain as the heli flies one forward STRIPE. Do
-- parallel passes by hand to fill out the map.
--
-- Two movement modes to compare (MODE below) -- neither ever touches the player:
--   "setpos"  -- SetPosition the heli forward a small step each tick. Deterministic, dead reliable.
--   "impulse" -- push the heli with Object.ApplyImpulse (world +X, held near TARGET_SPEED) and let it fly;
--                boxes track its actual position. Experimental -- tune IMPULSE/UP_IMPULSE if it sinks/stalls.
--
-- ★ TUNE:  MODE, MOVE_STEP/DT (slower = safer for streaming), LENGTH (stripe length), ROW_N/STEP (width),
--   FLY_Y/BOX_Y, MIN_G/MAX_G (terrain sentinel gate), IMPULSE/UP_IMPULSE/TARGET_SPEED, HELI_TEMPLATE/TEMPLATE.

local Ess = _G.Ess
if not (Ess and Ess.Object and Ess.Object.spawn and Ess.Loop and Ess.Player and Ess.Easy and Ess.Easy.Vehicle) then
    if Loader and Loader.Printf then Loader.Printf("[helimap] load Ess (dist/Ess.lua) first") end
    return
end

local MODE = "setpos"                  -- "setpos" | "impulse"
local HELI_TEMPLATE = "AH1Z"
local TEMPLATE = "Cash (Large)"
local ROW_N, STEP = 12, 32             -- row of ROW_N boxes STEP apart -> stripe width, spanning Z
local LENGTH = 1500                    -- fly this far forward (+X) then stop
local FLY_Y, BOX_Y = 130, 100
local MOVE_STEP = 16                   -- setpos: heli forward step per tick (small = slow, streaming-safe)
local TARGET_SPEED, IMPULSE, UP_IMPULSE = 40, 4000, 0   -- impulse mode (UP_IMPULSE>0 if it sinks)
local MIN_G, MAX_G = -48, 110          -- accept groundY only in this range (drops the terrain sentinel)
local STEADY_EPS, STEADY_NEEDED, MAX_SETTLE = 0.5, 6, 10.0
local DT = 0.25

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

local px, py, pz = Ess.Player.pose(0)
if not px then Ess.Log("[helimap] no player character"); return end

HM.on, HM.total = true, 0
HM.startX, HM.startZ, HM.heli, HM.row = px, pz, nil, {}
HM.phase, HM.wait, HM.stable, HM.settleT = "settle", 0, 0, 0
HM.prevX, HM.prevZ = px, pz

-- the ONE and ONLY player teleport: put them at the start (here). After this the player is never moved directly.
if Ess.Player.teleport then pcall(Ess.Player.teleport, px, py, pz, 0) end
Ess.Log("[helimap] settling at start before summoning the heli...")

local half = (ROW_N - 1) / 2
local function placeRow(cx, cz)
    for i = 1, #HM.row do
        if Ess.Object.valid(HM.row[i]) then pcall(Object.SetPosition, HM.row[i], cx, BOX_Y, cz + (i - 1 - half) * STEP) end
    end
end
local function readRow()
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
end

Ess.Loop.start("HeliMap", DT, function()
    if not HM.on then return false end

    if HM.phase == "settle" then
        HM.settleT = HM.settleT + DT
        local x, _, z = Ess.Player.pose(0)
        if x then
            if math.abs(x - HM.prevX) < STEADY_EPS and math.abs(z - HM.prevZ) < STEADY_EPS then HM.stable = HM.stable + 1 else HM.stable = 0 end
            HM.prevX, HM.prevZ = x, z
        end
        if HM.stable >= STEADY_NEEDED or HM.settleT >= MAX_SETTLE then HM.phase = "spawn" end
        return true

    elseif HM.phase == "spawn" then
        HM.heli = Ess.Easy.Vehicle.summon(HELI_TEMPLATE)     -- spawns the heli AND seats the player in it
        if not (HM.heli and Ess.Object.valid(HM.heli)) then
            HM.on = false; Ess.Log("[helimap] couldn't summon '" .. HELI_TEMPLATE .. "'"); return false
        end
        if MODE == "setpos" then pcall(Object.DisablePhysics, HM.heli) else pcall(Object.EnablePhysics, HM.heli) end
        pcall(Object.SetPosition, HM.heli, HM.startX, FLY_Y, HM.startZ)   -- lift heli (+ seated player) to altitude
        for i = 0, ROW_N - 1 do
            local u = Ess.Object.spawn(TEMPLATE, HM.startX, BOX_Y, HM.startZ + (i - half) * STEP, 0)
            if u then pcall(Object.DisablePhysics, u); HM.row[#HM.row + 1] = u end
        end
        if #HM.row == 0 then HM.on = false; cleanup(); Ess.Log("[helimap] box spawn failed -- TEMPLATE valid?"); return false end
        HM.curX = HM.startX
        wsline("<<ROADLOG>>START")
        Ess.Log(string.format("[helimap] %s mode: sweeping +X for %d from (%.0f,%.0f), %d-wide. F6 aborts.",
            MODE, LENGTH, HM.startX, HM.startZ, ROW_N))
        HM.phase = "fly"
        return true

    else -- fly
        if not (HM.heli and Ess.Object.valid(HM.heli)) then HM.on = false; cleanup(); Ess.Log("[helimap] lost the heli"); return false end
        local hx, hz
        if MODE == "setpos" then
            HM.curX = HM.curX + MOVE_STEP
            pcall(Object.SetPosition, HM.heli, HM.curX, FLY_Y, HM.startZ)   -- move ONLY the heli (player rides)
            hx, hz = HM.curX, HM.startZ
        else -- impulse: push the heli forward, let it fly, read where it actually is
            local okv, v = pcall(Object.GetVelocity, HM.heli)
            if not okv or (v or 0) < TARGET_SPEED then pcall(Object.ApplyImpulse, HM.heli, IMPULSE, UP_IMPULSE, 0, false) end
            local okp, x, _, z = pcall(Object.GetPosition, HM.heli)
            hx, hz = (okp and x) or HM.curX, (okp and z) or HM.startZ
            HM.curX = hx
        end

        placeRow(hx, hz)
        readRow()

        if HM.curX - HM.startX >= LENGTH then
            HM.on = false; cleanup()
            wsline("<<ROADLOG>>STOP " .. HM.total)
            Ess.Log(string.format("[helimap] stripe done -- %d terrain point(s). Fly a parallel pass for the next stripe.", HM.total))
            return false
        end
        return true
    end
end)
