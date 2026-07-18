local KEYVAL = "f6"   -- toggle key (add "HeliMap.lua=f6" under [OnKey]); press again to ABORT

-- HeliMap.lua -- terrain-FOLLOWING stripe sweep via Object.GetHeightAboveTerrain.
--
-- GetHeightAboveTerrain only reaches ~155u down (beyond that it returns a ~155.69 "no hit" sentinel). The map
-- spans ~500u of elevation (water ~-33 to mountains ~470+), so a fixed flight altitude can't read all of it.
-- Instead we FOLLOW the terrain: keep the box row a fixed SETPOINT (~90u) above the LAST reading so it stays
-- in ray range as the ground rises/falls, and ride the heli (physics OFF -> can't crash) just above the boxes.
-- Seeded from START_GROUND. If a column reads nothing (a cliff jumped out of range) it searches the altitude
-- back onto the terrain before advancing.
--
-- NEVER moves the player after the ONE initial teleport: Ess.Easy.Vehicle.summon seats them, then only the
-- heli/boxes move. Heli is summoned only after STREAM_WAIT so the start is streamed (else the seat fails and
-- the empty heli flies off). One forward (+X) stripe per run; do parallel passes by hand (bump START_Z).
--
-- ★ TUNE:  START_X/START_Z + START_GROUND (your start point and its ground height), LENGTH, ROW_N/STEP,
--   SETPOINT/SENTINEL_H/SEARCH (follower), STREAM_WAIT, MOVE_STEP/DT (speed), HELI_CLEAR, HELI_TEMPLATE.

local Ess = _G.Ess
if not (Ess and Ess.Object and Ess.Object.spawn and Ess.Loop and Ess.Player and Ess.Easy and Ess.Easy.Vehicle) then
    if Loader and Loader.Printf then Loader.Printf("[helimap] load Ess (dist/Ess.lua) first") end
    return
end

local HELI_TEMPLATE = "AH1Z"
local TEMPLATE = "Cash (Large)"
local ROW_N, STEP = 12, 32              -- ROW_N boxes STEP apart -> stripe width, spanning +Z from START_Z
local START_X, START_Z = 3461, -3636    -- your start point (edit per pass; +Z shift = ROW_N*STEP)
local START_GROUND = 472                -- ground height AT the start (seeds the follower) -- you gave 472
local LENGTH = 8204                     -- fly this far +X then stop
local STREAM_WAIT = 10.0                -- fixed wait after teleport for streaming before summoning the heli
local MOVE_STEP = 16                    -- heli forward step per tick (small = slow/streaming-safe)
local SETPOINT = 90                     -- keep the box row ~this far above terrain (well inside the ~155 ray)
local SENTINEL_H = 150                  -- a reading is valid only if hAbove is in (2, SENTINEL_H)
local SEARCH = 90                       -- when a column reads nothing, step the altitude guess to refind ground
local HELI_CLEAR = 60                   -- heli rides this far above the box row
local GUESS_LO, GUESS_HI = -60, 700     -- clamp the follower's ground guess to sane map elevations
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
HM.on, HM.total, HM.heli, HM.row = true, 0, nil, {}
HM.curX, HM.guess, HM.retry = START_X, START_GROUND, 0
HM.phase, HM.wait = "spawn", STREAM_WAIT

-- the ONE and ONLY player teleport: to the start, safely ABOVE its ground so we don't land inside a mountain.
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
        pcall(Object.SetPosition, HM.heli, START_X, HM.guess + SETPOINT + HELI_CLEAR, rowCenterZ)
        for i = 0, ROW_N - 1 do
            local u = Ess.Object.spawn(TEMPLATE, START_X, HM.guess + SETPOINT, START_Z + i * STEP, 0)
            if u then pcall(Object.DisablePhysics, u); HM.row[#HM.row + 1] = u end
        end
        if #HM.row == 0 then HM.on = false; cleanup(); Ess.Log("[helimap] box spawn failed -- TEMPLATE valid?"); return false end
        wsline("<<ROADLOG>>START")
        Ess.Log(string.format("[helimap] terrain-follow sweep +X for %d, z[%.0f..%.0f]. F6 aborts.", LENGTH, START_Z, START_Z + (ROW_N - 1) * STEP))
        HM.phase = "fly"
        return true
    end

    -- fly: position the row at the follower altitude, read, then either advance (got terrain) or search (lost it)
    if not (HM.heli and Ess.Object.valid(HM.heli)) then HM.on = false; cleanup(); Ess.Log("[helimap] lost the heli"); return false end
    local boxAlt = HM.guess + SETPOINT
    for i = 1, #HM.row do if Ess.Object.valid(HM.row[i]) then pcall(Object.SetPosition, HM.row[i], HM.curX, boxAlt, START_Z + (i - 1) * STEP) end end
    pcall(Object.SetPosition, HM.heli, HM.curX, boxAlt + HELI_CLEAR, rowCenterZ)

    local grounds, hs = {}, {}
    for i = 1, #HM.row do
        local u = HM.row[i]
        if Ess.Object.valid(u) then
            local okp, x, y, z = pcall(Object.GetPosition, u)
            local okh, h = pcall(Object.GetHeightAboveTerrain, u)
            if okp and x and okh and h then
                hs[#hs + 1] = h
                if h > 2 and h < SENTINEL_H then grounds[#grounds + 1] = { x = x, z = z, g = y - h } end
            end
        end
    end

    if #grounds > 0 then                              -- got the terrain: emit + follow it, advance a column
        local gy = {}
        for _, p in ipairs(grounds) do
            HM.total = HM.total + 1; gy[#gy + 1] = p.g
            wsline(string.format("<<ROADLOG>>DOT %.2f,%.2f,%.2f,0.0", p.x, p.g, p.z))
            Ess.Log(string.format("[TERRAIN] %d  x=%.2f  y=%.2f  z=%.2f  yaw=0.0", HM.total, p.x, p.g, p.z))
        end
        HM.guess, HM.retry = median(gy), 0
        HM.curX = HM.curX + MOVE_STEP
        if HM.curX - START_X >= LENGTH then
            HM.on = false; cleanup(); wsline("<<ROADLOG>>STOP " .. HM.total)
            Ess.Log(string.format("[helimap] stripe done -- %d terrain point(s). Set START_Z += %d and rerun.", HM.total, ROW_N * STEP))
            return false
        end
    else                                              -- lost the ground (cliff): search the altitude, don't advance
        local mh = median(hs)
        if mh and mh >= SENTINEL_H then HM.guess = clamp(HM.guess - SEARCH, GUESS_LO, GUESS_HI)   -- too high above terrain
        else HM.guess = clamp(HM.guess + SEARCH, GUESS_LO, GUESS_HI) end                          -- at/under terrain
        HM.retry = HM.retry + 1
        if HM.retry > 24 then HM.curX = HM.curX + MOVE_STEP; HM.retry = 0 end                     -- give up on this column
    end
    return true
end)
