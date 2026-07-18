local KEYVAL = "f9"   -- toggle key (add "GridProbe.lua=f9" under [OnKey])

-- GridProbe.lua -- "semi-rapid" AREA heightmap probe. Drops a grid of physics props around you; each falls
-- and settles on the terrain; we read where each landed (Object.GetPosition) to grab a whole CHUNK of
-- ground-height samples at once, then delete them. Feeds the same map channel as the loggers, but as
-- <<ROADLOG>>DOT points (scattered, not a connected trail), so the webmap fills the chunk in live and it
-- exports/rebuilds into the heightmap like everything else.
--
-- WHY drop objects: the engine has NO ground-raycast native (only Player.GetTargetUnderReticle, a single
-- reticle hit), so settling physics props and reading their rest height is the way to sample points. You do
-- NOT need to pin them with huge mass -- we read each object's FINAL x,y,z, so a prop that slides a bit on a
-- slope just yields a valid sample slightly off-grid (fine; the map bins to cells). Object.Remove cleanup is
-- MANDATORY -- never leave the probes behind.
--
-- ★ TUNE THESE LIVE (can't verify headless):
--   TEMPLATE  must be a spawnable PHYSICS prop that FALLS. "BirdBox" is a real cargo box; if nothing appears
--             or nothing drops, swap it. Ess.Object.spawn pcall-guards a bad template (returns nil, no crash).
--   OFFSET    a prop rests with its ORIGIN ~half its height above the ground. Drop one on flat ground of a
--             known height, compare the reported y, set OFFSET to the difference (subtracted from every read).
--   DROP_H    spawn height above YOUR y. Must clear the tallest terrain in the chunk, but keep it modest so
--             props don't drift far or hit ceilings/bridges. Best on chunks near your own elevation.
--   N, STEP   chunk = N*STEP units across, N*N objects. N=8 (64) is safe; big N risks the spawn cap.
--   SETTLE    seconds before reading; raise it if readings look mid-fall.

local Ess = _G.Ess
if not (Ess and Ess.Object and Ess.Object.spawn and Ess.Loop and Ess.Player) then
    if Loader and Loader.Printf then Loader.Printf("[gridprobe] load Ess (dist/Ess.lua) first") end
    return
end

local TEMPLATE = "BirdBox"
local N, STEP, DROP_H, SETTLE, OFFSET = 8, 16, 40, 2.0, 0.0

local function wsline(s) if Loader and Loader.WsSend then pcall(Loader.WsSend, s) end end

_G.GridProbe = _G.GridProbe or {}
if _G.GridProbe.busy then Ess.Log("[gridprobe] a probe is already settling -- wait for it to finish"); return end

local px, py, pz = Ess.Player.pose(0)
if not px then Ess.Log("[gridprobe] no player character"); return end

-- drop the grid, centred on the player, all from DROP_H above your height
local crates, half = {}, (N - 1) / 2
for ix = 0, N - 1 do
    for iz = 0, N - 1 do
        local x = px + (ix - half) * STEP
        local z = pz + (iz - half) * STEP
        local u = Ess.Object.spawn(TEMPLATE, x, py + DROP_H, z, 0)
        if u then
            pcall(Object.EnablePhysics, u)                 -- make sure it actually falls
            if Ess.Object.setInvincible then Ess.Object.setInvincible(u, true, "GridProbe") end
            crates[#crates + 1] = u
        end
    end
end
if #crates == 0 then Ess.Log("[gridprobe] nothing spawned -- is TEMPLATE '" .. TEMPLATE .. "' a valid physics prop?"); return end

_G.GridProbe.busy = true
Ess.Log(string.format("[gridprobe] dropped %d/%d probes (%dx%d @ %du), settling %.1fs...", #crates, N * N, N, N, STEP, SETTLE))
wsline("<<ROADLOG>>START")

-- after they settle: read each rest position, report as a DOT, and clean up. One-shot (returns false to stop).
Ess.Loop.start("GridProbeRead", SETTLE, function()
    local n = 0
    for _, u in ipairs(crates) do
        if Ess.Object.valid(u) then
            local ok, x, y, z = pcall(Object.GetPosition, u)
            if ok and x then
                n = n + 1
                wsline(string.format("<<ROADLOG>>DOT %.2f,%.2f,%.2f,0.0", x, y - OFFSET, z))
                Ess.Log(string.format("[GRID] %d  x=%.2f  y=%.2f  z=%.2f  yaw=0.0", n, x, y - OFFSET, z))
            end
            pcall(Object.Remove, u)     -- despawn -- mandatory cleanup
        end
    end
    wsline("<<ROADLOG>>STOP " .. n)
    Ess.Log(string.format("[gridprobe] read %d probe(s), cleaned up.", n))
    _G.GridProbe.busy = false
    return false
end)
