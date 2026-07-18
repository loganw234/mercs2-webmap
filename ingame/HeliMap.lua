local KEYVAL = "f6"   -- toggle key (add "HeliMap.lua=f6" under [OnKey]); press again to ABORT

-- HeliMap.lua -- terrain-height STRIPE sweep. Teleport to a map corner ONCE, wait for streaming, get in a
-- heli, fly one forward (+X) stripe reading ground via GetHeightAboveTerrain. Do parallel passes by hand to
-- cover the map: after each stripe, edit START_Z below by +ROW_N*STEP and run again.
--
-- NEVER moves the player after the one initial teleport. Ess.Easy.Vehicle.summon seats the player in the
-- driver seat; from then on only the HELI moves (SetPosition or impulse) and the seated player rides along,
-- so terrain streams with no load-screen loop. The heli is summoned only AFTER a fixed STREAM_WAIT so the
-- corner is fully streamed first -- otherwise the seat fails and the empty heli flies off without you.
--
-- MODE (neither ever touches the player):
--   "setpos"  -- SetPosition the heli forward a small step/tick. Deterministic, reliable.
--   "impulse" -- push the heli with ApplyImpulse (world +X, ~TARGET_SPEED); boxes track it. Experimental.
--
-- ★ TUNE:  START_X/START_Z (a map corner; map is +-4102 -- shift START_Z by +ROW_N*STEP each pass),
--   LENGTH (stripe length; 8204 = full width), ROW_N/STEP (stripe width), STREAM_WAIT, MOVE_STEP/DT (speed),
--   MODE, FLY_Y/BOX_Y, MIN_G/MAX_G, IMPULSE/UP_IMPULSE/TARGET_SPEED.

local Ess = _G.Ess
if not (Ess and Ess.Object and Ess.Object.spawn and Ess.Loop and Ess.Player and Ess.Easy and Ess.Easy.Vehicle) then
    if Loader and Loader.Printf then Loader.Printf("[helimap] load Ess (dist/Ess.lua) first") end
    return
end

local MODE = "setpos"                  -- "setpos" | "impulse"
local HELI_TEMPLATE = "AH1Z"
local TEMPLATE = "Cash (Large)"
local ROW_N, STEP = 12, 32             -- ROW_N boxes STEP apart -> stripe width, spanning +Z from START_Z
local START_X, START_Z = -4102, -4102  -- MAP CORNER (map is +-4102). Next pass: START_Z = START_Z + ROW_N*STEP
local LENGTH = 8204                    -- fly this far +X then stop (8204 = corner-to-corner)
local FLY_Y, BOX_Y = 130, 100
local STREAM_WAIT = 10.0               -- fixed wait after the teleport for streaming to finish before summoning
local MOVE_STEP = 16                   -- setpos: heli forward step per tick (small = slow/streaming-safe)
local TARGET_SPEED, IMPULSE, UP_IMPULSE = 40, 4000, 0   -- impulse mode (raise UP_IMPULSE if it sinks)
local MIN_G, MAX_G = -48, 110          -- accept groundY only in this range (drops the terrain sentinel/ocean)
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

if not Ess.Player.character(0) then Ess.Log("[helimap] no player character"); return end

local rowCenterZ = START_Z + (ROW_N - 1) * STEP / 2
HM.on, HM.total, HM.heli, HM.row = true, 0, nil, {}
HM.curX = START_X
HM.phase, HM.wait = "spawn", STREAM_WAIT

-- the ONE and ONLY player teleport: to the map corner. After this the player is never moved directly.
if Ess.Player.teleport then pcall(Ess.Player.teleport, START_X, FLY_Y, rowCenterZ, 0) end
Ess.Log(string.format("[helimap] teleported to corner (%.0f,%.0f); waiting %.0fs for streaming before summon...", START_X, START_Z, STREAM_WAIT))

local function placeRow(cx)
    for i = 1, #HM.row do
        if Ess.Object.valid(HM.row[i]) then pcall(Object.SetPosition, HM.row[i], cx, BOX_Y, START_Z + (i - 1) * STEP) end
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
    if HM.wait > 0 then HM.wait = HM.wait - DT; return true end   -- STREAM_WAIT: let the corner finish streaming

    if HM.phase == "spawn" then
        HM.heli = Ess.Easy.Vehicle.summon(HELI_TEMPLATE)         -- spawns the heli AND seats the player
        if not (HM.heli and Ess.Object.valid(HM.heli)) then
            HM.on = false; Ess.Log("[helimap] couldn't summon '" .. HELI_TEMPLATE .. "'"); return false
        end
        -- MAKE SURE the player is actually in the seat before we move the heli (else it flies off empty)
        local char = Ess.Player.character(0)
        if char and Ess.Vehicle and Ess.Vehicle.seatOf and not Ess.Vehicle.seatOf(char) and Ess.Vehicle.enterBestSeat then
            pcall(Ess.Vehicle.enterBestSeat, char, HM.heli)
        end
        if char and Ess.Vehicle and Ess.Vehicle.seatOf and not Ess.Vehicle.seatOf(char) then
            Ess.Log("[helimap] WARNING: player didn't get seated -- the heli may fly off without you. Raise STREAM_WAIT.")
        end
        if MODE == "setpos" then pcall(Object.DisablePhysics, HM.heli) else pcall(Object.EnablePhysics, HM.heli) end
        pcall(Object.SetPosition, HM.heli, START_X, FLY_Y, rowCenterZ)   -- lift heli (+ seated player) to altitude
        for i = 0, ROW_N - 1 do
            local u = Ess.Object.spawn(TEMPLATE, START_X, BOX_Y, START_Z + i * STEP, 0)
            if u then pcall(Object.DisablePhysics, u); HM.row[#HM.row + 1] = u end
        end
        if #HM.row == 0 then HM.on = false; cleanup(); Ess.Log("[helimap] box spawn failed -- TEMPLATE valid?"); return false end
        wsline("<<ROADLOG>>START")
        Ess.Log(string.format("[helimap] %s mode: stripe +X for %d from corner, z[%.0f..%.0f]. F6 aborts.",
            MODE, LENGTH, START_Z, START_Z + (ROW_N - 1) * STEP))
        HM.phase = "fly"
        return true
    end

    -- fly
    if not (HM.heli and Ess.Object.valid(HM.heli)) then HM.on = false; cleanup(); Ess.Log("[helimap] lost the heli"); return false end
    if MODE == "setpos" then
        HM.curX = HM.curX + MOVE_STEP
        pcall(Object.SetPosition, HM.heli, HM.curX, FLY_Y, rowCenterZ)   -- move ONLY the heli (player rides)
    else
        local okv, v = pcall(Object.GetVelocity, HM.heli)
        if not okv or (v or 0) < TARGET_SPEED then pcall(Object.ApplyImpulse, HM.heli, IMPULSE, UP_IMPULSE, 0, false) end
        local okp, x = pcall(Object.GetPosition, HM.heli)
        HM.curX = (okp and x) or HM.curX
    end

    placeRow(HM.curX)
    readRow()

    if HM.curX - START_X >= LENGTH then
        HM.on = false; cleanup()
        wsline("<<ROADLOG>>STOP " .. HM.total)
        Ess.Log(string.format("[helimap] stripe done -- %d terrain point(s). Set START_Z += %d and run again for the next stripe.", HM.total, ROW_N * STEP))
        return false
    end
    return true
end)
