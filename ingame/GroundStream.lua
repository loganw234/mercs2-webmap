local KEYVAL = "f5"   -- toggle key (add "GroundStream.lua=f5" under [OnKey]); press again to ABORT

-- GroundStream.lua -- automatic terrain scan via a cinematic-camera probe. NO teleport (teleporting to the
-- map corner loads out-of-bounds void and hard-crashes). Instead it starts the camera RIGHT WHERE YOU STAND
-- (already loaded) and flies it outward in smooth 32u hops (snake raster), so streaming keeps up and it never
-- jumps to an unloaded area. Only the cinematic camera moves -- the player never does.
--
-- Position yourself at the corner of the area you want, press F5: it sweeps +X/+Z across REGION_W x REGION_H
-- from there. Locks the camera onto a spawned prop (Ess.Camera.beginCinematic + lookAtObject -- the safe
-- primitives Ess.Cinematic uses) and reads Object.GetHeightAboveTerrain at each grid cell. Streams
-- <<GROUND>>x,y,z,dist. Altitude-follow keeps it in the ~155u ray. Ends the cinematic on finish/abort. F5 aborts.
--
-- ★ CONFIG: REGION_W / REGION_H (how far to sweep from you), RES_X / RES_Y (cell spacing; 32 = one per webmap
--   cell), DT (raise if reads thin out -- camera outrunning streaming), TEMPLATE.

local Ess = _G.Ess
if not (Ess and Ess.Camera and Ess.Player and Ess.Loop and Ess.Object) then
    if Loader and Loader.Printf then Loader.Printf("[groundstream] load Ess (dist/Ess.lua) first") end
    return
end

local LOOP_ID = "GroundStream"
local REGION_W, REGION_H = 8204, 8204  -- sweep this far +X / +Z from where you stand (8204 = whole map from a corner)
local RES_X, RES_Y = 32, 32
local TEMPLATE = "Verification Camera"
local CLEAR, CAM_UP = 100, 40          -- prop sits CLEAR above the ground guess; camera CAM_UP above the prop
local SENTINEL_H = 150
local SEARCH, MAX_RETRY = 90, 14
local GUESS_LO, GUESS_HI = -200, 700
local DT = 0.15                        -- camera travel ~= RES/DT world-units/sec; slow enough for streaming

local function wsline(s) if Loader and Loader.WsSend then pcall(Loader.WsSend, s) end end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end

_G.GroundStream = _G.GroundStream or { on = false, n = 0, prop = nil }
local S = _G.GroundStream

local function restore()
    pcall(Ess.Camera.endCinematic, 0)                            -- hand the camera back (never leave it held)
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

-- spawn the prop RIGHT WHERE YOU STAND (loaded) and take the camera THERE -- no teleport, no far jump.
S.prop = Ess.Object.spawn(TEMPLATE, px, py, pz, 0)
if not (S.prop and Ess.Object.valid(S.prop)) then Ess.Log("[groundstream] couldn't spawn '" .. TEMPLATE .. "'"); return end
pcall(Object.DisablePhysics, S.prop)
pcall(Ess.Camera.beginCinematic, 0, 0)           -- take the camera over, here where it's already loaded
pcall(Ess.Camera.lookAtObject, S.prop, nil, 0)   -- auto-track the prop; the camera follows it as it steps

S.on, S.n, S.guess, S.retry = true, 0, py or 0, 0
S.ox, S.oz = px, pz                              -- grid ORIGIN = where you stand; sweep +X/+Z from here
S.cols = math.floor(REGION_W / RES_X) + 1
S.rows = math.floor(REGION_H / RES_Y) + 1
S.ix, S.iz = 0, 0
wsline("<<ROADLOG>>START")
Ess.Log(string.format("[groundstream] scan %dx%d (%d pts) +X/+Z from here. No teleport. F5 aborts.",
    S.cols, S.rows, S.cols * S.rows))

Ess.Loop.start(LOOP_ID, DT, function()
    if not S.on then return false end
    if S.iz >= S.rows then                        -- whole region done
        S.on = false; restore(); wsline("<<ROADLOG>>STOP " .. S.n)
        Ess.Log(string.format("[groundstream] DONE -- %d terrain point(s). Camera restored.", S.n))
        return false
    end

    local z = S.oz + S.iz * RES_Y
    local x = (S.iz % 2 == 0) and (S.ox + S.ix * RES_X) or (S.ox + (S.cols - 1 - S.ix) * RES_X)   -- snake (smooth hops)
    local alt = S.guess + CLEAR

    pcall(Object.SetPosition, S.prop, x, alt, z)                 -- step the prop to the grid cell
    pcall(Ess.Camera.placeCamera, x, alt + CAM_UP, z, 0)         -- fly the camera with it (streams; no player move)
    local okh, h = pcall(Object.GetHeightAboveTerrain, S.prop)

    local advance = false
    if okh and h and h > 2 and h < SENTINEL_H then
        local g = alt - h
        S.guess = g; S.n = S.n + 1; S.retry = 0
        wsline(string.format("<<GROUND>>%.2f,%.2f,%.2f,%.2f", x, alt, z, h))   -- page computes groundY = y - dist
        advance = true
    else                                          -- out of range: nudge the altitude guess, retry this cell
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
