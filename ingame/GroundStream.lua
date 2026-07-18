local KEYVAL = "f5"   -- toggle key (add "GroundStream.lua=f5" under [OnKey])

-- GroundStream.lua -- fly-around terrain gatherer with a WIDE scan. It rigidly welds a grid of tiny probes to
-- your vehicle (Object.Attach -- the offset is applied by spawning each probe at its offset, THEN attaching,
-- so the weld holds it there) and reads Object.GetHeightAboveTerrain on EVERY probe each tick. So one pass
-- sweeps a whole swath instead of a single line. Streams <<GROUND>>x,y,z,dist per probe; ground-gather.html
-- turns each into a terrain point. Fly LOW: GetHeightAboveTerrain reaches ~155u down.
--
-- ★ TUNE: GRID_N x SPACING = swath width; TEMPLATE (any spawnable prop -- physics off, just a point to read
--   from); HARDPOINT (attach anchor on the vehicle; the per-probe offset is what actually spaces the grid).

local Ess = _G.Ess
if not (Ess and Ess.Player and Ess.Loop and Ess.Object) then
    if Loader and Loader.Printf then Loader.Printf("[groundstream] load Ess (dist/Ess.lua) first") end
    return
end

local LOOP_ID, INTERVAL, SENTINEL = "GroundStream", 0.2, 150
local GRID_N, SPACING = 5, 32      -- GRID_N x GRID_N probes SPACING apart -> a (GRID_N-1)*SPACING-wide swath
local TEMPLATE = "Cash (Large)"    -- any spawnable prop (we only read its position, physics off)
local HARDPOINT = ""               -- attach anchor; offset comes from pre-positioning each probe

local function wsline(s) if Loader and Loader.WsSend then pcall(Loader.WsSend, s) end end

_G.GroundStream = _G.GroundStream or { on = false, n = 0, probes = {}, parent = nil }
local S = _G.GroundStream

local function cleanup()
    for _, u in ipairs(S.probes or {}) do
        if Ess.Object.valid(u) then
            if S.parent and Ess.Object.valid(S.parent) then pcall(Object.Detach, S.parent, u) end
            pcall(Object.Remove, u)
        end
    end
    S.probes = {}
end

if S.on then                                     -- second press: STOP
    S.on = false; Ess.Loop.stop(LOOP_ID); cleanup()
    Ess.Log(string.format("[groundstream] STOPPED -- streamed %d reading(s).", S.n)); return
end

local x, y, z, _, char = Ess.Player.pose(0)
if not char then Ess.Log("[groundstream] no player character"); return end

-- weld the probe grid to the vehicle you're flying (or the character, on foot)
S.parent = Ess.Object.vehicleOf(char) or char
S.on, S.n, S.probes = true, 0, {}
local okp, ppx, ppy, ppz = pcall(Object.GetPosition, S.parent)
if not (okp and ppx) then ppx, ppy, ppz = x, y, z end

local half = (GRID_N - 1) / 2
for i = 0, GRID_N - 1 do
    for j = 0, GRID_N - 1 do
        local u = Ess.Object.spawn(TEMPLATE, ppx + (i - half) * SPACING, ppy, ppz + (j - half) * SPACING, 0)   -- at the offset...
        if u then
            pcall(Object.DisablePhysics, u)
            pcall(Object.Attach, S.parent, HARDPOINT, u)                                                        -- ...rigid-weld it there
            S.probes[#S.probes + 1] = u
        end
    end
end
if #S.probes == 0 then S.on = false; Ess.Log("[groundstream] no probes spawned -- TEMPLATE valid?"); return end
Ess.Log(string.format("[groundstream] STARTED -- %d probes (%dx%d @ %du, %du swath). Fly low; F5 to stop.",
    #S.probes, GRID_N, GRID_N, SPACING, (GRID_N - 1) * SPACING))

Ess.Loop.start(LOOP_ID, INTERVAL, function()
    if not S.on then return false end
    for _, u in ipairs(S.probes) do
        if Ess.Object.valid(u) then
            local ok, ux, uy, uz = pcall(Object.GetPosition, u)
            local okh, h = pcall(Object.GetHeightAboveTerrain, u)
            if ok and ux and okh and h and h > 1 and h < SENTINEL then     -- in range -> a real ground reading
                S.n = S.n + 1
                wsline(string.format("<<GROUND>>%.2f,%.2f,%.2f,%.2f", ux, uy, uz, h))
            end
        end
    end
    return true
end)
