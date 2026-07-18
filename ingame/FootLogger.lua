local KEYVAL = "f10"   -- toggle key (add "FootLogger.lua=f10" under [OnKey])

-- FootLogger.lua -- the ON-FOOT companion to RoadLogger.lua. Same job (log ground samples for the webmap's
-- heightmap) but it logs the CHARACTER's position instead of summoning a vehicle -- so you can gather height
-- where cars can't go: interiors, rooftops, hillsides, tight alleys, off-road. Walking is slow and precise,
-- so it samples finer (MIN_MOVE 0.5).
--
-- It broadcasts on the SAME WS hidden channel as RoadLogger (<<ROADLOG>>START / PT / STOP), so the live map's
-- mapping mode picks it up with no changes -- foot samples and road samples both feed the one heightmap. It
-- still writes "[FOOT] ..." game-log lines as an offline fallback (build_heightmap.py reads x=/y=/z= from any
-- tag). Bind it to a DIFFERENT key than RoadLogger so both can live under [OnKey] at once (F10 vs F11).

local Ess = _G.Ess
if not (Ess and Ess.Player and Ess.Player.pose and Ess.Loop) then
    if Loader and Loader.Printf then Loader.Printf("[footlog] load Ess (dist/Ess.lua) first") end
    return
end

local LOOP_ID, INTERVAL, MIN_MOVE = "FootLogger", 0.25, 0.5

-- broadcast to WS map clients only (hidden channel); silently does nothing on a bridge without WsSend.
local function wsline(s) if Loader and Loader.WsSend then pcall(Loader.WsSend, s) end end

_G.FootLogger = _G.FootLogger or { on = false, n = 0, lx = nil, lz = nil }
local S = _G.FootLogger

if S.on then                                     -- second press: STOP
    S.on = false; Ess.Loop.stop(LOOP_ID)
    wsline("<<ROADLOG>>STOP " .. S.n)
    Ess.Log(string.format("[footlog] STOPPED -- logged %d point(s).", S.n)); return
end

if not Ess.Player.character(0) then Ess.Log("[footlog] no player character"); return end

S.on, S.n, S.lx, S.lz = true, 0, nil, nil
wsline("<<ROADLOG>>START")
Ess.Log("[footlog] STARTED -- logging on foot every " .. INTERVAL .. "s (F10 again to stop)")

Ess.Loop.start(LOOP_ID, INTERVAL, function()
    if not S.on then return false end
    local x, y, z, yaw = Ess.Player.pose(0)     -- character position (where you're standing)
    if not x then return true end
    if S.lx and ((x-S.lx)*(x-S.lx) + (z-S.lz)*(z-S.lz)) < MIN_MOVE*MIN_MOVE then return true end
    S.n = S.n + 1; S.lx, S.lz = x, z
    wsline(string.format("<<ROADLOG>>PT %.2f,%.2f,%.2f,%.1f", x, y, z, yaw or 0))
    Ess.Log(string.format("[FOOT] %d  x=%.2f  y=%.2f  z=%.2f  yaw=%.1f", S.n, x, y, z, yaw or 0))
    return true
end)
