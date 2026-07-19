local KEYVAL = "f5"   -- toggle key (add "GroundStream.lua=f5" under [OnKey]); press again to ABORT

-- GroundStream.lua -- FULL-MAP terrain scan via a cinematic-camera probe. NO teleport (teleporting to the
-- map corner loads out-of-bounds void and hard-crashes). Instead it starts the camera RIGHT WHERE YOU STAND
-- (already loaded) and WALKS it in smooth 32u hops, so streaming keeps up and it never jumps to an unloaded
-- area. Only the cinematic camera moves -- the player never does.
--
-- Two phases:
--   TRANSIT: from your position, the camera walks hop-by-hop to the NEAREST map corner (map = +/-4102 on
--            X and Z, calibrated from missionforge). It probes ground along the way (readings streamed too).
--   SCAN:    from that corner, a snake raster sweeps the ENTIRE 8204x8204 map toward the opposite corner,
--            one reading per RES cell -- 100% coverage.
--
-- Locks the camera onto a spawned prop (Ess.Camera.beginCinematic + lookAtObject -- the safe primitives
-- Ess.Cinematic uses) and reads Object.GetHeightAboveTerrain at each step. Streams <<GROUND>>x,y,z,dist.
-- Altitude-follow keeps it in the ~155u ray. Ends the cinematic on finish/abort. F5 aborts.
--
-- ★ CONFIG: RES (cell spacing; match build_heightmap.py --cell), DT (raise if reads thin out -- camera
--   outrunning streaming), TEMPLATE. At RES 16 / DT 0.02: 501x501 = 251001 cells ~= 1h25m best case
--   (loop is frame-rate-capped, so ~2.5h at 30fps), plus land-retry overhead.

local Ess = _G.Ess
if not (Ess and Ess.Camera and Ess.Player and Ess.Loop and Ess.Object) then
    if Loader and Loader.Printf then Loader.Printf("[groundstream] load Ess (dist/Ess.lua) first") end
    return
end

local LOOP_ID = "GroundStream"
local MAP_MIN, MAP_MAX = -3999, 3999   -- world extent, both axes (8204x8204 centred on 0,0; missionforge-calibrated)
local RES = 16                         -- hop/cell size (16 = one reading per webmap cell at --cell 16)
local TEMPLATE = "Verification Camera"
local CLEAR, CAM_UP = 100, 40          -- prop sits CLEAR above the ground guess; camera CAM_UP above the prop
local SENTINEL_H = 350
local SEARCH, MAX_RETRY = 90, 14
local GUESS_LO, GUESS_HI = -200, 700
local DT = 0.02                        -- camera travel ~= RES/DT world-units/sec; slow enough for streaming

-- ★ RESUME: nil = fresh full scan from your nearest corner. To continue a failed pass, set the corner the
--   failed run STARTED from (its [groundstream] TRANSIT log line says it) and the z where it died; the camera
--   walks to the START of that row and re-rasters from there (one redundant row = seconds, guarantees no gap).
--   Set back to nil when done.
local RESUME = { corner_x = 3999, corner_z = -3999, row_z = 2929 }

-- ★ BREATHER: every PAUSE_ROWS completed rows, hold the camera still for PAUSE_SECS so the engine can catch
--   up on streamed assets (the crash pattern was "dies every ~130 rows" -- first run survived 132, so pause
--   at 10% under that). The camera doesn't move during the pause, which is what lets streaming drain.
local PAUSE_ROWS = 50
local PAUSE_SECS = 5

-- A ground of EXACTLY 0 is the engine's unstreamed-geometry placeholder, never real terrain (real water
-- surface reads ~-35, seafloor down to ~-180). Those cells get ZERO_RETRY ticks of patience (dense city
-- streaming), but after >8 consecutive zero-skips we assume meshless open ocean and skim at 1 retry.
local ZERO_RETRY = MAX_RETRY * 4

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
S.phase = "transit"
S.tx, S.tz = px, pz                              -- transit cursor: starts at the player, walks to the target
if RESUME then                                   -- pin the failed run's corner so the sweep geometry matches
    S.cx, S.cz = RESUME.corner_x, RESUME.corner_z
else
    S.cx = (px >= 0) and MAP_MAX or MAP_MIN      -- nearest corner (shortest safe walk)
    S.cz = (pz >= 0) and MAP_MAX or MAP_MIN
end
S.sx = (S.cx > 0) and -1 or 1                    -- scan sweep direction: away from the corner, across the map
S.sz = (S.cz > 0) and -1 or 1
S.cols = math.floor((MAP_MAX - MAP_MIN) / RES) + 1
S.rows = S.cols
S.startRow = 0
if RESUME then                                   -- resume at the START of the row that contains row_z
    S.startRow = clamp(math.floor((RESUME.row_z - S.cz) * S.sz / RES), 0, S.rows - 1)
end
-- transit target: the resume row's FIRST cell (snake: even rows start corner-side, odd rows far-side)
S.tgtx = (S.startRow % 2 == 0) and S.cx or (S.cx + (S.cols - 1) * RES * S.sx)
S.tgtz = S.cz + S.startRow * RES * S.sz
S.ix, S.iz = 0, S.startRow
wsline("<<ROADLOG>>START")
Ess.Log(string.format("[groundstream] TRANSIT: walking camera to (%d,%d)%s, then scan rows %d..%d of %dx%d. No teleport. F5 aborts.",
    S.tgtx, S.tgtz, RESUME and " (RESUME row start)" or " (corner)", S.startRow, S.rows - 1, S.cols, S.rows))

S.rowsDone, S.pauseTicks, S.zeroStreak = 0, 0, 0

Ess.Loop.start(LOOP_ID, DT, function()
    if not S.on then return false end
    if S.pauseTicks > 0 then S.pauseTicks = S.pauseTicks - 1; return true end   -- breather: hold still, let streaming drain

    -- pick this tick's target cell
    local x, z
    if S.phase == "transit" then
        x, z = S.tx, S.tz
    else
        if S.iz >= S.rows then                    -- whole map done
            S.on = false; restore(); wsline("<<ROADLOG>>STOP " .. S.n)
            Ess.Log(string.format("[groundstream] DONE -- %d terrain point(s). Camera restored.", S.n))
            return false
        end
        z = S.cz + S.iz * RES * S.sz
        x = (S.iz % 2 == 0) and (S.cx + S.ix * RES * S.sx)                    -- snake (smooth hops)
                            or  (S.cx + (S.cols - 1 - S.ix) * RES * S.sx)
    end
    local alt = S.guess + CLEAR

    pcall(Object.SetPosition, S.prop, x, alt, z)                 -- step the prop to the cell
    pcall(Ess.Camera.placeCamera, x, alt + CAM_UP, z, 0)         -- fly the camera with it (streams; no player move)
    local okh, h = pcall(Object.GetHeightAboveTerrain, S.prop)

    local advance = false
    local g = (okh and h and h > 2 and h < SENTINEL_H) and (alt - h) or nil
    if g and (g < -0.1 or g > 0.1) then         -- real terrain (real water surface reads ~-35, never 0)
        S.guess = g; S.n = S.n + 1; S.retry, S.zeroStreak = 0, 0
        wsline(string.format("<<GROUND>>%.2f,%.2f,%.2f,%.2f", x, alt, z, h))   -- page computes groundY = y - dist
        advance = true
    elseif g then                                 -- ground EXACTLY 0 = unstreamed geometry, NOT data: hold this
        S.retry = S.retry + 1                     -- cell and wait for streaming to catch up (city-density stalls).
        local budget = (S.zeroStreak > 8) and 1 or ZERO_RETRY   -- long zero runs = meshless open ocean -> fast-skip
        if S.retry > budget then S.retry = 0; S.zeroStreak = S.zeroStreak + 1; advance = true end   -- leave cell empty
    else                                          -- out of range: nudge the altitude guess, retry this cell
        if h and h >= SENTINEL_H then S.guess = clamp(S.guess - SEARCH, GUESS_LO, GUESS_HI)
        else S.guess = clamp(S.guess + SEARCH, GUESS_LO, GUESS_HI) end
        S.retry = S.retry + 1
        if S.retry > MAX_RETRY then S.retry = 0; advance = true end   -- give up (void) -> keep moving
    end

    if advance then
        if S.phase == "transit" then
            local dx, dz = S.tgtx - S.tx, S.tgtz - S.tz
            local d = math.sqrt(dx * dx + dz * dz)
            if d <= RES then                      -- target reached -> begin/resume the raster from here
                S.phase = "scan"; S.ix, S.iz, S.retry = 0, S.startRow, 0
                Ess.Log(string.format("[groundstream] (%d,%d) reached -- SCAN: rows %d..%d of the %dx%d raster.",
                    S.tgtx, S.tgtz, S.startRow, S.rows - 1, S.cols, S.rows))
            else                                  -- one RES-length hop straight toward the target
                S.tx = S.tx + dx / d * RES
                S.tz = S.tz + dz / d * RES
            end
        else
            S.ix = S.ix + 1
            if S.ix >= S.cols then
                S.ix = 0; S.iz = S.iz + 1
                S.rowsDone = S.rowsDone + 1
                if S.rowsDone % PAUSE_ROWS == 0 and S.iz < S.rows then
                    S.pauseTicks = math.floor(PAUSE_SECS / DT)
                    Ess.Log(string.format("[groundstream] row %d/%d -- %ds breather for asset streaming.",
                        S.iz, S.rows, PAUSE_SECS))
                end
            end
        end
    end
    return true
end)
