/* 34_heightmap.js -- the height tensor: query + elevation/hillshade/contour overlay + profile tool.
 *
 * Data (window.MERCS_HEIGHTMAP, built by tools/build_heightmap.py) is a DENSE row-major Int16 grid
 * (base64-packed, height*10, -32768 = never sampled) plus a Uint8 source-tier plane. What it powers:
 *   * WM.heightAt(x,z)  -> ground height at any world point, bilinear over the 4 surrounding cell centres
 *                          (renormalised when some corners are unknown); IDW ring fallback near sparse
 *                          edges; null if nothing's close (honest "unknown").
 *   * WM.slopeAt(x,z)   -> terrain slope in degrees (central differences), null where unknown.
 *   * one canvas-painted L.imageOverlay (hypsometric tint x hillshade, optional contour lines, ocean tint)
 *     -- a single DOM node instead of one L.rectangle per cell, so a full 501x501 map pans smoothly.
 *   * a two-click elevation profile tool (WM.startProfile): pick A and B on the map, get a drawn
 *     cross-section with distance / min / max readouts. */
(function () {
  "use strict";
  var WM = window.WM;
  var HM = null;            // {cell, ox, oz, w, h, hts:Int16Array, tiers:Uint8Array, rampHi, bathyLo, ...}
  var overlay = null, dirty = true;
  var SHADE = true, CONTOURS = false, CONTOUR_STEP = 25;
  var SENTINEL = -32768;

  // SPLIT hypsometric ramp anchored at the coastline: below SEA_LEVEL = blue bathymetry, above = land colours
  // starting at GREEN immediately -- so near-sea-level cities/roads read as lowland, never as shallows.
  var SEA_LEVEL = -35;         // the game's actual water surface (NOT 0 -- exact 0 = unstreamed-geometry junk)
  var LAND_STOPS = [[0, [72, 142, 82]], [0.3, [140, 182, 74]], [0.55, [214, 202, 84]], [0.78, [212, 124, 46]], [1, [172, 50, 50]]];
  var BATHY_STOPS = [[0, [14, 38, 74]], [1, [66, 146, 196]]];   // deep -> shallow
  function rampOf(stops, t) {
    t = t < 0 ? 0 : t > 1 ? 1 : t;
    for (var i = 1; i < stops.length; i++) {
      if (t <= stops[i][0]) {
        var a = stops[i - 1], b = stops[i], f = (t - a[0]) / ((b[0] - a[0]) || 1);
        return [Math.round(a[1][0] + (b[1][0] - a[1][0]) * f), Math.round(a[1][1] + (b[1][1] - a[1][1]) * f), Math.round(a[1][2] + (b[1][2] - a[1][2]) * f)];
      }
    }
    return stops[stops.length - 1][1];
  }
  // hv in world units -> [r,g,b]; uses HM.rampHi (p98 of LAND heights) and HM.bathyLo (deepest seabed)
  function colorFor(hv) {
    if (hv <= SEA_LEVEL) return rampOf(BATHY_STOPS, (hv - HM.bathyLo) / ((SEA_LEVEL - HM.bathyLo) || 1));
    return rampOf(LAND_STOPS, (hv - SEA_LEVEL) / ((HM.rampHi - SEA_LEVEL) || 1));
  }

  function b64bytes(s) {
    var bin = atob(s), n = bin.length, u = new Uint8Array(n);
    for (var i = 0; i < n; i++) u[i] = bin.charCodeAt(i);
    return u;
  }

  // raw cell height in world units (cx,cz are CELL coords, i.e. floor(world/cell)); null = no data
  function cellH(cx, cz) {
    var ix = cx - HM.ox, iz = cz - HM.oz;
    if (ix < 0 || iz < 0 || ix >= HM.w || iz >= HM.h) return null;
    var q = HM.hts[iz * HM.w + ix];
    return q === SENTINEL ? null : q / 10;
  }

  WM.heightAt = function (x, z) {
    if (!HM) return null;
    var c = HM.cell;
    // bilinear over the 4 surrounding CELL CENTRES (centre of cell cx is (cx+0.5)*c)
    var fx = x / c - 0.5, fz = z / c - 0.5;
    var x0 = Math.floor(fx), z0 = Math.floor(fz), tx = fx - x0, tz = fz - z0;
    var h00 = cellH(x0, z0), h10 = cellH(x0 + 1, z0), h01 = cellH(x0, z0 + 1), h11 = cellH(x0 + 1, z0 + 1);
    var sw = 0, sv = 0;
    function acc(hv, wgt) { if (hv != null && wgt > 0) { sw += wgt; sv += hv * wgt; } }
    acc(h00, (1 - tx) * (1 - tz)); acc(h10, tx * (1 - tz)); acc(h01, (1 - tx) * tz); acc(h11, tx * tz);
    if (sw > 0.001) return sv / sw;                  // full or renormalised-partial bilinear
    // nothing adjacent -- inverse-distance over a few rings (sparse legacy-log areas), else honest null
    var cx = Math.floor(x / c), cz = Math.floor(z / c), R = 3;
    for (var dx = -R; dx <= R; dx++) for (var dz = -R; dz <= R; dz++) {
      var hh = cellH(cx + dx, cz + dz); if (hh == null) continue;
      var d = Math.sqrt(dx * dx + dz * dz) || 0.5, wgt = 1 / (d * d);
      sw += wgt; sv += wgt * hh;
    }
    return sw > 0 ? sv / sw : null;
  };

  // terrain slope in degrees at a world point (central differences over neighbouring cells); null = unknown
  WM.slopeAt = function (x, z) {
    if (!HM) return null;
    var c = HM.cell, cx = Math.floor(x / c), cz = Math.floor(z / c);
    var l = cellH(cx - 1, cz), r = cellH(cx + 1, cz), u = cellH(cx, cz - 1), d = cellH(cx, cz + 1);
    if (l == null || r == null || u == null || d == null) return null;
    var gx = (r - l) / (2 * c), gz = (d - u) / (2 * c);
    return Math.atan(Math.sqrt(gx * gx + gz * gz)) * 180 / Math.PI;
  };

  /* ---- overlay: paint the whole tensor once into an offscreen canvas, ship it as ONE imageOverlay ---- */

  function shadeAt(i, ix, iz) {
    // Horn hillshade, sun from the NW at 45 deg altitude. Missing neighbours fall back to the centre cell.
    var w = HM.w, hts = HM.hts, c0 = hts[i];
    function g(dx, dz) {
      var jx = ix + dx, jz = iz + dz;
      if (jx < 0 || jz < 0 || jx >= w || jz >= HM.h) return c0;
      var q = hts[jz * w + jx]; return q === SENTINEL ? c0 : q;
    }
    var cell10 = HM.cell * 10;   // heights are *10, so distances scale the same
    var dzdx = ((g(1, -1) + 2 * g(1, 0) + g(1, 1)) - (g(-1, -1) + 2 * g(-1, 0) + g(-1, 1))) / (8 * cell10);
    var dzdz = ((g(-1, 1) + 2 * g(0, 1) + g(1, 1)) - (g(-1, -1) + 2 * g(0, -1) + g(1, -1))) / (8 * cell10);
    var slope = Math.atan(1.6 * Math.sqrt(dzdx * dzdx + dzdz * dzdz));   // 1.6 = vertical exaggeration
    var aspect = Math.atan2(dzdz, -dzdx);
    var az = 315 * Math.PI / 180, altR = 45 * Math.PI / 180;
    var s = Math.cos(altR) * Math.cos(slope) + Math.sin(altR) * Math.sin(slope) * Math.cos(az - aspect);
    return s < 0 ? 0 : s;
  }

  function paint() {
    var w = HM.w, h = HM.h, hts = HM.hts;
    var cv = document.createElement("canvas"); cv.width = w; cv.height = h;
    var ctx = cv.getContext("2d"), img = ctx.createImageData(w, h), px = img.data;
    var step10 = CONTOUR_STEP * 10;
    for (var iz = 0; iz < h; iz++) {
      // world +z = image TOP and world +x = image LEFT (game X runs west-positive), so flip both axes
      var row = h - 1 - iz;
      for (var ix = 0; ix < w; ix++) {
        var i = iz * w + ix, q = hts[i];
        var p = (row * w + (w - 1 - ix)) * 4;
        var alpha = 208, interp = false;
        if (q === SENTINEL) {
          // sparse legacy logs (32u scans, road traces) fill isolated cells of the 16u grid, which renders as
          // dot/dash artifacting -- so bridge small holes from neighbours (2-cell reach), translucent so
          // interpolated fill is visibly softer than scanned truth. Big unscanned areas stay transparent.
          var sww = 0, svv = 0, nn = 0;
          for (var dz2 = -2; dz2 <= 2; dz2++) for (var dx2 = -2; dx2 <= 2; dx2++) {
            var jx = ix + dx2, jz = iz + dz2;
            if (jx < 0 || jz < 0 || jx >= w || jz >= h) continue;
            var qq = hts[jz * w + jx]; if (qq === SENTINEL) continue;
            var wgt = 1 / (dx2 * dx2 + dz2 * dz2);
            sww += wgt; svv += qq * wgt; nn++;
          }
          if (nn < 3) { px[p + 3] = 0; continue; }
          q = svv / sww;
          alpha = 150;
          interp = true;
        }
        var hv = q / 10, col = colorFor(hv);   // split ramp: bathymetry below SEA_LEVEL, green-up land above
        // interpolated cells get flat shading + no contours: their raw slot is still SENTINEL, so the
        // neighbour-difference math of hillshade/contours would produce garbage there
        var sh = (SHADE && !interp) ? 0.35 + 0.75 * shadeAt(i, ix, iz) : 1;
        var r = col[0] * sh, g = col[1] * sh, b = col[2] * sh;
        if (CONTOURS && !interp) {
          // contour where the height band changes vs the +x or +z neighbour (index lines every 4th darker)
          var qr = ix + 1 < w ? hts[i + 1] : q, qd = iz + 1 < h ? hts[i + w] : q;
          if (qr === SENTINEL) qr = q; if (qd === SENTINEL) qd = q;
          var band = Math.floor(q / step10);
          if (band !== Math.floor(qr / step10) || band !== Math.floor(qd / step10)) {
            var f = (band % 4 === 0) ? 0.35 : 0.6;
            r *= f; g *= f; b *= f; alpha = 235;
          }
        }
        px[p] = r > 255 ? 255 : r; px[p + 1] = g > 255 ? 255 : g; px[p + 2] = b > 255 ? 255 : b; px[p + 3] = alpha;
      }
    }
    ctx.putImageData(img, 0, 0);
    return cv;
  }

  function gridBounds() {
    var c = HM.cell;
    var a = WM.worldToLatLng(HM.ox * c, HM.oz * c);
    var b = WM.worldToLatLng((HM.ox + HM.w) * c, (HM.oz + HM.h) * c);
    return L.latLngBounds([a, b]);
  }

  function rebuild() {
    var pane = WM.map.getPane("heightmap") || WM.map.createPane("heightmap");
    pane.style.zIndex = 350; pane.style.pointerEvents = "none";
    var url = paint().toDataURL("image/png");
    if (overlay) overlay.setUrl(url);
    else overlay = L.imageOverlay(url, gridBounds(), { pane: "heightmap", opacity: 1, interactive: false });
    dirty = false;
  }

  WM.setHeightmapVisible = function (on) {
    if (!HM) return;
    if (on) { if (!overlay || dirty) rebuild(); overlay.addTo(WM.map); }
    else if (overlay) WM.map.removeLayer(overlay);
  };
  WM.setHillshade = function (on) { SHADE = !!on; dirty = true; if (overlay && WM.map.hasLayer(overlay)) rebuild(); };
  WM.setContours = function (on) { CONTOURS = !!on; dirty = true; if (overlay && WM.map.hasLayer(overlay)) rebuild(); };

  /* ---- LZ finder: highlight flat, dry, scanned ground (heli landing / base spots) ---- */

  var lzOverlay = null, LZ_MAX_SLOPE = 8;   // degrees
  function paintLZ() {
    var w = HM.w, h = HM.h, c = HM.cell;
    var cv = document.createElement("canvas"); cv.width = w; cv.height = h;
    var ctx = cv.getContext("2d"), img = ctx.createImageData(w, h), px = img.data;
    var maxG = Math.tan(LZ_MAX_SLOPE * Math.PI / 180);
    for (var iz = 0; iz < h; iz++) {
      var row = h - 1 - iz;
      for (var ix = 0; ix < w; ix++) {
        var q = HM.hts[iz * w + ix];
        if (q === SENTINEL || q / 10 <= SEA_LEVEL + 0.5) continue;   // unknown or wet -> transparent
        // central-difference slope; all 4 neighbours must be known (no guessing at LZs)
        var l = cellH(HM.ox + ix - 1, HM.oz + iz), r = cellH(HM.ox + ix + 1, HM.oz + iz);
        var u = cellH(HM.ox + ix, HM.oz + iz - 1), d = cellH(HM.ox + ix, HM.oz + iz + 1);
        if (l == null || r == null || u == null || d == null) continue;
        var gx = (r - l) / (2 * c), gz = (d - u) / (2 * c);
        if (Math.sqrt(gx * gx + gz * gz) > maxG) continue;
        var p = (row * w + (w - 1 - ix)) * 4;
        px[p] = 80; px[p + 1] = 230; px[p + 2] = 120; px[p + 3] = 135;
      }
    }
    ctx.putImageData(img, 0, 0);
    return cv;
  }
  WM.setLZVisible = function (on) {
    if (!HM) return;
    if (on) {
      if (!lzOverlay) {
        var pane = WM.map.getPane("heightmap") || WM.map.createPane("heightmap");
        pane.style.zIndex = 350; pane.style.pointerEvents = "none";
        lzOverlay = L.imageOverlay(paintLZ().toDataURL("image/png"), gridBounds(), { pane: "heightmap", interactive: false });
      }
      lzOverlay.addTo(WM.map);
    } else if (lzOverlay) WM.map.removeLayer(lzOverlay);
  };

  /* ---- elevation profile: click A, click B, get the cross-section ---- */

  var prof = null;   // {a:{x,z}|null, line:L.polyline|null, onClick, onKey}
  function profCleanup() {
    if (!prof) return;
    WM.map.off("click", prof.onClick);
    if (prof.trackB) WM.map.off("mousemove", prof.trackB);
    document.removeEventListener("keydown", prof.onKey);
    if (prof.line) WM.map.removeLayer(prof.line);
    var el = WM.map.getContainer(); el.style.cursor = "";
    var bar = document.getElementById("coordBar"); if (bar && bar.dataset.prof) { bar.textContent = ""; delete bar.dataset.prof; }
    prof = null;
  }
  function profHint(msg) {
    var bar = document.getElementById("coordBar");
    if (bar) { bar.textContent = msg; bar.dataset.prof = "1"; }
  }

  WM.startProfile = function () {
    if (!HM) return;
    profCleanup();
    prof = { a: null, line: null };
    WM.map.getContainer().style.cursor = "crosshair";
    profHint("PROFILE: click the START point (Esc cancels)");
    prof.onKey = function (e) { if (e.key === "Escape") profCleanup(); };
    prof.onClick = function (e) {
      var wpt = WM.latLngToWorld(e.latlng);
      if (!prof.a) {
        prof.a = wpt;
        prof.line = L.polyline([e.latlng, e.latlng], { color: "#e8e13a", weight: 2, dashArray: "6 4", interactive: false }).addTo(WM.map);
        prof.trackB = trackB;
        WM.map.on("mousemove", trackB);
        profHint("PROFILE: click the END point (Esc cancels)");
        return;
      }
      var a = prof.a, b = wpt;
      profCleanup();
      showProfile(a, b);
    };
    function trackB(e) { if (prof && prof.line && prof.a) prof.line.setLatLngs([WM.worldToLatLng(prof.a.x, prof.a.z), e.latlng]); }
    WM.map.on("click", prof.onClick);
    document.addEventListener("keydown", prof.onKey);
  };

  function showProfile(a, b) {
    var dist = Math.sqrt((b.x - a.x) * (b.x - a.x) + (b.z - a.z) * (b.z - a.z));
    var N = Math.max(2, Math.min(440, Math.round(dist / (HM.cell / 2))));
    var hs = [], lo = Infinity, hi = -Infinity, known = 0;
    for (var i = 0; i <= N; i++) {
      var t = i / N, hh = WM.heightAt(a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t);
      hs.push(hh);
      if (hh != null) { known++; if (hh < lo) lo = hh; if (hh > hi) hi = hh; }
    }
    if (!known) { WM.confirmModal("<h3>Elevation profile</h3><p>No height data along that line yet — scan it first.</p>", { okText: "OK" }); return; }
    if (lo > SEA_LEVEL) lo = SEA_LEVEL; if (hi < SEA_LEVEL) hi = SEA_LEVEL;   // always show sea level for context
    var pad = (hi - lo) * 0.08 + 1; lo -= pad; hi += pad;
    // line of sight: standing eye height at both ends; blocked where terrain rises above the straight sight line
    var EYE = 1.8, eyeA = hs[0] != null ? hs[0] + EYE : null, eyeB = hs[N] != null ? hs[N] + EYE : null;
    var losBlockI = -1;
    if (eyeA != null && eyeB != null) {
      for (var li = 1; li < N; li++) {
        if (hs[li] != null && hs[li] > eyeA + (eyeB - eyeA) * (li / N)) { losBlockI = li; break; }
      }
    }
    var losMsg = (eyeA == null || eyeB == null) ? ""
      : (losBlockI < 0 ? " · <b style='color:#7ed87e'>LOS clear</b>"
        : " · <b style='color:#e08a5a'>LOS blocked</b> at " + Math.round(dist * losBlockI / N) + "u");
    WM.confirmModal(
      "<h3>Elevation profile</h3>"
      + "<canvas id='profCanvas' width='440' height='170' style='width:100%;border:1px solid var(--line);border-radius:6px;background:#0c0d09'></canvas>"
      + "<p class='hint'>" + Math.round(dist) + "u from (" + Math.round(a.x) + ", " + Math.round(a.z) + ") to ("
      + Math.round(b.x) + ", " + Math.round(b.z) + ") · low " + (lo + pad).toFixed(1) + " · high " + (hi - pad).toFixed(1) + losMsg + "</p>",
      { okText: "Done", cancelText: "Again", onCancel: function () { WM.startProfile(); } });
    var cv = document.getElementById("profCanvas"); if (!cv) return;
    var ctx = cv.getContext("2d"), W = cv.width, H = cv.height;
    function yFor(hh) { return H - (hh - lo) / (hi - lo) * H; }
    // sea level line (the game's water surface sits at ~-35, not 0)
    ctx.strokeStyle = "rgba(90,150,200,0.55)"; ctx.setLineDash([4, 4]); ctx.beginPath();
    ctx.moveTo(0, yFor(SEA_LEVEL)); ctx.lineTo(W, yFor(SEA_LEVEL)); ctx.stroke(); ctx.setLineDash([]);
    // filled terrain cross-section (gaps where unscanned)
    ctx.fillStyle = "rgba(120,170,80,0.35)"; ctx.strokeStyle = "#a4d060"; ctx.lineWidth = 1.5;
    var run = null;
    function flush(endI) {
      if (run == null) return;
      ctx.beginPath();
      for (var j = run; j < endI; j++) { var xx = j / N * W, yy = yFor(hs[j]); if (j === run) ctx.moveTo(xx, yy); else ctx.lineTo(xx, yy); }
      ctx.stroke();
      ctx.lineTo((endI - 1) / N * W, H); ctx.lineTo(run / N * W, H); ctx.closePath(); ctx.fill();
      run = null;
    }
    for (var i2 = 0; i2 <= N; i2++) {
      if (hs[i2] == null) flush(i2);
      else if (run == null) run = i2;
    }
    flush(N + 1);
    // sight line (A eye -> B eye), with the first blocking point marked
    if (eyeA != null && eyeB != null) {
      ctx.strokeStyle = losBlockI < 0 ? "rgba(160,220,160,0.7)" : "rgba(230,150,100,0.7)";
      ctx.setLineDash([2, 3]); ctx.beginPath();
      ctx.moveTo(0, yFor(eyeA)); ctx.lineTo(W, yFor(eyeB)); ctx.stroke(); ctx.setLineDash([]);
      if (losBlockI >= 0) {
        var bx = losBlockI / N * W, by = yFor(hs[losBlockI]);
        ctx.strokeStyle = "#e08a5a"; ctx.lineWidth = 1.5; ctx.beginPath();
        ctx.moveTo(bx - 4, by - 4); ctx.lineTo(bx + 4, by + 4); ctx.moveTo(bx + 4, by - 4); ctx.lineTo(bx - 4, by + 4); ctx.stroke();
      }
    }
    // endpoint heights
    ctx.fillStyle = "#d8dcc8"; ctx.font = "11px monospace";
    var hA = hs[0], hB = hs[N];
    if (hA != null) ctx.fillText("A " + hA.toFixed(1), 5, Math.max(12, yFor(hA) - 5));
    if (hB != null) { var t2 = "B " + hB.toFixed(1); ctx.fillText(t2, W - ctx.measureText(t2).width - 5, Math.max(12, yFor(hB) - 5)); }
  }

  /* ---- init ---- */

  WM.initHeightmap = function () {
    var raw = window.MERCS_HEIGHTMAP || null;
    var sec = document.getElementById("hmSection"); if (sec) sec.hidden = !raw;
    if (!raw) return;
    HM = raw;
    HM.hts = new Int16Array(b64bytes(raw.heightsB64).buffer);
    HM.tiers = b64bytes(raw.tiersB64);
    // ramp anchors: LAND colours span SEA_LEVEL..p98 of land heights (so peaks don't wash out the lowlands);
    // bathymetry spans the deepest scanned seabed..SEA_LEVEL.
    var land = [], deep = raw.yMin;
    for (var i = 0; i < HM.hts.length; i++) {
      var q = HM.hts[i]; if (q === SENTINEL) continue;
      var hv2 = q / 10;
      if (hv2 > SEA_LEVEL) land.push(hv2); else if (hv2 < deep) deep = hv2;
    }
    land.sort(function (a, b) { return a - b; });
    HM.rampHi = land.length ? land[Math.floor(land.length * 0.98)] : raw.yMax;
    HM.bathyLo = deep;
    var leg = document.getElementById("hmLegend");
    if (leg) {
      // legend: a small bathy chip, then the land gradient from the -35 coastline up
      var g = LAND_STOPS.map(function (s) { return "rgb(" + s[1].join(",") + ") " + Math.round(s[0] * 100) + "%"; }).join(",");
      var bg = BATHY_STOPS.map(function (s) { return "rgb(" + s[1].join(",") + ") " + Math.round(s[0] * 100) + "%"; }).join(",");
      leg.innerHTML = "<div style='display:flex;gap:2px'>"
        + "<div class='hm-bar' style='flex:0 0 22%;background:linear-gradient(90deg," + bg + ")'></div>"
        + "<div class='hm-bar' style='flex:1;background:linear-gradient(90deg," + g + ")'></div></div>"
        + "<div class='hm-scale'><span>" + Math.round(HM.bathyLo) + "</span><span>sea " + SEA_LEVEL + "</span><span>" + Math.round(HM.rampHi) + "</span></div>";
    }
    var info = document.getElementById("hmInfo");
    if (info) {
      var cov = Math.round(100 * HM.cellCount / (HM.w * HM.h));
      info.textContent = HM.n + " samples · " + HM.w + "×" + HM.h + " @ " + HM.cell + "u (" + cov + "% scanned)";
    }
  };
})();
