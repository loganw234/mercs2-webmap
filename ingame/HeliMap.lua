local KEYVAL = "f6"   -- toggle key (add "HeliMap.lua=f6" under [OnKey]); press again to ABORT

-- HeliMap.lua -- brute full-map terrain sweep, one point per tick. The player (seated in a summoned heli) is
-- the probe: each tick we SetPosition the HELI to the next grid point and read Object.GetHeightAboveTerrain.
-- No boxes. Slow-mo freezes the world so the teleporting heli doesn't disturb anything; tune SLOWMO to taste.
--
-- STARTUP: teleport the player to the start corner ONCE, wait for it to stream, THEN summon the heli (which
-- seats them there -- you can't seat them into a vehicle summoned in an unstreamed spot). After that the
-- player is NEVER SetPositioned directly; only the heli moves, carrying the seated player.
--
-- Altitude follow: GetHeightAboveTerrain reaches ~155u down (155.69 = "no hit") but the map spans ~500u of
-- elevation, so we hold the heli ~CLEAR above the LAST good reading. If a point is out of range we nudge the
-- guess and retry the SAME point next tick until it reads (or skip after MAX_RETRY -> ocean/void).
--
-- Runs once for a forever dataset -- slowness is fine. Always restores time on finish/abort. F6 aborts.
-- ★ CONFIG: RES_X / RES_Y -- sample spacing in world units (1,1 = every unit / finest; 32 = one per webmap
--   cell = sensible default). SLOWMO -- world time scale while sweeping (tune later). MAP_HALF, HELI_TEMPLATE.

local Ess = _G.Ess
if not (Ess and Ess.Object and Ess.Loop and Ess.Player and Ess.Easy and Ess.Easy.Vehicle and Ess.Time) then
    if Loader and Loader.Printf then Loader.Printf("[helimap] load Ess (dist/Ess.lua) first") end
    return
end

local HELI_TEMPLATE = "AH1Z"
local MAP_HALF = 4102              -- sweep +-MAP_HALF (full map)
local RES_X, RES_Y = 32, 32        -- sample spacing (world units) per axis. 1,1 = every unit. 32 = one per webmap cell.
local SLOWMO = 0.1                 -- world time scale during the sweep -- tune later for an acceptable speed
local DT = 0.02                    -- tick interval (game time); real seconds/tick = DT / SLOWMO
local STREAM_WAIT = 8.0            -- wait after the start teleport for streaming before summoning the heli
local START_ALT = 550              -- teleport altitude at the start (above the tallest terrain so we don't land in rock)
local CLEAR = 100                  -- hold the heli this far above the running ground guess (inside the ~155 ray)
local SENTINEL_H = 150             -- a read is valid only if hAbove is in (2, SENTINEL_H)
local SEARCH, MAX_RETRY = 90, 14   -- out of range: nudge the guess by SEARCH, retry same point up to MAX_RETRY, then skip
local GUESS_LO, GUESS_HI = -150, 700

local function wsline(s) if Loader and Loader.WsSend then pcall(Loader.WsSend, s) end end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end

_G.HeliMap = _G.HeliMap or {}
local HM = _G.HeliMap

local function stopTime() if Ess.Time.restoreScale then pcall(Ess.Time.restoreScale) end end
local function killHeli() if HM.heli and Ess.Object.valid(HM.heli) then pcall(Object.Remove, HM.heli) end; HM.heli = nil end

if HM.on then                                    -- second press: ABORT
    HM.on = false; Ess.Loop.stop("HeliMap"); stopTime(); killHeli()
    wsline("<<ROADLOG>>STOP " .. (HM.total or 0))
    Ess.Log(string.format("[helimap] aborted -- %d point(s). Time restored.", HM.total or 0)); return
end

if not Ess.Player.character(0) then Ess.Log("[helimap] no player character"); return end

HM.on, HM.total, HM.guess, HM.retry, HM.heli = true, 0, 0, 0, nil
HM.cols = math.floor(2 * MAP_HALF / RES_X) + 1
HM.rows = math.floor(2 * MAP_HALF / RES_Y) + 1
HM.ix, HM.iz = 0, 0
HM.phase, HM.wait = "summon", STREAM_WAIT

-- the ONE and ONLY player teleport: to the start corner, high enough to clear any terrain. Then we stream +
-- summon there. After this the player is never moved directly.
local startX, startZ = -MAP_HALF, -MAP_HALF
if Ess.Player.teleport then pcall(Ess.Player.teleport, startX, START_ALT, startZ, 0) end
Ess.Log(string.format("[helimap] teleported to start (%.0f,%.0f); streaming %.0fs before summon...", startX, startZ, STREAM_WAIT))

Ess.Loop.start("HeliMap", DT, function()
    if not HM.on then return false end
    if HM.wait > 0 then HM.wait = HM.wait - DT; return true end   -- STREAM_WAIT (still normal speed here)

    if HM.phase == "summon" then
        HM.heli = Ess.Easy.Vehicle.summon(HELI_TEMPLATE)          -- summon at the (now-streamed) start + seat player
        if not (HM.heli and Ess.Object.valid(HM.heli)) then HM.on = false; stopTime(); Ess.Log("[helimap] couldn't summon '" .. HELI_TEMPLATE .. "'"); return false end
        local char = Ess.Player.character(0)
        if char and Ess.Vehicle and Ess.Vehicle.seatOf and not Ess.Vehicle.seatOf(char) and Ess.Vehicle.enterBestSeat then pcall(Ess.Vehicle.enterBestSeat, char, HM.heli) end
        if char and Ess.Vehicle and Ess.Vehicle.seatOf and not Ess.Vehicle.seatOf(char) then Ess.Log("[helimap] WARNING: player not seated -- raise STREAM_WAIT.") end
        pcall(Object.DisablePhysics, HM.heli)                     -- kinematic: SetPosition holds, no drift
        if Ess.Easy.Time.slowmo then Ess.Easy.Time.slowmo(SLOWMO, 999999) end   -- NOW freeze the world for the sweep
        wsline("<<ROADLOG>>START")
        Ess.Log(string.format("[helimap] sweep %dx%d (%d pts) @ res %d,%d, slowmo %.2f. One point/tick. F6 aborts.",
            HM.cols, HM.rows, HM.cols * HM.rows, RES_X, RES_Y, SLOWMO))
        HM.phase = "sweep"
        return true
    end

    -- sweep: one point per tick
    if HM.iz >= HM.rows then                      -- whole grid done
        HM.on = false; stopTime(); killHeli()
        wsline("<<ROADLOG>>STOP " .. HM.total)
        Ess.Log(string.format("[helimap] DONE -- %d terrain point(s). Time restored.", HM.total))
        return false
    end

    local z = -MAP_HALF + HM.iz * RES_Y
    local x = (HM.iz % 2 == 0) and (-MAP_HALF + HM.ix * RES_X) or (MAP_HALF - HM.ix * RES_X)   -- snake raster

    pcall(Object.SetPosition, HM.heli, x, HM.guess + CLEAR, z)    -- ONE teleport
    local okh, h = pcall(Object.GetHeightAboveTerrain, HM.heli)   -- + ONE read
    local okp, _, hy = pcall(Object.GetPosition, HM.heli)

    local advance = false
    if okh and h and okp and hy and h > 2 and h < SENTINEL_H then
        local g = hy - h
        HM.guess = g; HM.total = HM.total + 1; HM.retry = 0
        wsline(string.format("<<ROADLOG>>DOT %.2f,%.2f,%.2f,0.0", x, g, z))
        Ess.Log(string.format("[TERRAIN] %d  x=%.2f  y=%.2f  z=%.2f  yaw=0.0", HM.total, x, g, z))
        advance = true
    else                                          -- out of range: nudge the altitude guess, retry this point
        if h and h >= SENTINEL_H then HM.guess = clamp(HM.guess - SEARCH, GUESS_LO, GUESS_HI)   -- terrain below the ray
        else HM.guess = clamp(HM.guess + SEARCH, GUESS_LO, GUESS_HI) end                        -- heli at/under terrain
        HM.retry = HM.retry + 1
        if HM.retry > MAX_RETRY then HM.retry = 0; advance = true end   -- give up (ocean/void) -> skip, no emit
    end

    if advance then
        HM.ix = HM.ix + 1
        if HM.ix >= HM.cols then HM.ix = 0; HM.iz = HM.iz + 1 end
    end
    return true
end)
