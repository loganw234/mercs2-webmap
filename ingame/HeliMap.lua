local KEYVAL = "f6"   -- toggle key (add "HeliMap.lua=f6" under [OnKey]); press again to ABORT

-- HeliMap.lua -- terrain-FOLLOWING stripe sweep via Object.GetHeightAboveTerrain.
--
-- GetHeightAboveTerrain only reaches ~155u down (155.69 = the no-hit sentinel), and the map spans ~500u of
-- elevation, so altitude must follow the ground. CRUCIALLY each box in the row follows its OWN column's
-- terrain (independent altitude) -- a shared altitude can't read a cross-slope, so only the one matching box
-- was reading. The heli (physics OFF -> can't crash) rides above the median. Seeded from START_GROUND; a box
-- that loses the ground (out of ray range) searches its altitude back onto it.
--
-- NEVER moves the player after the ONE initial teleport (Ess.Easy.Vehicle.summon seats them; then only the
-- heli/boxes move). Summon waits STREAM_WAIT so the start is streamed. One stripe per run along SWEEP_DIR*X;
-- do parallel passes by hand (bump START_Z by +ROW_N*STEP).
--
-- ★ TUNE:  START_X/START_Z + START_GROUND (start point + its terrain height), SWEEP_DIR (-1 = -X into the
--   map from the +X corner; +1 = +X), LENGTH, ROW_N/STEP, SETPOINT/SENTINEL_H/SEARCH, STREAM_WAIT,
--   MOVE_STEP/DT, HELI_CLEAR, HELI_TEMPLATE/TEMPLATE.

local Ess = _G.Ess
if not (Ess and Ess.Object and Ess.Object.spawn and Ess.Loop and Ess.Player and Ess.Easy and Ess.Easy.Vehicle) then
    if Loader and Loader.Printf then Loader.Printf("[helimap] load Ess (dist/Ess.lua) first") end
    return
end

local HELI_TEMPLATE = "AH1Z"
local TEMPLATE = "Cash (Large)"
local ROW_N, STEP = 12, 32              -- ROW_N boxes STEP apart -> stripe width, spanning +Z from START_Z
local START_X, START_Z = 3461, -3636    -- start point (edit per pass; +Z shift = ROW_N*STEP)
local START_GROUND = 472                -- ground height AT the start (seeds the follower)
local SWEEP_DIR = -1                    -- -1 sweeps -X (INTO the map from the +X corner); +1 sweeps +X
local LENGTH = 8204                     -- fly this far along SWEEP_DIR*X then stop
local STREAM_WAIT = 10.0                -- fixed wait after teleport for streaming before summoning the heli
local MOVE_STEP = 16                    -- heli forward step per tick (small = slow/streaming-safe)
local SETPOINT = 90                     -- keep each box ~this far above its terrain (well inside the ~155 ray)
local SENTINEL_H = 150                  -- a reading is valid only if hAbove is in (2, SENTINEL_H)
local SEARCH = 90                       -- when a box loses the ground, step its altitude this much to refind it
local HELI_CLEAR = 60                   -- heli rides this far above the row's median altitude
local GUESS_LO, GUESS_HI = -60, 700     -- clamp a box's altitude guess to sane map elevations
local DT = 0.25

local function wsline(s) if Loader and Loader.WsSend then pcall(Loader.WsSend, s) end end
local function median(t) if #t == 0 then return nil end; table.sort(t); return t[math.floor((#t + 1) / 2)] end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end

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
HM.on, HM.total, HM.heli, HM.row, HM.bg = true, 0, nil, {}, {}
HM.curX = START_X
HM.phase, HM.wait = "spawn", STREAM_WAIT

-- the ONE and ONLY player teleport: to the start, safely ABOVE its ground so we don't land inside terrain.
if Ess.Player.teleport then pcall(Ess.Player.teleport, START_X, START_GROUND + 40, rowCenterZ, 0) end
Ess.Log(string.format("[helimap] teleported to (%.0f,%.0f) ground~%.0f; waiting %.0fs for streaming...", START_X, START_Z, START_GROUND, STREAM_WAIT))

Ess.Loop.start("HeliMap", DT, function()
    if not HM.on then return false end
    if HM.wait > 0 then HM.wait = HM.wait - DT; return true end

    if HM.phase == "spawn" then
        HM.heli = Ess.Easy.Vehicle.summon(HELI_TEMPLATE)      -- spawns the heli AND seats the player
        if not (HM.heli and Ess.Object.valid(HM.heli)) then HM.on = false; Ess.Log("[helimap] couldn't summon '" .. HELI_TEMPLATE .. "'"); return false end
        local char = Ess.Player.character(0)
        if char and Ess.Vehicle and Ess.Vehicle.seatOf and not Ess.Vehicle.seatOf(char) and Ess.Vehicle.enterBestSeat then pcall(Ess.Vehicle.enterBestSeat, char, HM.heli) end
        if char and Ess.Vehicle and Ess.Vehicle.seatOf and not Ess.Vehicle.seatOf(char) then Ess.Log("[helimap] WARNING: player not seated -- raise STREAM_WAIT.") end
        pcall(Object.DisablePhysics, HM.heli)                 -- kinematic: SetPosition can't crash it into terrain
        pcall(Object.SetYaw, HM.heli, (SWEEP_DIR > 0) and -90 or 90)   -- face the flight direction (cosmetic)
        pcall(Object.SetPosition, HM.heli, START_X, START_GROUND + SETPOINT + HELI_CLEAR, rowCenterZ)
        for i = 0, ROW_N - 1 do
            local u = Ess.Object.spawn(TEMPLATE, START_X, START_GROUND + SETPOINT, START_Z + i * STEP, 0)
            if u then pcall(Object.DisablePhysics, u); HM.row[#HM.row + 1] = u; HM.bg[#HM.row] = START_GROUND end
        end
        if #HM.row == 0 then HM.on = false; cleanup(); Ess.Log("[helimap] box spawn failed -- TEMPLATE valid?"); return false end
        wsline("<<ROADLOG>>START")
        Ess.Log(string.format("[helimap] per-box terrain-follow, sweep %sX for %d, z[%.0f..%.0f] (%d boxes). F6 aborts.",
            SWEEP_DIR > 0 and "+" or "-", LENGTH, START_Z, START_Z + (ROW_N - 1) * STEP, #HM.row))
        HM.phase = "fly"
        return true
    end

    -- fly: each box follows its OWN column's terrain height (independent altitude)
    if not (HM.heli and Ess.Object.valid(HM.heli)) then HM.on = false; cleanup(); Ess.Log("[helimap] lost the heli"); return false end
    local alts = {}
    for i = 1, #HM.row do
        local u = HM.row[i]
        if Ess.Object.valid(u) then
            local z = START_Z + (i - 1) * STEP
            pcall(Object.SetPosition, u, HM.curX, HM.bg[i] + SETPOINT, z)
            local okp, x, y, zz = pcall(Object.GetPosition, u)
            local okh, h = pcall(Object.GetHeightAboveTerrain, u)
            if okp and x and okh and h then
                if h > 2 and h < SENTINEL_H then
                    local g = y - h
                    HM.bg[i] = g
                    HM.total = HM.total + 1
                    wsline(string.format("<<ROADLOG>>DOT %.2f,%.2f,%.2f,0.0", x, g, zz))
                    Ess.Log(string.format("[TERRAIN] %d  x=%.2f  y=%.2f  z=%.2f  yaw=0.0", HM.total, x, g, zz))
                elseif h >= SENTINEL_H then HM.bg[i] = clamp(HM.bg[i] - SEARCH, GUESS_LO, GUESS_HI)   -- box too high above terrain
                else HM.bg[i] = clamp(HM.bg[i] + SEARCH, GUESS_LO, GUESS_HI) end                     -- box at/under terrain
            end
        end
        alts[#alts + 1] = HM.bg[i]
    end
    pcall(Object.SetPosition, HM.heli, HM.curX, (median(alts) or START_GROUND) + SETPOINT + HELI_CLEAR, rowCenterZ)

    HM.curX = HM.curX + SWEEP_DIR * MOVE_STEP
    if math.abs(HM.curX - START_X) >= LENGTH then
        HM.on = false; cleanup(); wsline("<<ROADLOG>>STOP " .. HM.total)
        Ess.Log(string.format("[helimap] stripe done -- %d terrain point(s). Set START_Z += %d and rerun.", HM.total, ROW_N * STEP))
        return false
    end
    return true
end)
