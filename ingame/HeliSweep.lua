local KEYVAL = "f8"   -- toggle key (add "HeliSweep.lua=f8" under [OnKey]); press again to ABORT

-- HeliSweep.lua -- automated AREA sweep: the fast, hands-free heightmap probe.
--
-- It hops a helicopter (a drop platform) across a SWEEP x SWEEP grid of chunks. At each chunk it drops a
-- GRID_N x GRID_N grid of boxes from altitude, lets them settle, reads where they landed (as it does for
-- GridProbe), cleans them up, and moves to the next chunk -- covering a whole region with one keypress.
--
-- Because the boxes fall from a fixed high altitude over terrain that varies, this is LESS accurate than the
-- hand-driven/walked probes (more bounce/drift), so its samples log as [HELI] and build_heightmap tiers them
-- as the LOWEST authority (vehicle > foot > grid > heli): a heli sample only wins a cell nothing better has
-- reached. Never more than GRID_N*GRID_N boxes exist at once (each chunk is cleaned before the next), so it
-- stays well under the spawn cap. Feeds the live map as <<ROADLOG>>DOT points, same as GridProbe.
--
-- ★ TUNE LIVE:  HELI_TEMPLATE (a spawnable heli; best-effort -- the sweep still runs if it fails to summon),
--   TEMPLATE (a fallable box), DROP_Y (absolute drop altitude -- must clear the tallest terrain in the
--   sweep; real terrain tops out ~70, the HQ instance is ~450, so ~120 is a safe start), SETTLE (from
--   altitude it may need >8s), SWEEP/GRID_N/STEP (coverage vs time; total run ~= SWEEP*SWEEP * SETTLE), OFFSET.

local Ess = _G.Ess
if not (Ess and Ess.Object and Ess.Object.spawn and Ess.Loop and Ess.Player) then
    if Loader and Loader.Printf then Loader.Printf("[helisweep] load Ess (dist/Ess.lua) first") end
    return
end

local HELI_TEMPLATE = "Little Bird"
local TEMPLATE       = "BirdBox"
local SWEEP, GRID_N, STEP, DROP_Y, SETTLE, OFFSET = 4, 8, 16, 120, 10.0, 0.0
local CHUNK = GRID_N * STEP    -- chunk spacing == grid width, so chunks tile edge-to-edge

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

-- build the SWEEP x SWEEP list of chunk centres around the player
local chunks, halfS = {}, (SWEEP - 1) / 2
for ix = 0, SWEEP - 1 do
    for iz = 0, SWEEP - 1 do
        chunks[#chunks + 1] = { x = px + (ix - halfS) * CHUNK, z = pz + (iz - halfS) * CHUNK }
    end
end
HS.on, HS.chunks, HS.i, HS.total, HS.crates = true, chunks, 1, 0, {}

-- summon the drop platform (best-effort; the sweep runs regardless). Physics off so it stays where placed.
HS.heli = Ess.Easy and Ess.Easy.Vehicle and Ess.Easy.Vehicle.summon and Ess.Easy.Vehicle.summon(HELI_TEMPLATE) or nil
if HS.heli and Ess.Object.valid(HS.heli) then
    pcall(Object.DisablePhysics, HS.heli)
    if Ess.Object.setInvincible then Ess.Object.setInvincible(HS.heli, true, "HeliSweep") end
end

local function dropChunk(c)
    if HS.heli and Ess.Object.valid(HS.heli) then pcall(Object.SetPosition, HS.heli, c.x, DROP_Y + 8, c.z) end
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
dropChunk(chunks[1])   -- drop the first chunk; the loop reads it after it settles, then advances
Ess.Log(string.format("[helisweep] %dx%d chunks (%du), %dx%d boxes each, settle %.1fs -- ~%.0fs total. F8 to abort.",
    SWEEP, SWEEP, CHUNK, GRID_N, GRID_N, SETTLE, SWEEP * SWEEP * SETTLE))

Ess.Loop.start("HeliSweep", SETTLE, function()
    if not HS.on then return false end
    readChunk()                        -- read the chunk that just settled
    HS.i = HS.i + 1
    if HS.i > #HS.chunks then           -- sweep complete
        HS.on = false
        if HS.heli and Ess.Object.valid(HS.heli) then pcall(Object.Remove, HS.heli) end
        wsline("<<ROADLOG>>STOP " .. HS.total)
        Ess.Log(string.format("[helisweep] done -- %d probe(s) across %d chunks.", HS.total, #HS.chunks))
        return false
    end
    dropChunk(HS.chunks[HS.i])          -- drop the next chunk; it settles over the next interval
    return true
end)
