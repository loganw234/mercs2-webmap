local KEYVAL = "f6"   -- toggle key (add "HeliMap.lua=f6" under [OnKey]); press again to ABORT

-- HeliMap.lua -- brute full-map terrain sweep. The PLAYER (seated in a summoned heli) is the probe: we
-- SetPosition the HELI across a raster grid over the whole map and read Object.GetHeightAboveTerrain at each
-- point. No boxes. Slow-mo (Ess.Easy.Time.slowmo) freezes the world so nothing drifts and the whole sweep
-- passes in a blink of GAME time (the player "stays roughly in place" in-game) while we grind through it in
-- real time. Never SetPositions the player directly -- only the heli moves; the seated player rides.
--
-- GetHeightAboveTerrain only reaches ~155u down (155.69 = "no hit"), and the map spans ~500u of elevation,
-- so each point does a tiny altitude search: keep the heli ~CLEAR above the LAST reading, and if a point is
-- out of range, step the guess until it reads (or skip after MAX_SEARCH -- deep ocean/void).
--
-- ★ ALWAYS restores time on finish/abort. F6 again aborts. Emits every point as <<ROADLOG>>DOT + [TERRAIN].
-- ★ TUNE:  MAP_HALF/GRID_STEP (coverage/resolution -- full map at 32u is ~65k points), BATCH/DT/SLOWMO,
--   CLEAR/SENTINEL_H/SEARCH/MAX_SEARCH, HELI_TEMPLATE.

local Ess = _G.Ess
if not (Ess and Ess.Object and Ess.Loop and Ess.Player and Ess.Easy and Ess.Easy.Vehicle and Ess.Time) then
    if Loader and Loader.Printf then Loader.Printf("[helimap] load Ess (dist/Ess.lua) first") end
    return
end

local HELI_TEMPLATE = "AH1Z"
local MAP_HALF, GRID_STEP = 4102, 32   -- sweep +-MAP_HALF at GRID_STEP spacing (32 = heightmap cell size)
local CLEAR = 100                      -- probe height above the running ground guess (keeps within the ~155 ray)
local SENTINEL_H = 150                 -- a read is valid only if hAbove is in (2, SENTINEL_H)
local SEARCH, MAX_SEARCH = 90, 10      -- out-of-range: step the guess by SEARCH, up to MAX_SEARCH tries, then skip
local GUESS_LO, GUESS_HI = -150, 700   -- clamp the ground guess to sane map elevations
local BATCH = 1500                     -- grid points per tick (big -> few game-ticks -> "roughly in place")
local DT, SLOWMO = 0.03, 0.01          -- real seconds/tick = DT/SLOWMO; ~65k pts / BATCH ticks -> a couple min

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

local px, py, pz = Ess.Player.pose(0)
if not px then Ess.Log("[helimap] no player character"); return end

-- summon the heli where the player already stands (streamed) and make sure they're seated before we move it
HM.heli = Ess.Easy.Vehicle.summon(HELI_TEMPLATE)
if not (HM.heli and Ess.Object.valid(HM.heli)) then Ess.Log("[helimap] couldn't summon '" .. HELI_TEMPLATE .. "'"); return end
local char = Ess.Player.character(0)
if char and Ess.Vehicle and Ess.Vehicle.seatOf and not Ess.Vehicle.seatOf(char) and Ess.Vehicle.enterBestSeat then pcall(Ess.Vehicle.enterBestSeat, char, HM.heli) end
pcall(Object.DisablePhysics, HM.heli)            -- kinematic: SetPosition holds, no drift to corrupt reads

HM.on, HM.total, HM.guess = true, 0, py or 0
HM.cols = math.floor(2 * MAP_HALF / GRID_STEP) + 1
HM.rows = HM.cols
HM.ix, HM.iz = 0, 0

if Ess.Easy.Time.slowmo then Ess.Easy.Time.slowmo(SLOWMO, 999999) end   -- freeze the world; we restore on finish
wsline("<<ROADLOG>>START")
Ess.Log(string.format("[helimap] brute sweep: %dx%d grid @ %du (~%d pts), slowmo %.2f. F6 aborts.",
    HM.cols, HM.rows, GRID_STEP, HM.cols * HM.rows, SLOWMO))

-- one point: park the heli over (x,z) at guess+CLEAR, read terrain, searching the altitude if out of range
local function probe(x, z)
    for _ = 1, MAX_SEARCH do
        pcall(Object.SetPosition, HM.heli, x, HM.guess + CLEAR, z)
        local okh, h = pcall(Object.GetHeightAboveTerrain, HM.heli)
        local okp, _, hy = pcall(Object.GetPosition, HM.heli)
        if not (okh and h and okp and hy) then return end
        if h > 2 and h < SENTINEL_H then
            local g = hy - h
            HM.guess = g; HM.total = HM.total + 1
            wsline(string.format("<<ROADLOG>>DOT %.2f,%.2f,%.2f,0.0", x, g, z))
            Ess.Log(string.format("[TERRAIN] %d  x=%.2f  y=%.2f  z=%.2f  yaw=0.0", HM.total, x, g, z))
            return
        end
        if h >= SENTINEL_H then HM.guess = clamp(HM.guess - SEARCH, GUESS_LO, GUESS_HI)   -- terrain below the ray
        else HM.guess = clamp(HM.guess + SEARCH, GUESS_LO, GUESS_HI) end                  -- heli at/under terrain
    end
    -- no terrain found in range after MAX_SEARCH -> deep ocean/void; skip (no emit)
end

Ess.Loop.start("HeliMap", DT, function()
    if not HM.on then return false end
    for _ = 1, BATCH do
        if HM.iz >= HM.rows then                 -- finished the whole grid
            HM.on = false; stopTime(); killHeli()
            wsline("<<ROADLOG>>STOP " .. HM.total)
            Ess.Log(string.format("[helimap] DONE -- %d terrain point(s). Time restored.", HM.total))
            return false
        end
        local z = -MAP_HALF + HM.iz * GRID_STEP
        local x = (HM.iz % 2 == 0) and (-MAP_HALF + HM.ix * GRID_STEP) or (MAP_HALF - HM.ix * GRID_STEP)  -- snake raster
        probe(x, z)
        HM.ix = HM.ix + 1
        if HM.ix >= HM.cols then HM.ix = 0; HM.iz = HM.iz + 1 end
    end
    return true
end)
