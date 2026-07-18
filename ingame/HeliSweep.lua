local KEYVAL = "f8"   -- toggle key (add "HeliSweep.lua=f8" under [OnKey]); press again to ABORT

-- HeliSweep.lua -- automated AREA sweep: the fast, hands-free heightmap probe.
--
-- Hops a helicopter (drop platform) across a SWEEP x SWEEP grid of chunks. Per chunk it TELEPORTS the heli,
-- WAITS for the new area to stream in, drops a GRID_N x GRID_N box grid from altitude, waits for them to
-- SETTLE, reads where they landed, cleans them up, and moves on -- a whole region with one keypress (F8;
-- press again to abort). Never more than one chunk of boxes alive at once (spawn-cap safe).
--
-- ★ The STREAM_WAIT after each teleport is essential: Pg.Spawn into an area that hasn't finished streaming
--   silently fails for most boxes (Logan's finding -- "only a few spawn"). If a fresh chunk still comes up
--   sparse, raise STREAM_WAIT.
--
-- Dropping from a fixed altitude over varied terrain is less accurate (bounce/drift), so its samples log as
-- [HELI] and build_heightmap tiers them LOWEST (vehicle > foot > grid > heli): a heli sample only wins a cell
-- nothing better has reached. Feeds the live map as <<ROADLOG>>DOT points, same as GridProbe.
--
-- ★ TUNE LIVE:  STREAM_WAIT (raise if chunks spawn sparse), SETTLE (from altitude it may need >8s), DROP_Y
--   (absolute drop altitude -- must clear the tallest terrain in the sweep; real terrain tops out ~70), SWEEP
--   /GRID_N/STEP (coverage vs time; run ~= SWEEP*SWEEP * (STREAM_WAIT+SETTLE)), HELI_TEMPLATE/TEMPLATE, OFFSET.

local Ess = _G.Ess
if not (Ess and Ess.Object and Ess.Object.spawn and Ess.Loop and Ess.Player) then
    if Loader and Loader.Printf then Loader.Printf("[helisweep] load Ess (dist/Ess.lua) first") end
    return
end

local HELI_TEMPLATE = "AH1Z"           -- known-good heli (Logan)
local TEMPLATE       = "Cash (Large)"  -- known-good spawnable prop (Logan)
local SWEEP, GRID_N, STEP, DROP_Y, SETTLE, OFFSET = 4, 8, 16, 120, 10.0, 0.0
local STREAM_WAIT = 3.0                -- seconds after teleport for the area to stream in BEFORE dropping
local CHUNK = GRID_N * STEP            -- chunk spacing == grid width, so chunks tile edge-to-edge
local DT = 0.5                         -- state-machine tick

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

-- SWEEP x SWEEP chunk centres around the player
local chunks, halfS = {}, (SWEEP - 1) / 2
for ix = 0, SWEEP - 1 do
    for iz = 0, SWEEP - 1 do
        chunks[#chunks + 1] = { x = px + (ix - halfS) * CHUNK, z = pz + (iz - halfS) * CHUNK }
    end
end
HS.on, HS.chunks, HS.i, HS.total, HS.crates, HS.phase, HS.wait = true, chunks, 1, 0, {}, "move", 0

-- summon the drop platform (best-effort; the sweep runs regardless). Physics off so it stays where placed.
HS.heli = (Ess.Easy and Ess.Easy.Vehicle and Ess.Easy.Vehicle.summon and Ess.Easy.Vehicle.summon(HELI_TEMPLATE)) or nil
if HS.heli and Ess.Object.valid(HS.heli) then
    pcall(Object.DisablePhysics, HS.heli)
    if Ess.Object.setInvincible then Ess.Object.setInvincible(HS.heli, true, "HeliSweep") end
end

local function dropChunk(c)
    HS.crates = {}
    local half = (GRID_N - 1) / 2
    for ix = 0, GRID_N - 1 do
        for iz = 0, GRID_N - 1 do
            local u = Ess.Object.spawn(TEMPLATE, c.x + (ix - half) * STEP, DROP_Y, c.z + (iz - half) * STEP, 0)
            if u then pcall(Object.EnablePhysics, u); HS.crates[#HS.crates + 1] = u end
        end
    end
end

local function readChunk()
    for _, u in ipairs(HS.crates) do
        if Ess.Object.valid(u) then
            local ok, x, y, z = pcall(Object.GetPosition, u)
            if ok and x then
                HS.total = HS.total + 1
                wsline(string.format("<<ROADLOG>>DOT %.2f,%.2f,%.2f,0.0", x, y - OFFSET, z))
                Ess.Log(string.format("[HELI] %d  x=%.2f  y=%.2f  z=%.2f  yaw=0.0", HS.total, x, y - OFFSET, z))
            end
            pcall(Object.Remove, u)
        end
    end
    HS.crates = {}
end

wsline("<<ROADLOG>>START")
Ess.Log(string.format("[helisweep] %dx%d chunks (%du), %dx%d boxes, wait %.1fs + settle %.1fs -- ~%.0fs total. F8 aborts.",
    SWEEP, SWEEP, CHUNK, GRID_N, GRID_N, STREAM_WAIT, SETTLE, SWEEP * SWEEP * (STREAM_WAIT + SETTLE)))

-- per chunk: move (teleport) -> wait STREAM_WAIT -> drop -> wait SETTLE -> read -> next chunk
Ess.Loop.start("HeliSweep", DT, function()
    if not HS.on then return false end
    if HS.wait > 0 then HS.wait = HS.wait - DT; return true end     -- still waiting out a phase

    if HS.phase == "move" then
        local c = HS.chunks[HS.i]
        if HS.heli and Ess.Object.valid(HS.heli) then pcall(Object.SetPosition, HS.heli, c.x, DROP_Y + 8, c.z) end
        HS.phase, HS.wait = "drop", STREAM_WAIT                     -- let the area stream in before dropping
        return true
    elseif HS.phase == "drop" then
        dropChunk(HS.chunks[HS.i])
        HS.phase, HS.wait = "read", SETTLE                         -- let them fall + settle
        return true
    else -- read
        readChunk()
        HS.i = HS.i + 1
        if HS.i > #HS.chunks then                                   -- sweep complete
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
