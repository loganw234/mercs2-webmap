local KEYVAL = "f5"   -- toggle key (add "GroundStream.lua=f5" under [OnKey]); press again to ABORT

-- GroundStream.lua -- automatic full-map terrain scan via a cinematic-camera probe. Spawns a prop, locks the
-- camera onto it with Ess.Camera (beginCinematic + lookAtObject -- the SAME safe primitives Ess.Cinematic's
-- chase/camera steps use; raw Camera.* calls crash), then steps the prop + camera across a grid reading
-- Object.GetHeightAboveTerrain at each point. The PLAYER never moves, so no load-screen loops -- only the
-- cinematic camera flies. Streams <<GROUND>>x,y,z,dist per point. ALWAYS ends the cinematic on finish/abort.
--
-- Altitude-follow (GetHeightAboveTerrain reaches ~155u; the map spans ~500u): hold the prop ~CLEAR above the
-- LAST reading; if a point is out of range, nudge the guess and retry it next tick.
--
-- ★ CONFIG: RES_X / RES_Y (grid spacing in world units; 32 = one per webmap cell), MAP_HALF, TEMPLATE.

local Ess = _G.Ess
if not (Ess and Ess.Camera and Ess.Player and Ess.Loop and Ess.Object) then
    if Loader and Loader.Printf then Loader.Printf("[groundstream] load Ess (dist/Ess.lua) first") end
    return
end

local LOOP_ID = "GroundStream"
local MAP_HALF = 4102
local RES_X, RES_Y = 32, 32
local TEMPLATE = "Verification Camera"
local CLEAR, CAM_UP = 100, 40          -- prop sits CLEAR above the ground guess; camera CAM_UP above the prop
local SENTINEL_H = 150
local SEARCH, MAX_RETRY = 90, 14
local GUESS_LO, GUESS_HI = -200, 700
local DT = 0.05

local function wsline(s) if Loader and Loader.WsSend then pcall(Loader.WsSend, s) end end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end

_G.GroundStream = _G.GroundStream or { on = false, n = 0, prop = nil }
local S = _G.GroundStream

local function restore()
    pcall(Ess.Camera.endCinematic, 0)                            -- hand the camera back to the game (never leave it held)
    if S.prop and Ess.Object.valid(S.prop) then pcall(Object.Remove, S.prop) end
    S.prop = nil
end

if S.on then                                     -- second press: ABORT
    S.on = false; Ess.Loop.stop(LOOP_ID); restore()
    wsline("<<ROADLOG>>STOP " .. (S.n or 0))
    Ess.Log(string.format("[groundstream] aborted -- %d point(s). Camera restored.", S.n or 0)); return
end

local px, py, pz = Ess.Player.pose(0)
if not px then Ess.Log("[groundstream] no player character"); return end

S.prop = Ess.Object.spawn(TEMPLATE, px, py, pz, 0)
if not (S.prop and Ess.Object.valid(S.prop)) then Ess.Log("[groundstream] couldn't spawn '" .. TEMPLATE .. "'"); return end
pcall(Object.DisablePhysics, S.prop)

pcall(Ess.Camera.beginCinematic, 0, 0)           -- take the camera over (blend 0 = instant, no lag on moves)
pcall(Ess.Camera.lookAtObject, S.prop, nil, 0)   -- auto-track the prop; the camera follows it as it steps

S.on, S.n, S.guess, S.retry = true, 0, py or 0, 0
S.cols = math.floor(2 * MAP_HALF / RES_X) + 1
S.rows = math.floor(2 * MAP_HALF / RES_Y) + 1
S.ix, S.iz = 0, 0
wsline("<<ROADLOG>>START")
Ess.Log(string.format("[groundstream] cinematic scan %dx%d (%d pts) @ res %d,%d. Player stays put; F5 aborts.",
    S.cols, S.rows, S.cols * S.rows, RES_X, RES_Y))

Ess.Loop.start(LOOP_ID, DT, function()
    if not S.on then return false end
    if S.iz >= S.rows then                        -- whole grid done
        S.on = false; restore(); wsline("<<ROADLOG>>STOP " .. S.n)
        Ess.Log(string.format("[groundstream] DONE -- %d terrain point(s). Camera restored.", S.n))
        return false
    end

    local z = -MAP_HALF + S.iz * RES_Y
    local x = (S.iz % 2 == 0) and (-MAP_HALF + S.ix * RES_X) or (MAP_HALF - S.ix * RES_X)   -- snake raster
    local alt = S.guess + CLEAR

    pcall(Object.SetPosition, S.prop, x, alt, z)                 -- step the prop to the grid point
    pcall(Ess.Camera.placeCamera, x, alt + CAM_UP, z, 0)         -- move the camera with it (streams; no player move)
    local okh, h = pcall(Object.GetHeightAboveTerrain, S.prop)

    local advance = false
    if okh and h and h > 2 and h < SENTINEL_H then
        local g = alt - h
        S.guess = g; S.n = S.n + 1; S.retry = 0
        wsline(string.format("<<GROUND>>%.2f,%.2f,%.2f,%.2f", x, alt, z, h))   -- page computes groundY = y - dist
        advance = true
    else                                          -- out of range: nudge the altitude guess, retry this point
        if h and h >= SENTINEL_H then S.guess = clamp(S.guess - SEARCH, GUESS_LO, GUESS_HI)
        else S.guess = clamp(S.guess + SEARCH, GUESS_LO, GUESS_HI) end
        S.retry = S.retry + 1
        if S.retry > MAX_RETRY then S.retry = 0; advance = true end   -- give up (ocean/void) -> skip
    end

    if advance then
        S.ix = S.ix + 1
        if S.ix >= S.cols then S.ix = 0; S.iz = S.iz + 1 end
    end
    return true
end)
