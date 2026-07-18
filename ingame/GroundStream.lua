local KEYVAL = "f5"   -- toggle key (add "GroundStream.lua=f5" under [OnKey])

-- GroundStream.lua -- fly-around terrain gatherer with a WIDE scan. Rigidly welds a grid of tiny probes to
-- your vehicle and reads Object.GetHeightAboveTerrain on EVERY probe each tick -- so one pass sweeps a whole
-- swath, not a single line. Streams <<GROUND>>x,y,z,dist per probe; ground-gather.html turns each into a
-- terrain point. Fly LOW: GetHeightAboveTerrain reaches ~155u down.
--
-- The weld: Object.Attach snaps every child's ORIGIN to the hardpoint (they all pile up at the heli centre),
-- so the grid offset has to be re-applied AFTER attaching -- via Object.SetPositionToObject with a per-probe
-- offset. (Fresh spawns also need a moment before their transform is ready, hence ATTACH_DELAY.) The prop must
-- weld rigidly: "Verification Camera" sticks; physics props like "Cash (Large)" don't.
--
-- ★ TUNE: GRID_N x SPACING = swath width; TEMPLATE; HARDPOINT (a confirmed rigid anchor on the vehicle);
--   ATTACH_DELAY; OFF_Y (drop the grid this far below the hardpoint if you want).

local Ess = _G.Ess
if not (Ess and Ess.Player and Ess.Loop and Ess.Object) then
    if Loader and Loader.Printf then Loader.Printf("[groundstream] load Ess (dist/Ess.lua) first") end
    return
end

local LOOP_ID, INTERVAL, SENTINEL = "GroundStream", 0.2, 150
local GRID_N, SPACING = 5, 32                  -- GRID_N x GRID_N probes SPACING apart -> a (GRID_N-1)*SPACING swath
local TEMPLATE = "Verification Camera"         -- welds rigidly (physics props like "Cash (Large)" don't stick)
local HARDPOINT = "prop_gen_part_p6snf8"       -- confirmed rigid-weld anchor on the heli (Logan)
local ATTACH_DELAY, OFF_Y = 0.5, 0             -- fresh transforms need ~0.3s; OFF_Y drops the grid below the anchor

local function wsline(s) if Loader and Loader.WsSend then pcall(Loader.WsSend, s) end end

_G.GroundStream = _G.GroundStream or { on = false, n = 0, probes = {}, offsets = {}, parent = nil }
local S = _G.GroundStream

local function cleanup()
    for _, u in ipairs(S.probes or {}) do
        if Ess.Object.valid(u) then
            if S.parent and Ess.Object.valid(S.parent) then pcall(Object.Detach, S.parent, u) end
            pcall(Object.Remove, u)
        end
    end
    S.probes, S.offsets = {}, {}
end

if S.on then                                     -- second press: STOP
    S.on = false; Ess.Loop.stop(LOOP_ID); cleanup()
    Ess.Log(string.format("[groundstream] STOPPED -- streamed %d reading(s).", S.n)); return
end

local x, y, z, _, char = Ess.Player.pose(0)
if not char then Ess.Log("[groundstream] no player character"); return end

S.parent = Ess.Object.vehicleOf(char) or char   -- the heli you're flying (or the character, on foot)
S.on, S.n, S.probes, S.offsets, S.attached, S.wait = true, 0, {}, {}, false, ATTACH_DELAY
local okp, ppx, ppy, ppz = pcall(Object.GetPosition, S.parent)
if not (okp and ppx) then ppx, ppy, ppz = x, y, z end

-- spawn all probes at the parent; the per-probe offset is applied after they're welded
local half = (GRID_N - 1) / 2
for i = 0, GRID_N - 1 do
    for j = 0, GRID_N - 1 do
        local u = Ess.Object.spawn(TEMPLATE, ppx, ppy, ppz, 0)
        if u then
            pcall(Object.DisablePhysics, u)
            S.probes[#S.probes + 1] = u
            S.offsets[#S.probes] = { ox = (i - half) * SPACING, oz = (j - half) * SPACING }
        end
    end
end
if #S.probes == 0 then S.on = false; Ess.Log("[groundstream] no probes spawned -- TEMPLATE '" .. TEMPLATE .. "' valid?"); return end
Ess.Log(string.format("[groundstream] STARTED -- %d probes (%dx%d @ %du, %du swath); welding in %.1fs. Fly low; F5 to stop.",
    #S.probes, GRID_N, GRID_N, SPACING, (GRID_N - 1) * SPACING, ATTACH_DELAY))

Ess.Loop.start(LOOP_ID, INTERVAL, function()
    if not S.on then return false end

    if not S.attached then                       -- transforms ready: weld each, THEN push it out to its grid offset
        S.wait = S.wait - INTERVAL
        if S.wait > 0 then return true end
        for k, u in ipairs(S.probes) do
            if Ess.Object.valid(u) then
                pcall(Object.Attach, S.parent, HARDPOINT, u)                                            -- rigid weld (-> hardpoint)
                pcall(Object.SetPositionToObject, u, S.parent, HARDPOINT, S.offsets[k].ox, OFF_Y, S.offsets[k].oz)  -- offset from it
            end
        end
        S.attached = true
        Ess.Log("[groundstream] probes welded + offset; streaming.")
        return true
    end

    for _, u in ipairs(S.probes) do              -- poll every probe -> a swath of readings per tick
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
