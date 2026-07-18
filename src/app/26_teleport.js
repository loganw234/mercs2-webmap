/* 26_teleport.js -- the "teleport spot" layer action. Teleport-kind markers get a bright labelled dot and a
 * "Teleport here" button in their popup that jumps the LOCAL player to that spot in the running game, over
 * the same live bridge the player-overlay uses. Read-nothing/does-one-thing: it calls Ess.Player.teleport,
 * which handles co-op heroes + facing (yaw) in one call. Needs a live connection; the button says so when
 * there isn't one. */
(function () {
  "use strict";
  var WM = window.WM;

  // jump the local player to a saved spot. `done(ok, msg)` optional. No-op (reports false) if not connected.
  WM.teleportTo = function (tp, done) {
    if (!tp) { if (done) done(false, "no spot"); return; }
    if (!(WM.bridge && WM.bridge.state === "open")) { if (done) done(false, "not connected"); return; }
    var y = (typeof tp.y === "number") ? tp.y : 0;
    var yaw = (typeof tp.yaw === "number") ? tp.yaw : 0;
    var code = "if not (Ess and Ess.Player and Ess.Player.teleport) then return 'no-ess' end\n"
      + "Ess.Player.teleport(" + tp.x + ", " + y + ", " + tp.z + ", " + yaw + ")\n"
      + "return 'ok'";
    WM.bridge.run(code).then(function (r) {
      var ok = !!(r && r.ok && String(r.value).indexOf("ok") !== -1);
      if (done) done(ok, r ? r.value : null);
    });
  };

  // wire the "Teleport here" button whenever a teleport-spot popup opens. Reflects live/offline state.
  WM.initTeleport = function () {
    WM.map.on("popupopen", function (e) {
      var m = e.popup && e.popup._source; if (!m || m._wmKind !== "teleport") return;
      var el = e.popup.getElement && e.popup.getElement();
      var btn = el && el.querySelector(".wm-teleport"); if (!btn) return;
      function sync() {
        var live = !!(WM.bridge && WM.bridge.state === "open");
        btn.disabled = !live;
        btn.textContent = live ? "⇱ Teleport here" : "Connect to game to teleport";
        btn.className = "wm-teleport" + (live ? "" : " disabled");
      }
      sync();
      btn.onclick = function () {
        if (btn.disabled) return;
        btn.textContent = "Teleporting…";
        WM.teleportTo(m._wmTp, function (ok) {
          btn.textContent = ok ? "✓ Teleported" : "Teleport failed";
          setTimeout(sync, 1300);
        });
      };
    });
  };
})();
