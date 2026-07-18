/* 24_collected.js -- per-box "I collected this" ticks, persisted in localStorage so they survive a reload.
 * Keyed by a stable per-point id (dataset id + entity_id, or index as a fallback). Collected markers dim
 * out; "Hide collected" removes them entirely; "Reset ticks" clears everything. Works on any dataset, but
 * the real use is the built-in toolboxes. Degrades quietly if localStorage is unavailable. */
(function () {
  "use strict";
  var WM = window.WM;
  var LS_KEY = "mercs2-webmap:collected:v1";
  var set = {};   // key -> true

  function load() {
    set = {};
    try { var raw = localStorage.getItem(LS_KEY); if (raw) JSON.parse(raw).forEach(function (k) { set[k] = true; }); }
    catch (e) {}
  }
  function save() {
    try { localStorage.setItem(LS_KEY, JSON.stringify(Object.keys(set))); } catch (e) {}
  }

  WM.isCollected = function (key) { return !!set[key]; };
  WM.setCollected = function (key, on) { if (on) set[key] = true; else delete set[key]; save(); };

  // style a collectible marker for its current collected state (dim when done).
  WM.applyCollectedStyle = function (m) {
    if (!m || !m._wmKey) return;
    if (WM.isCollected(m._wmKey)) m.setStyle({ fillColor: "#5b6048", color: "#0006", fillOpacity: 0.3, weight: 1 });
    else m.setStyle({ fillColor: m._wmColor, color: "#0008", fillOpacity: 0.9, weight: 1 });
  };

  // walk every registered collectible marker across all datasets/groups (the full list, INCLUDING ones
  // currently hidden by "Hide collected" -- so they can be brought back).
  function eachMarker(fn) {
    WM.datasets.forEach(function (d) {
      Object.keys(d.groups).forEach(function (key) {
        var g = d.groups[key];
        (g.markers || []).forEach(function (m) { fn(m, g.layer); });
      });
    });
  }

  WM.toggleCollectedByMarker = function (m) {
    if (!m || !m._wmKey) return;
    var on = !WM.isCollected(m._wmKey);
    WM.setCollected(m._wmKey, on);
    WM.applyCollectedStyle(m);
    if (WM.hideCollected && on && m._wmLayer && m._wmLayer.hasLayer(m)) m._wmLayer.removeLayer(m);
    WM.updateProgress();
  };

  WM.setHideCollected = function (on) {
    WM.hideCollected = !!on;
    eachMarker(function (m, layer) {
      var collected = WM.isCollected(m._wmKey);
      if (WM.hideCollected && collected) { if (layer.hasLayer(m)) layer.removeLayer(m); }
      else if (!layer.hasLayer(m)) layer.addLayer(m);
    });
    WM.updateProgress();
  };

  WM.resetCollected = function () {
    set = {}; save();
    eachMarker(function (m, layer) { WM.applyCollectedStyle(m); if (!layer.hasLayer(m)) layer.addLayer(m); });
    WM.updateProgress();
  };

  WM.groupCollected = function (g) {
    var done = 0; (g.markers || []).forEach(function (m) { if (WM.isCollected(m._wmKey)) done++; });
    return done;
  };
  WM.collectedCounts = function () {
    var total = 0, done = 0;
    eachMarker(function (m) { if (!m._wmKey) return; total++; if (WM.isCollected(m._wmKey)) done++; });   // skip teleport (non-collectible) markers
    return { done: done, total: total };
  };

  WM.updateProgress = function () {
    if (WM.renderLayerPanel) WM.renderLayerPanel();
    var c = WM.collectedCounts();
    var el = document.getElementById("collectedOverall");
    if (el) el.textContent = c.total ? (c.done + " / " + c.total + " collected") : "";
    var ctrls = document.getElementById("collectedControls");
    if (ctrls) ctrls.hidden = (c.total === 0);
  };

  // one delegated handler wires the "Mark collected" button in every marker popup.
  WM.initCollected = function () {
    load();
    WM.map.on("popupopen", function (e) {
      var m = e.popup && e.popup._source; if (!m || !m._wmKey) return;
      var el = e.popup.getElement && e.popup.getElement();
      var btn = el && el.querySelector(".wm-collect"); if (!btn) return;
      function sync() {
        var on = WM.isCollected(m._wmKey);
        btn.textContent = on ? "☑ Collected — undo" : "☐ Mark collected";
        btn.className = "wm-collect" + (on ? " on" : "");
      }
      sync();
      btn.onclick = function () { WM.toggleCollectedByMarker(m); sync(); };
    });
  };
})();
