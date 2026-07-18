local KEYVAL = "f5"   -- toggle key (add "GroundStream.lua=f5" under [OnKey])

-- GroundStream.lua -- fly-around terrain gatherer with a WIDE scan. Spawns a grid of tiny probes and, each
-- tick, SetPositions them around your vehicle's CURRENT position (so they ride along as a grid) and reads
-- Object.GetHeightAboveTerrain on every one -- one pass sweeps a whole swath, not a single line. Streams
-- <<GROUND>>x,y,z,dist per probe; ground-gather.html turns each into a terrain point. Fly LOW (~155u ray).
--
-- NOTE: no Object.Attach -- the rigid weld kept snapping the whole grid onto the hardpoint (offset lost) and
-- then broke entirely. Repositioning each probe per tick gives the identical grid with none of that grief;
-- it's the same SetPosition + read that already produced the validated data.
--
-- ★ TUNE: GRID_N x SPACING = swath width; TEMPLATE (any spawnable prop, physics off); OFF_Y (grid height vs
--   the vehicle -- 0 = same level).

local Ess = _G.Ess
if not (Ess and Ess.Player and Ess.Loop and Ess.Object) then
    if Loader and Loader.Printf then Loader.Printf("[groundstream] load Ess (dist/Ess.lua) first") end
    return
end

local LOOP_ID, INTERVAL, SENTINEL = "GroundStream", 0.2, 150
local GRID_N, SPACING = 5, 32          -- GRID_N x GRID_N probes SPACING apart -> a (GRID_N-1)*SPACING-wide swath
local TEMPLATE = "Verification Camera" -- any spawnable prop; we only read its position (physics off)
local OFF_Y = 0                        -- probe grid height relative to the vehicle

local function wsline(s) if Loader and Loader.WsSend then pcall(Loader.WsSend, s) end end

_G.GroundStream = _G.GroundStream or { on = false, n = 0, probes = {}, offsets = {}, parent = nil }
local S = _G.GroundStream

local function cleanup()
    for _, u in ipairs(S.probes or {}) do if Ess.Object.valid(u) then pcall(Object.Remove, u) end end
    S.probes, S.offsets = {}, {}
end

if S.on then                                     -- second press: STOP
    S.on = false; Ess.Loop.stop(LOOP_ID); cleanup()
    Ess.Log(string.format("[groundstream] STOPPED -- streamed %d reading(s).", S.n)); return
end

local x, y, z, _, char = Ess.Player.pose(0)
if not char then Ess.Log("[groundstream] no player character"); return end

S.parent = Ess.Object.vehicleOf(char) or char   -- the heli you're flying (or the character, on foot)
S.on, S.n, S.probes, S.offsets = true, 0, {}, {}
local okp, ppx, ppy, ppz = pcall(Object.GetPosition, S.parent)
if not (okp and ppx) then ppx, ppy, ppz = x, y, z end

-- spawn the grid SPREAD OUT (each at its offset, so nothing piles up), physics off
local half = (GRID_N - 1) / 2
for i = 0, GRID_N - 1 do
    for j = 0, GRID_N - 1 do
        local ox, oz = (i - half) * SPACING, (j - half) * SPACING
        local u = Ess.Object.spawn(TEMPLATE, ppx + ox, ppy + OFF_Y, ppz + oz, 0)
        if u then
            pcall(Object.DisablePhysics, u)
            S.probes[#S.probes + 1] = u
            S.offsets[#S.probes] = { ox = ox, oz = oz }
        end
    end
end
if #S.probes == 0 then S.on = false; Ess.Log("[groundstream] no probes spawned -- TEMPLATE '" .. TEMPLATE .. "' valid?"); return end
Ess.Log(string.format("[groundstream] STARTED -- %d probes (%dx%d @ %du, %du swath). Fly low; F5 to stop.",
    #S.probes, GRID_N, GRID_N, SPACING, (GRID_N - 1) * SPACING))

Ess.Loop.start(LOOP_ID, INTERVAL, function()
    if not S.on then return false end
    local okc, cx, cy, cz = pcall(Object.GetPosition, S.parent)
    if not (okc and cx) then return true end
    for k, u in ipairs(S.probes) do
        if Ess.Object.valid(u) then
            local px, py, pz = cx + S.offsets[k].ox, cy + OFF_Y, cz + S.offsets[k].oz
            pcall(Object.SetPosition, u, px, py, pz)                    -- keep it in its grid slot around the heli
            local okh, h = pcall(Object.GetHeightAboveTerrain, u)
            if okh and h and h > 1 and h < SENTINEL then               -- in range -> a real ground reading
                S.n = S.n + 1
                wsline(string.format("<<GROUND>>%.2f,%.2f,%.2f,%.2f", px, py, pz, h))
            end
        end
    end
    return true
end)
