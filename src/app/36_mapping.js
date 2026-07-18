/* 36_mapping.js -- telemetry-driven "mapping mode". No UI toggle: the in-game RoadLogger.lua broadcasts over
 * the WS hidden channel, and this listens. When those signals arrive the map auto-draws your live trail and
 * collects the samples; the Mapping panel section only appears once a signal (or a saved session) exists, so
 * it's invisible to anyone not running the logger. Export the session as a data/*.log for build_heightmap.py.
 *
 * Protocol (from RoadLogger.lua, delivered via 30_live's onData):
 *   <<ROADLOG>>START            <<ROADLOG>>PT x,y,z,yaw            <<ROADLOG>>STOP n
 */
(function () {
  "use strict";
  var WM = window.WM;
  var TAG = "<<ROADLOG>>";
  var LS_KEY = "mercs2-webmap:mapping:v1";
  var JUMP = 80;   // > this between consecutive points = a teleport/gap -> break the trail, don't count distance
  var S = { samples: [], dist: 0, active: false, trail: null, cur: null, last: null, saveTimer: 0 };

  function load() { try { var o = JSON.parse(localStorage.getItem(LS_KEY) || "null"); if (o) { S.samples = o.samples || []; S.dist = o.dist || 0; } } catch (e) {} }
  function save() { try { localStorage.setItem(LS_KEY, JSON.stringify({ samples: S.samples, dist: S.dist })); } catch (e) {} }
  function saveSoon() { if (S.saveTimer) return; S.saveTimer = setTimeout(function () { S.saveTimer = 0; save(); }, 1500); }

  function group() { if (!S.trail) S.trail = L.layerGroup().addTo(WM.map); return S.trail; }
  function newSeg(ll) { S.cur = L.polyline(ll ? [ll] : [], { color: "#ffd24a", weight: 2, opacity: 0.85, interactive: false }); S.cur.addTo(group()); }
  function addLL(x, z, jumped) { var ll = WM.worldToLatLng(x, z); if (jumped || !S.cur) newSeg(ll); else S.cur.addLatLng(ll); }

  function panel() {
    var sec = document.getElementById("mapSection"); if (sec) sec.hidden = !(S.active || S.samples.length);
    var c = document.getElementById("mapCount");
    if (c) c.textContent = S.samples.length + " samples · " + Math.round(S.dist) + "u" + (S.active ? "  ·  ● recording" : "");
    var dot = document.getElementById("mapDot"); if (dot) dot.className = "dot " + (S.active ? "open" : "closed");
  }

  var mapping = {
    onStart: function () { S.active = true; S.last = S.samples.length ? S.samples[S.samples.length - 1] : null; S.cur = null; panel(); },
    onStop: function () { S.active = false; save(); panel(); },
    onPoint: function (x, y, z) {
      if (!S.active) S.active = true;   // START may have been missed (map connected mid-run)
      var last = S.last, jumped = false;
      if (last) { var d = Math.sqrt((x - last.x) * (x - last.x) + (z - last.z) * (z - last.z)); if (d > JUMP) jumped = true; else S.dist += d; }
      var s = { x: Math.round(x * 100) / 100, y: Math.round(y * 100) / 100, z: Math.round(z * 100) / 100 };
      S.samples.push(s); S.last = s;
      addLL(x, z, jumped); saveSoon(); panel();
    },
    count: function () { return S.samples.length; },
    clear: function () { S.samples = []; S.dist = 0; S.last = null; S.cur = null; S.active = false; if (S.trail) { WM.map.removeLayer(S.trail); S.trail = null; } save(); panel(); },
    exportLog: function () {
      return S.samples.map(function (s, i) { return "[Ess] [ROAD] " + (i + 1) + "  x=" + s.x.toFixed(2) + "  y=" + s.y.toFixed(2) + "  z=" + s.z.toFixed(2); }).join("\n");
    },
  };
  WM.mapping = mapping;

  // called by 30_live for any <<ROADLOG>> line off the WS hidden channel.
  WM.onRoadLog = function (line) {
    var rest = line.slice(TAG.length);
    if (rest.indexOf("START") === 0) { mapping.onStart(); return; }
    if (rest.indexOf("STOP") === 0) { mapping.onStop(); return; }
    if (rest.indexOf("PT ") === 0) {
      var p = rest.slice(3).split(","), x = parseFloat(p[0]), y = parseFloat(p[1]), z = parseFloat(p[2]);
      if (isFinite(x) && isFinite(z)) mapping.onPoint(x, isFinite(y) ? y : 0, z);
    }
  };

  WM.initMapping = function () {
    load();
    if (S.samples.length) {   // restore a persisted session's trail (split into segments on big jumps)
      var prev = null;
      for (var i = 0; i < S.samples.length; i++) { var s = S.samples[i]; var j = prev && Math.sqrt((s.x - prev.x) * (s.x - prev.x) + (s.z - prev.z) * (s.z - prev.z)) > JUMP; addLL(s.x, s.z, i === 0 || j); prev = s; }
    }
    panel();
  };
})();
