/* 30_live.js -- OPTIONAL live-player overlay, PUSH model (not polling).
 *
 * WHY PUSH: the old version called bridge.run() every 200ms, and every run() ships the full serializer
 * chunk for the game to RECOMPILE each tick -- that per-tick compile is the real cost (it's what made it
 * feel bad). Instead we send ONE setup chunk that starts an in-game Ess.Loop streaming the pose over the
 * hidden WS channel (Loader.WsSend); the page just listens on onData. Compile-once -- the same pattern that
 * streamed ~80 bones at 100Hz with ~0 game-side cost. The marker is a plain dot (no heading arrow). The
 * whole feature is opt-in and degrades gracefully: with no game/connection the static layers still work. */
(function () {
  "use strict";
  var WM = window.WM;
  var URL = "ws://127.0.0.1:27050";
  var LOOP_ID = "webmap_pose";
  var TAG = "<<POSE>>";

  // ONE-TIME setup: start an in-game loop that WsSend's the player position ~10x/sec. Ess.Loop.start
  // REPLACES any existing loop under this id, so re-sending on reconnect can't stack duplicates.
  var SETUP =
    "if not (Ess and Ess.Loop and Ess.Player) then return 'no-ess' end\n" +
    "Ess.Loop.start('" + LOOP_ID + "', 0.1, function()\n" +
    "  local x,y,z = Ess.Player.pose(0)\n" +
    "  if x then Loader.WsSend('" + TAG + "'..string.format('%.2f,%.2f,%.2f', x, y, z)) end\n" +
    "  return true\n" +
    "end)\n" +
    "return 'started'";
  var STOP = "if Ess and Ess.Loop then Ess.Loop.stop('" + LOOP_ID + "') end return 'stopped'";

  var hintTimer = null;

  function setDot(state) {
    var dot = document.getElementById("liveDot"); if (dot) dot.className = "dot " + state;
    var btn = document.getElementById("liveBtn");
    if (btn) btn.textContent = state === "open" ? "Disconnect" : (state === "connecting" ? "Connecting…" : "Connect to game");
    var info = document.getElementById("liveInfo"); if (info) info.hidden = state !== "open";
    var save = document.getElementById("saveSpotBtn"); if (save && save.textContent.indexOf("Saving") === -1) save.disabled = state !== "open";
    if (WM.renderLegend) WM.renderLegend();
  }

  function ensureMarker() {
    if (WM.liveMarker) return WM.liveMarker;
    WM.liveMarker = L.circleMarker([WM.MAP.H / 2, WM.MAP.W / 2], {
      radius: 7, color: "#0b3b1e", weight: 2, fillColor: "#41d18b", fillOpacity: 1, interactive: false,
    });
    return WM.liveMarker;
  }

  function showPose(x, y, z) {
    var ll = WM.worldToLatLng(x, z);
    var m = ensureMarker();
    if (!WM.map.hasLayer(m)) m.addTo(WM.map);
    m.setLatLng(ll);
    if (m.bringToFront) m.bringToFront();
    var c = document.getElementById("liveCoords");
    if (c) c.textContent = "x " + x.toFixed(1) + "   y " + y.toFixed(1) + "   z " + z.toFixed(1);
    if (WM.follow) WM.map.panTo(ll, { animate: false });   // instant re-center; animating every tick is what janks
  }

  // hidden-channel telemetry: our pose lines are un-tagged (run()'s tagged results are consumed before this).
  function onData(line) {
    if (!line || line.indexOf(TAG) !== 0) return;
    var p = line.slice(TAG.length).split(",");
    var x = parseFloat(p[0]), y = parseFloat(p[1]), z = parseFloat(p[2]);
    if (isFinite(x) && isFinite(z)) showPose(x, isFinite(y) ? y : 0, z);
  }

  function armHint() {
    clearTimeout(hintTimer);
    hintTimer = setTimeout(function () {
      if (!WM.bridge || WM.bridge.state === "open") return;
      var h = document.getElementById("liveHint");
      if (h) h.innerHTML = "Still not connected. Check that the <b>game is running</b> with the lua-bridge (and "
        + "Ess loaded), and that the browser <b>allowed the local connection</b> (Chrome shows a one-time prompt). "
        + "Opening this page over <code>https</code> or from disk both work; some browsers block "
        + "<code>ws://127.0.0.1</code> — the bridge can also serve the page itself at <code>http://127.0.0.1:27050/</code>.";
    }, 9000);
  }

  WM.connectLive = function () {
    if (WM.bridge && (WM.bridge.state === "open" || WM.bridge.state === "connecting")) { WM.disconnectLive(); return; }
    var b = new EssBridge(URL, { autoReconnect: true });
    WM.bridge = b;
    b.onData = onData;
    b.onLog = function () {};
    b.onStatus = function (s) {
      setDot(s);
      if (s === "open") { clearTimeout(hintTimer); b.run(SETUP); }   // (re)start the in-game loop on every open, incl. reconnect
    };
    setDot("connecting"); armHint();
    b.connect().catch(function () {});
  };

  WM.disconnectLive = function () {
    clearTimeout(hintTimer);
    if (WM.bridge) {
      try { WM.bridge.run(STOP); } catch (e) {}   // best-effort: stop the in-game loop (ws.send flushes before close)
      WM.bridge.close(); WM.bridge = null;
    }
    if (WM.liveMarker && WM.map.hasLayer(WM.liveMarker)) WM.map.removeLayer(WM.liveMarker);
    setDot("closed");
  };
})();
