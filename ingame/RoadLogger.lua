local KEYVAL = "f11"   -- toggle key (add "RoadLogger.lua=f11" under [OnKey])

-- RoadLogger.lua -- drive around and log ground samples for the webmap's heightmap.
--
-- Repurposed to ALSO broadcast over the lua-bridge WebSocket hidden channel (Loader.WsSend), so the live
-- webmap (mercs2-webmap) auto-detects it and turns on "mapping mode" with ZERO user input: press F11, the
-- map starts drawing your trail + collecting samples; press F11 again and it finalises. The WS signals are:
--     <<ROADLOG>>START
--     <<ROADLOG>>PT <x>,<y>,<z>,<yaw>          (one per logged point)
--     <<ROADLOG>>STOP <count>
-- It STILL writes the same "[ROAD] ..." lines to the game log (Ess.Log) as an offline fallback -- so you can
-- map with or without the map open, and feed either into tools/build_heightmap.py. WsSend is a no-op when
-- nothing's listening / on a non-WS bridge, so this is safe everywhere.

local Ess = _G.Ess
if not (Ess and Ess.Easy and Ess.Easy.Vehicle and Ess.Loop) then
    if Loader and Loader.Printf then Loader.Printf("[roadlog] load Ess (dist/Ess.lua) first") end
    return
end

local LOOP_ID, INTERVAL, MIN_MOVE = "RoadLogger", 0.25, 1.0

-- broadcast to WS map clients only (hidden channel); silently does nothing on a bridge without WsSend.
local function wsline(s) if Loader and Loader.WsSend then pcall(Loader.WsSend, s) end end

_G.RoadLogger = _G.RoadLogger or { on = false, veh = nil, n = 0, lx = nil, lz = nil }
local S = _G.RoadLogger

if S.on then                                     -- second press: STOP
    S.on = false; Ess.Loop.stop(LOOP_ID)
    wsline("<<ROADLOG>>STOP " .. S.n)
    Ess.Log(string.format("[roadlog] STOPPED -- logged %d point(s).", S.n)); return
end

local char = Ess.Player.character(0)
if not char then Ess.Log("[roadlog] no player character"); return end
local veh = Ess.Object.vehicleOf(char)
if not (veh and Ess.Object.valid(veh)) then veh = Ess.Easy.Vehicle.summon("Veyron") end
if not veh then Ess.Log("[roadlog] couldn't get/summon a vehicle"); return end
Ess.Object.setInvincible(veh, true, "RoadLogger")

S.on, S.veh, S.n, S.lx, S.lz = true, veh, 0, nil, nil
wsline("<<ROADLOG>>START")
Ess.Log("[roadlog] STARTED -- logging every " .. INTERVAL .. "s (F11 again to stop)")

Ess.Loop.start(LOOP_ID, INTERVAL, function()
    if not S.on then return false end
    local g = S.veh
    if not (g and Ess.Object.valid(g)) then g = Ess.Object.vehicleOf(Ess.Player.character(0)); S.veh = g end
    local x, y, z, yaw
    if g and Ess.Object.valid(g) then
        local ok, px, py, pz = pcall(Object.GetPosition, g)
        if ok and px then x, y, z = px, py, pz; local oky, yv = pcall(Object.GetYaw, g); yaw = (oky and yv) or 0 end
    end
    if not x then x, y, z, yaw = Ess.Player.pose(0) end
    if not x then return true end
    if S.lx and ((x-S.lx)*(x-S.lx) + (z-S.lz)*(z-S.lz)) < MIN_MOVE*MIN_MOVE then return true end
    S.n = S.n + 1; S.lx, S.lz = x, z
    wsline(string.format("<<ROADLOG>>PT %.2f,%.2f,%.2f,%.1f", x, y, z, yaw or 0))
    Ess.Log(string.format("[ROAD] %d  x=%.2f  y=%.2f  z=%.2f  yaw=%.1f", S.n, x, y, z, yaw or 0))
    return true
end)
