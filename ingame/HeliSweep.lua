local KEYVAL = "f8"   -- toggle key (add "HeliSweep.lua=f8" under [OnKey]); press again to ABORT

-- HeliSweep.lua -- automated AREA sweep: the fast, hands-free heightmap probe.
--
-- Hops a helicopter (drop platform) across a SWEEP x SWEEP grid of chunks. Per chunk, a small state machine:
--   move   -- teleport the heli to the chunk
--   (wait) -- STREAM_WAIT for the new area to stream in (else Pg.Spawn silently fails -> few boxes)
--   spawn  -- drop the GRID_N x GRID_N box grid in BATCHES (all-at-once can lock the whole grid midair)
--   settle -- POLL a few boxes' height; when it stops changing for STABLE_NEEDED checks, they've come to rest
--   read   -- report each box that ACTUALLY FELL (fall guard rejects any still stuck near drop altitude),
--             delete them all, advance to the next chunk
-- One chunk of boxes exists at a time (spawn-cap safe). F8 again aborts (cleans up boxes + heli).
--
-- Dropping from altitude over varied terrain is less accurate (bounce/drift), so samples log as [HELI] and
-- build_heightmap tiers them LOWEST (vehicle > foot > grid > heli). Feeds the live map as <<ROADLOG>>DOT.
--
-- ★ TUNE LIVE:  BATCH (boxes per spawn tick -- lower if grids still lock midair), STREAM_WAIT (raise if
--   chunks spawn sparse), STABLE_NEEDED/SETTLE_EPS/MAX_SETTLE (settle sensitivity), DROP_Y/MIN_FALL (drop
--   altitude + how far a box must fall to count), SWEEP/GRID_N/STEP, HELI_TEMPLATE/TEMPLATE, OFFSET.

local Ess = _G.Ess
if not (Ess and Ess.Object and Ess.Object.spawn and Ess.Loop and Ess.Player) then
    if Loader and Loader.Printf then Loader.Printf("[helisweep] load Ess (dist/Ess.lua) first") end
    return
end

local HELI_TEMPLATE = "AH1Z"           -- known-good heli (Logan)
local TEMPLATE       = "Cash (Large)"  -- known-good spawnable prop (Logan)
local SWEEP, GRID_N, STEP, DROP_Y, OFFSET = 4, 8, 16, 120, 0.0
local STREAM_WAIT = 3.0    -- seconds after teleport for the area to stream in before dropping
local BATCH = 16           -- boxes spawned per tick (staggered so the grid doesn't lock midair)
local DT = 0.2             -- state-machine / settle-poll tick
local STABLE_NEEDED = 10   -- consecutive stable polls (~STABLE_NEEDED*DT sec of no movement) => settled
local SETTLE_EPS = 0.1     -- |dy| below this per poll counts as "not moving"
local MAX_SETTLE = 15.0    -- hard cap on settling time per chunk (seconds)
local MIN_FALL = 15        -- a box must fall this far below DROP_Y to count (else it locked midair -> reject)
local N_SAMPLES = 6        -- how many boxes to poll for settlement
local CHUNK = GRID_N * STEP

local function wsline(s) if Loader and Loader.WsSend then pcall(Loader.WsSend, s) end end

_G.HeliSweep = _G.HeliSweep or {}
local HS = _G.HeliSweep

local function cleanupCrates()
    for _, u in ipairs(HS.crates or {}) do if Ess.Object.valid(u) then pcall(Object.Remove, u) end end
    HS.crates = {}
end

if HS.on then                                    -- second press: ABORT
    HS.on = false; Ess.Loop.stop("HeliSweep")
    cleanupCrates()
    if HS.heli and Ess.Object.valid(HS.heli) then pcall(Object.Remove, HS.heli) end
    wsline("<<ROADLOG>>STOP " .. (HS.total or 0))
    Ess.Log(string.format("[helisweep] aborted -- %d probe(s) so far.", HS.total or 0)); return
end

local px, _, pz = Ess.Player.pose(0)
if not px then Ess.Log("[helisweep] no player character"); return end

local chunks, halfS = {}, (SWEEP - 1) / 2
for ix = 0, SWEEP - 1 do
    for iz = 0, SWEEP - 1 do
        chunks[#chunks + 1] = { x = px + (ix - halfS) * CHUNK, z = pz + (iz - halfS) * CHUNK }
    end
end
HS.on, HS.chunks, HS.i, HS.total, HS.crates, HS.phase, HS.wait = true, chunks, 1, 0, {}, "move", 0

HS.heli = (Ess.Easy and Ess.Easy.Vehicle and Ess.Easy.Vehicle.summon and Ess.Easy.Vehicle.summon(HELI_TEMPLATE)) or nil
if HS.heli and Ess.Object.valid(HS.heli) then
    pcall(Object.DisablePhysics, HS.heli)
    if Ess.Object.setInvincible then Ess.Object.setInvincible(HS.heli, true, "HeliSweep") end
end

local function chunkPositions(c)
    local pos, half = {}, (GRID_N - 1) / 2
    for ix = 0, GRID_N - 1 do
        for iz = 0, GRID_N - 1 do
            pos[#pos + 1] = { x = c.x + (ix - half) * STEP, z = c.z + (iz - half) * STEP }
        end
    end
    return pos
end

-- poll up to N_SAMPLES boxes' heights, spread across the grid
local function sampleHeights()
    local ys, step = {}, math.max(1, math.floor(#HS.crates / N_SAMPLES))
    local i = 1
    while i <= #HS.crates and #ys < N_SAMPLES do
        if Ess.Object.valid(HS.crates[i]) then
            local ok, _, y = pcall(Object.GetPosition, HS.crates[i])
            if ok and y then ys[#ys + 1] = y end
        end
        i = i + step
    end
    return ys
end

wsline("<<ROADLOG>>START")
Ess.Log(string.format("[helisweep] %dx%d chunks (%du), %dx%d boxes in batches of %d, poll-settle. F8 aborts.",
    SWEEP, SWEEP, CHUNK, GRID_N, GRID_N, BATCH))

Ess.Loop.start("HeliSweep", DT, function()
    if not HS.on then return false end
    if HS.wait > 0 then HS.wait = HS.wait - DT; return true end

    if HS.phase == "move" then
        local c = HS.chunks[HS.i]
        if HS.heli and Ess.Object.valid(HS.heli) then pcall(Object.SetPosition, HS.heli, c.x, DROP_Y + 8, c.z) end
        HS.toSpawn, HS.crates = chunkPositions(c), {}
        HS.phase, HS.wait = "spawn", STREAM_WAIT      -- wait for streaming, THEN spawn
        return true

    elseif HS.phase == "spawn" then
        local k = 0                                   -- one BATCH per tick (staggered)
        while #HS.toSpawn > 0 and k < BATCH do
            local p = table.remove(HS.toSpawn)
            local u = Ess.Object.spawn(TEMPLATE, p.x, DROP_Y, p.z, 0)
            if u then pcall(Object.EnablePhysics, u); HS.crates[#HS.crates + 1] = u end
            k = k + 1
        end
        if #HS.toSpawn == 0 then HS.stable, HS.settleT, HS.prev = 0, 0, nil; HS.phase = "settle" end
        return true

    elseif HS.phase == "settle" then
        HS.settleT = HS.settleT + DT
        local ys = sampleHeights()
        if HS.prev and #ys == #HS.prev and #ys > 0 then
            local moved = false
            for i = 1, #ys do if math.abs(ys[i] - HS.prev[i]) > SETTLE_EPS then moved = true; break end end
            HS.stable = moved and 0 or (HS.stable + 1)
        end
        HS.prev = ys
        if HS.stable >= STABLE_NEEDED or HS.settleT >= MAX_SETTLE then HS.phase = "read" end
        return true

    else -- read
        local kept, locked = 0, 0
        for _, u in ipairs(HS.crates) do
            if Ess.Object.valid(u) then
                local ok, x, y, z = pcall(Object.GetPosition, u)
                if ok and x then
                    if y < DROP_Y - MIN_FALL then          -- actually fell -> valid sample
                        HS.total = HS.total + 1; kept = kept + 1
                        wsline(string.format("<<ROADLOG>>DOT %.2f,%.2f,%.2f,0.0", x, y - OFFSET, z))
                        Ess.Log(string.format("[HELI] %d  x=%.2f  y=%.2f  z=%.2f  yaw=0.0", HS.total, x, y - OFFSET, z))
                    else
                        locked = locked + 1                -- stuck near drop altitude -> midair, reject
                    end
                end
                pcall(Object.Remove, u)
            end
        end
        HS.crates = {}
        Ess.Log(string.format("[helisweep] chunk %d/%d: %d kept%s", HS.i, #HS.chunks, kept,
            locked > 0 and (", " .. locked .. " midair-rejected") or ""))
        HS.i = HS.i + 1
        if HS.i > #HS.chunks then
            HS.on = false
            if HS.heli and Ess.Object.valid(HS.heli) then pcall(Object.Remove, HS.heli) end
            wsline("<<ROADLOG>>STOP " .. HS.total)
            Ess.Log(string.format("[helisweep] done -- %d probe(s) across %d chunks.", HS.total, #HS.chunks))
            return false
        end
        HS.phase, HS.wait = "move", 0
        return true
    end
end)
