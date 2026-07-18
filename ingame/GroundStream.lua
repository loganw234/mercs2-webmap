local KEYVAL = "f5"   -- toggle key (add "GroundStream.lua=f5" under [OnKey])

-- GroundStream.lua -- the dead-simple ground-height gatherer. Fly around manually (a fast heli, low), and
-- this streams your position + distance-to-ground over the WS hidden channel; the ground-gather.html page
-- turns each into a terrain point and saves them. No teleporting, no automation -- you drive, it logs.
--
-- Sends:  <<GROUND>>x,y,z,dist   (dist = Object.GetHeightAboveTerrain; the page computes groundY = y - dist)
-- Fly LOW: GetHeightAboveTerrain only reaches ~155u, so readings beyond that are skipped -- stay near the deck.

local Ess = _G.Ess
if not (Ess and Ess.Player and Ess.Loop and Ess.Object) then
    if Loader and Loader.Printf then Loader.Printf("[groundstream] load Ess (dist/Ess.lua) first") end
    return
end

local LOOP_ID, INTERVAL, SENTINEL = "GroundStream", 0.2, 150

local function wsline(s) if Loader and Loader.WsSend then pcall(Loader.WsSend, s) end end

_G.GroundStream = _G.GroundStream or { on = false, n = 0 }
local S = _G.GroundStream

if S.on then                                     -- second press: STOP
    S.on = false; Ess.Loop.stop(LOOP_ID)
    Ess.Log(string.format("[groundstream] STOPPED -- streamed %d point(s).", S.n)); return
end

if not Ess.Player.character(0) then Ess.Log("[groundstream] no player character"); return end

S.on, S.n = true, 0
Ess.Log("[groundstream] STARTED -- fly around low; F5 again to stop.")

Ess.Loop.start(LOOP_ID, INTERVAL, function()
    if not S.on then return false end
    local x, y, z, _, c = Ess.Player.pose(0)
    if not (x and c) then return true end
    local okh, h = pcall(Object.GetHeightAboveTerrain, c)
    if okh and h and h > 1 and h < SENTINEL then      -- in range -> a real ground reading
        S.n = S.n + 1
        wsline(string.format("<<GROUND>>%.2f,%.2f,%.2f,%.2f", x, y, z, h))
    end
    return true
end)
