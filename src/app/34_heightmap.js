/* 34_heightmap.js -- the height grid: query + an elevation overlay.
 *
 * Data (window.MERCS_HEIGHTMAP, built by tools/build_heightmap.py) is a sparse grid of driven/walked ground
 * samples: cell -> [medianHeight, sampleCount]. Two things it powers:
 *   * WM.heightAt(x,z) -> ground height at any world point. Exact cell if we've been there; else inverse-
 *     distance-weighted from nearby cells within a few rings; null if nothing's close (honest "unknown").
 *   * a toggleable elevation overlay -- one hypsometric-coloured rectangle per known cell, drawn in its own
 *     pane BELOW the markers so the dots stay readable. As you log more area, the overlay fills in. */
(function () {
  "use strict";
  var WM = window.WM;
  var HM = null, overlay = null;

  // low -> high hypsometric ramp (deep, blue, green, yellow, orange, peak-red)
  var STOPS = [[0, [26, 74, 122]], [0.2, [43, 140, 190]], [0.4, [65, 171, 93]], [0.6, [217, 210, 74]], [0.8, [217, 123, 41]], [1, [176, 48, 48]]];
  function ramp(t) {
    t = t < 0 ? 0 : t > 1 ? 1 : t;
    for (var i = 1; i < STOPS.length; i++) {
      if (t <= STOPS[i][0]) {
        var a = STOPS[i - 1], b = STOPS[i], f = (t - a[0]) / ((b[0] - a[0]) || 1);
        return [Math.round(a[1][0] + (b[1][0] - a[1][0]) * f), Math.round(a[1][1] + (b[1][1] - a[1][1]) * f), Math.round(a[1][2] + (b[1][2] - a[1][2]) * f)];
      }
    }
    return STOPS[STOPS.length - 1][1];
  }
  function colorFor(h) { var c = ramp((h - HM.yMin) / ((HM.yMax - HM.yMin) || 1)); return "rgb(" + c[0] + "," + c[1] + "," + c[2] + ")"; }

  WM.heightAt = function (x, z) {
    if (!HM) return null;
    var c = HM.cell, cx = Math.floor(x / c), cz = Math.floor(z / c);
    var hit = HM.cells[cx + "," + cz];
    if (hit) return hit[0];
    // inverse-distance-weighted over occupied cells within R rings; null if nothing near (unexplored)
    var R = 3, sw = 0, sv = 0;
    for (var dx = -R; dx <= R; dx++) for (var dz = -R; dz <= R; dz++) {
      var cc = HM.cells[(cx + dx) + "," + (cz + dz)]; if (!cc) continue;
      var d = Math.sqrt(dx * dx + dz * dz) || 0.5, w = 1 / (d * d);
      sw += w; sv += w * cc[0];
    }
    return sw > 0 ? sv / sw : null;
  };

  // a dedicated pane + canvas renderer BELOW the markers (overlayPane is 400) so the overlay never hides dots.
  function renderer() {
    if (WM._hmRenderer) return WM._hmRenderer;
    var pane = WM.map.getPane("heightmap") || WM.map.createPane("heightmap");
    pane.style.zIndex = 350; pane.style.pointerEvents = "none";
    WM._hmRenderer = L.canvas({ pane: "heightmap" });
    return WM._hmRenderer;
  }

  var TIER_OPACITY = { 4: 0.66, 3: 0.56, 2: 0.46, 1: 0.36 };   // brighter = firmer source: vehicle > foot > grid > heli
  function buildOverlay() {
    overlay = L.layerGroup();
    var c = HM.cell, r = renderer();
    for (var key in HM.cells) {
      if (!HM.cells.hasOwnProperty(key)) continue;
      var parts = key.split(","), cx = +parts[0], cz = +parts[1], cell = HM.cells[key];
      var a = WM.worldToLatLng(cx * c, cz * c), b = WM.worldToLatLng((cx + 1) * c, (cz + 1) * c);
      L.rectangle([[a.lat, a.lng], [b.lat, b.lng]], {
        stroke: false, fill: true, fillColor: colorFor(cell[0]), fillOpacity: TIER_OPACITY[cell[2]] || 0.6,
        interactive: false, renderer: r, pane: "heightmap",
      }).addTo(overlay);
    }
  }

  WM.setHeightmapVisible = function (on) {
    if (!HM) return;
    if (on) { if (!overlay) buildOverlay(); overlay.addTo(WM.map); }
    else if (overlay) WM.map.removeLayer(overlay);
  };

  WM.initHeightmap = function () {
    HM = window.MERCS_HEIGHTMAP || null;
    var sec = document.getElementById("hmSection"); if (sec) sec.hidden = !HM;
    if (!HM) return;
    var leg = document.getElementById("hmLegend");
    if (leg) {
      var g = STOPS.map(function (s) { return "rgb(" + s[1].join(",") + ") " + Math.round(s[0] * 100) + "%"; }).join(",");
      leg.innerHTML = "<div class='hm-bar' style='background:linear-gradient(90deg," + g + ")'></div>"
        + "<div class='hm-scale'><span>" + Math.round(HM.yMin) + "</span><span>height</span><span>" + Math.round(HM.yMax) + "</span></div>";
    }
    var info = document.getElementById("hmInfo");
    if (info) info.textContent = HM.n + " samples · " + HM.cellCount + " cells · " + HM.cell + "u grid · brighter = firmer source";
  };
})();
