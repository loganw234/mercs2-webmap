/* 20_layers.js -- the generic layer loader. A "dataset" is any JSON array of points that each carry a
 * position (either {position:{x,y,z}} or a bare {x,y,z}); optionally split into sub-groups by a field
 * (groupBy) so, e.g., the two toolbox batches become two independently toggleable colours. This is what
 * makes the tool reusable: the built-in collectibles are just the first dataset, and "Load JSON layer…"
 * feeds any similar file through the exact same path. */
(function () {
  "use strict";
  var WM = window.WM;
  var PALETTE = ["#4aa3ff", "#ff8c3a", "#41d18b", "#c878ff", "#ffd24a", "#ff5d73", "#16b3a3", "#b4e63c"];
  var colorSeq = 0;

  function esc(s) { return String(s).replace(/[&<>]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]; }); }
  function r1(n) { return Math.round((Number(n) || 0) * 10) / 10; }

  function posOf(p) {
    if (p && p.position && typeof p.position.x === "number") return p.position;
    if (p && typeof p.x === "number" && typeof p.z === "number") return { x: p.x, y: (typeof p.y === "number" ? p.y : 0), z: p.z };
    return null;
  }
  function popupHtml(label, p, pos) {
    var s = "<b>" + esc(label) + "</b><br><span class='mono'>x " + r1(pos.x) + "  y " + r1(pos.y) + "  z " + r1(pos.z) + "</span>";
    for (var k in p) {
      if (!p.hasOwnProperty(k) || k === "position" || k === "x" || k === "y" || k === "z") continue;
      s += "<br><span class='k'>" + esc(k) + "</span>: " + esc(String(p[k]));
    }
    s += "<div class='wm-pop-actions'><button type='button' class='wm-collect'>☐ Mark collected</button></div>";
    return s;
  }

  // Normalize whatever was loaded into { id, name, groupBy, colors, labels, points:[] }.
  function normalize(ds, fallbackName) {
    if (Array.isArray(ds)) return { name: fallbackName || "Layer", points: ds };
    var out = {
      id: ds.id, name: ds.name || fallbackName || "Layer", groupBy: ds.groupBy,
      colors: ds.colors || {}, labels: ds.labels || {},
      points: ds.points || ds.features || ds.items || [],
    };
    return out;
  }

  WM.addDataset = function (raw, fallbackName) {
    var ds = normalize(raw, fallbackName);
    var groupBy = ds.groupBy, buckets = {}, order = [];
    ds.points.forEach(function (p) {
      var key = groupBy ? (p[groupBy] == null ? "—" : String(p[groupBy])) : "_all";
      if (!buckets[key]) { buckets[key] = []; order.push(key); }
      buckets[key].push(p);
    });

    var entry = { id: ds.id || ("ds" + (WM.datasets.length + 1)), name: ds.name, groups: {} };
    order.forEach(function (key) {
      var pts = buckets[key];
      var color = ds.colors[key] || PALETTE[colorSeq++ % PALETTE.length];
      var label = ds.labels[key] || (key === "_all" ? ds.name : key);
      var lg = L.layerGroup(), placed = 0, first = null, markers = [];
      pts.forEach(function (p, idx) {
        var pos = posOf(p); if (!pos) return;
        var ll = WM.worldToLatLng(pos.x, pos.z); if (!first) first = ll;
        var m = L.circleMarker(ll, { radius: 5, color: "#0008", weight: 1, fillColor: color, fillOpacity: 0.9 });
        m._wmKey = entry.id + ":" + (p.entity_id || p.id || ("#" + idx));   // stable per-point id for collected ticks
        m._wmColor = color; m._wmLayer = lg;
        m.bindPopup(popupHtml(label, p, pos));
        m.bindTooltip(label, { direction: "top", opacity: 0.9 });
        if (WM.applyCollectedStyle) WM.applyCollectedStyle(m);   // dim if already ticked off
        lg.addLayer(m); markers.push(m); placed++;
      });
      lg.addTo(WM.map);
      entry.groups[key] = { layer: lg, color: color, label: label, count: placed, visible: true, sample: first, markers: markers };
    });

    WM.datasets.push(entry);
    if (WM.hideCollected && WM.setHideCollected) WM.setHideCollected(true);   // hide any already-collected in a newly loaded layer
    WM.renderLayerPanel();
    WM.renderLegend();
    if (WM.updateProgress) WM.updateProgress();
    return entry;
  };

  // fit the view to every visible marker across all datasets (used after loading a file, and by the panel).
  WM.fitToLayers = function () {
    var b = L.latLngBounds([]);
    WM.datasets.forEach(function (d) {
      for (var k in d.groups) {
        var g = d.groups[k];
        if (g.visible) g.layer.eachLayer(function (m) { if (m.getLatLng) b.extend(m.getLatLng()); });
      }
    });
    if (b.isValid()) WM.map.fitBounds(b.pad(0.12));
  };

  WM.setGroupVisible = function (dsId, key, on) {
    for (var i = 0; i < WM.datasets.length; i++) {
      if (WM.datasets[i].id !== dsId) continue;
      var g = WM.datasets[i].groups[key]; if (!g) return;
      g.visible = on;
      if (on) g.layer.addTo(WM.map); else WM.map.removeLayer(g.layer);
      return;
    }
  };

  // Render the per-group toggle rows in the panel.
  WM.renderLayerPanel = function () {
    var host = document.getElementById("layerList"); if (!host) return;
    host.innerHTML = "";
    if (!WM.datasets.length) { host.innerHTML = "<p class='hint' style='margin:0'>No layers loaded.</p>"; return; }
    WM.datasets.forEach(function (d) {
      Object.keys(d.groups).forEach(function (key) {
        var g = d.groups[key];
        var name = (Object.keys(d.groups).length > 1) ? (d.name + " · " + g.label) : g.label;
        var done = WM.groupCollected ? WM.groupCollected(g) : 0;
        var row = document.createElement("label");
        row.className = "row";
        row.innerHTML = "<input type='checkbox'" + (g.visible ? " checked" : "") + ">"
          + "<span class='swatch' style='background:" + g.color + "'></span>"
          + "<span class='name'>" + esc(name) + "</span><span class='count'>" + done + "/" + g.count + "</span>";
        row.querySelector("input").addEventListener("change", function (e) { WM.setGroupVisible(d.id, key, e.target.checked); WM.renderLegend(); });
        host.appendChild(row);
      });
    });
  };

  WM.renderLegend = function () {
    var host = document.getElementById("legend"); if (!host) return;
    var items = [];
    WM.datasets.forEach(function (d) {
      Object.keys(d.groups).forEach(function (key) {
        var g = d.groups[key]; if (!g.visible) return;
        items.push("<span class='li'><span class='swatch' style='background:" + g.color + "'></span>" + g.label + "</span>");
      });
    });
    if (WM.bridge && WM.bridge.state === "open") items.push("<span class='li'><span class='swatch' style='background:#41d18b'></span>you</span>");
    host.innerHTML = items.join("");
  };
})();
