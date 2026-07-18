local KEYVAL = "f5"   -- toggle key (add "GroundStream.lua=f5" under [OnKey]); press again to ABORT

-- GroundStream.lua -- automatic full-map terrain scan via a cinematic-camera probe.
--
-- STARTUP ORDER (this is what stops the crash): teleport the player to the start corner ONCE, wait for it to
-- STREAM, THEN spawn the prop + take the camera THERE. Otherwise tick 1 flings the camera from the player's
-- loaded area straight to an unstreamed corner and the game hard-crashes. After that the player never moves;
-- only the cinematic camera flies, in smooth 32u hops (snake raster), so streaming keeps up as it goes.
--
-- Locks the camera onto the prop with Ess.Camera (beginCinematic + lookAtObject -- the safe primitives
-- Ess.Cinematic uses; raw Camera.* calls crash) and reads Object.GetHeightAboveTerrain at each grid point.
-- Streams <<GROUND>>x,y,z,dist. Altitude-follow keeps the prop within the ~155u ray. ALWAYS ends the
-- cinematic on finish/abort. F5 aborts.
--
-- ★ CONFIG: RES_X / RES_Y (grid spacing; 32 = one per webmap cell), MAP_HALF, DT (raise if the camera
--   outruns streaming and reads thin out), STREAM_WAIT, TEMPLATE.

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
local STREAM_WAIT = 8.0                -- wait after the start teleport for the corner to stream before taking the camera
local START_ALT = 300                  -- teleport altitude at the corner (above terrain so we don't land in rock)
local SENTINEL_H = 150
local SEARCH, MAX_RETRY = 90, 14
local GUESS_LO, GUESS_HI = -200, 700
local DT = 0.15                        -- ~RES/DT world-units/sec of camera travel; slow enough for streaming

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

if not Ess.Player.character(0) then Ess.Log("[groundstream] no player character"); return end

S.on, S.n, S.retry, S.prop = true, 0, 0, nil
S.cols = math.floor(2 * MAP_HALF / RES_X) + 1
S.rows = math.floor(2 * MAP_HALF / RES_Y) + 1
S.ix, S.iz = 0, 0
S.phase, S.wait = "setup", STREAM_WAIT

-- the ONE player teleport: to the start corner, so it streams before the camera goes there.
local startX, startZ = -MAP_HALF, -MAP_HALF
if Ess.Player.teleport then pcall(Ess.Player.teleport, startX, START_ALT, startZ, 0) end
Ess.Log(string.format("[groundstream] teleported to start corner (%.0f,%.0f); streaming %.0fs...", startX, startZ, STREAM_WAIT))

Ess.Loop.start(LOOP_ID, DT, function()
    if not S.on then return false end
    if S.wait > 0 then S.wait = S.wait - DT; return true end   -- let the corner finish streaming

    if S.phase == "setup" then
        local cx, cy, cz = Ess.Player.pose(0)                  -- the player is at the (now-streamed) corner
        S.prop = Ess.Object.spawn(TEMPLATE, cx or startX, cy or START_ALT, cz or startZ, 0)   -- spawn NEAR the player
        if not (S.prop and Ess.Object.valid(S.prop)) then S.on = false; Ess.Log("[groundstream] couldn't spawn '" .. TEMPLATE .. "'"); return false end
        pcall(Object.DisablePhysics, S.prop)
        pcall(Ess.Camera.beginCinematic, 0, 0)                 -- take the camera over, HERE where it's loaded
        pcall(Ess.Camera.lookAtObject, S.prop, nil, 0)         -- auto-track the prop
        S.guess = cy or 0
        wsline("<<ROADLOG>>START")
        Ess.Log(string.format("[groundstream] cinematic scan %dx%d (%d pts) @ res %d,%d. Player stays put; F5 aborts.",
            S.cols, S.rows, S.cols * S.rows, RES_X, RES_Y))
        S.phase = "sweep"
        return true
    end

    if S.iz >= S.rows then                                     -- whole grid done
        S.on = false; restore(); wsline("<<ROADLOG>>STOP " .. S.n)
        Ess.Log(string.format("[groundstream] DONE -- %d terrain point(s). Camera restored.", S.n))
        return false
    end

    local z = -MAP_HALF + S.iz * RES_Y
    local x = (S.iz % 2 == 0) and (-MAP_HALF + S.ix * RES_X) or (MAP_HALF - S.ix * RES_X)   -- snake raster (smooth hops)
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
