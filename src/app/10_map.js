/* 10_map.js -- Leaflet CRS.Simple init + the world<->map coordinate transform.
 *
 * The map is a fixed game image, not the Earth, so CRS.Simple treats it as a plain plane: latLng is just
 * (y, x) in "map units". We define the image bounds as the logical 8204x8204 span and stretch the embedded
 * jpeg across it. The transform is the same edge-driven math missionforge.html uses (kept identical so the
 * two tools agree to the pixel), wrapped once as worldToLatLng so every marker placement goes through it. */
(function () {
  "use strict";
  var WM = window.WM, M = WM.MAP;

  // world (x,z) -> image pixel (px,py), py measured DOWN from the image's top-left. (missionforge's wToS)
  function worldToPixel(x, z) {
    var spanW = Math.abs(M.rightX - M.leftX) || 1, spanH = Math.abs(M.botZ - M.topZ) || 1;
    var px = (x - M.leftX) / (M.rightX - M.leftX) * spanW + (M.offX || 0);
    var py = (z - M.topZ) / (M.botZ - M.topZ) * spanH + (M.offZ || 0);
    return [px, py];
  }
  // With CRS.Simple bounds [[0,0],[H,W]], the image's TOP edge is at lat=H, so a top-down pixel (px,py)
  // becomes latLng(H - py, px). (Leaflet's lat increases upward; our py increases downward.)
  function worldToLatLng(x, z) { var p = worldToPixel(x, z); return L.latLng(M.H - p[1], p[0]); }

  // inverse (for the mouse-position readout): latLng -> world (x,z).
  function latLngToWorld(ll) {
    var spanW = Math.abs(M.rightX - M.leftX) || 1, spanH = Math.abs(M.botZ - M.topZ) || 1;
    var px = ll.lng, py = M.H - ll.lat;
    var x = (px - (M.offX || 0)) / spanW * (M.rightX - M.leftX) + M.leftX;
    var z = (py - (M.offZ || 0)) / spanH * (M.botZ - M.topZ) + M.topZ;
    return { x: x, z: z };
  }

  WM.worldToPixel = worldToPixel;
  WM.worldToLatLng = worldToLatLng;
  WM.latLngToWorld = latLngToWorld;

  WM.initMap = function () {
    var map = L.map("map", {
      crs: L.CRS.Simple,
      minZoom: -6, maxZoom: 3, zoomSnap: 0.25, wheelPxPerZoomLevel: 120,
      attributionControl: false, zoomControl: true,
      preferCanvas: true,   // render the ~100 markers + the moving player dot on one canvas -- much cheaper than SVG
    });
    WM.map = map;

    var bounds = [[0, 0], [M.H, M.W]];
    var img = window.MERCS_MAP_IMAGE;
    if (img) {
      L.imageOverlay(img, bounds).addTo(map);
    } else {
      // no embedded image (e.g. running straight off src without a build) -- still usable as a coordinate grid
      L.rectangle(bounds, { color: "#33362a", weight: 1, fill: false }).addTo(map);
    }
    map.fitBounds(bounds);
    map.setMaxBounds(L.latLngBounds(bounds).pad(0.35));

    var bar = document.getElementById("coordBar");
    map.on("mousemove", function (e) {
      if (!bar) return;
      var w = latLngToWorld(e.latlng);
      bar.textContent = "world   x " + Math.round(w.x) + "    z " + Math.round(w.z);
    });
    map.on("mouseout", function () { if (bar) bar.textContent = ""; });
    return map;
  };
})();
