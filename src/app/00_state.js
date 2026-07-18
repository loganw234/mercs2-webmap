/* 00_state.js -- the one shared namespace + the map calibration. Everything hangs off window.WM. */
(function (root) {
  "use strict";
  root.WM = root.WM || {
    map: null,
    datasets: [],        // [{ id, name, groups:{ key -> {layer,color,label,count,visible} } }]
    bridge: null,        // EssBridge when live-connected
    liveMarker: null,
    follow: false,
    pollTimer: null,

    // Map calibration -- VERBATIM from mercs2-tools/missionforge.html (confirmed pixel-perfect). The image is
    // an 8204x8204 top-down render; world (0,0) is its centre. Axes are edge-driven: leftX = world X at the
    // image's LEFT edge, topZ = world Z at the TOP edge. Game X runs west-positive (leftX=+4102) and Z is
    // north-up (topZ=+4102); offX/offZ are the fine 50px nudge. W/H are the LOGICAL map-unit span Leaflet's
    // CRS.Simple bounds use -- independent of how big the embedded jpeg actually is (it just gets stretched).
    MAP: { W: 8204, H: 8204, leftX: 4102, rightX: -4102, topZ: 4102, botZ: -4102, offX: -50, offZ: -50 },
  };
})(typeof self !== "undefined" ? self : this);
