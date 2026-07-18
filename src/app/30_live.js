/* 30_live.js -- OPTIONAL live-player overlay. Connects the browser straight to the running game over the
 * lua-bridge WebSocket (ess-bridge.js) and draws where player 0 is standing, updated a few times a second.
 *
 * Poll model: we ask `Ess.Player.pose(0)` on a self-scheduling loop (one request in flight at a time, never
 * stacking) and move a heading-arrow marker. run() always resolves, so a hitch can never hang the loop. The
 * whole feature degrades gracefully: static layers work with no game and no connection. */
(function () {
  "use strict";
  var WM = window.WM;
  var URL = "ws://127.0.0.1:27050";
  var POLL_MS = 200;

  // one clean CSV line back -- easy to parse, and pose() returns x,y,z,yaw (yaw in DEGREES, engine convention).
  var POSE_CHUNK =
    "local x,y,z,yaw = Ess.Player.pose(0)\n" +
    "if not x then return false end\n" +
    "return string.format('%.3f,%.3f,%.3f,%.4f', x, y, z, yaw or 0)";

  var running = false, hintTimer = null;

  function setDot(state) {
    var dot = document.getElementById("liveDot"); if (dot) dot.className = "dot " + state;
    var btn = document.getElementById("liveBtn");
    if (btn) btn.textContent = state === "open" ? "Disconnect" : (state === "connecting" ? "Connecting…" : "Connect to game");
    var info = document.getElementById("liveInfo"); if (info) info.hidden = state !== "open";
    if (WM.renderLegend) WM.renderLegend();
  }

  function ensureMarker() {
    if (WM.liveMarker) return WM.liveMarker;
    var icon = L.divIcon({ className: "live-icon", html: "<div class='live-arrow'></div>", iconSize: [26, 26], iconAnchor: [13, 13] });
    WM.liveMarker = L.marker([WM.MAP.H / 2, WM.MAP.W / 2], { icon: icon, zIndexOffset: 1000, interactive: false, keyboard: false });
    return WM.liveMarker;
  }

  function showPose(x, y, z, yaw) {
    var ll = WM.worldToLatLng(x, z);
    var m = ensureMarker();
    if (!WM.map.hasLayer(m)) m.addTo(WM.map);
    m.setLatLng(ll);
    var el = m.getElement && m.getElement();
    if (el) { var a = el.querySelector(".live-arrow"); if (a) a.style.transform = "rotate(" + (yaw || 0) + "deg)"; }
    var c = document.getElementById("liveCoords");
    if (c) c.textContent = "x " + x.toFixed(1) + "   y " + y.toFixed(1) + "   z " + z.toFixed(1) + "   yaw " + Math.round(yaw || 0) + "°";
    if (WM.follow) WM.map.panTo(ll, { animate: true, duration: 0.2 });
  }

  function noFix() { var c = document.getElementById("liveCoords"); if (c) c.textContent = "waiting for player…"; }

  function parsePose(value) {
    if (value == null) return null;
    var s = String(value).trim();
    if (s.charAt(0) === '"' && s.charAt(s.length - 1) === '"') s = s.slice(1, -1); // strip the serializer's %q quoting
    var p = s.split(","); if (p.length < 3) return null;
    var x = parseFloat(p[0]), y = parseFloat(p[1]), z = parseFloat(p[2]), yaw = parseFloat(p[3] || "0");
    if (!isFinite(x) || !isFinite(z)) return null;
    return { x: x, y: isFinite(y) ? y : 0, z: z, yaw: isFinite(yaw) ? yaw : 0 };
  }

  function loop() {
    if (!running) return;
    if (WM.bridge && WM.bridge.state === "open") {
      WM.bridge.run(POSE_CHUNK).then(function (res) {
        if (!running) return;
        if (res && res.ok) { var p = parsePose(res.value); if (p) showPose(p.x, p.y, p.z, p.yaw); else noFix(); }
        WM.pollTimer = setTimeout(loop, POLL_MS);
      });
    } else {
      WM.pollTimer = setTimeout(loop, POLL_MS);
    }
  }
  function startPolling() { if (running) return; running = true; loop(); }
  function stopPolling() { running = false; if (WM.pollTimer) { clearTimeout(WM.pollTimer); WM.pollTimer = null; } }

  // If we never reach "open" within a few seconds, most likely Chrome's local-network prompt was dismissed,
  // the page is on a scheme the browser won't let reach loopback, or the game/bridge isn't up. Say so.
  function armHint() {
    clearTimeout(hintTimer);
    hintTimer = setTimeout(function () {
      if (!WM.bridge || WM.bridge.state === "open") return;
      var h = document.getElementById("liveHint");
      if (h) h.innerHTML = "Still not connected. Check that the <b>game is running</b> with the lua-bridge, and that "
        + "the browser <b>allowed the local connection</b> (Chrome shows a one-time prompt). Opening this page over "
        + "<code>https</code> or from disk both work; some browsers block <code>ws://127.0.0.1</code> — the bridge "
        + "can also serve the page itself at <code>http://127.0.0.1:27050/</code>.";
    }, 9000);
  }

  WM.connectLive = function () {
    if (WM.bridge && (WM.bridge.state === "open" || WM.bridge.state === "connecting")) { WM.disconnectLive(); return; }
    var b = new EssBridge(URL, { autoReconnect: true, resultTimeout: 4000 });
    WM.bridge = b;
    b.onStatus = function (s) { setDot(s); };
    b.onLog = function () {};
    setDot("connecting"); armHint();
    b.connect().then(function () { clearTimeout(hintTimer); startPolling(); }).catch(function () {});
  };

  WM.disconnectLive = function () {
    stopPolling(); clearTimeout(hintTimer);
    if (WM.bridge) { WM.bridge.close(); WM.bridge = null; }
    if (WM.liveMarker && WM.map.hasLayer(WM.liveMarker)) WM.map.removeLayer(WM.liveMarker);
    setDot("closed");
  };
})();
