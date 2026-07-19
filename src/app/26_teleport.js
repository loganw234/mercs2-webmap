/* 26_teleport.js -- the "teleport spot" layer: a live spot-collector.
 *
 *   * Teleport-kind markers get a bright labelled dot + a "Teleport here" button that jumps the LOCAL player
 *     to that spot in the running game (Ess.Player.teleport handles co-op heroes + facing in one call).
 *   * The layer is BUILT-IN spots (window.MERCS_TELEPORTS, committed in the repo) PLUS user spots kept in
 *     localStorage, so it can grow at runtime. Three ways to add: "Save current spot" (reads your live pose),
 *     "Paste import" (raw [Ess][LOCATION] log lines OR JSON), and of course editing teleports.js by hand.
 *   * "Export" dumps the localStorage spots as JSON to paste into src/data/teleports.js and ship to everyone.
 *
 * User spots are localStorage-only until exported+committed -- built-in spots (no _uid) can't be deleted here. */
(function () {
  "use strict";
  var WM = window.WM;
  var LS_KEY = "mercs2-webmap:teleports:v1";
  var user = [];   // [{ id, name, position:{x,y,z}, yaw }]
  var seq = 0;

  function load() {
    user = [];
    try { var raw = localStorage.getItem(LS_KEY); if (raw) user = JSON.parse(raw) || []; } catch (e) {}
    user.forEach(function (s) { if (!s.id) s.id = "u" + (++seq); });
  }
  function save() { try { localStorage.setItem(LS_KEY, JSON.stringify(user)); } catch (e) {} }
  function newId() { return "u" + Date.now().toString(36) + (++seq).toString(36); }

  function builtinPoints() { var t = window.MERCS_TELEPORTS; return (t && t.points) ? t.points.slice() : []; }
  function userPoints() { return user.map(function (s) { return { name: s.name, position: s.position, yaw: s.yaw, _uid: s.id }; }); }

  // rebuild the single "teleports" layer from built-in + user spots. Cheap (a handful of markers).
  function rebuild() {
    if (WM.removeDataset) WM.removeDataset("teleports");
    WM.addDataset({ id: "teleports", name: "Teleport spots", kind: "teleport", color: "#3fd0e0",
      points: builtinPoints().concat(userPoints()) });
    refreshExport();
  }

  // parse pasted text -> [{name,position:{x,y,z},yaw}]. Accepts JSON (array / {points:[]} / a single spot) OR
  // raw in-game log lines like:  [Ess] [LOCATION] Runway  @ x=2708.85  y=-13.97  z=-642.95  yaw=165.7
  function parseSpots(text) {
    text = String(text || "").trim();
    if (!text) return [];
    try {
      var j = JSON.parse(text);
      var arr = Array.isArray(j) ? j : (j.points || (j.position || typeof j.x === "number" ? [j] : []));
      return arr.map(function (o) {
        var pos = o.position || o;
        var x = parseFloat(pos.x), y = parseFloat(pos.y), z = parseFloat(pos.z), yaw = parseFloat(o.yaw);
        if (!isFinite(x) || !isFinite(z)) return null;
        return { name: o.name || "Spot", position: { x: x, y: isFinite(y) ? y : 0, z: z }, yaw: isFinite(yaw) ? yaw : 0 };
      }).filter(Boolean);
    } catch (e) { /* not JSON -- fall through to log-line parsing */ }

    var re = /\[LOCATION\]\s*(.+?)\s*@\s*x\s*=\s*(-?[\d.]+)\s+y\s*=\s*(-?[\d.]+)\s+z\s*=\s*(-?[\d.]+)(?:\s+yaw\s*=\s*(-?[\d.]+))?/ig;
    var out = [], m;
    while ((m = re.exec(text))) {
      out.push({ name: (m[1] || "Spot").trim() || "Spot",
        position: { x: parseFloat(m[2]), y: parseFloat(m[3]), z: parseFloat(m[4]) }, yaw: m[5] ? parseFloat(m[5]) : 0 });
    }
    return out;
  }

  function refreshExport() {
    var t = document.getElementById("exportText"), pane = document.getElementById("exportPane");
    if (t && pane && !pane.hidden) t.value = WM.teleports.exportJSON();
  }

  WM.teleports = {
    get user() { return user; },
    add: function (spot) { spot.id = newId(); user.push(spot); save(); rebuild(); return spot; },
    remove: function (id) { for (var i = 0; i < user.length; i++) if (user[i].id === id) { user.splice(i, 1); break; } save(); rebuild(); },
    importText: function (text) { var s = parseSpots(text); s.forEach(function (o) { o.id = newId(); user.push(o); }); if (s.length) { save(); rebuild(); } return s.length; },
    // ALL current spots (built-in + saved), stripped to the teleports.js point shape -- so committing is a
    // clean "replace the points array" rather than a manual merge.
    exportJSON: function () {
      return JSON.stringify(builtinPoints().concat(userPoints()).map(function (s) {
        var pos = s.position || {}; return { name: s.name, position: { x: pos.x, y: pos.y, z: pos.z }, yaw: s.yaw };
      }), null, 2);
    },
    init: function () { load(); WM.tpAll = WM.tpAllEnabled(); rebuild(); },
  };

  // Save the LOCAL player's CURRENT position as a new spot. One-shot pose read (not the per-frame stream), so
  // it grabs a fresh reading incl. yaw. Needs a live connection.
  WM.captureSpot = function (name, done) {
    if (!(WM.bridge && WM.bridge.state === "open")) { if (done) done(false, "not connected"); return; }
    var code = "local x,y,z,yaw = Ess.Player.pose(0)\n"
      + "if not x then return 'no-pose' end\n"
      + "return string.format('%.3f,%.3f,%.3f,%.4f', x, y, z, yaw or 0)";
    WM.bridge.run(code).then(function (r) {
      if (!r || !r.ok) { if (done) done(false, "no reply"); return; }
      var s = String(r.value); if (s.charAt(0) === '"' && s.charAt(s.length - 1) === '"') s = s.slice(1, -1);
      var p = s.split(","), x = parseFloat(p[0]), y = parseFloat(p[1]), z = parseFloat(p[2]), yaw = parseFloat(p[3] || "0");
      if (!isFinite(x) || !isFinite(z)) { if (done) done(false, "no fix"); return; }
      var spot = WM.teleports.add({ name: name || ("Spot " + (user.length + 1)),
        position: { x: x, y: isFinite(y) ? y : 0, z: z }, yaw: isFinite(yaw) ? yaw : 0 });
      if (WM.map) WM.map.panTo(WM.worldToLatLng(spot.position.x, spot.position.z), { animate: true });
      if (done) done(true, spot);
    });
  };

  // jump the local player to a saved spot over the live bridge. done(ok,msg) optional.
  WM.teleportTo = function (tp, done) {
    if (!tp) { if (done) done(false, "no spot"); return; }
    if (!(WM.bridge && WM.bridge.state === "open")) { if (done) done(false, "not connected"); return; }
    var y = (typeof tp.y === "number") ? tp.y : 0, yaw = (typeof tp.yaw === "number") ? tp.yaw : 0;
    var code = "if not (Ess and Ess.Player and Ess.Player.teleport) then return 'no-ess' end\n"
      + "Ess.Player.teleport(" + tp.x + ", " + y + ", " + tp.z + ", " + yaw + ")\n"
      + "return 'ok'";
    WM.bridge.run(code).then(function (r) {
      var ok = !!(r && r.ok && String(r.value).indexOf("ok") !== -1);
      if (done) done(ok, r ? r.value : null);
    });
  };

  // ---- "Teleport to all" mode (persisted): when on, ANY marker's popup gets a teleport button ----
  var TPALL_KEY = "mercs2-webmap:tpall";
  WM.tpAllEnabled = function () { try { return localStorage.getItem(TPALL_KEY) === "1"; } catch (e) { return false; } };
  WM.setTpAll = function (on) { WM.tpAll = !!on; try { localStorage.setItem(TPALL_KEY, on ? "1" : "0"); } catch (e) {} };

  // wire a teleport button to a {x,y,z,yaw} spot: reflect live/offline, run the jump on click.
  function wireTeleportButton(btn, tp) {
    (function sync() {
      var live = !!(WM.bridge && WM.bridge.state === "open");
      btn.disabled = !live;
      btn.textContent = live ? "⇱ Teleport here" : "Connect to game to teleport";
      btn.className = "wm-teleport" + (live ? "" : " disabled");
      btn.onclick = function () {
        if (btn.disabled) return;
        btn.textContent = "Teleporting…";
        WM.teleportTo(tp, function (ok) { btn.textContent = ok ? "✓ Teleported" : "Teleport failed"; setTimeout(sync, 1300); });
      };
    })();
  }

  // Right-click anywhere -> ground-snapped teleport popup. The heightmap tensor supplies the safe y that
  // arbitrary-point teleports never had: land = ground + 2, water = just above the -35 surface, and if the
  // spot is unscanned we say so and jump in high (200) rather than guessing into the ground.
  function groundPopup(e) {
    var w = WM.latLngToWorld(e.latlng);
    var h = WM.heightAt ? WM.heightAt(w.x, w.z) : null;
    var s = WM.slopeAt ? WM.slopeAt(w.x, w.z) : null;
    var SEA = -35;
    var y, desc;
    if (h == null) { y = 200; desc = "no height data — will drop in from 200"; }
    else if (h <= SEA) { y = SEA + 2; desc = "water · depth ~" + Math.round(SEA - h) + "u (seabed " + h.toFixed(1) + ")"; }
    else { y = h + 2; desc = "ground " + h.toFixed(1) + (s != null && s >= 0.5 ? " · slope " + Math.round(s) + "°" : ""); }

    var div = document.createElement("div");
    div.innerHTML = "<b>" + Math.round(w.x) + ", " + Math.round(w.z) + "</b><br><span class='hint'>" + desc + "</span><br>";
    var btn = document.createElement("button"); btn.type = "button";
    div.appendChild(btn);
    wireTeleportButton(btn, { x: w.x, y: y, z: w.z, yaw: 0 });
    L.popup({ closeButton: true }).setLatLng(e.latlng).setContent(div).openOn(WM.map);
  }

  // Teleport spots get their button (+ delete). With "Teleport to all" on, every OTHER marker gets a
  // teleport button injected into its popup too.
  WM.initTeleport = function () {
    WM.map.on("contextmenu", groundPopup);
    WM.map.on("popupopen", function (e) {
      var mk = e.popup && e.popup._source; if (!mk) return;
      var el = e.popup.getElement && e.popup.getElement(); if (!el) return;

      if (mk._wmKind === "teleport") {
        var btn = el.querySelector(".wm-teleport");
        if (btn) wireTeleportButton(btn, mk._wmTp);
        var del = el.querySelector(".wm-tp-del");
        if (del) del.onclick = function () {
          var uid = del.getAttribute("data-uid");
          if (uid && window.confirm("Delete saved spot \"" + ((mk._wmTp && mk._wmTp.name) || "") + "\"?")) WM.teleports.remove(uid);
        };
        return;
      }

      // non-teleport marker: inject a teleport button when "Teleport to all" is on, or remove a stale one
      // that lingered from when it was on (Leaflet reuses the popup DOM across opens).
      var actions = el.querySelector(".wm-pop-actions"); if (!actions) return;
      var existing = actions.querySelector(".wm-teleport");
      if (WM.tpAll && mk._wmPos) {
        if (!existing) { existing = document.createElement("button"); existing.type = "button"; existing.className = "wm-teleport"; actions.insertBefore(existing, actions.firstChild); }
        wireTeleportButton(existing, { x: mk._wmPos.x, y: mk._wmPos.y, z: mk._wmPos.z, yaw: 0 });
      } else if (existing && existing.parentNode) {
        existing.parentNode.removeChild(existing);
      }
    });
  };
})();
